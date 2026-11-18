import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../widgets.dart';
import 'chat_naming.dart';

/// Conversations, grouped by project (default), purpose or when they were
/// last active; each group folds and shows its count and cost. Named
/// `[PROJECT] (COST) DD/MM: TOPIC` ([ChatNaming]). Search, rename, file under
/// a project or purpose, pin, archive, close; the projects themselves are
/// kept from the folder button.
class ThreadSidebar extends ConsumerStatefulWidget {
  const ThreadSidebar({super.key, this.onPicked, this.onCollapse});

  /// Called after a conversation (or "New chat") is picked, e.g. to close
  /// the drawer on a phone.
  final VoidCallback? onPicked;
  final VoidCallback? onCollapse;

  @override
  ConsumerState<ThreadSidebar> createState() => _ThreadSidebarState();
}

class _ThreadSidebarState extends ConsumerState<ThreadSidebar> {
  final _search = TextEditingController();
  String _query = '';
  bool _archived = false;

  /// Folded groups, per grouping (`project:General`).
  final _folded = <String>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(selectedThreadProvider);
    final busy = {
      for (final m in ref.watch(activeMessagesProvider).value ?? const <ChatMessage>[]) m.threadId,
    };
    final threadsValue = ref.watch(threadsProvider);
    return ColoredBox(
      color: VaColors.canvas,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 8, 4),
          child: Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () {
                  ref.read(selectedThreadProvider.notifier).select(null);
                  widget.onPicked?.call();
                },
                icon: const Icon(Icons.edit_square, size: 18),
                label: const Text('New chat'),
              ),
            ),
            IconButton(
              key: const Key('manage-projects'),
              tooltip: 'Projects',
              onPressed: () => showDialog<void>(context: context, builder: (_) => const ProjectsDialog()),
              icon: Icon(Icons.folder_copy_outlined, color: VaColors.muted),
            ),
            if (widget.onCollapse != null)
              IconButton(
                tooltip: 'Hide conversations',
                onPressed: widget.onCollapse,
                icon: Icon(Icons.view_sidebar_outlined, color: VaColors.muted),
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: TextField(
            controller: _search,
            onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            decoration: InputDecoration(
              hintText: 'Search conversations',
              prefixIcon: Icon(Icons.search, size: 18, color: VaColors.muted),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () => setState(() {
                        _search.clear();
                        _query = '';
                      }),
                    ),
              fillColor: VaColors.sunken,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
          child: _GroupingSwitch(
            value: ref.watch(threadGroupingProvider),
            onChanged: (g) => ref.read(threadGroupingProvider.notifier).set(g),
          ),
        ),
        Expanded(
          child: VaAsyncView(
            value: threadsValue,
            data: (all) {
              final archivedCount = all.where((th) => th.archived).length;
              final shown = all.where((th) {
                if (th.archived != _archived) return false;
                if (_query.isEmpty) return true;
                return ChatNaming.name(th).toLowerCase().contains(_query) ||
                    (th.lastMessage ?? '').toLowerCase().contains(_query) ||
                    (th.purpose?.label.toLowerCase().contains(_query) ?? false) ||
                    th.agent.contains(_query);
              }).toList();
              final grouping = ref.watch(threadGroupingProvider);
              final groups = ThreadSidebarGroups.by(grouping, shown, DateTime.now());
              return Column(children: [
                Expanded(
                  child: shown.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(16),
                          child: VaEmptyNote(
                            _query.isNotEmpty
                                ? 'No conversation matches "$_query".'
                                : _archived
                                    ? 'Nothing archived.'
                                    : 'No conversations yet. Start one with New chat.',
                            icon: Icons.chat_bubble_outline,
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                          children: [
                            for (final (label, list) in groups) ...[
                              _GroupHeader(
                                label: label,
                                threads: list,
                                // Recent groups are short-lived; they never fold.
                                folded: grouping != ThreadGrouping.recent && _query.isEmpty && _folded.contains('${grouping.name}:$label'),
                                onToggle: grouping == ThreadGrouping.recent
                                    ? null
                                    : () => setState(() {
                                          final k = '${grouping.name}:$label';
                                          _folded.contains(k) ? _folded.remove(k) : _folded.add(k);
                                        }),
                              ),
                              if (grouping == ThreadGrouping.recent || _query.isNotEmpty || !_folded.contains('${grouping.name}:$label'))
                              for (final th in list)
                                ThreadTile(
                                  thread: th,
                                  selected: th.id == selected,
                                  busy: busy.contains(th.id),
                                  onTap: () {
                                    ref.read(selectedThreadProvider.notifier).select(th.id);
                                    widget.onPicked?.call();
                                  },
                                ),
                            ],
                          ],
                        ),
                ),
                if (archivedCount > 0 || _archived)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: TextButton.icon(
                      onPressed: () => setState(() => _archived = !_archived),
                      icon: Icon(_archived ? Icons.arrow_back : Icons.archive_outlined, size: 18),
                      label: Text(_archived ? 'Back to conversations' : 'Archived ($archivedCount)'),
                      style: TextButton.styleFrom(foregroundColor: VaColors.muted, alignment: Alignment.centerLeft),
                    ),
                  ),
              ]);
            },
          ),
        ),
      ]),
    );
  }
}

class ThreadTile extends ConsumerStatefulWidget {
  const ThreadTile({super.key, required this.thread, required this.selected, required this.busy, required this.onTap});
  final ChatThread thread;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;

  @override
  ConsumerState<ThreadTile> createState() => _ThreadTileState();
}

class _ThreadTileState extends ConsumerState<ThreadTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final th = widget.thread;
    final touch = Theme.of(context).platform == TargetPlatform.iOS || Theme.of(context).platform == TargetPlatform.android;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: widget.selected ? VaColors.sunken : (_hover ? VaColors.sunken.withValues(alpha: .6) : VaColors.sunken.withValues(alpha: 0)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 2, 8),
              child: Row(children: [
                AgentAvatar(agent: th.agent, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Tooltip(
                      message: ChatNaming.name(th),
                      waitDuration: const Duration(milliseconds: 700),
                      // Two lines: the [Project] (cost) DD/MM prefix would
                      // otherwise leave no room for the topic.
                      child: Text(
                        ChatNaming.name(th),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium?.copyWith(fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500),
                      ),
                    ),
                    Text(
                      [
                        agentLabel(th.agent),
                        ?th.purpose?.label,
                        if (th.closed) 'closed',
                        th.updatedAt == null ? 'just now' : ago(th.updatedAt),
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelSmall,
                    ),
                  ]),
                ),
                if (widget.busy)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Tooltip(message: 'Answering', child: VaStatusDot(color: VaColors.info, pulse: true)),
                  ),
                if (th.pinned && !_hover && !widget.selected)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Icon(Icons.push_pin, size: 14, color: VaColors.faint),
                  ),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 120),
                  opacity: _hover || widget.selected || touch ? 1 : 0,
                  child: ThreadMenu(thread: th, small: true),
                ),
              ]),
            ),
          ),
          ),
        ),
      ),
    );
  }
}

/// Rename, pin, archive and close a conversation.
class ThreadMenu extends ConsumerWidget {
  const ThreadMenu({super.key, required this.thread, this.small = false});
  final ChatThread thread;
  final bool small;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(repositoryProvider);
    final th = thread;
    return PopupMenuButton<String>(
      tooltip: 'Conversation options',
      iconSize: small ? 18 : 22,
      padding: EdgeInsets.zero,
      icon: Icon(Icons.more_horiz, color: VaColors.muted),
      onSelected: (v) async {
        if (repo == null) return;
        switch (v) {
          case 'rename':
            final title = await showDialog<String>(context: context, builder: (_) => RenameDialog(initial: th.title));
            if (title != null && context.mounted) await guarded(context, () => repo.rename(th.id, title));
          case 'project':
            final picked = await showDialog<_ProjectPick>(context: context, builder: (_) => ProjectPicker(current: th.project));
            if (picked != null && context.mounted) await guarded(context, () => repo.setProject(th.id, picked.project));
          case 'purpose':
            final purpose = await showDialog<ChatPurpose>(context: context, builder: (_) => PurposePicker(current: th.purpose));
            if (purpose != null && context.mounted) await guarded(context, () => repo.setPurpose(th.id, purpose));
          case 'pin':
            await guarded(context, () => repo.setPinned(th.id, !th.pinned));
          case 'archive':
            await guarded(context, () => repo.setArchived(th.id, !th.archived));
            if (!th.archived && ref.read(selectedThreadProvider) == th.id) {
              ref.read(selectedThreadProvider.notifier).select(null);
            }
          case 'close':
            final yes = await confirmClose(context);
            if (yes && context.mounted) await guarded(context, () => repo.close(th.id));
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Rename topic'), dense: true)),
        PopupMenuItem(
          value: 'project',
          child: ListTile(leading: const Icon(Icons.folder_outlined), title: const Text('Move to project…'), subtitle: Text(th.projectName), dense: true),
        ),
        PopupMenuItem(
          value: 'purpose',
          child: ListTile(leading: const Icon(Icons.label_outline), title: const Text('Purpose…'), subtitle: Text(th.purpose?.label ?? 'Not set'), dense: true),
        ),
        PopupMenuItem(
          value: 'pin',
          child: ListTile(leading: Icon(th.pinned ? Icons.push_pin_outlined : Icons.push_pin), title: Text(th.pinned ? 'Unpin' : 'Pin'), dense: true),
        ),
        PopupMenuItem(
          value: 'archive',
          child: ListTile(
            leading: Icon(th.archived ? Icons.unarchive_outlined : Icons.archive_outlined),
            title: Text(th.archived ? 'Unarchive' : 'Archive'),
            dense: true,
          ),
        ),
        if (!th.closed)
          const PopupMenuItem(
            value: 'close',
            child: ListTile(leading: Icon(Icons.task_alt), title: Text('Close and journal'), dense: true),
          ),
      ],
    );
  }
}

Future<bool> confirmClose(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Close this conversation?'),
        content: const Text(
          'The agent writes a one-paragraph journal entry of it and ends the session. '
          'The conversation stays readable but takes no new messages.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Close and journal')),
        ],
      ),
    ) ??
    false;

class RenameDialog extends StatefulWidget {
  const RenameDialog({super.key, required this.initial});
  final String initial;

  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _done() {
    final v = _c.text.trim();
    if (v.isNotEmpty) Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename topic'),
    content: SizedBox(
      width: 380,
      child: TextField(
        controller: _c,
        autofocus: true,
        maxLength: 200,
        decoration: const InputDecoration(
          labelText: 'Topic',
          helperText: 'Shown as [Project] (cost) DD/MM: Topic. The namer will not change it.',
          helperMaxLines: 2,
        ),
        onSubmitted: (_) => _done(),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: _done, child: const Text('Rename')),
    ],
  );
}

/// Conversations grouped the way the sidebar lists them.
abstract final class ThreadSidebarGroups {
  static List<(String, List<ChatThread>)> by(ThreadGrouping grouping, List<ChatThread> threads, DateTime now) =>
      switch (grouping) {
        ThreadGrouping.recent => of(threads, now),
        ThreadGrouping.project => _keyed(threads, (th) => th.projectName, last: 'General'),
        ThreadGrouping.purpose => _keyed(threads, (th) => th.purpose?.label ?? 'Not filed yet', last: 'Not filed yet'),
      };

  /// Groups by [key]; the group with the latest activity first ([last]
  /// always at the end), pinned conversations first within a group.
  static List<(String, List<ChatThread>)> _keyed(List<ChatThread> threads, String Function(ChatThread) key, {required String last}) {
    DateTime at(ChatThread th) => th.updatedAt ?? th.createdAt ?? DateTime.now();
    final buckets = <String, List<ChatThread>>{};
    for (final th in threads) {
      (buckets[key(th)] ??= []).add(th);
    }
    for (final list in buckets.values) {
      list.sort((a, b) => a.pinned != b.pinned ? (a.pinned ? -1 : 1) : at(b).compareTo(at(a)));
    }
    DateTime latest(List<ChatThread> l) => l.map(at).reduce((a, b) => a.isAfter(b) ? a : b);
    final keys = buckets.keys.toList()
      ..sort((a, b) {
        if (a == last || b == last) return a == last ? 1 : -1;
        return latest(buckets[b]!).compareTo(latest(buckets[a]!));
      });
    return [for (final k in keys) (k, buckets[k]!)];
  }

  static List<(String, List<ChatThread>)> of(List<ChatThread> threads, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final buckets = <String, List<ChatThread>>{};
    for (final th in threads) {
      final at = (th.updatedAt ?? th.createdAt ?? now).toLocal();
      final day = DateTime(at.year, at.month, at.day);
      final age = today.difference(day).inDays;
      final key = th.pinned
          ? 'Pinned'
          : age <= 0
              ? 'Today'
              : age == 1
                  ? 'Yesterday'
                  : age < 7
                      ? 'Previous 7 days'
                      : age < 30
                          ? 'Previous 30 days'
                          : 'Older';
      (buckets[key] ??= []).add(th);
    }
    const order = ['Pinned', 'Today', 'Yesterday', 'Previous 7 days', 'Previous 30 days', 'Older'];
    return [for (final k in order) if (buckets[k] != null) (k, buckets[k]!)];
  }
}


class _GroupingSwitch extends StatelessWidget {
  const _GroupingSwitch({required this.value, required this.onChanged});
  final ThreadGrouping value;
  final ValueChanged<ThreadGrouping> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: SegmentedButton<ThreadGrouping>(
      key: const Key('thread-grouping'),
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: Theme.of(context).textTheme.labelSmall,
      ),
      segments: const [
        ButtonSegment(value: ThreadGrouping.project, label: Text('Project'), tooltip: 'Group by project'),
        ButtonSegment(value: ThreadGrouping.purpose, label: Text('Purpose'), tooltip: 'Group by purpose'),
        ButtonSegment(value: ThreadGrouping.recent, label: Text('Recent'), tooltip: 'Group by last activity'),
      ],
      selected: {value},
      onSelectionChanged: (s) => onChanged(s.single),
    ),
  );
}

/// A group's name, how many conversations it has and what they cost; folds
/// when [onToggle] is given.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label, required this.threads, required this.folded, this.onToggle});
  final String label;
  final List<ChatThread> threads;
  final bool folded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cost = threads.fold<double>(0, (a, th) => a + th.costUsd);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 14, 10, 6),
        child: Row(children: [
          if (onToggle != null) ...[
            AnimatedRotation(
              turns: folded ? -.25 : 0,
              duration: const Duration(milliseconds: 140),
              child: Icon(Icons.expand_more, size: 16, color: VaColors.faint),
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
          ),
          Text(
            '${threads.length} · ${usd(cost)}',
            style: text.labelSmall?.copyWith(color: VaColors.faint, fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ]),
      ),
    );
  }
}

/// A project choice; [project] null = General.
typedef _ProjectPick = ({String? project});

/// Picks the project a conversation is filed under, or adds one.
class ProjectPicker extends ConsumerStatefulWidget {
  const ProjectPicker({super.key, required this.current});
  final String? current;

  @override
  ConsumerState<ProjectPicker> createState() => _ProjectPickerState();
}

class _ProjectPickerState extends ConsumerState<ProjectPicker> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _add(List<ChatProject> existing) async {
    final name = _name.text;
    final repo = ref.read(repositoryProvider);
    if (repo == null || name.trim().isEmpty) return;
    var ok = false;
    await guarded(context, () async {
      await repo.addProject(name, existing: existing);
      ok = true;
    });
    if (ok && mounted) Navigator.pop(context, (project: name.replaceAll(RegExp(r'\s+'), ' ').trim()));
  }

  @override
  Widget build(BuildContext context) {
    final projects = ref.watch(chatProjectsProvider).value ?? const <ChatProject>[];
    Widget option(String? project) => RadioListTile<String?>(
      dense: true,
      value: project,
      title: Text(project ?? 'General'),
      subtitle: project == null ? const Text('Not about any one project') : null,
    );
    return AlertDialog(
      title: const Text('Move to project'),
      content: SizedBox(
        width: 380,
        child: RadioGroup<String?>(
          groupValue: widget.current,
          onChanged: (v) => Navigator.pop(context, (project: v)),
          child: ListView(shrinkWrap: true, children: [
            for (final p in projects) option(p.name),
            option(null),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TextField(
                key: const Key('new-project-name'),
                controller: _name,
                maxLength: 80,
                decoration: const InputDecoration(labelText: 'New project', hintText: 'Name'),
                onSubmitted: (_) => _add(projects),
              ),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => _add(projects), child: const Text('Add and move')),
      ],
    );
  }
}

class PurposePicker extends StatelessWidget {
  const PurposePicker({super.key, required this.current});
  final ChatPurpose? current;

  static const descriptions = {
    ChatPurpose.build: 'Making or changing something',
    ChatPurpose.fix: 'Debugging or repairing',
    ChatPurpose.research: 'Finding out or comparing',
    ChatPurpose.plan: 'Deciding, strategy, planning ahead',
    ChatPurpose.advice: 'An opinion or recommendation',
    ChatPurpose.ops: 'Running, deploying, monitoring, infrastructure',
    ChatPurpose.admin: 'Calendar, tasks, reminders, messages',
    ChatPurpose.other: 'Anything else',
  };

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Purpose'),
    content: SizedBox(
      width: 380,
      child: RadioGroup<ChatPurpose>(
        groupValue: current,
        onChanged: (v) => Navigator.pop(context, v),
        child: ListView(shrinkWrap: true, children: [
          for (final p in ChatPurpose.values)
            RadioListTile<ChatPurpose>(dense: true, value: p, title: Text(p.label), subtitle: Text(descriptions[p]!)),
        ]),
      ),
    ),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
  );
}

/// The projects conversations are filed under: add, rename (its
/// conversations follow), delete (they move to General).
class ProjectsDialog extends ConsumerStatefulWidget {
  const ProjectsDialog({super.key});

  @override
  ConsumerState<ProjectsDialog> createState() => _ProjectsDialogState();
}

class _ProjectsDialogState extends ConsumerState<ProjectsDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(repositoryProvider);
    final projects = ref.watch(chatProjectsProvider).value ?? const <ChatProject>[];
    final threads = ref.watch(threadsProvider).value ?? const <ChatThread>[];
    String count(String? name) {
      final list = threads.where((th) => th.project == name).toList();
      return '${list.length} ${list.length == 1 ? 'conversation' : 'conversations'} · ${usd(list.fold<double>(0, (a, th) => a + th.costUsd))}';
    }

    Future<void> add() async {
      if (repo == null || _name.text.trim().isEmpty) return;
      await guarded(context, () async {
        await repo.addProject(_name.text, existing: projects);
        _name.clear();
      });
    }

    return AlertDialog(
      title: const Text('Projects'),
      content: SizedBox(
        width: 420,
        child: ListView(shrinkWrap: true, children: [
          Text(
            'New conversations are filed under one of these by a small model after the first reply, '
            'unless you pick one when you start. Renaming a project refiles its conversations; '
            'deleting one moves them to General.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: VaColors.muted),
          ),
          const SizedBox(height: 8),
          for (final p in projects)
            ListTile(
              key: Key('project-${p.id}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder_outlined),
              title: Text(p.name),
              subtitle: Text(count(p.name)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: 'Rename',
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: () async {
                    final name = await showDialog<String>(context: context, builder: (_) => _NameDialog(title: 'Rename project', initial: p.name));
                    if (name != null && context.mounted && repo != null) {
                      await guarded(context, () => repo.renameProject(p, name, existing: projects));
                    }
                  },
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () async {
                    final yes = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: Text('Delete ${p.name}?'),
                        content: const Text('Its conversations move to General. They are not deleted.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
                        ],
                      ),
                    );
                    if ((yes ?? false) && context.mounted && repo != null) await guarded(context, () => repo.deleteProject(p));
                  },
                ),
              ]),
            ),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.inbox_outlined, color: VaColors.muted),
            title: const Text('General'),
            subtitle: Text(count(null)),
          ),
          const Divider(),
          Row(children: [
            Expanded(
              child: TextField(
                key: const Key('add-project-name'),
                controller: _name,
                maxLength: 80,
                decoration: const InputDecoration(labelText: 'New project'),
                onSubmitted: (_) => add(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(key: const Key('add-project'), onPressed: add, child: const Text('Add')),
          ]),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.initial});
  final String title;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _done() {
    final v = _c.text.trim();
    if (v.isNotEmpty) Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 360,
      child: TextField(controller: _c, autofocus: true, maxLength: 80, onSubmitted: (_) => _done()),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: _done, child: const Text('Save')),
    ],
  );
}
