import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/providers.dart';
import 'charts.dart';
import 'hosts.dart';
import 'projects_page.dart';
import 'widgets.dart';

/// The front page: what is running now, where, at what load and cost.
class OverviewPage extends ConsumerWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(clockProvider);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 1100;
    final hosts = ref.watch(allStatusProvider).value ?? const <String, HostStatus>{};
    final devstations = ref.watch(devstationsProvider).value ?? const <Devstation>[];
    final known = {for (final d in devstations) 'devstation-${d.id}'};
    final shownHosts = orderedHosts(hosts).where((e) => !e.key.startsWith('devstation-') || known.contains(e.key)).toList();

    Widget pair(Widget a, Widget b, {int fa = 3, int fb = 2}) => wide
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: fa, child: a),
              const SizedBox(width: 16),
              Expanded(flex: fb, child: b),
            ],
          )
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [a, const SizedBox(height: 16), b]);

    return PageScroll(
      children: [
        const _Greeting(),
        const _Kpis(),
        const SizedBox(height: 22),
        _SectionLabel(
          'Hosts',
          trailing: Text('CPU, memory and disk as each worker last reported', style: Theme.of(context).textTheme.labelSmall),
        ),
        if (!ref.watch(allStatusProvider).hasValue && !ref.watch(allStatusProvider).hasError)
          const Card(
            child: Padding(padding: EdgeInsets.all(18), child: LinearProgressIndicator(minHeight: 2)),
          )
        else
          VaResponsiveGrid(
            minWidth: 300,
            maxColumns: 4,
            children: [for (final e in shownHosts) HostCard(id: e.key, status: e.value)],
          ),
        const SizedBox(height: 22),
        pair(const ActivityPanel(), const ActiveTasksPanel()),
        const SizedBox(height: 16),
        pair(const UsagePanel(), const AccountsPanel()),
        const SizedBox(height: 16),
        pair(const SpendPanel(), const ProjectsSummaryPanel()),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label, {this.trailing});
  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 10,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleSmall),
        ?trailing,
      ],
    ),
  );
}

class _Greeting extends ConsumerWidget {
  const _Greeting();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final mac = ref.watch(macStatusProvider).value;
    final approvals = (ref.watch(approvalsProvider).value ?? const <Approval>[]).where((a) => a.status == 'pending').length;
    final user = ref.watch(authStateProvider).value;
    final on = macIsOn(mac, now);
    final h = now.hour;
    final hello = h < 5
        ? 'Working late'
        : h < 12
        ? 'Good morning'
        : h < 18
        ? 'Good afternoon'
        : 'Good evening';
    final name = (user?.displayName ?? '').split(' ').first;
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return PageTitle(
      title: name.isEmpty ? hello : '$hello, $name',
      subtitle: '${days[now.weekday - 1]}, ${now.day} ${months[now.month - 1]}',
      trailing: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (ref.watch(macStatusProvider).hasValue)
            VaStatusPill(label: on ? 'Agents on the Mac' : 'Agents in the cloud', color: on ? VaColors.success : VaColors.info),
          if (approvals > 0)
            ActionChip(
              avatar: Icon(Icons.gavel, size: 16, color: VaColors.warning),
              label: Text('$approvals approval${approvals == 1 ? '' : 's'} waiting'),
              onPressed: () => ref.read(pageProvider.notifier).go(ConsolePage.system),
            ),
        ],
      ),
    );
  }
}

/// A headline number with context.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.sub, this.icon, this.child, this.accent});
  final String label;
  final String value;
  final String? sub;
  final IconData? icon;
  final Widget? child;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 138),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (icon != null) ...[Icon(icon, size: 16, color: accent ?? VaColors.muted), const SizedBox(width: 6)],
                  Expanded(
                    child: Text(
                      label,
                      style: text.labelMedium?.copyWith(color: VaColors.muted),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                value,
                style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600, fontFamily: VaType.mono, letterSpacing: -.5),
              ),
              if (sub != null) ...[
                const SizedBox(height: 2),
                Text(sub!, style: text.labelSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
              if (child != null) ...[const SizedBox(height: 10), child!],
            ],
          ),
        ),
      ),
    );
  }
}

class _Kpis extends ConsumerWidget {
  const _Kpis();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final active = ref.watch(activeMessagesProvider).value ?? const <ChatMessage>[];
    final running = active.where((m) => m.status == MessageStatus.running).length;
    final queued = active.length - running;
    final factory = (ref.watch(factoryRequestsProvider).value ?? const <FactoryRequest>[])
        .where((r) => r.status == 'queued' || r.status == 'running')
        .length;
    final days = ref.watch(usageDaysProvider).value ?? const <UsageDay>[];
    final stats = ref.watch(usageStatsProvider).value;
    final billing = ref.watch(billingProvider).value;
    final today = operatorDay(now);
    final todayStats = days.where((d) => d.day == today).firstOrNull;
    final month = today.substring(0, 7);
    final monthCost = days.where((d) => d.day.startsWith(month)).fold<double>(0, (a, d) => a + d.costUsd);
    final series = lastDays(days, now, 14);
    const target = 15.0;
    bool ready(AsyncValue<Object?> v) => v.hasValue;
    final liveReady = ready(ref.watch(activeMessagesProvider));
    final daysReady = ready(ref.watch(usageDaysProvider)) && ready(ref.watch(usageStatsProvider));
    final billingReady = ready(ref.watch(billingProvider));
    const loading = 'Loading…';
    return VaResponsiveGrid(
      minWidth: 165,
      maxColumns: 4,
      children: [
        StatTile(
          label: 'Live now',
          icon: Icons.bolt,
          accent: running > 0 ? VaColors.info : null,
          value: liveReady ? '$running' : '—',
          sub: !liveReady
              ? loading
              : [
                  '$running answering',
                  '$queued queued',
                  if (factory > 0) '$factory Factory job${factory == 1 ? '' : 's'}',
                ].join(' · '),
        ),
        StatTile(
          label: 'Chat turns today',
          icon: Icons.forum_outlined,
          value: daysReady ? '${todayStats?.turns ?? 0}' : '—',
          sub: !daysReady ? loading : '${todayStats?.failed ?? 0} failed · ${compact(todayStats?.outputTokens ?? 0)} tokens out',
          child: !daysReady ? null : Sparkline(values: [for (final d in series) d.turns.toDouble()], height: 28),
        ),
        StatTile(
          label: 'Chat cost this month',
          icon: Icons.toll_outlined,
          value: daysReady ? usd(monthCost) : '—',
          sub: !daysReady ? loading : 'API-equivalent (subscription) · ${usd(stats?.costUsd ?? 0)} all time',
          child: !daysReady ? null : Sparkline(values: [for (final d in series) d.costUsd], height: 28, color: VaColors.series[2]),
        ),
        StatTile(
          label: 'GCP spend this month',
          icon: Icons.cloud_outlined,
          value: billing == null ? '—' : money(billing.costAmount, billing.currencyCode),
          sub: !billingReady
              ? loading
              : billing == null
              ? 'Waiting for the budget’s first report (a few times a day)'
              : 'Target S\$${target.toStringAsFixed(0)} · budget ${money(billing.budgetAmount, billing.currencyCode)} · ${ago(billing.updatedAt)}',
          child: billing == null ? null : VaMeter(value: billing.costAmount / target, warnAt: .66, badAt: 1),
        ),
      ],
    );
  }
}

/// The last [n] operator days, oldest first, with empty days filled in.
List<UsageDay> lastDays(List<UsageDay> days, DateTime now, int n) {
  final byDay = {for (final d in days) d.day: d};
  return [
    for (var i = n - 1; i >= 0; i--)
      byDay[operatorDay(now.subtract(Duration(days: i)))] ?? UsageDay(day: operatorDay(now.subtract(Duration(days: i)))),
  ];
}

/// What is happening right now: turns being answered, Factory jobs,
/// approvals waiting.
class ActivityPanel extends ConsumerWidget {
  const ActivityPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final threads = {for (final th in ref.watch(threadsProvider).value ?? const <ChatThread>[]) th.id: th};
    final factory = (ref.watch(factoryRequestsProvider).value ?? const <FactoryRequest>[])
        .where((r) => r.status == 'queued' || r.status == 'running')
        .toList();
    final approvals = (ref.watch(approvalsProvider).value ?? const <Approval>[]).where((a) => a.status == 'pending').toList();
    final repo = ref.read(repositoryProvider);
    return VaPanel(
      title: 'Activity',
      subtitle: 'Live: turns, Factory jobs and approvals',
      icon: Icons.timeline,
      child: VaAsyncView(
        value: ref.watch(activeMessagesProvider),
        data: (active) {
          if (active.isEmpty && factory.isEmpty && approvals.isEmpty) {
            return const VaEmptyNote('Nothing running. The agents are idle.', icon: Icons.nightlight_outlined);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final a in approvals)
                _ActivityRow(
                  leading: Icon(Icons.gavel, size: 18, color: VaColors.warning),
                  title: '${a.requestedBy} asks: ${a.action}',
                  subtitle: '${a.details} · ${ago(a.createdAt)}',
                  trailing: repo == null
                      ? null
                      : Wrap(
                          spacing: 4,
                          children: [
                            TextButton(
                              onPressed: () => guarded(context, () => repo.decide(a.id, approve: false)),
                              child: const Text('Reject'),
                            ),
                            FilledButton.tonal(
                              onPressed: () => guarded(context, () => repo.decide(a.id, approve: true)),
                              child: const Text('Approve'),
                            ),
                          ],
                        ),
                ),
              for (final m in active)
                _ActivityRow(
                  leading: AgentAvatar(agent: threads[m.threadId]?.agent ?? 'genie', size: 24),
                  title: threads[m.threadId]?.title ?? 'Conversation',
                  subtitle: [
                    agentLabel(threads[m.threadId]?.agent ?? 'genie'),
                    if (m.status == MessageStatus.running)
                      '${m.activity ?? ((m.partial ?? '').isEmpty ? 'thinking' : 'writing')} on the ${m.claimedBy ?? 'worker'}'
                    else
                      'queued',
                    if (m.kind == 'close') 'closing',
                    ago(m.createdAt),
                  ].join(' · '),
                  live: m.status == MessageStatus.running,
                  onTap: () => openChat(ref, threadId: m.threadId),
                ),
              for (final r in factory)
                _ActivityRow(
                  leading: Icon(Icons.precision_manufacturing_outlined, size: 18, color: VaColors.info),
                  title: 'Factory: ${r.action} ${r.devstationId}',
                  subtitle: '${r.status} · ${ago(r.createdAt)}',
                  live: r.status == 'running',
                  onTap: () => ref.read(pageProvider.notifier).go(ConsolePage.projects),
                ),
              if (active.isNotEmpty || factory.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Tap a turn to open its conversation.', style: text.labelSmall),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.leading,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
    this.live = false,
  });
  final Widget leading;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                  ),
                  Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.labelSmall),
                ],
              ),
            ),
            if (live)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: VaStatusDot(color: VaColors.info, pulse: true),
              ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// Agent sessions in use, most recent first.
class ActiveTasksPanel extends ConsumerWidget {
  const ActiveTasksPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final threads = {for (final th in ref.watch(threadsProvider).value ?? const <ChatThread>[]) th.id: th};
    return VaPanel(
      title: 'Active tasks',
      subtitle: 'Open agent sessions and their context',
      icon: Icons.task_alt,
      child: VaAsyncView(
        value: ref.watch(meshProvider),
        data: (mesh) {
          final active = [...?mesh?.sessions.where((s) => s.status == 'active')]
            ..sort((a, b) => (b.lastUsedAt ?? DateTime(0)).compareTo(a.lastUsedAt ?? DateTime(0)));
          if (active.isEmpty) return const VaEmptyNote('No open sessions.', icon: Icons.task_alt);
          return Column(
            children: [
              for (final s in active.take(8))
                Builder(
                  builder: (context) {
                    final threadId = s.taskId.startsWith('console-') ? s.taskId.substring(8) : null;
                    final title = threadId == null ? s.taskId : threads[threadId]?.title ?? s.taskId;
                    return InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: threadId == null || !threads.containsKey(threadId) ? null : () => openChat(ref, threadId: threadId),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                        child: Row(
                          children: [
                            AgentAvatar(agent: s.agent, size: 24),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                                  ),
                                  Text(
                                    '${agentLabel(s.agent)} · ${s.turns} turn${s.turns == 1 ? '' : 's'} · ${compact(s.contextTokens)} context'
                                    '${s.costUsd > 0 ? ' · ${usd(s.costUsd)}' : ''} · ${ago(s.lastUsedAt)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: text.labelSmall,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              if (active.length > 8)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('and ${active.length - 8} more (System page)', style: text.labelSmall),
                ),
            ],
          );
        },
      ),
    );
  }
}

enum _Metric { turns, cost, tokens }

/// Chat turns per day, by agent.
class UsagePanel extends ConsumerStatefulWidget {
  const UsagePanel({super.key});

  @override
  ConsumerState<UsagePanel> createState() => _UsagePanelState();
}

class _UsagePanelState extends ConsumerState<UsagePanel> {
  _Metric _metric = _Metric.turns;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final now = DateTime.now();
    final stats = ref.watch(usageStatsProvider).value;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    String label(String day) => '${int.parse(day.substring(8))} ${months[int.parse(day.substring(5, 7)) - 1]}';
    return VaPanel(
      title: 'Chat usage',
      subtitle: 'Last 14 days (Singapore time)',
      icon: Icons.bar_chart,
      trailing: SegmentedButton<_Metric>(
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact, textStyle: text.labelSmall),
        segments: const [
          ButtonSegment(value: _Metric.turns, label: Text('Turns')),
          ButtonSegment(value: _Metric.cost, label: Text('Cost')),
          ButtonSegment(value: _Metric.tokens, label: Text('Tokens')),
        ],
        selected: {_metric},
        onSelectionChanged: (s) => setState(() => _metric = s.first),
      ),
      child: VaAsyncView(
        value: ref.watch(usageDaysProvider),
        data: (days) {
          final series = lastDays(days, now, 14);
          final bars = [
            for (final d in series)
              (
                label: label(d.day),
                value: switch (_metric) {
                  _Metric.turns => d.turns.toDouble(),
                  _Metric.cost => d.costUsd,
                  _Metric.tokens => d.outputTokens.toDouble(),
                },
                detail:
                    '${label(d.day)} · ${d.turns} turns · ${usd(d.costUsd)} · ${compact(d.outputTokens)} tokens'
                    '${d.failed > 0 ? ' · ${d.failed} failed' : ''}',
              ),
          ];
          final agents = (stats?.byAgent.entries.toList() ?? [])..sort((a, b) => b.value.turns.compareTo(a.value.turns));
          final total = agents.fold<int>(0, (a, e) => a + e.value.turns);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (series.every((d) => d.turns == 0 && d.failed == 0))
                const VaEmptyNote('No chat turns in the last 14 days.', icon: Icons.bar_chart)
              else
                BarChart(
                  bars: bars,
                  color: _metric == _Metric.cost
                      ? VaColors.series[2]
                      : _metric == _Metric.tokens
                      ? VaColors.series[1]
                      : null,
                  format: (v) => switch (_metric) {
                    _Metric.turns => '${v.round()} turns',
                    _Metric.cost => usd(v),
                    _Metric.tokens => '${compact(v.round())} tokens',
                  },
                ),
              if (agents.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text('All time, by agent', style: text.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                for (final e in agents.take(6))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        AgentAvatar(agent: e.key, size: 18),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 110,
                          child: Text(agentLabel(e.key), style: text.bodySmall, overflow: TextOverflow.ellipsis),
                        ),
                        Expanded(
                          child: VaMeter(value: total == 0 ? 0 : e.value.turns / total, color: agentColor(context, e.key)),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 110,
                          child: Text(
                            '${e.value.turns} · ${usd(e.value.costUsd)}',
                            textAlign: TextAlign.right,
                            style: text.labelSmall?.copyWith(fontFamily: VaType.mono),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Claude subscription usage per account.
class AccountsPanel extends ConsumerWidget {
  const AccountsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final now = DateTime.now();
    final stats = ref.watch(usageStatsProvider).value;
    return VaPanel(
      title: 'Claude accounts',
      subtitle: '5-hour and weekly limits, as Claude Code last reported',
      icon: Icons.account_circle_outlined,
      child: VaAsyncView(
        value: ref.watch(meshProvider),
        data: (mesh) {
          final accounts = mesh?.accounts ?? const <AccountView>[];
          if (accounts.isEmpty) {
            return const VaEmptyNote('No account registered. Register one with `va_agent accounts add <id>`.');
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final a in accounts) ...[
                Row(
                  children: [
                    Text(a.label, style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    if (a.limitedUntil != null && a.limitedUntil!.isAfter(now))
                      VaStatusPill(label: 'Limited', color: VaColors.danger, dense: true),
                    const Spacer(),
                    if (stats?.byAccount[a.id] != null)
                      Text('${stats!.byAccount[a.id]!.turns} chat turns', style: text.labelSmall),
                  ],
                ),
                const SizedBox(height: 8),
                _Window(label: '5 hours', usage: a.fiveHour),
                _Window(label: '7 days', usage: a.sevenDay),
                const SizedBox(height: 10),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Window extends StatelessWidget {
  const _Window({required this.label, required this.usage});
  final String label;
  final UsageView? usage;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final u = usage;
    final reset = u?.resetsAt == null
        ? ''
        : ' · resets ${u!.resetsAt!.difference(DateTime.now()).inHours >= 24 ? '${u.resetsAt!.toLocal().day}/${u.resetsAt!.toLocal().month}' : clockTime(context, u.resetsAt!)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(label, style: text.labelSmall),
              const Spacer(),
              Text(u == null ? 'not reported yet' : '${pct(u.utilization)}$reset', style: text.labelSmall),
            ],
          ),
          const SizedBox(height: 4),
          VaMeter(value: u?.utilization),
        ],
      ),
    );
  }
}

/// GCP spend this month against the target and the budget.
class SpendPanel extends ConsumerWidget {
  const SpendPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    return VaPanel(
      title: 'GCP spend',
      subtitle: 'Month to date, from the Vral Altos budget',
      icon: Icons.payments_outlined,
      trailing: TextButton(onPressed: () => ref.read(pageProvider.notifier).go(ConsolePage.billing), child: const Text('Breakdown')),
      child: VaAsyncView(
        value: ref.watch(billingProvider),
        data: (b) {
          if (b == null) {
            return const VaEmptyNote(
              'No report yet. The monthly budget publishes its month-to-date cost a few '
              'times a day; the first figure appears here after its next report.',
              icon: Icons.hourglass_empty,
            );
          }
          final month = b.month ?? operatorDay(DateTime.now()).substring(0, 7);
          final y = int.parse(month.substring(0, 4));
          final mo = int.parse(month.substring(5, 7));
          final daysInMonth = DateTime(y, mo + 1, 0).day;
          final points = [
            for (final e in b.days.entries.toList()..sort((a, c) => a.key.compareTo(c.key)))
              if (e.key.startsWith(month)) (int.parse(e.key.substring(8)), e.value),
          ];
          final today = DateTime.now().day;
          final perDay = b.costAmount / math.max(1, today);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.end,
                children: [
                  Text(
                    money(b.costAmount, b.currencyCode),
                    style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600, fontFamily: VaType.mono),
                  ),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('≈ ${money(perDay * daysInMonth, b.currencyCode)} at this pace', style: text.labelSmall),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SpendChart(
                points: points,
                daysInMonth: daysInMonth,
                marks: [
                  (value: 15.0, label: 'target S\$15'),
                  if (b.budgetAmount != null) (value: b.budgetAmount!, label: 'budget ${money(b.budgetAmount, b.currencyCode)}'),
                ],
              ),
              const SizedBox(height: 8),
              Text('Updated ${ago(b.updatedAt)} · alerts email at every S\$5', style: text.labelSmall),
            ],
          );
        },
      ),
    );
  }
}

/// Devstations at a glance, with their controls.
class ProjectsSummaryPanel extends ConsumerWidget {
  const ProjectsSummaryPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statuses = ref.watch(allStatusProvider).value ?? const {};
    final requests = ref.watch(factoryRequestsProvider).value ?? const <FactoryRequest>[];
    final pending = {
      for (final r in requests)
        if (r.status == 'queued' || r.status == 'running') r.devstationId: r,
    };
    return VaPanel(
      title: 'Projects',
      subtitle: 'Devstations and their directors',
      icon: Icons.folder_outlined,
      trailing: TextButton(onPressed: () => ref.read(pageProvider.notifier).go(ConsolePage.projects), child: const Text('Open')),
      child: VaAsyncView(
        value: ref.watch(devstationsProvider),
        data: (list) => list.isEmpty
            ? const VaEmptyNote('No Devstations. Create one on the Projects page.', icon: Icons.precision_manufacturing_outlined)
            : Column(
                children: [
                  for (final d in list)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: DevstationCard(
                        devstation: d,
                        worker: statuses['devstation-${d.id}'],
                        pending: pending[d.id],
                        compact: true,
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
