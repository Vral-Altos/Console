import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import 'widgets.dart';

/// The build phase: Devstations (GCE dev VMs running Claude Code), one per
/// project with active work.
class FactoryPage extends ConsumerWidget {
  const FactoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Section(
        title: 'Devstations',
        child: AsyncView(
          value: ref.watch(devstationsProvider),
          data: (list) => list.isEmpty
              ? const Text(
                  'No Devstations. A Devstation is a GCE VM with Claude Code for one '
                  'project; only projects with active work keep one running.',
                )
              : Column(children: [
                  for (final d in list)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(d.state == 'running' ? Icons.play_circle : Icons.pause_circle_outline),
                      title: Text(d.project),
                      subtitle: Text([
                        d.state,
                        ?d.machineType,
                        ?d.zone,
                        'active ${ago(d.lastActiveAt)}',
                      ].join(' · ')),
                    ),
                ]),
        ),
      ),
    ],
  );
}
