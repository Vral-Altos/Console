import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ui_mesh/ui_mesh.dart';

import 'code_editing.dart';

/// A plain code editor: line numbers, syntax colouring, no soft wrap,
/// Tab / Shift-Tab indent, auto-indent and bracket closing as you type,
/// word completion (Tab or a tap to accept, ↑/↓ to choose, Esc to dismiss),
/// and ⌘S / Ctrl-S to save.
class CodeEditor extends StatefulWidget {
  const CodeEditor({super.key, required this.controller, this.onSave, this.focusNode, this.readOnly = false});

  final CodeController controller;
  final VoidCallback? onSave;
  final FocusNode? focusNode;
  final bool readOnly;

  static const fontSize = 13.0;
  static const lineHeight = 1.45;

  @override
  State<CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<CodeEditor> {
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  final _completer = WordCompleter();
  final _v = ScrollController();
  final _h = ScrollController();
  List<String> _suggestions = const [];
  var _picked = 0;
  String _lastText = '';
  String _gutter = '1';
  var _lines = 1;
  var _longest = 0;

  @override
  void initState() {
    super.initState();
    _focus.onKeyEvent = _onKey;
    widget.controller.addListener(_changed);
    _measure();
  }

  @override
  void didUpdateWidget(CodeEditor old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _suggestions = const [];
      _measure();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    if (widget.focusNode == null) _focus.dispose();
    _v.dispose();
    _h.dispose();
    super.dispose();
  }

  void _measure() {
    final text = widget.controller.text;
    _lastText = text;
    var lines = 1, longest = 0, run = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 10) {
        lines++;
        longest = math.max(longest, run);
        run = 0;
      } else {
        run++;
      }
    }
    _longest = math.max(longest, run);
    if (lines != _lines || _gutter.isEmpty) {
      _lines = lines;
      _gutter = List.generate(lines, (i) => '${i + 1}').join('\n');
    }
  }

  void _changed() {
    final c = widget.controller;
    final textChanged = c.text != _lastText;
    if (textChanged) _measure();
    final next = textChanged && c.selection.isCollapsed && _focus.hasFocus
        ? _completer.suggest(c.text, c.selection.baseOffset, c.language)
        : (textChanged ? const <String>[] : _suggestions);
    if (textChanged || next != _suggestions) {
      setState(() {
        _suggestions = next;
        _picked = 0;
      });
    }
  }

  void _accept(String word) {
    final c = widget.controller;
    c.replace(acceptCompletion(c.value, word));
    setState(() => _suggestions = const []);
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final c = widget.controller;
    final key = e.logicalKey;
    if ((keys.isMetaPressed || keys.isControlPressed) && key == LogicalKeyboardKey.keyS) {
      widget.onSave?.call();
      return KeyEventResult.handled;
    }
    if (widget.readOnly) return KeyEventResult.ignored;
    if (_suggestions.isNotEmpty) {
      if (key == LogicalKeyboardKey.escape) {
        setState(() => _suggestions = const []);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
        final d = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
        setState(() => _picked = (_picked + d) % _suggestions.length);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.tab && !keys.isShiftPressed) {
        _accept(_suggestions[_picked]);
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.tab) {
      c.replace(indentLines(c.value, outdent: keys.isShiftPressed));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: VaType.mono,
      fontFamilyFallback: const ['Menlo', 'Consolas', 'monospace'],
      fontSize: CodeEditor.fontSize,
      height: CodeEditor.lineHeight,
      color: Theme.of(context).colorScheme.onSurface,
    );
    final strut = StrutStyle(
      fontFamily: VaType.mono,
      fontSize: CodeEditor.fontSize,
      height: CodeEditor.lineHeight,
      forceStrutHeight: true,
    );
    final charW =
        (TextPainter(
          text: TextSpan(text: 'MMMMMMMMMM', style: style),
          textDirection: TextDirection.ltr,
        )..layout()).width /
        10;
    final gutterW = '$_lines'.length * charW + 24;

    return Stack(
      children: [
        LayoutBuilder(
          builder: (context, box) {
            final width = math.max(box.maxWidth - gutterW, (_longest + 4) * charW + 24);
            return Scrollbar(
              controller: _v,
              child: SingleChildScrollView(
                controller: _v,
                padding: EdgeInsets.only(bottom: box.maxHeight / 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: gutterW,
                      padding: const EdgeInsets.only(right: 12, top: 8),
                      child: Text(
                        _gutter,
                        textAlign: TextAlign.right,
                        strutStyle: strut,
                        style: style.copyWith(color: VaColors.faint),
                      ),
                    ),
                    Expanded(
                      child: Scrollbar(
                        controller: _h,
                        child: SingleChildScrollView(
                          controller: _h,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: width,
                            child: TextField(
                              key: const ValueKey('code-field'),
                              controller: widget.controller,
                              focusNode: _focus,
                              readOnly: widget.readOnly,
                              maxLines: null,
                              style: style,
                              strutStyle: strut,
                              keyboardType: TextInputType.multiline,
                              autocorrect: false,
                              enableSuggestions: false,
                              smartDashesType: SmartDashesType.disabled,
                              smartQuotesType: SmartQuotesType.disabled,
                              textCapitalization: TextCapitalization.none,
                              scrollPhysics: const NeverScrollableScrollPhysics(),
                              decoration: const InputDecoration.collapsed(
                                hintText: '',
                              ).copyWith(contentPadding: const EdgeInsets.only(top: 8, right: 24)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        if (_suggestions.isNotEmpty)
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: Material(
              key: const ValueKey('completions'),
              elevation: 3,
              color: VaColors.panel,
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  children: [
                    for (final (i, w) in _suggestions.indexed)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () => _accept(w),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: i == _picked ? Theme.of(context).colorScheme.primary.withValues(alpha: .16) : null,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(w, style: style.copyWith(fontSize: 12.5, height: 1)),
                          ),
                        ),
                      ),
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text('Tab', style: TextStyle(fontSize: 12, color: VaColors.faint)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
