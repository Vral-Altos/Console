import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_mesh/ui_mesh.dart';

import '../data/models.dart';
import '../data/providers.dart';
import 'charts.dart';
import 'widgets.dart';

/// Which kind of host a `status/<id>` document is.
enum HostKind { mac, cloud, devstation }

HostKind hostKind(String id) => id == 'mac'
    ? HostKind.mac
    : id == 'cloud'
    ? HostKind.cloud
    : HostKind.devstation;

String hostTitle(String id) => switch (hostKind(id)) {
  HostKind.mac => 'Mac worker',
  HostKind.cloud => 'Cloud runner',
  HostKind.devstation => 'Devstation ${id.replaceFirst('devstation-', '')}',
};

IconData hostIcon(String id) => switch (hostKind(id)) {
  HostKind.mac => Icons.laptop_mac,
  HostKind.cloud => Icons.cloud_outlined,
  HostKind.devstation => Icons.dns_outlined,
};

/// A host's state, load and recent history.
class HostCard extends ConsumerWidget {
  const HostCard({super.key, required this.id, required this.status});
  final String id;
  final HostStatus? status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    ref.watch(clockProvider);
    final now = DateTime.now();
    final s = status;
    final kind = hostKind(id);
    final fresh = isFresh(s, now);
    final (String label, Color color, bool pulse) = switch (kind) {
      _ when s == null => ('Never seen', VaColors.faint, false),
      HostKind.cloud => (
        s.lastRunAt != null && now.difference(s.lastRunAt!) < const Duration(minutes: 15) ? 'Recently active' : 'Scaled to zero',
        s.lastRunAt != null && now.difference(s.lastRunAt!) < const Duration(minutes: 15) ? VaColors.info : VaColors.faint,
        false,
      ),
      _ => fresh ? ('Serving', VaColors.success, true) : ('Away', VaColors.warning, false),
    };
    final m = s?.metrics;
    final memFrac = m?.memUsed != null && (m?.memTotal ?? 0) > 0 ? m!.memUsed! / m.memTotal! : null;
    final diskFrac = m?.diskUsed != null && (m?.diskTotal ?? 0) > 0 ? m!.diskUsed! / m.diskTotal! : null;
    final stale = kind != HostKind.cloud && !fresh;
    final footer = <String>[
      if (s?.host != null && kind != HostKind.cloud) s!.host!,
      if (s?.claudeVersion != null) 'Claude ${s!.claudeVersion!.split(' ').first}',
      if (kind == HostKind.cloud && s?.revision != null) s!.revision!,
      if ((s?.agents ?? const []).isNotEmpty) '${s!.agents.length} agent${s.agents.length == 1 ? '' : 's'}',
      if (s?.startedAt != null && kind != HostKind.cloud && fresh) 'up ${duration(now.difference(s!.startedAt!))}',
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(hostIcon(id), size: 18, color: VaColors.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(hostTitle(id), style: text.titleSmall, overflow: TextOverflow.ellipsis),
                ),
                VaStatusPill(label: label, color: color, pulse: pulse, dense: true),
              ],
            ),
            const SizedBox(height: 14),
            if (m == null)
              VaEmptyNote(
                s == null ? 'This host has not reported yet.' : 'No load reading yet (it reports with its next heartbeat).',
                icon: Icons.monitor_heart_outlined,
              )
            else ...[
              Opacity(
                opacity: stale ? .55 : 1,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: RingGauge(
                        value: m.cpu,
                        label: 'CPU',
                        caption: '${m.cores} core${m.cores == 1 ? '' : 's'}',
                        size: 64,
                      ),
                    ),
                    Expanded(
                      child: RingGauge(
                        value: memFrac,
                        label: 'Memory',
                        caption: '${bytes(m.memUsed)}\nof ${bytes(m.memTotal)}',
                        size: 64,
                      ),
                    ),
                    // Cloud Run's filesystem is in memory: no meaningful disk.
                    if (kind != HostKind.cloud)
                      Expanded(
                        child: RingGauge(
                          value: diskFrac,
                          label: 'Disk',
                          caption: '${bytes(m.diskUsed)}\nof ${bytes(m.diskTotal)}',
                          size: 64,
                        ),
                      ),
                  ],
                ),
              ),
              if (s!.history.length >= 2) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _Trend(label: 'CPU', values: [for (final p in s.history) p.cpu], color: VaColors.series[0]),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _Trend(label: 'Memory', values: [for (final p in s.history) p.mem], color: VaColors.series[1]),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Text(
                kind == HostKind.cloud
                    ? 'Reading from its last run, ${ago(m.at, now: now)}'
                    : stale
                    ? 'Last reading ${ago(m.at, now: now)}'
                    : 'Worker process ${bytes(m.rss)}${m.load1 == null ? '' : ' · load ${m.load1!.toStringAsFixed(2)}'}',
                style: text.labelSmall,
              ),
            ],
            if (footer.isNotEmpty) ...[
              const SizedBox(height: 10),
              Divider(color: VaColors.border),
              const SizedBox(height: 8),
              Text(footer.join(' · '), style: text.labelSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
            if (kind == HostKind.cloud && s?.lastRunAt != null) ...[
              const SizedBox(height: 4),
              Text(
                'Last run ${ago(s!.lastRunAt, now: now)}: ${s.lastResult ?? ''}',
                style: text.labelSmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Trend extends StatelessWidget {
  const _Trend({required this.label, required this.values, required this.color});
  final String label;
  final List<double?> values;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('$label · last ${values.length} readings', style: Theme.of(context).textTheme.labelSmall),
      const SizedBox(height: 4),
      Sparkline(values: values, color: color, max: 1, height: 30),
    ],
  );
}

/// Every host the system knows, Mac and cloud first.
List<MapEntry<String, HostStatus?>> orderedHosts(Map<String, HostStatus> all) => [
  MapEntry('mac', all['mac']),
  MapEntry('cloud', all['cloud']),
  for (final e in all.entries.where((e) => e.key.startsWith('devstation-')).toList()..sort((a, b) => a.key.compareTo(b.key)))
    MapEntry(e.key, e.value),
];
