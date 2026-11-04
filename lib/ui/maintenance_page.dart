import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/providers.dart';
import 'widgets.dart';

/// The running system: where agents run, Claude accounts and usage, agent
/// sessions, and tool syncs.
class MaintenancePage extends ConsumerWidget {
  const MaintenancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Section(
          title: 'Agent hosts',
          child: Column(children: [
            AsyncView(
              value: ref.watch(macStatusProvider),
              data: (mac) => _row(
                Icons.laptop_mac,
                'Mac worker',
                mac == null
                    ? 'Never seen.'
                    : '${macIsOn(mac, now) ? 'Serving' : 'Away'} · ${mac.host ?? ''} · '
                          'last seen ${ago(mac.lastSeen, now: now)}',
              ),
            ),
            AsyncView(
              value: ref.watch(cloudStatusProvider),
              data: (cloud) => _row(
                Icons.cloud_outlined,
                'Cloud runner',
                cloud == null
                    ? 'Has not started yet (it starts when the Mac is away and a message arrives).'
                    : '${cloud.revision ?? 'revision ?'} · started ${ago(cloud.startedAt, now: now)}'
                          '${cloud.lastRunAt == null ? '' : ' · last run ${ago(cloud.lastRunAt, now: now)}: ${cloud.lastResult}'}',
              ),
            ),
          ]),
        ),
        Section(
          title: 'Claude accounts',
          child: AsyncView(
            value: ref.watch(meshProvider),
            data: (mesh) => (mesh?.accounts ?? []).isEmpty
                ? const Text('No account registered: the Mac uses its own Claude login and the '
                    'cloud cannot run agents. Register with `va_agent accounts add <id>`.')
                : Column(children: [for (final a in mesh!.accounts) _account(context, a, now)]),
          ),
        ),
        Section(
          title: 'Active agent sessions',
          child: AsyncView(
            value: ref.watch(meshProvider),
            data: (mesh) {
              final active = [...?mesh?.sessions.where((s) => s.status == 'active')]
                ..sort((a, b) => (b.lastUsedAt ?? now).compareTo(a.lastUsedAt ?? now));
              if (active.isEmpty) return const Text('None.');
              return Column(children: [
                for (final s in active)
                  _row(
                    Icons.chat_bubble_outline,
                    '${s.agent} · ${s.taskId}',
                    '${s.turns} turns · ${s.contextTokens} context tokens · '
                        '${s.compactions} compactions · account ${s.accountId} · ${ago(s.lastUsedAt, now: now)}',
                  ),
              ]);
            },
          ),
        ),
        Section(
          title: 'Tool syncs',
          child: AsyncView(
            value: ref.watch(portfolioSyncProvider),
            data: (p) => _row(
              Icons.candlestick_chart_outlined,
              'Autobench portfolio copy',
              p == null
                  ? 'Never synced.'
                  : '${p.source ?? ''} · synced ${ago(p.syncedAt, now: now)}',
            ),
          ),
        ),
      ],
    );
  }

  static Widget _row(IconData icon, String title, String subtitle) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
  );

  static Widget _account(BuildContext context, AccountView a, DateTime now) {
    String w(String name, UsageView? u) => u == null
        ? '$name —'
        : '$name ${(u.utilization * 100).round()}%'
              '${u.resetsAt == null ? '' : ' (resets ${TimeOfDay.fromDateTime(u.resetsAt!.toLocal()).format(context)})'}';
    final limited = a.limitedUntil != null && a.limitedUntil!.isAfter(now);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(limited ? Icons.block : Icons.account_circle_outlined),
      title: Text(a.label),
      subtitle: Text('${w('5h', a.fiveHour)} · ${w('7d', a.sevenDay)}${limited ? ' · limited' : ''}'),
    );
  }
}
