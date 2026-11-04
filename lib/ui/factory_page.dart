import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/providers.dart';
import 'widgets.dart';

/// The build phase: Devstations (GCE dev VMs with Claude Code), one per
/// project with active work. Buttons queue Factory requests; the cloud
/// runner applies them with Terraform (a minute or two each).
class FactoryPage extends ConsumerWidget {
  const FactoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(clockProvider);
    final statuses = ref.watch(allStatusProvider).value ?? const {};
    final pending = {
      for (final r in ref.watch(factoryRequestsProvider).value ?? const <FactoryRequest>[])
        if (r.status == 'queued' || r.status == 'running') r.devstationId,
    };
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Section(
          title: 'Devstations',
          trailing: FilledButton.tonalIcon(
            onPressed: () => showDialog<void>(context: context, builder: (_) => const NewDevstationDialog()),
            icon: const Icon(Icons.add),
            label: const Text('New Devstation'),
          ),
          child: AsyncView(
            value: ref.watch(devstationsProvider),
            data: (list) => list.isEmpty
                ? const Text(
                    'No Devstations. A Devstation is a Spot VM with Claude Code and the '
                    "project's director agent; it costs only while running.",
                  )
                : Column(children: [
                    for (final d in list)
                      DevstationTile(
                        devstation: d,
                        worker: statuses['devstation-${d.id}'],
                        busy: pending.contains(d.id),
                      ),
                  ]),
          ),
        ),
        Section(
          title: 'Recent Factory requests',
          child: AsyncView(
            value: ref.watch(factoryRequestsProvider),
            data: (list) => list.isEmpty
                ? const Text('None yet.')
                : Column(children: [
                    for (final r in list)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(switch (r.status) {
                          'done' => Icons.check_circle_outline,
                          'failed' => Icons.error_outline,
                          _ => Icons.hourglass_top,
                        }),
                        title: Text('${r.action} ${r.devstationId}'),
                        subtitle: Text([
                          r.status,
                          ago(r.createdAt),
                          ?r.error,
                        ].join(' · ')),
                      ),
                  ]),
          ),
        ),
      ],
    );
  }
}

class DevstationTile extends ConsumerWidget {
  const DevstationTile({super.key, required this.devstation, this.worker, required this.busy});
  final Devstation devstation;
  final HostStatus? worker;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = devstation;
    final serving = isFresh(worker, DateTime.now());
    Future<void> request(String action) =>
        ref.read(repositoryProvider)!.requestFactory(action: action, devstationId: d.id);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(switch (d.state) {
        'running' => Icons.play_circle,
        'stopped' => Icons.pause_circle_outline,
        'failed' => Icons.error_outline,
        _ => Icons.sync,
      }),
      title: Text('${d.project} (${d.id})'),
      subtitle: Text([
        d.state,
        if (d.state == 'running') serving ? 'director serving' : 'director starting…',
        ?d.machineType,
        ?worker?.claudeVersion,
        if (d.repoUrl?.isNotEmpty ?? false) d.repoUrl!,
        ?d.error,
      ].join(' · ')),
      trailing: busy
          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : Wrap(spacing: 4, children: [
              if (d.desired == 'stopped')
                IconButton(tooltip: 'Start', onPressed: () => request('start'), icon: const Icon(Icons.play_arrow)),
              if (d.desired == 'running')
                IconButton(tooltip: 'Stop', onPressed: () => request('stop'), icon: const Icon(Icons.stop)),
              IconButton(
                tooltip: 'Tear down',
                onPressed: () async {
                  final yes = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: Text('Tear down ${d.id}?'),
                      content: const Text(
                          "The VM and its disk are deleted. The director's memory (state/) is kept in the cloud."),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Tear down')),
                      ],
                    ),
                  );
                  if (yes ?? false) await request('destroy');
                },
                icon: const Icon(Icons.delete_outline),
              ),
            ]),
    );
  }
}

class NewDevstationDialog extends ConsumerStatefulWidget {
  const NewDevstationDialog({super.key});

  @override
  ConsumerState<NewDevstationDialog> createState() => _NewDevstationDialogState();
}

class _NewDevstationDialogState extends ConsumerState<NewDevstationDialog> {
  final _form = GlobalKey<FormState>();
  final _id = TextEditingController();
  final _project = TextEditingController();
  final _repo = TextEditingController();
  String _machine = 'e2-standard-2';
  bool _busy = false;
  String? _error;

  static const machines = {
    'e2-medium': '2 shared vCPU, 4 GB',
    'e2-standard-2': '2 vCPU, 8 GB',
    'e2-standard-4': '4 vCPU, 16 GB',
    'e2-standard-8': '8 vCPU, 32 GB',
  };

  @override
  void dispose() {
    for (final c in [_id, _project, _repo]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _create() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(repositoryProvider)!.requestFactory(
        action: 'create',
        devstationId: _id.text.trim(),
        project: _project.text.trim(),
        machineType: _machine,
        repoUrl: _repo.text.trim(),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _error = 'Not sent: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New Devstation'),
    content: SizedBox(
      width: 420,
      child: Form(
        key: _form,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextFormField(
            controller: _id,
            decoration: const InputDecoration(labelText: 'Id', helperText: 'lowercase, e.g. atlas'),
            validator: (v) =>
                RegExp(r'^[a-z][a-z0-9-]{1,19}$').hasMatch(v?.trim() ?? '') ? null : '2–20: a–z, 0–9, -',
          ),
          TextFormField(
            controller: _project,
            decoration: const InputDecoration(labelText: 'Project'),
            validator: (v) => RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._-]{0,79}$').hasMatch(v?.trim() ?? '')
                ? null
                : 'Letters, digits, spaces, . _ -',
          ),
          TextFormField(
            controller: _repo,
            decoration: const InputDecoration(labelText: 'Git repository (optional, public https)'),
            validator: (v) {
              final t = v?.trim() ?? '';
              return t.isEmpty || RegExp(r'^https://[A-Za-z0-9.-]+/[A-Za-z0-9._/-]+$').hasMatch(t)
                  ? null
                  : 'An https:// Git URL';
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _machine,
            decoration: const InputDecoration(labelText: 'Machine (Spot)'),
            items: [
              for (final e in machines.entries)
                DropdownMenuItem(value: e.key, child: Text('${e.key} — ${e.value}')),
            ],
            onChanged: (v) => setState(() => _machine = v ?? _machine),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ]),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: _busy ? null : _create, child: const Text('Create')),
    ],
  );
}
