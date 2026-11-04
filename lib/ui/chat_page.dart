import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/providers.dart';
import 'widgets.dart';

/// Conversations with the agents. Messages go into the mailbox; the Mac
/// worker (or, while the Mac is away, the cloud runner) answers.
class ChatPage extends ConsumerWidget {
  const ChatPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final selected = ref.watch(selectedThreadProvider);
    if (wide) {
      return Row(children: [
        const SizedBox(width: 320, child: ThreadList()),
        const VerticalDivider(width: 1),
        Expanded(child: selected == null ? const NewThreadView() : ThreadView(threadId: selected)),
      ]);
    }
    return _NarrowChat(selected: selected);
  }
}

class _NarrowChat extends ConsumerStatefulWidget {
  const _NarrowChat({required this.selected});
  final String? selected;

  @override
  ConsumerState<_NarrowChat> createState() => _NarrowChatState();
}

class _NarrowChatState extends ConsumerState<_NarrowChat> {
  bool _composing = false;

  @override
  Widget build(BuildContext context) {
    final back = Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () {
          ref.read(selectedThreadProvider.notifier).select(null);
          setState(() => _composing = false);
        },
        icon: const Icon(Icons.arrow_back),
        label: const Text('Conversations'),
      ),
    );
    if (widget.selected != null) {
      return Column(children: [back, Expanded(child: ThreadView(threadId: widget.selected!))]);
    }
    if (_composing) return Column(children: [back, const Expanded(child: NewThreadView())]);
    return ThreadList(onNew: () => setState(() => _composing = true));
  }
}

class ThreadList extends ConsumerWidget {
  const ThreadList({super.key, this.onNew});
  final VoidCallback? onNew;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedThreadProvider);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: () {
              ref.read(selectedThreadProvider.notifier).select(null);
              onNew?.call();
            },
            icon: const Icon(Icons.add),
            label: const Text('New conversation'),
          ),
        ),
      ),
      Expanded(
        child: AsyncView(
          value: ref.watch(threadsProvider),
          data: (threads) => threads.isEmpty
              ? const Center(child: Text('No conversations yet.'))
              : ListView(children: [
                  for (final t in threads)
                    ListTile(
                      selected: t.id == selected,
                      leading: CircleAvatar(child: Text(t.agent.substring(0, 1).toUpperCase())),
                      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${t.agent}${t.closed ? ' · closed' : ''} · ${ago(t.updatedAt)}'
                        '${t.lastMessage == null ? '' : '\n${t.lastMessage}'}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => ref.read(selectedThreadProvider.notifier).select(t.id),
                    ),
                ]),
        ),
      ),
    ]);
  }
}

/// Picks an agent and sends the first message.
class NewThreadView extends ConsumerStatefulWidget {
  const NewThreadView({super.key});

  @override
  ConsumerState<NewThreadView> createState() => _NewThreadViewState();
}

class _NewThreadViewState extends ConsumerState<NewThreadView> {
  String _agent = 'genie';

  @override
  Widget build(BuildContext context) {
    final mac = ref.watch(macStatusProvider).value;
    final cloud = ref.watch(cloudStatusProvider).value;
    final agents = {'genie', ...?mac?.agents, ...?cloud?.agents}.toList()..sort();
    return Column(children: [
      Expanded(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('New conversation', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              DropdownMenu<String>(
                initialSelection: _agent,
                label: const Text('Agent'),
                onSelected: (a) => setState(() => _agent = a ?? 'genie'),
                dropdownMenuEntries: [for (final a in agents) DropdownMenuEntry(value: a, label: a)],
              ),
            ]),
          ),
        ),
      ),
      Composer(
        hint: 'Message $_agent',
        onSend: (text) async {
          final id = await ref.read(repositoryProvider)!.startThread(agent: _agent, text: text);
          ref.read(selectedThreadProvider.notifier).select(id);
        },
      ),
    ]);
  }
}

class ThreadView extends ConsumerWidget {
  const ThreadView({super.key, required this.threadId});
  final String threadId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thread = ref.watch(threadsProvider).value?.where((t) => t.id == threadId).firstOrNull;
    final messages = ref.watch(messagesProvider(threadId));
    final busy = messages.value?.any((m) =>
            m.status == MessageStatus.queued || m.status == MessageStatus.running) ??
        false;
    return Column(children: [
      ListTile(
        title: Text(thread?.title ?? ''),
        subtitle: Text('${thread?.agent ?? ''}${thread?.closed ?? false ? ' · closed' : ''}'),
        trailing: thread == null || thread.closed
            ? null
            : TextButton.icon(
                onPressed: busy ? null : () => ref.read(repositoryProvider)!.close(threadId),
                icon: const Icon(Icons.task_alt),
                label: const Text('Close'),
              ),
      ),
      const Divider(height: 1),
      Expanded(
        child: AsyncView(
          value: messages,
          data: (list) => ListView(
            reverse: true,
            padding: const EdgeInsets.all(16),
            children: [for (final m in list.reversed) MessageBubble(message: m)],
          ),
        ),
      ),
      if (!(thread?.closed ?? false))
        Composer(hint: 'Message ${thread?.agent ?? ''}', onSend: (text) => ref.read(repositoryProvider)!.send(threadId, text)),
    ]);
  }
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = message.fromOperator;
    final note = switch (message.status) {
      MessageStatus.queued => 'Waiting for the Mac or the cloud…',
      MessageStatus.running => 'Answering on the ${message.claimedBy ?? 'worker'}…',
      MessageStatus.failed => 'Failed: ${message.error ?? 'unknown error'}',
      _ => null,
    };
    final close = message.kind == 'close';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (close)
              const Text('Closing the conversation (journal entry).', style: TextStyle(fontStyle: FontStyle.italic))
            else
              SelectableText(message.text),
            if (note != null) ...[
              const SizedBox(height: 6),
              Text(note,
                  style: TextStyle(
                    fontSize: 12,
                    color: message.status == MessageStatus.failed ? scheme.error : scheme.onSurfaceVariant,
                  )),
            ],
            if (!mine && message.placement != null) ...[
              const SizedBox(height: 6),
              Text(
                'Answered on the ${message.placement}'
                '${message.accountId == null ? '' : ' · account ${message.accountId}'}',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

class Composer extends StatefulWidget {
  const Composer({super.key, required this.onSend, required this.hint});
  final Future<void> Function(String text) onSend;
  final String hint;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _text = TextEditingController();
  bool _sending = false;
  String? _error;

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.onSend(text);
      _text.clear();
    } catch (e) {
      setState(() => _error = 'Not sent: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: TextField(
            controller: _text,
            minLines: 1,
            maxLines: 8,
            maxLength: 20000,
            buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
            decoration: InputDecoration(
              hintText: widget.hint,
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _send(),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          tooltip: 'Send',
          onPressed: _sending ? null : _send,
          icon: const Icon(Icons.send),
        ),
      ]),
    ),
  );
}
