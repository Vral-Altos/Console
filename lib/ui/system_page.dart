import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/providers.dart';
import 'hosts.dart';
import 'projects_page.dart';
import 'widgets.dart';

/// The running system in detail: approvals, hosts, agent sessions, usage by
/// host and account, tool syncs, and the Console's own settings.
class SystemPage extends ConsumerWidget {
  const SystemPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(clockProvider);
    final wide = MediaQuery.sizeOf(context).width >= 1100;
    Widget pair(Widget a, Widget b) => wide
        ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: a),
            const SizedBox(width: 16),
            Expanded(child: b),
          ])
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [a, const SizedBox(height: 16), b]);
    return PageScroll(children: [
      const PageTitle(title: 'System', subtitle: 'Hosts, sessions, approvals and syncs.'),
      const ApprovalsPanel(),
      const SizedBox(height: 16),
      const HostDetailsPanel(),
      const SizedBox(height: 16),
      const SessionsPanel(),
      const SizedBox(height: 16),
      pair(const UsageSplitPanel(), const SyncsPanel()),
      const SizedBox(height: 16),
      const SettingsPanel(),
    ]);
  }
}

/// Agents' requests for the operator's approval.
class ApprovalsPanel extends ConsumerWidget {
  const ApprovalsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final repo = ref.read(repositoryProvider);
    return VaPanel(
      title: 'Approvals',
      subtitle: 'Agents ask here before spending, deploying or anything irreversible.',
      icon: Icons.gavel,
      child: VaAsyncView(
        value: ref.watch(approvalsProvider),
        data: (list) => list.isEmpty
            ? const VaEmptyNote('No requests.')
            : Column(children: [
                for (final a in list)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(
                        switch (a.status) {
                          'approved' => Icons.check_circle,
                          'rejected' => Icons.block,
                          _ => Icons.help,
                        },
                        size: 18,
                        color: switch (a.status) { 'approved' => VaColors.success, 'rejected' => VaColors.danger, _ => VaColors.warning },
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${agentLabel(a.requestedBy)}: ${a.action}', style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                          if (a.details.isNotEmpty) Text(a.details, style: text.bodySmall),
                          Text(
                            '${a.status} · asked ${ago(a.createdAt)}${a.decidedAt == null ? '' : ' · decided ${ago(a.decidedAt)}'}',
                            style: text.labelSmall,
                          ),
                        ]),
                      ),
                      if (a.status == 'pending' && repo != null)
                        Wrap(spacing: 4, children: [
                          TextButton(onPressed: () => guarded(context, () => repo.decide(a.id, approve: false)), child: const Text('Reject')),
                          FilledButton(onPressed: () => guarded(context, () => repo.decide(a.id, approve: true)), child: const Text('Approve')),
                        ]),
                    ]),
                  ),
              ]),
      ),
    );
  }
}

/// Every host's card, plus its identifiers.
class HostDetailsPanel extends ConsumerWidget {
  const HostDetailsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    return VaPanel(
      title: 'Hosts',
      subtitle: 'The Mac serves while its heartbeat is under 2 minutes old; otherwise the cloud runner takes the work.',
      icon: Icons.dns_outlined,
      child: VaAsyncView(
        value: ref.watch(allStatusProvider),
        data: (all) => VaResponsiveGrid(minWidth: 320, maxColumns: 3, children: [
          for (final e in orderedHosts(all))
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              HostCard(id: e.key, status: e.value),
              if (e.value != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    VaKeyValue('Last heartbeat', e.value!.lastSeen == null ? '—' : ago(e.value!.lastSeen)),
                    if (e.value!.startedAt != null) VaKeyValue('Started', ago(e.value!.startedAt)),
                    if (e.value!.agents.isNotEmpty) VaKeyValue('Agents', e.value!.agents.join(', ')),
                    if (e.value!.claudeVersion != null) VaKeyValue('Claude Code', e.value!.claudeVersion!),
                    if (e.value!.revision != null) VaKeyValue('Revision', e.value!.revision!, mono: true),
                  ]),
                ),
              Text('', style: text.labelSmall),
            ]),
        ]),
      ),
    );
  }
}

/// Every agent session the mesh knows, filterable by status.
class SessionsPanel extends ConsumerStatefulWidget {
  const SessionsPanel({super.key});

  @override
  ConsumerState<SessionsPanel> createState() => _SessionsPanelState();
}

class _SessionsPanelState extends ConsumerState<SessionsPanel> {
  String _filter = 'active';

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final narrow = MediaQuery.sizeOf(context).width < 760;
    final threads = {for (final th in ref.watch(threadsProvider).value ?? const <ChatThread>[]) th.id: th};
    return VaPanel(
      title: 'Agent sessions',
      subtitle: 'Claude Code sessions: context, turns and API-equivalent cost',
      icon: Icons.memory,
      trailing: SegmentedButton<String>(
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact, textStyle: text.labelSmall),
        segments: const [
          ButtonSegment(value: 'active', label: Text('Active')),
          ButtonSegment(value: 'all', label: Text('All')),
        ],
        selected: {_filter},
        onSelectionChanged: (s) => setState(() => _filter = s.first),
      ),
      child: VaAsyncView(
        value: ref.watch(meshProvider),
        data: (mesh) {
          final list = [...?mesh?.sessions.where((s) => _filter == 'all' || s.status == 'active')]
            ..sort((a, b) => (b.lastUsedAt ?? DateTime(0)).compareTo(a.lastUsedAt ?? DateTime(0)));
          if (list.isEmpty) return VaEmptyNote(_filter == 'active' ? 'No active sessions.' : 'No sessions yet.');
          final total = list.fold<double>(0, (a, s) => a + s.costUsd);
          final rows = [
            for (final s in list.take(60))
              Builder(builder: (context) {
                final threadId = s.taskId.startsWith('console-') ? s.taskId.substring(8) : null;
                final title = threadId != null && threads[threadId] != null ? threads[threadId]!.title : s.taskId;
                final status = switch (s.status) {
                  'active' => VaStatusPill(label: 'active', color: VaColors.success, dense: true),
                  'handedOff' => VaStatusPill(label: 'handed off', color: VaColors.info, dense: true),
                  _ => VaStatusPill(label: s.status, color: VaColors.faint, dense: true),
                };
                final open = threadId != null && threads.containsKey(threadId) ? () => openChat(ref, threadId: threadId) : null;
                if (narrow) {
                  return InkWell(
                    onTap: open,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(children: [
                        AgentAvatar(agent: s.agent, size: 22),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall?.copyWith(fontWeight: FontWeight.w500)),
                            Text('${s.turns} turns · ${compact(s.contextTokens)} ctx · ${usd(s.costUsd)} · ${s.accountId} · ${ago(s.lastUsedAt)}',
                                style: text.labelSmall),
                          ]),
                        ),
                        status,
                      ]),
                    ),
                  );
                }
                return InkWell(
                  onTap: open,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Row(children: [
                      Expanded(
                        flex: 4,
                        child: Row(children: [
                          AgentAvatar(agent: s.agent, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall?.copyWith(fontWeight: FontWeight.w500)),
                              Text(agentLabel(s.agent), style: text.labelSmall),
                            ]),
                          ),
                        ]),
                      ),
                      Expanded(flex: 1, child: Text('${s.turns}', style: text.bodySmall)),
                      Expanded(flex: 2, child: Text('${compact(s.contextTokens)}${s.compactions > 0 ? ' (${s.compactions}×)' : ''}', style: text.bodySmall)),
                      Expanded(flex: 1, child: Text(usd(s.costUsd), style: text.bodySmall?.copyWith(fontFamily: VaType.mono))),
                      Expanded(flex: 1, child: Text(s.accountId, style: text.bodySmall)),
                      Expanded(flex: 2, child: Text(ago(s.lastUsedAt), style: text.bodySmall)),
                      SizedBox(width: 96, child: Align(alignment: Alignment.centerRight, child: status)),
                    ]),
                  ),
                );
              }),
          ];
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (!narrow)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: DefaultTextStyle(
                  style: text.labelSmall!.copyWith(fontWeight: FontWeight.w600),
                  child: const Row(children: [
                    Expanded(flex: 4, child: Text('Task')),
                    Expanded(flex: 1, child: Text('Turns')),
                    Expanded(flex: 2, child: Text('Context')),
                    Expanded(flex: 1, child: Text('Cost')),
                    Expanded(flex: 1, child: Text('Account')),
                    Expanded(flex: 2, child: Text('Last used')),
                    SizedBox(width: 96, child: Text('Status', textAlign: TextAlign.right)),
                  ]),
                ),
              ),
            if (!narrow) Divider(color: VaColors.border),
            for (final r in rows) r,
            const SizedBox(height: 8),
            Text('${list.length} session${list.length == 1 ? '' : 's'} · ${usd(total)} API-equivalent'
                '${list.length > 60 ? ' · showing the latest 60' : ''}', style: text.labelSmall),
          ]);
        },
      ),
    );
  }
}

/// Chat turns split by where they ran and which account paid.
class UsageSplitPanel extends ConsumerWidget {
  const UsageSplitPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    return VaPanel(
      title: 'Where chats ran',
      subtitle: 'All-time chat turns by host and by Claude account',
      icon: Icons.pie_chart_outline,
      child: VaAsyncView(
        value: ref.watch(usageStatsProvider),
        data: (stats) {
          if (stats == null || stats.turns + stats.failed == 0) return const VaEmptyNote('No chat turns counted yet.');
          Widget split(String title, Map<String, UsageSlice> m) {
            final total = m.values.fold<int>(0, (a, s) => a + s.turns);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(title, style: text.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              for (final e in m.entries.toList()..sort((a, b) => b.value.turns.compareTo(a.value.turns)))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    SizedBox(width: 90, child: Text(e.key, style: text.bodySmall)),
                    Expanded(child: VaMeter(value: total == 0 ? 0 : e.value.turns / total)),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 120,
                      child: Text('${e.value.turns} · ${usd(e.value.costUsd)}${e.value.failed > 0 ? ' · ${e.value.failed}✕' : ''}',
                          textAlign: TextAlign.right, style: text.labelSmall?.copyWith(fontFamily: VaType.mono)),
                    ),
                  ]),
                ),
            ]);
          }

          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 24, runSpacing: 8, children: [
              _Figure('Turns', '${stats.turns}'),
              _Figure('Failed', '${stats.failed}'),
              _Figure('Output tokens', compact(stats.outputTokens)),
              _Figure('Cost', usd(stats.costUsd)),
              if (stats.turns > 0) _Figure('Avg. turn', duration(Duration(milliseconds: stats.durationMs ~/ stats.turns))),
            ]),
            const SizedBox(height: 16),
            split('By host', stats.byPlacement),
            const SizedBox(height: 14),
            if (stats.byAccount.isNotEmpty) split('By account', stats.byAccount),
          ]);
        },
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: text.labelSmall),
      Text(value, style: text.titleMedium?.copyWith(fontFamily: VaType.mono)),
    ]);
  }
}

/// Copies other tools keep in the platform database.
class SyncsPanel extends ConsumerWidget {
  const SyncsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    return VaPanel(
      title: 'Tool syncs',
      subtitle: 'What tools copy into the platform database for the agents',
      icon: Icons.sync,
      child: VaAsyncView(
        value: ref.watch(portfolioSyncProvider),
        data: (p) => Row(children: [
          Icon(Icons.candlestick_chart_outlined, size: 20, color: VaColors.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Autobench portfolio copy', style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
              Text(
                p == null ? 'Never synced.' : '${p.source ?? ''} · synced ${ago(p.syncedAt)}',
                style: text.labelSmall,
              ),
            ]),
          ),
          if (p?.syncedAt != null)
            VaStatusPill(
              label: DateTime.now().difference(p!.syncedAt!) < const Duration(hours: 26) ? 'Fresh' : 'Stale',
              color: DateTime.now().difference(p.syncedAt!) < const Duration(hours: 26) ? VaColors.success : VaColors.warning,
              dense: true,
            ),
        ]),
      ),
    );
  }
}

/// The signed-in account.
class SettingsPanel extends ConsumerWidget {
  const SettingsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final user = ref.watch(authStateProvider).value;
    return VaPanel(
      title: 'Console',
      icon: Icons.settings_outlined,
      child: Wrap(spacing: 24, runSpacing: 16, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (user != null)
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Signed in as', style: text.labelMedium),
            const SizedBox(height: 6),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text(user.email ?? '', style: text.bodyMedium),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () => ref.read(firebaseAuthProvider)?.signOut(),
                icon: const Icon(Icons.logout, size: 18),
                label: const Text('Sign out'),
              ),
            ]),
          ]),
      ]),
    );
  }
}
