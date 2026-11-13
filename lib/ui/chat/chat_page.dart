import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../theme.dart';
import '../widgets.dart';
import 'composer.dart';
import 'message_tiles.dart';
import 'thread_sidebar.dart';

/// Conversations with the agents. Messages go into the mailbox; the Mac
/// worker (or, while the Mac is away, the cloud runner; a director's
/// Devstation for a director) answers, streaming its progress back.
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  bool _sidebar = true;
  final _scaffold = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final selected = ref.watch(selectedThreadProvider);
    final onMenu = wide ? (_sidebar ? null : () => setState(() => _sidebar = true)) : () => _scaffold.currentState?.openDrawer();
    final main = _Switch(
      child: selected == null
          ? NewChatView(key: const ValueKey('new'), onMenu: onMenu)
          : ConversationView(key: ValueKey(selected), threadId: selected, onMenu: onMenu),
    );
    return CallbackShortcuts(
      bindings: {
        // Show or hide the conversations: ⌘⇧S / Ctrl+Shift+S.
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true, shift: true): _toggleSidebar,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true): _toggleSidebar,
      },
      child: _layout(context, t, wide, main),
    );
  }

  void _toggleSidebar() {
    if (MediaQuery.sizeOf(context).width >= 900) {
      setState(() => _sidebar = !_sidebar);
    } else {
      final s = _scaffold.currentState;
      s?.isDrawerOpen ?? false ? s?.closeDrawer() : s?.openDrawer();
    }
  }

  Widget _layout(BuildContext context, Tokens t, bool wide, Widget main) {
    if (wide) {
      return Row(children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: _sidebar
              ? SizedBox(
                  width: 280,
                  child: DecoratedBox(
                    decoration: BoxDecoration(border: Border(right: BorderSide(color: t.border))),
                    child: ThreadSidebar(onCollapse: () => setState(() => _sidebar = false)),
                  ),
                )
              : const SizedBox(width: 0, height: double.infinity),
        ),
        Expanded(child: main),
      ]);
    }
    return Scaffold(
      key: _scaffold,
      backgroundColor: t.canvas,
      drawer: Drawer(
        backgroundColor: t.canvas,
        width: 300,
        shape: const RoundedRectangleBorder(),
        child: SafeArea(child: ThreadSidebar(onPicked: () => _scaffold.currentState?.closeDrawer())),
      ),
      body: main,
    );
  }
}

/// Cross-fades between conversations instead of cutting.
class _Switch extends StatelessWidget {
  const _Switch({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 200),
    switchInCurve: Curves.easeOutCubic,
    switchOutCurve: Curves.easeInCubic,
    layoutBuilder: (current, previous) => Stack(children: [...previous, ?current]),
    transitionBuilder: (child, a) => FadeTransition(
      opacity: a,
      child: SlideTransition(position: Tween(begin: const Offset(0, .008), end: Offset.zero).animate(a), child: child),
    ),
    child: child,
  );
}

/// The bar above a conversation.
class _ChatHeader extends StatelessWidget {
  const _ChatHeader({required this.onMenu, this.trailing, required this.children});
  final VoidCallback? onMenu;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
      child: Row(children: [
        if (onMenu != null)
          IconButton(tooltip: 'Conversations', onPressed: onMenu, icon: const Icon(Icons.menu)),
        if (onMenu == null) const SizedBox(width: 8),
        ...children,
        ?trailing,
      ]),
    );
  }
}

class ConversationView extends ConsumerStatefulWidget {
  const ConversationView({super.key, required this.threadId, this.onMenu});
  final String threadId;
  final VoidCallback? onMenu;

  @override
  ConsumerState<ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends ConsumerState<ConversationView> {
  final _scroll = ScrollController();
  final _composer = GlobalKey<ComposerState>();
  bool _showJump = false;

  /// When each item was first shown: items that arrive after the
  /// conversation opened animate in; the ones it opened with do not.
  final _firstSeen = <String, DateTime>{};
  bool _opened = false;

  /// Messages there were when the operator scrolled away from the latest.
  int? _countWhenAway;
  int _count = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final away = _scroll.hasClients && _scroll.offset > 400;
      if (away != _showJump) {
        setState(() {
          _showJump = away;
          _countWhenAway = away ? _count : null;
        });
      }
    });
  }

  bool _fresh(String key) {
    final now = DateTime.now();
    final seen = _firstSeen.putIfAbsent(key, () => _opened ? now : DateTime(2000));
    return now.difference(seen) < const Duration(milliseconds: 400);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom() => _scroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);

  Future<void> _send(String text, List<AttachmentRef> attachments, List<MentionRef> mentions) async {
    await ref.read(repositoryProvider)!.send(widget.threadId, text, attachments: attachments, mentions: mentions);
    if (_scroll.hasClients) _toBottom();
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final threads = ref.watch(threadsProvider).value;
    final thread = threads?.where((th) => th.id == widget.threadId).firstOrNull;
    final messagesValue = ref.watch(messagesProvider(widget.threadId));
    final messages = messagesValue.value ?? const <ChatMessage>[];
    final agent = thread?.agent ?? 'genie';
    final active = messages
        .where((m) => m.fromOperator && (m.status == MessageStatus.running || m.status == MessageStatus.queued))
        .toList();
    final stopTarget = active.where((m) => m.status == MessageStatus.running).firstOrNull ?? active.firstOrNull;
    final repo = ref.read(repositoryProvider);
    final description = ref.watch(agentsProvider).where((a) => a.name == agent).firstOrNull?.description;

    Future<void> stop(ChatMessage m) => guarded(context, () => repo!.stop(m.id));
    void retry(ChatMessage m) => guarded(context, () => _send(m.text, m.attachments, m.mentions));
    void edit(ChatMessage m) => _composer.currentState?.restore(m.text, attachments: m.attachments, mentions: m.mentions);

    void editLast() {
      if (thread?.closed ?? true) return;
      final last = messages.lastWhere((m) => m.fromOperator && m.kind != 'close', orElse: () => const ChatMessage(id: '', threadId: '', fromOperator: false, text: ''));
      if (last.fromOperator) edit(last);
    }

    final items = _items(context, messages, agent, thread?.closed ?? false, stop: stop, retry: retry, edit: edit);
    final loaded = messagesValue.hasValue && messages.isNotEmpty;
    _count = messages.length;
    final unseen = _showJump && _countWhenAway != null && messages.length > _countWhenAway!;
    final keyed = [for (final (k, w) in items) (k, w, _fresh(k))];
    if (loaded) _opened = true;

    return Column(children: [
      _ChatHeader(
        onMenu: widget.onMenu,
        trailing: thread == null ? null : ThreadMenu(thread: thread),
        children: [
          AgentAvatar(agent: agent, size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(thread?.title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
              Text(
                [agentLabel(agent), if (thread?.closed ?? false) 'closed', ?description].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.labelSmall,
              ),
            ]),
          ),
        ],
      ),
      Expanded(
        child: Stack(children: [
          if (messagesValue.hasError)
            AsyncView(value: messagesValue, data: (_) => const SizedBox.shrink())
          else if (!loaded)
            const SingleChildScrollView(child: ChatColumn(child: ConversationSkeleton()))
          else
            SelectionArea(
              child: ListView.builder(
                controller: _scroll,
                reverse: true,
                padding: const EdgeInsets.only(top: 12, bottom: 28),
                itemCount: keyed.length,
                findChildIndexCallback: (key) {
                  final k = (key as ValueKey<String>).value;
                  final i = keyed.indexWhere((e) => e.$1 == k);
                  return i < 0 ? null : keyed.length - 1 - i;
                },
                itemBuilder: (context, i) {
                  final (k, w, fresh) = keyed[keyed.length - 1 - i];
                  return Appear(key: ValueKey(k), animate: fresh, child: ChatColumn(child: w));
                },
              ),
            ),
          // Text fades out under the composer rather than being cut off.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 24,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [t.canvas.withValues(alpha: 0), t.canvas],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 12,
            left: 0,
            right: 0,
            child: Center(
              child: AnimatedSlide(
                offset: _showJump ? Offset.zero : const Offset(0, .6),
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child: AnimatedOpacity(
                  opacity: _showJump ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: IgnorePointer(
                    ignoring: !_showJump,
                    child: Material(
                      color: t.panel,
                      shape: StadiumBorder(side: BorderSide(color: t.border)),
                      elevation: 3,
                      shadowColor: Colors.black26,
                      child: InkWell(
                        customBorder: const StadiumBorder(),
                        onTap: _toBottom,
                        child: Tooltip(
                          message: 'Jump to latest',
                          child: AnimatedSize(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOutCubic,
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: unseen ? 14 : 9, vertical: 9),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Icon(Icons.arrow_downward_rounded, size: 18, color: unseen ? Theme.of(context).colorScheme.primary : null),
                                if (unseen) ...[
                                  const SizedBox(width: 6),
                                  Text('New messages', style: text.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
                                ],
                              ]),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
      if (thread?.closed ?? false)
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.lock_outline, size: 16, color: t.muted),
              const SizedBox(width: 8),
              Flexible(child: Text('This conversation is closed.', style: text.bodySmall?.copyWith(color: t.muted))),
              const SizedBox(width: 12),
              FilledButton.tonal(
                onPressed: () => openChat(ref, agent: agent),
                child: Text('New chat with ${agentLabel(agent)}'),
              ),
            ]),
          ),
        )
      else
        Composer(
          key: _composer,
          draftKey: widget.threadId,
          threadId: widget.threadId,
          hint: 'Reply to ${agentLabel(agent)}…',
          onSend: _send,
          onStop: stopTarget == null ? null : () => stop(stopTarget),
          onEditLast: editLast,
          stopping: stopTarget?.cancelRequested ?? false,
          footnote: '${agentLabel(agent)} can make mistakes. Check what matters.',
        ),
    ]);
  }

  List<(String, Widget)> _items(
    BuildContext context,
    List<ChatMessage> messages,
    String agent,
    bool closed, {
    required void Function(ChatMessage) stop,
    required void Function(ChatMessage) retry,
    required void Function(ChatMessage) edit,
  }) {
    final now = DateTime.now();
    final out = <(String, Widget)>[];
    DateTime? lastDay;
    final lastAgent = messages.lastIndexWhere((m) => !m.fromOperator);
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      final at = (m.createdAt ?? now).toLocal();
      final day = DateTime(at.year, at.month, at.day);
      if (lastDay != day) {
        out.add(('day-$day', SystemNote(text: dayLabel(at, now), icon: Icons.calendar_today_outlined)));
        lastDay = day;
      }
      if (m.kind == 'close') {
        out.add(('close-${m.id}', switch (m.status) {
          MessageStatus.done => const SystemNote(text: 'Closed · the agent wrote a journal entry', icon: Icons.task_alt),
          MessageStatus.failed => FailedNote(message: m, onRetry: null),
          MessageStatus.cancelled => const SystemNote(text: 'Close cancelled'),
          _ => const SystemNote(text: 'Closing · writing the journal entry…', icon: Icons.hourglass_top),
        }));
        continue;
      }
      if (m.fromOperator) {
        out.add(('msg-${m.id}', OperatorBubble(message: m, onEdit: closed ? null : edit)));
        switch (m.status) {
          case MessageStatus.queued || MessageStatus.running:
            // Keyed by the question, as the reply will be: the streamed
            // answer becomes the finished one in place.
            out.add(('turn-${m.id}', PendingReply(message: m, agent: agent, onStop: () => stop(m))));
          case MessageStatus.failed:
            out.add(('failed-${m.id}', FailedNote(message: m, onRetry: closed ? null : () => retry(m))));
          case MessageStatus.cancelled:
            final next = i + 1 < messages.length ? messages[i + 1] : null;
            if (next == null || next.fromOperator || !next.stopped) {
              out.add(('stopped-${m.id}', const SystemNote(text: 'Stopped before a reply', icon: Icons.stop_circle_outlined)));
            }
          default:
        }
      } else {
        final prompt = messages.take(i).lastWhere((x) => x.fromOperator && x.kind != 'close', orElse: () => m);
        final turn = 'turn-${prompt.id}';
        final key = prompt.fromOperator && !out.any((e) => e.$1 == turn) ? turn : 'msg-${m.id}';
        out.add((key, AgentReply(
          message: m,
          agent: agent,
          latest: i == lastAgent,
          onRetry: i == lastAgent && !closed && prompt.fromOperator ? () => retry(prompt) : null,
        )));
      }
    }
    return out;
  }
}

/// A new conversation: pick an agent, write the first message.
class NewChatView extends ConsumerWidget {
  const NewChatView({super.key, this.onMenu});
  final VoidCallback? onMenu;

  static String greeting(DateTime now) {
    final h = now.hour;
    return h < 5 ? 'Working late' : h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final agent = ref.watch(newChatAgentProvider);
    final agents = ref.watch(agentsProvider);
    final hosts = ref.watch(allStatusProvider).value ?? const {};
    ref.watch(clockProvider);
    final now = DateTime.now();
    final narrow = MediaQuery.sizeOf(context).width < 600;

    String where(String a) {
      if (!ref.watch(allStatusProvider).hasValue) return '';
      if (a.startsWith('director-')) {
        final id = a.substring(9);
        return isFresh(hosts['devstation-$id'], now) ? 'On Devstation $id' : 'Devstation $id is stopped';
      }
      return isFresh(hosts['mac'], now) ? 'On the Mac' : 'In the cloud';
    }

    return Column(children: [
      if (onMenu != null) _ChatHeader(onMenu: onMenu, children: [Text('New chat', style: text.titleSmall)]),
      Expanded(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: narrow ? 24 : 56),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 800),
              child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
                AgentAvatar(agent: agent, size: 48),
                const SizedBox(height: 18),
                Text(
                  '${greeting(now)}.',
                  textAlign: TextAlign.center,
                  style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -.5),
                ),
                const SizedBox(height: 6),
                Text('Who do you want to talk to?', style: text.bodyLarge?.copyWith(color: t.muted)),
                const SizedBox(height: 28),
                ResponsiveGrid(
                  minWidth: 220,
                  gap: 10,
                  children: [
                    for (final a in agents)
                      _AgentCard(
                        name: a.name,
                        description: a.description,
                        where: where(a.name),
                        selected: a.name == agent,
                        onTap: () => ref.read(newChatAgentProvider.notifier).set(a.name),
                      ),
                  ],
                ),
              ]),
            ),
          ),
        ),
      ),
      Composer(
        draftKey: 'new',
        hint: 'Message ${agentLabel(agent)}…',
        autofocus: !narrow,
        onSend: (text, attachments, mentions) async {
          final id = await ref.read(repositoryProvider)!.startThread(agent: agent, text: text, attachments: attachments, mentions: mentions);
          ref.read(selectedThreadProvider.notifier).select(id);
        },
        leading: _AgentMenu(selected: agent, agents: [for (final a in agents) a.name]),
        footnote: 'Enter to send · Shift+Enter for a new line · @ to mention · drop files to attach',
      ),
    ]);
  }
}

class _AgentCard extends StatelessWidget {
  const _AgentCard({required this.name, required this.description, required this.where, required this.selected, required this.onTap});
  final String name;
  final String? description;
  final String where;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Semantics(
      selected: selected,
      button: true,
      label: 'Agent ${agentLabel(name)}',
      child: Material(
        color: selected ? scheme.primary.withValues(alpha: .08) : t.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: selected ? scheme.primary.withValues(alpha: .6) : t.border, width: selected ? 1.4 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AgentAvatar(agent: name, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(agentLabel(name), style: text.titleSmall),
                  if (description != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(description!, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodySmall?.copyWith(color: t.muted)),
                    ),
                  if (where.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(where, style: text.labelSmall?.copyWith(color: t.faint)),
                  ],
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _AgentMenu extends ConsumerWidget {
  const _AgentMenu({required this.selected, required this.agents});
  final String selected;
  final List<String> agents;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Tokens.of(context);
    return PopupMenuButton<String>(
      tooltip: 'Choose the agent',
      initialValue: selected,
      onSelected: (a) => ref.read(newChatAgentProvider.notifier).set(a),
      itemBuilder: (_) => [
        for (final a in agents)
          PopupMenuItem(
            value: a,
            child: Row(children: [AgentAvatar(agent: a, size: 20), const SizedBox(width: 10), Text(agentLabel(a))]),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: t.sunken, borderRadius: BorderRadius.circular(10)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          AgentAvatar(agent: selected, size: 18),
          const SizedBox(width: 8),
          Flexible(child: Text(agentLabel(selected), overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelLarge)),
          Icon(Icons.expand_more, size: 18, color: t.muted),
        ]),
      ),
    );
  }
}
