import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../theme.dart';
import '../widgets.dart';

/// How a conversation is named everywhere in the Console:
/// `[PROJECT] (TOTAL COST) DD/MM: TOPIC`, e.g.
/// `[Financier] ($0.42) 16/11: Dividend tax on SGX stocks`.
///
/// Built from the thread's fields (project, the workers' running cost, the
/// day it started in the operator's time zone, the topic), so it follows
/// every turn and every refiling without anyone rewriting a title.
abstract final class ChatNaming {
  /// `DD/MM` of [t] in the operator's time zone (UTC+8, as usage is counted).
  static String day(DateTime t) {
    final d = operatorDay(t); // yyyy-mm-dd
    return '${d.substring(8, 10)}/${d.substring(5, 7)}';
  }

  static String topic(ChatThread th) => th.title.trim().isEmpty ? 'Untitled' : th.title.trim();

  static String name(ChatThread th, {DateTime? now}) =>
      '[${th.projectName}] (${usd(th.costUsd)}) ${day(th.createdAt ?? now ?? DateTime.now())}: ${topic(th)}';
}

/// `5h 42%` for a usage window.
String quotaLabel(String window, UsageView w) => '$window ${pct(w.utilization)}';

/// When a usage window resets, in words.
String resetsIn(UsageView w, {DateTime? now}) {
  final at = w.resetsAt;
  if (at == null) return '';
  final left = at.difference(now ?? DateTime.now());
  if (left.isNegative) return 'reset';
  return 'resets in ${duration(left)}';
}

/// The conversation's model, its account's quota and its total cost, for the
/// chat header. Quota is the account's live usage (`agent_mesh/state`),
/// falling back to what the last reply recorded.
class ChatUsageBar extends ConsumerWidget {
  const ChatUsageBar({super.key, required this.thread, required this.messages, this.compact = false});
  final ChatThread thread;
  final List<ChatMessage> messages;

  /// Phone width: the tightest quota window only (the cost is in the name;
  /// each reply lists the rest).
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final last = messages.where((m) => !m.fromOperator && (m.model != null || m.accountId != null)).lastOrNull;
    final account = last?.accountId == null
        ? null
        : (ref.watch(meshProvider).value?.accounts ?? const <AccountView>[]).where((a) => a.id == last!.accountId).firstOrNull;
    final fiveHour = account?.fiveHour ?? last?.quota?.fiveHour;
    final sevenDay = account?.sevenDay ?? last?.quota?.sevenDay;
    final turns = messages.where((m) => !m.fromOperator && m.costUsd != null).length;
    final chips = <Widget>[
      ModelEffortMenu(thread: thread, compact: compact),
      if (fiveHour != null && (!compact || (sevenDay?.utilization ?? 0) <= fiveHour.utilization))
        QuotaChip(window: '5h', usage: fiveHour, account: account?.label ?? last?.accountId),
      if (sevenDay != null && (!compact || (fiveHour?.utilization ?? 0) < sevenDay.utilization))
        QuotaChip(window: '7d', usage: sevenDay, account: account?.label ?? last?.accountId),
      if (!compact)
      UsageChip(
        icon: Icons.payments_outlined,
        label: usd(thread.costUsd),
        tooltip: 'This conversation so far: ${usd(thread.costUsd)} over $turns '
            '${turns == 1 ? 'reply' : 'replies'} (API-equivalent; a subscription is not billed per turn).',
      ),
    ];
    return Wrap(spacing: 6, runSpacing: 4, alignment: WrapAlignment.end, children: chips);
  }
}

class UsageChip extends StatelessWidget {
  const UsageChip({super.key, required this.icon, required this.label, required this.tooltip, this.color});
  final IconData icon;
  final String label;
  final String tooltip;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: t.sunken, borderRadius: BorderRadius.circular(8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: color ?? t.muted),
          const SizedBox(width: 5),
          Text(label, style: text.labelSmall?.copyWith(color: color ?? t.muted, fontFeatures: const [FontFeature.tabularFigures()])),
        ]),
      ),
    );
  }
}

/// One usage window: a small meter and its percentage.
class QuotaChip extends StatelessWidget {
  const QuotaChip({super.key, required this.window, required this.usage, this.account});
  final String window;
  final UsageView usage;
  final String? account;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final u = usage.utilization;
    final color = u >= .9 ? t.bad : u >= .75 ? t.warn : t.muted;
    final reset = resetsIn(usage);
    return Tooltip(
      message: [
        '${window == '5h' ? '5-hour' : '7-day'} quota${account == null ? '' : ' of $account'}: ${pct(u)} used',
        if (reset.isNotEmpty) reset,
        if (usage.status != null && usage.status != 'allowed') usage.status!,
      ].join(' · '),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: t.sunken, borderRadius: BorderRadius.circular(8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(window, style: text.labelSmall?.copyWith(color: t.faint)),
          const SizedBox(width: 6),
          SizedBox(width: 28, child: Meter(value: u, height: 4)),
          const SizedBox(width: 6),
          Text(pct(u), style: text.labelSmall?.copyWith(color: color, fontFeatures: const [FontFeature.tabularFigures()])),
        ]),
      ),
    );
  }
}

/// `Opus 5.5 · medium`: the conversation's model and effort, the agent's
/// own where the operator has not chosen.
String modelEffortLabel(String? model, String? effort) =>
    [if (model != null) modelName(model), ?effort].join(' · ');

/// The conversation's model and effort, and the menu to change them. A
/// choice applies from the next message; "Agent default" clears it.
class ModelEffortMenu extends ConsumerWidget {
  const ModelEffortMenu({super.key, required this.thread, this.compact = false});
  final ChatThread thread;
  final bool compact;

  static const efforts = {
    'low': 'Low — quickest, cheapest',
    'medium': 'Medium',
    'high': 'High',
    'xhigh': 'Extra high',
    'max': 'Max — slowest, most thorough',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final own = ref.watch(agentDefaultsProvider)[thread.agent];
    final model = thread.model ?? own?.model;
    final effort = thread.effort ?? own?.effort;
    final chosen = thread.model != null || thread.effort != null;
    final label = modelEffortLabel(model, effort);
    final repo = ref.read(repositoryProvider);

    void set({String? model, String? effort}) => guarded(
      context,
      () => repo!.setModelEffort(thread.id, model: model, effort: effort),
    );

    PopupMenuItem<String> heading(String s) => PopupMenuItem<String>(
      enabled: false,
      height: 28,
      child: Text(s, style: text.labelSmall?.copyWith(color: t.faint, letterSpacing: .6)),
    );

    return PopupMenuButton<String>(
      key: const Key('model-effort'),
      tooltip: 'Model and effort for this conversation',
      onSelected: (v) {
        final (kind, value) = (v.substring(0, 2), v.substring(2));
        if (kind == 'm:') set(model: value.isEmpty ? null : value, effort: thread.effort);
        if (kind == 'e:') set(model: thread.model, effort: value.isEmpty ? null : value);
      },
      itemBuilder: (_) => [
        heading('MODEL'),
        CheckedPopupMenuItem(
          value: 'm:',
          checked: thread.model == null,
          child: Text('Agent default${own?.model == null ? '' : ' (${modelName(own!.model)})'}'),
        ),
        for (final m in chatModels)
          CheckedPopupMenuItem(value: 'm:$m', checked: thread.model == m, child: Text(modelName(m))),
        const PopupMenuDivider(),
        heading('EFFORT'),
        CheckedPopupMenuItem(
          value: 'e:',
          checked: thread.effort == null,
          child: Text('Agent default${own?.effort == null ? '' : ' (${own!.effort})'}'),
        ),
        for (final e in efforts.entries)
          CheckedPopupMenuItem(value: 'e:${e.key}', checked: thread.effort == e.key, child: Text(e.value)),
      ],
      child: compact
          ? Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(Icons.tune, size: 18, color: chosen ? t.info : t.muted),
            )
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: t.sunken,
                borderRadius: BorderRadius.circular(8),
                border: chosen ? Border.all(color: t.info.withValues(alpha: .5)) : null,
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.memory, size: 13, color: chosen ? t.info : t.muted),
                const SizedBox(width: 5),
                Text(label.isEmpty ? 'Default' : label,
                    style: text.labelSmall?.copyWith(color: chosen ? t.info : t.muted)),
                Icon(Icons.arrow_drop_down, size: 16, color: t.faint),
              ]),
            ),
    );
  }
}
