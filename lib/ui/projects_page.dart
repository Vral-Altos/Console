import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/providers.dart';
import 'charts.dart';
import 'theme.dart';
import 'widgets.dart';

/// Projects and their Devstations (GCE dev VMs with Claude Code and the
/// project's director). Buttons queue Factory requests; the cloud runner
/// applies them with Terraform in Cloud Build (a minute or two each).
class ProjectsPage extends ConsumerWidget {
  const ProjectsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final t = Tokens.of(context);
    ref.watch(clockProvider);
    final statuses = ref.watch(allStatusProvider).value ?? const {};
    final requests = ref.watch(factoryRequestsProvider).value ?? const <FactoryRequest>[];
    final pending = {
      for (final r in requests)
        if (r.status == 'queued' || r.status == 'running') r.devstationId: r,
    };
    return PageScroll(children: [
      PageTitle(
        title: 'Projects',
        subtitle: 'Each project with active work gets a Devstation: a Spot VM with Claude Code and its director agent. It costs only while running.',
        trailing: FilledButton.icon(
          onPressed: () => showDialog<void>(context: context, builder: (_) => const NewDevstationDialog()),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('New Devstation'),
        ),
      ),
      AsyncView(
        value: ref.watch(devstationsProvider),
        data: (list) {
          if (list.isEmpty) {
            return Panel(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(children: [
                  Icon(Icons.precision_manufacturing_outlined, size: 36, color: t.faint),
                  const SizedBox(height: 12),
                  Text('No Devstations yet', style: text.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    'Create one for a project to give its director a machine to work on.',
                    style: text.bodySmall?.copyWith(color: t.muted),
                    textAlign: TextAlign.center,
                  ),
                ]),
              ),
            );
          }
          final sorted = [...list]..sort((a, b) => '${a.project}/${a.id}'.compareTo('${b.project}/${b.id}'));
          return ResponsiveGrid(minWidth: 330, maxColumns: 4, children: [
            for (final d in sorted)
              DevstationCard(devstation: d, worker: statuses['devstation-${d.id}'], pending: pending[d.id]),
          ]);
        },
      ),
      const SizedBox(height: 8),
      Panel(
        title: 'Factory requests',
        subtitle: 'The last 30, newest first.',
        icon: Icons.history,
        child: AsyncView(
          value: ref.watch(factoryRequestsProvider),
          data: (list) => list.isEmpty
              ? const EmptyNote('None yet.')
              : Column(children: [for (final r in list) FactoryRequestRow(request: r)]),
        ),
      ),
    ]);
  }
}

/// A scrolling page with the Console's margins and width.
class PageScroll extends StatelessWidget {
  const PageScroll({super.key, required this.children, this.maxWidth = 1360});
  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(narrow ? 14 : 28, narrow ? 14 : 24, narrow ? 14 : 28, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      ),
    );
  }
}

class PageTitle extends StatelessWidget {
  const PageTitle({super.key, required this.title, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final t = Tokens.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final head = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -.4)),
      if (subtitle != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(subtitle!, style: text.bodyMedium?.copyWith(color: t.muted)),
        ),
    ]);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: narrow || trailing == null
          ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              head,
              if (trailing != null) ...[const SizedBox(height: 12), trailing!],
            ])
          : Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(child: head),
              const SizedBox(width: 16),
              trailing!,
            ]),
    );
  }
}

(String, Color, bool) devstationState(BuildContext context, Devstation d, bool serving) {
  final t = Tokens.of(context);
  return switch (d.state) {
    'running' when serving => ('Running · director serving', t.ok, true),
    'running' => ('Running · director starting', t.info, true),
    'stopped' => ('Stopped', t.faint, false),
    'failed' => ('Failed', t.bad, false),
    'provisioning' => ('Provisioning', t.info, true),
    'starting' => ('Starting', t.info, true),
    'stopping' => ('Stopping', t.warn, true),
    'deleting' => ('Tearing down', t.warn, true),
    _ => (d.state, t.faint, false),
  };
}

/// One Devstation: state, load, its director, and controls.
class DevstationCard extends ConsumerWidget {
  const DevstationCard({super.key, required this.devstation, this.worker, this.pending, this.compact = false});
  final Devstation devstation;
  final HostStatus? worker;
  final FactoryRequest? pending;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final d = devstation;
    final serving = isFresh(worker, DateTime.now());
    final (label, color, pulse) = devstationState(context, d, serving);
    final m = serving ? worker?.metrics : null;
    final memFrac = m?.memUsed != null && (m?.memTotal ?? 0) > 0 ? m!.memUsed! / m.memTotal! : null;
    final repo = ref.read(repositoryProvider);
    Future<void> request(String action) =>
        guarded(context, () => repo!.requestFactory(action: action, devstationId: d.id));
    final busy = pending != null;
    final director = 'director-${d.id}';

    final controls = Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
      if (busy)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Text('${pending!.action} ${pending!.status}…', style: text.labelSmall),
          ]),
        )
      else ...[
        if (d.desired == 'stopped')
          FilledButton.tonalIcon(
            onPressed: () => request('start'),
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('Start'),
          ),
        if (d.desired == 'running')
          OutlinedButton.icon(
            onPressed: () => request('stop'),
            icon: const Icon(Icons.stop_rounded, size: 18),
            label: const Text('Stop'),
          ),
        IconButton(
          tooltip: 'Tear down',
          onPressed: () async {
            final yes = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: Text('Tear down ${d.id}?'),
                content: const Text("The VM and its disk are deleted. The director's memory (state/) is kept in the cloud."),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: t.bad),
                    onPressed: () => Navigator.pop(c, true),
                    child: const Text('Tear down'),
                  ),
                ],
              ),
            );
            if (yes ?? false) await request('destroy');
          },
          icon: Icon(Icons.delete_outline, color: t.muted),
        ),
      ],
      TextButton.icon(
        onPressed: () => openChat(ref, agent: director),
        icon: const Icon(Icons.forum_outlined, size: 18),
        label: const Text('Chat with director'),
      ),
    ]);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.dns_outlined, size: 18, color: t.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(d.project, style: text.titleSmall, overflow: TextOverflow.ellipsis),
                Text([d.id, ?d.machineType, if (d.diskGb != null) '${d.diskGb} GB', ?d.zone].join(' · '), style: text.labelSmall, overflow: TextOverflow.ellipsis),
              ]),
            ),
          ]),
          const SizedBox(height: 10),
          Align(alignment: Alignment.centerLeft, child: StatusPill(label: label, color: color, pulse: pulse, dense: true)),
          if (d.error != null && d.error!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(d.error!, style: text.bodySmall?.copyWith(color: t.bad), maxLines: 3, overflow: TextOverflow.ellipsis),
          ],
          if (!compact) ...[
            const SizedBox(height: 12),
            if (m != null) ...[
              _MiniMeter(label: 'CPU', value: m.cpu, detail: '${m.cores} core${m.cores == 1 ? '' : 's'}'),
              _MiniMeter(label: 'Memory', value: memFrac, detail: '${bytes(m.memUsed)} / ${bytes(m.memTotal)}'),
              if ((worker?.history.length ?? 0) >= 2) ...[
                const SizedBox(height: 6),
                Sparkline(values: [for (final p in worker!.history) p.cpu], max: 1, height: 26, color: t.series[0]),
              ],
              const SizedBox(height: 8),
            ],
            if (d.repoUrl?.isNotEmpty ?? false) KeyValue('Repository', d.repoUrl!, mono: true),
            if (d.identity != null) KeyValue('Runs as', d.identity!.split('@').first, mono: true),
            if (worker?.claudeVersion != null) KeyValue('Claude Code', worker!.claudeVersion!.split(' ').first),
            if (d.createdAt != null) KeyValue('Created', ago(d.createdAt)),
          ],
          const SizedBox(height: 12),
          controls,
        ]),
      ),
    );
  }
}

class _MiniMeter extends StatelessWidget {
  const _MiniMeter({required this.label, required this.value, required this.detail});
  final String label;
  final double? value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text(label, style: text.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
          const Spacer(),
          Text('${pct(value)} · $detail', style: text.labelSmall),
        ]),
        const SizedBox(height: 4),
        Meter(value: value),
      ]),
    );
  }
}

class FactoryRequestRow extends StatelessWidget {
  const FactoryRequestRow({super.key, required this.request});
  final FactoryRequest request;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final r = request;
    final (IconData icon, Color color) = switch (r.status) {
      'done' => (Icons.check_circle, t.ok),
      'failed' => (Icons.error, t.bad),
      'running' => (Icons.sync, t.info),
      _ => (Icons.schedule, t.faint),
    };
    final took = r.createdAt != null && r.finishedAt != null ? ' · took ${duration(r.finishedAt!.difference(r.createdAt!))}' : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${r.action[0].toUpperCase()}${r.action.substring(1)} ${r.devstationId}${r.project == null ? '' : ' (${r.project})'}',
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
            Text('${r.status} · ${ago(r.createdAt)}$took', style: text.labelSmall),
            if (r.error != null) Text(r.error!, style: text.bodySmall?.copyWith(color: t.bad)),
          ]),
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
  int _disk = 30;
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
        diskGb: _disk,
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
      width: 440,
      child: Form(
        key: _form,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextFormField(
            controller: _id,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Id', helperText: 'Lowercase, e.g. atlas. Its director is director-<id>.'),
            validator: (v) =>
                RegExp(r'^[a-z][a-z0-9-]{1,19}$').hasMatch(v?.trim() ?? '') ? null : '2–20 characters: a–z, 0–9, -',
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _project,
            decoration: const InputDecoration(labelText: 'Project'),
            validator: (v) => RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._-]{0,79}$').hasMatch(v?.trim() ?? '')
                ? null
                : 'Letters, digits, spaces, . _ -',
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _repo,
            decoration: const InputDecoration(labelText: 'Git repository (optional, https)'),
            validator: (v) {
              final t = v?.trim() ?? '';
              return t.isEmpty || RegExp(r'^https://[A-Za-z0-9.-]+/[A-Za-z0-9._/-]+$').hasMatch(t)
                  ? null
                  : 'An https:// Git URL';
            },
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: _machine,
            decoration: const InputDecoration(labelText: 'Machine (Spot)'),
            items: [
              for (final e in machines.entries)
                DropdownMenuItem(value: e.key, child: Text('${e.key} — ${e.value}')),
            ],
            onChanged: (v) => setState(() => _machine = v ?? _machine),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<int>(
            key: const Key('devstation-disk'),
            initialValue: _disk,
            decoration: const InputDecoration(
              labelText: 'Disk',
              helperText: 'Kept while stopped (~US\$0.10 per GB a month).',
            ),
            items: [
              for (final gb in const [30, 60, 100, 200]) DropdownMenuItem(value: gb, child: Text('$gb GB')),
            ],
            onChanged: (v) => setState(() => _disk = v ?? _disk),
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
