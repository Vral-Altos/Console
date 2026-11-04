import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../theme.dart';
import '../widgets.dart';

/// Conversations, newest first, grouped by when they were last active;
/// pinned ones on top. Search, rename, pin, archive, close.
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

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final selected = ref.watch(selectedThreadProvider);
    final busy = {
      for (final m in ref.watch(activeMessagesProvider).value ?? const <ChatMessage>[]) m.threadId,
    };
    final threadsValue = ref.watch(threadsProvider);
    return ColoredBox(
      color: t.canvas,
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
            if (widget.onCollapse != null)
              IconButton(
                tooltip: 'Hide conversations',
                onPressed: widget.onCollapse,
                icon: Icon(Icons.view_sidebar_outlined, color: t.muted),
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
              prefixIcon: Icon(Icons.search, size: 18, color: t.muted),
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
              fillColor: t.sunken,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
        Expanded(
          child: AsyncView(
            value: threadsValue,
            data: (all) {
              final archivedCount = all.where((th) => th.archived).length;
              final shown = all.where((th) {
                if (th.archived != _archived) return false;
                if (_query.isEmpty) return true;
                return th.title.toLowerCase().contains(_query) ||
                    (th.lastMessage ?? '').toLowerCase().contains(_query) ||
                    th.agent.contains(_query);
              }).toList();
              final groups = ThreadSidebarGroups.of(shown, DateTime.now());
              return Column(children: [
                Expanded(
                  child: shown.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(16),
                          child: EmptyNote(
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
                              Padding(
                                padding: const EdgeInsets.fromLTRB(10, 14, 10, 6),
                                child: Text(label, style: text.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
                              ),
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
                      style: TextButton.styleFrom(foregroundColor: t.muted, alignment: Alignment.centerLeft),
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
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final th = widget.thread;
    final touch = Theme.of(context).platform == TargetPlatform.iOS || Theme.of(context).platform == TargetPlatform.android;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Material(
          color: widget.selected ? t.sunken : (_hover ? t.sunken.withValues(alpha: .6) : Colors.transparent),
          borderRadius: BorderRadius.circular(10),
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
                    Text(
                      th.title.isEmpty ? 'Untitled' : th.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500),
                    ),
                    Text(
                      '${agentLabel(th.agent)}${th.closed ? ' · closed' : ''} · ${th.updatedAt == null ? 'just now' : ago(th.updatedAt)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelSmall,
                    ),
                  ]),
                ),
                if (widget.busy)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Tooltip(message: 'Answering', child: StatusDot(color: t.info, pulse: true)),
                  ),
                if (th.pinned && !_hover && !widget.selected)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Icon(Icons.push_pin, size: 14, color: t.faint),
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
      icon: Icon(Icons.more_horiz, color: Tokens.of(context).muted),
      onSelected: (v) async {
        if (repo == null) return;
        switch (v) {
          case 'rename':
            final title = await showDialog<String>(context: context, builder: (_) => RenameDialog(initial: th.title));
            if (title != null && context.mounted) await guarded(context, () => repo.rename(th.id, title));
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
        const PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Rename'), dense: true)),
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
    title: const Text('Rename conversation'),
    content: SizedBox(
      width: 380,
      child: TextField(
        controller: _c,
        autofocus: true,
        maxLength: 200,
        decoration: const InputDecoration(labelText: 'Title'),
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
