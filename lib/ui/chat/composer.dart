import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../theme.dart';

/// The message box: grows with its text; Enter sends, Shift+Enter breaks
/// the line. While the agent is answering, the button stops it (typing a
/// new message turns it back into Send, which queues the message).
class Composer extends ConsumerStatefulWidget {
  const Composer({
    super.key,
    required this.draftKey,
    required this.hint,
    required this.onSend,
    this.controller,
    this.onStop,
    this.stopping = false,
    this.leading,
    this.footnote,
    this.autofocus = false,
  });

  /// Which conversation's draft this is (kept while the Console is open).
  final String draftKey;
  final String hint;
  final Future<void> Function(String text) onSend;
  final TextEditingController? controller;

  /// Set while a turn runs: shows the stop button.
  final VoidCallback? onStop;
  final bool stopping;
  final Widget? leading;
  final String? footnote;
  final bool autofocus;

  static const maxLength = 20000;

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  late TextEditingController _c;
  bool _own = false;
  final _focus = FocusNode();
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _own = widget.controller == null;
    _c = widget.controller ?? TextEditingController();
    final draft = ref.read(draftsProvider)[widget.draftKey];
    if (draft != null && _c.text.isEmpty) _c.text = draft;
    _c.addListener(_changed);
  }

  @override
  void didUpdateWidget(Composer old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller || old.draftKey != widget.draftKey) {
      _c.removeListener(_changed);
      if (_own) _c.dispose();
      _attach();
      if (old.draftKey != widget.draftKey) _c.text = ref.read(draftsProvider)[widget.draftKey] ?? '';
    }
  }

  void _changed() {
    ref.read(draftsProvider.notifier).set(widget.draftKey, _c.text);
    setState(() {}); // the button follows the text
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    if (_own) _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _c.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.onSend(text);
      _c.clear();
    } catch (e) {
      if (mounted) setState(() => _error = 'Not sent: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.enter) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isShiftPressed || _c.value.composing.isValid) return KeyEventResult.ignored;
    _send();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final empty = _c.text.trim().isEmpty;
    final showStop = widget.onStop != null && empty;
    final long = _c.text.length > Composer.maxLength * .9;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                decoration: BoxDecoration(
                  color: t.panel,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: _focus.hasFocus ? scheme.primary.withValues(alpha: .55) : t.border),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: .05), blurRadius: 18, offset: const Offset(0, 4)),
                  ],
                ),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: Row(children: [
                      if (widget.leading != null) ConstrainedBox(constraints: const BoxConstraints(maxWidth: 240), child: widget.leading!),
                      const Spacer(),
                      if (long)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text('${_c.text.length} / ${Composer.maxLength}',
                              style: text.labelSmall?.copyWith(color: t.warn)),
                        ),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 150),
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
                                tooltip: 'Send',
                                onPressed: empty || _sending ? null : _send,
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
