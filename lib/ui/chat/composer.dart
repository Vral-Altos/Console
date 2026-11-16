import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/attachments.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../theme.dart';
import '../widgets.dart';
import 'attachment_views.dart';
import 'file_io.dart';

typedef SendMessage = Future<void> Function(String text, List<AttachmentRef> attachments, List<MentionRef> mentions);

/// The message box: grows with its text; Enter sends, Shift+Enter breaks
/// the line. Files come from the paperclip, a paste or a drop (uploaded at
/// once, sent with the message); `@` mentions a conversation, a project or
/// an agent. While the agent is answering, the button stops it (typing a
/// new message turns it back into Send, which queues the message).
class Composer extends ConsumerStatefulWidget {
  const Composer({
    super.key,
    required this.draftKey,
    required this.hint,
    required this.onSend,
    this.threadId,
    this.onStop,
    this.onEditLast,
    this.stopping = false,
    this.leading,
    this.footnote,
    this.autofocus = false,
  });

  /// Which conversation's draft this is (kept while the Console is open).
  final String draftKey;
  final String hint;
  final SendMessage onSend;

  /// The conversation written in (not offered as a mention).
  final String? threadId;

  /// Set while a turn runs: shows the stop button.
  final VoidCallback? onStop;

  /// ↑ in an empty box: edit the last message sent.
  final VoidCallback? onEditLast;
  final bool stopping;
  final Widget? leading;
  final String? footnote;
  final bool autofocus;

  static const maxLength = 20000;

  @override
  ConsumerState<Composer> createState() => ComposerState();
}

class _Upload {
  _Upload(this.file);
  final PickedFile file;
  double progress = 0;
  AttachmentRef? ref;
  String? error;
  bool get done => ref != null;
}

/// One suggestion of the @ menu.
typedef MentionOption = ({MentionRef mention, String subtitle});

/// Highlights the mentions in the text being written.
class _MentionController extends TextEditingController {
  List<MentionRef> mentions = const [];
  Color? color;

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    if (mentions.isEmpty || (withComposing && value.composing.isValid)) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    return mentionSpan(context, text, mentions, style);
  }
}

class ComposerState extends ConsumerState<Composer> {
  final _c = _MentionController();
  final _focus = FocusNode();
  final _uploads = <_Upload>[];
  final _mentions = <MentionRef>[];
  bool _sending = false;
  bool _dragging = false;
  String? _error;
  void Function()? _unlisten;

  /// Kept for dispose (providers cannot be read then).
  AttachmentStore? _store;

  /// The `@query` being typed: where its `@` is, and the query.
  ({int start, String query})? _at;
  int? _dismissedAt;
  int _highlight = 0;
  List<MentionOption> _shown = const [];

  @override
  void initState() {
    super.initState();
    _c.text = ref.read(draftsProvider)[widget.draftKey] ?? '';
    _c.addListener(_changed);
    _unlisten = listenForFiles(
      onFiles: (files) {
        if (mounted && ref.read(pageProvider) == ConsolePage.chat) add(files);
      },
      onDragging: (d) {
        if (mounted && ref.read(pageProvider) == ConsolePage.chat) setState(() => _dragging = d);
      },
    );
  }

  @override
  void didUpdateWidget(Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.draftKey != widget.draftKey) _c.text = ref.read(draftsProvider)[widget.draftKey] ?? '';
  }

  @override
  void dispose() {
    _unlisten?.call();
    _c.removeListener(_changed);
    _c.dispose();
    _focus.dispose();
    // Uploads never sent go again.
    for (final u in _uploads) {
      if (u.ref != null) unawaited(_store?.discard(u.ref!));
    }
    super.dispose();
  }

  void _changed() {
    ref.read(draftsProvider.notifier).set(widget.draftKey, _c.text);
    final sel = _c.selection;
    ({int start, String query})? at;
    if (sel.isValid && sel.isCollapsed && sel.baseOffset <= _c.text.length) {
      final m = RegExp(r'(?:^|\s)@([^\s@]{0,40})$').firstMatch(_c.text.substring(0, sel.baseOffset));
      if (m != null) at = (start: sel.baseOffset - m[1]!.length - 1, query: m[1]!);
    }
    if (at?.start != _at?.start || at?.query != _at?.query) _highlight = 0;
    if (at == null || at.start != _dismissedAt) _dismissedAt = null;
    _at = at;
    // Mentions whose text was deleted are dropped.
    _mentions.removeWhere((m) => !_c.text.contains(m.token));
    setState(() {}); // the button follows the text
  }

  /// Puts a sent message back for editing.
  void restore(String text, {List<AttachmentRef> attachments = const [], List<MentionRef> mentions = const []}) {
    setState(() {
      _uploads
        ..clear()
        ..addAll([for (final a in attachments) _Upload(PickedFile(name: a.name, bytes: Uint8List(0), contentType: a.contentType))..ref = a..progress = 1]);
      _mentions
        ..clear()
        ..addAll(mentions);
    });
    _c.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    _focus.requestFocus();
  }

  /// Uploads [files] for the next message.
  void add(List<PickedFile> files) {
    if (files.isEmpty) return;
    final store = ref.read(attachmentStoreProvider);
    if (store == null) {
      setState(() => _error = 'Attachments are not configured in this build.');
      return;
    }
    final room = AttachmentLimits.maxFiles - _uploads.length;
    final problems = <String>[];
    if (files.length > room) problems.add('At most ${AttachmentLimits.maxFiles} files per message.');
    for (final f in files.take(room.clamp(0, files.length))) {
      if (f.size > AttachmentLimits.maxBytes) {
        problems.add('${f.name} is over ${AttachmentLimits.maxBytes ~/ (1024 * 1024)} MB.');
        continue;
      }
      if (f.size == 0) {
        problems.add('${f.name} is empty.');
        continue;
      }
      final u = _Upload(f);
      _uploads.add(u);
      _start(store, u);
    }
    setState(() => _error = problems.isEmpty ? null : problems.join(' '));
    _focus.requestFocus();
  }

  Future<void> _start(AttachmentStore store, _Upload u) async {
    try {
      u.error = null;
      final r = await store.upload(u.file, onProgress: (p) {
        if (mounted) setState(() => u.progress = p);
      });
      if (!mounted || !_uploads.contains(u)) {
        unawaited(store.discard(r));
        return;
      }
      setState(() {
        u.ref = r;
        u.progress = 1;
      });
    } catch (e) {
      if (mounted) setState(() => u.error = 'Upload failed — tap to retry');
    }
  }

  void _remove(_Upload u) {
    setState(() => _uploads.remove(u));
    if (u.ref != null) unawaited(ref.read(attachmentStoreProvider)?.discard(u.ref!));
  }

  Future<void> _pick() async {
    try {
      add(await pickFiles());
    } catch (e) {
      setState(() => _error = 'Could not read the files: $e');
    }
  }

  void _startMention() {
    final v = _c.value;
    final at = v.selection.isValid ? v.selection.baseOffset : v.text.length;
    final before = v.text.substring(0, at);
    final insert = before.isEmpty || before.endsWith(' ') || before.endsWith('\n') ? '@' : ' @';
    _c.value = TextEditingValue(
      text: before + insert + v.text.substring(at),
      selection: TextSelection.collapsed(offset: at + insert.length),
    );
    _focus.requestFocus();
  }

  void _pickMention(MentionRef m) {
    final at = _at;
    if (at == null) return;
    final caret = _c.selection.baseOffset;
    final token = '${m.token} ';
    final text = _c.text.replaceRange(at.start, caret, token);
    if (!_mentions.contains(m)) _mentions.add(m);
    _c.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: at.start + token.length));
    _focus.requestFocus();
  }

  bool get _uploading => _uploads.any((u) => !u.done);
  bool get _canSend =>
      !_sending && !_uploading && (_c.text.trim().isNotEmpty || _uploads.isNotEmpty);

  Future<void> _send() async {
    if (!_canSend) return;
    final text = _c.text.trim();
    final files = [for (final u in _uploads) u.ref!];
    final mentions = [for (final m in _mentions) if (text.contains(m.token)) m];
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.onSend(text, files, mentions);
      _uploads.clear(); // sent: kept with the message
      _mentions.clear();
      _c.clear();
    } catch (e) {
      if (mounted) setState(() => _error = 'Not sent: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (_shown.isNotEmpty) {
      if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
        setState(() => _highlight = (_highlight + (key == LogicalKeyboardKey.arrowDown ? 1 : -1)) % _shown.length);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.tab) {
        if (e is KeyDownEvent) _pickMention(_shown[_highlight.clamp(0, _shown.length - 1)].mention);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        setState(() => _dismissedAt = _at?.start);
        return KeyEventResult.handled;
      }
    }
    if (e is KeyDownEvent && key == LogicalKeyboardKey.escape && widget.onStop != null && !widget.stopping) {
      widget.onStop!();
      return KeyEventResult.handled;
    }
    if (e is KeyDownEvent && key == LogicalKeyboardKey.arrowUp && widget.onEditLast != null && _c.text.isEmpty && _uploads.isEmpty) {
      widget.onEditLast!();
      return KeyEventResult.handled;
    }
    if (e is! KeyDownEvent || key != LogicalKeyboardKey.enter) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isShiftPressed || _c.value.composing.isValid) return KeyEventResult.ignored;
    _send();
    return KeyEventResult.handled;
  }

  /// What @ can mention: watched while the composer is up, so the menu
  /// opens with everything in hand.
  List<MentionOption> _options({
    required List<({String name, String? description})> agents,
    required List<Devstation> devstations,
    required List<ChatThread> threads,
  }) {
    final at = _at;
    if (at == null || at.start == _dismissedAt || !_focus.hasFocus) return const [];
    final q = at.query.toLowerCase();
    final now = DateTime.now();
    final all = <MentionOption>[
      for (final a in agents)
        (mention: MentionRef(kind: MentionKind.agent, id: a.name, label: agentLabel(a.name).replaceAll(' · ', '-')), subtitle: a.description ?? 'Agent'),
      for (final d in devstations)
        (mention: MentionRef(kind: MentionKind.project, id: d.id, label: _label(d.project)), subtitle: 'Project · Devstation ${d.id} · ${d.state}'),
      for (final t in threads.where((t) => !t.archived && t.id != widget.threadId).take(60))
        (
          mention: MentionRef(kind: MentionKind.thread, id: t.id, label: _label(t.title)),
          subtitle: 'Conversation · ${t.projectName} · ${agentLabel(t.agent)}${t.updatedAt == null ? '' : ' · ${ago(t.updatedAt, now: now)}'}',
        ),
    ];
    int rank(MentionOption o) {
      final l = o.mention.label.toLowerCase();
      return l.startsWith(q) ? 0 : l.split(RegExp(r'[\s_-]')).any((w) => w.startsWith(q)) ? 1 : 2;
    }

    final hits = q.isEmpty ? all : all.where((o) => o.mention.label.toLowerCase().contains(q) || o.mention.id.toLowerCase().contains(q)).toList();
    final ordered = [...hits]..sort((a, b) => rank(a).compareTo(rank(b)));
    // A few of each kind when nothing is typed yet.
    if (q.isEmpty) {
      return [
        for (final k in MentionKind.values) ...ordered.where((o) => o.mention.kind == k).take(k == MentionKind.thread ? 4 : 5),
      ]..sort((a, b) => _kindOrder(a.mention.kind).compareTo(_kindOrder(b.mention.kind)));
    }
    return ordered.take(8).toList();
  }

  static int _kindOrder(MentionKind k) => switch (k) {
    MentionKind.thread => 0,
    MentionKind.project => 1,
    MentionKind.agent => 2,
  };

  static String _label(String s) {
    final one = s.replaceAll(RegExp(r'[\s@]+'), ' ').trim();
    return one.length <= 40 ? one : '${one.substring(0, 39)}…';
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final empty = _c.text.trim().isEmpty && _uploads.isEmpty;
    final showStop = widget.onStop != null && empty;
    final long = _c.text.length > Composer.maxLength * .9;
    _c.mentions = List.of(_mentions);
    _shown = _options(
      agents: ref.watch(agentsProvider),
      devstations: ref.watch(devstationsProvider).value ?? const [],
      threads: ref.watch(threadsProvider).value ?? const [],
    );
    if (_highlight >= _shown.length) _highlight = 0;
    _store = ref.watch(attachmentStoreProvider);
    final canAttach = _store != null;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_shown.isNotEmpty)
                _MentionMenu(
                  options: _shown,
                  highlight: _highlight,
                  onPick: _pickMention,
                  onHover: (i) => setState(() => _highlight = i),
                ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  color: _dragging ? scheme.primary.withValues(alpha: .05) : t.panel,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: _dragging
                        ? scheme.primary
                        : _focus.hasFocus
                        ? t.faint.withValues(alpha: .7)
                        : t.border,
                    width: _dragging ? 1.6 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: _focus.hasFocus ? .09 : .05), blurRadius: _focus.hasFocus ? 24 : 18, offset: const Offset(0, 6)),
                  ],
                ),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (_dragging)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Row(children: [
                        Icon(Icons.file_download_outlined, size: 18, color: scheme.primary),
                        const SizedBox(width: 8),
                        Text('Drop to attach', style: text.labelLarge?.copyWith(color: scheme.primary)),
                      ]),
                    ),
                  if (_uploads.isNotEmpty)
                    SizedBox(
                      height: 62,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(10, 10, 10, 2),
                        itemCount: _uploads.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, i) {
                          final u = _uploads[i];
                          final type = contentTypeFor(u.file.name, u.file.contentType);
                          final image = type != null && type.startsWith('image/') && type != 'image/svg+xml' && u.file.bytes.isNotEmpty;
                          return FileChip(
                            name: u.file.name,
                            contentType: type,
                            size: u.ref?.size ?? u.file.size,
                            thumbnail: image ? Image.memory(u.file.bytes, fit: BoxFit.cover, cacheWidth: 96) : null,
                            progress: u.done || u.error != null ? null : u.progress,
                            error: u.error,
                            onTap: u.error == null ? null : () => _start(ref.read(attachmentStoreProvider)!, u),
                            onRemove: () => _remove(u),
                          );
                        },
                      ),
                    ),
                  Focus(
                    onKeyEvent: _onKey,
                    onFocusChange: (_) => setState(() {}),
                    child: TextField(
                      controller: _c,
                      focusNode: _focus,
                      autofocus: widget.autofocus,
                      minLines: 1,
                      maxLines: 10,
                      maxLength: Composer.maxLength,
                      textInputAction: TextInputAction.newline,
                      keyboardType: TextInputType.multiline,
                      style: text.bodyLarge,
                      buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                      decoration: InputDecoration(
                        hintText: widget.hint,
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 8, 8),
                    child: Row(children: [
                      IconButton(
                        tooltip: canAttach ? 'Attach files' : 'Attachments are not configured',
                        onPressed: canAttach && _uploads.length < AttachmentLimits.maxFiles ? _pick : null,
                        icon: Icon(Icons.attach_file, size: 20, color: t.muted),
                      ),
                      IconButton(
                        tooltip: 'Mention a conversation, project or agent',
                        onPressed: _startMention,
                        icon: Icon(Icons.alternate_email, size: 20, color: t.muted),
                      ),
                      if (widget.leading != null) ...[
                        const SizedBox(width: 4),
                        Flexible(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 340), child: widget.leading!)),
                      ],
                      const Spacer(),
                      if (long)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text('${_c.text.length} / ${Composer.maxLength}', style: text.labelSmall?.copyWith(color: t.warn)),
                        ),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        transitionBuilder: (c, a) => ScaleTransition(scale: Tween(begin: .7, end: 1.0).animate(a), child: FadeTransition(opacity: a, child: c)),
                        child: showStop
                            ? IconButton.filled(
                                key: const ValueKey('stop'),
                                tooltip: widget.stopping ? 'Stopping…' : 'Stop',
                                onPressed: widget.stopping ? null : widget.onStop,
                                style: IconButton.styleFrom(backgroundColor: scheme.onSurface, foregroundColor: t.panel),
                                icon: widget.stopping
                                    ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: t.panel))
                                    : const Icon(Icons.stop_rounded, size: 20),
                              )
                            : IconButton.filled(
                                key: const ValueKey('send'),
                                tooltip: _uploading ? 'Waiting for uploads…' : 'Send',
                                onPressed: _canSend ? _send : null,
                                icon: _sending
                                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.arrow_upward_rounded, size: 20),
                              ),
                      ),
                    ]),
                  ),
                ]),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 6),
                  child: Text(_error!, style: text.labelSmall?.copyWith(color: t.bad)),
                )
              else if (widget.footnote != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(widget.footnote!, textAlign: TextAlign.center, style: text.labelSmall?.copyWith(color: t.faint)),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _MentionMenu extends StatelessWidget {
  const _MentionMenu({required this.options, required this.highlight, required this.onPick, required this.onHover});
  final List<MentionOption> options;
  final int highlight;
  final void Function(MentionRef) onPick;
  final void Function(int) onHover;

  static String _heading(MentionKind k) => switch (k) {
    MentionKind.thread => 'Conversations',
    MentionKind.project => 'Projects',
    MentionKind.agent => 'Agents',
  };

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final rows = <Widget>[];
    MentionKind? last;
    for (final (i, o) in options.indexed) {
      if (o.mention.kind != last) {
        last = o.mention.kind;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 2),
          child: Text(_heading(last), style: text.labelSmall?.copyWith(color: t.faint, fontWeight: FontWeight.w600)),
        ));
      }
      rows.add(MouseRegion(
        onEnter: (_) => onHover(i),
        child: Semantics(
          button: true,
          selected: i == highlight,
          label: 'Mention ${o.mention.label}',
          excludeSemantics: true,
          child: InkWell(
            onTap: () => onPick(o.mention),
            child: Container(
              color: i == highlight ? scheme.primary.withValues(alpha: .09) : null,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(children: [
                if (o.mention.kind == MentionKind.agent)
                  AgentAvatar(agent: o.mention.id, size: 22)
                else
                  Icon(mentionIcon(o.mention.kind), size: 18, color: t.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(o.mention.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                    Text(o.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.labelSmall?.copyWith(color: t.faint)),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ));
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: t.panel,
        elevation: 6,
        shadowColor: Colors.black26,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: t.border)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 300),
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
          ),
        ),
      ),
    );
  }
}
