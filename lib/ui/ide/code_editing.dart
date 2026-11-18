import 'package:flutter/material.dart';

import '../chat/code_highlight.dart';

/// The highlight grammar for a file name, or null for plain text.
String? languageForFile(String name) {
  final lower = name.toLowerCase();
  if (lower == 'dockerfile' || lower.endsWith('.dockerfile')) return 'dockerfile';
  if (lower == 'makefile') return 'bash';
  final dot = lower.lastIndexOf('.');
  if (dot < 0) return null;
  return switch (lower.substring(dot + 1)) {
    'dart' => 'dart',
    'py' => 'python',
    'js' || 'mjs' || 'cjs' || 'jsx' || 'rules' => 'javascript',
    'ts' || 'tsx' => 'typescript',
    'json' || 'arb' || 'jsonc' => 'json',
    'yaml' || 'yml' => 'yaml',
    'md' || 'markdown' => 'markdown',
    'sh' || 'bash' || 'zsh' || 'env' => 'bash',
    'go' => 'go',
    'rs' => 'rust',
    'java' => 'java',
    'kt' || 'kts' || 'gradle' => 'kotlin',
    'swift' => 'swift',
    'c' || 'h' || 'cc' || 'cpp' || 'hpp' || 'm' || 'mm' => 'cpp',
    'css' || 'scss' => 'css',
    'html' || 'xml' || 'svg' || 'plist' => 'xml',
    'sql' => 'sql',
    'tf' || 'tfvars' || 'hcl' || 'toml' || 'ini' || 'cfg' || 'conf' => 'ini',
    'diff' || 'patch' => 'diff',
    _ => null,
  };
}

const _pairs = {'(': ')', '[': ']', '{': '}'};
const _closers = {')', ']', '}'};

/// Where the line containing [offset] starts.
int lineStart(String text, int offset) => offset <= 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;

/// The leading whitespace of the line containing [offset].
String lineIndent(String text, int offset) {
  final start = lineStart(text, offset);
  var end = start;
  while (end < text.length && (text[end] == ' ' || text[end] == '\t')) {
    end++;
  }
  return text.substring(start, end);
}

/// Editing helpers applied as the operator types (soft keyboards included,
/// so they work from what changed rather than from key presses):
/// a new line keeps the indentation (one level more after an opening
/// bracket, or a colon in Python/YAML), and splits a bracket pair onto
/// three lines; an opening bracket gets its closer; typing a closer that is
/// already there steps over it. Returns null when [next] is left as it is.
TextEditingValue? assistEdit(TextEditingValue old, TextEditingValue next, {String? language, String tab = '  '}) {
  if (next.composing.isValid || !next.selection.isCollapsed || !old.selection.isValid) return null;
  final sel = old.selection;
  final before = old.text.substring(0, sel.start);
  final after = old.text.substring(sel.end);
  // Exactly one character typed at the cursor (replacing any selection)?
  if (next.text.length != before.length + 1 + after.length ||
      !next.text.startsWith(before) ||
      !next.text.endsWith(after) ||
      next.selection.baseOffset != before.length + 1) {
    return null;
  }
  final ch = next.text[before.length];
  if (ch == '\n') {
    final indent = lineIndent(before, before.length);
    final trimmed = before.trimRight();
    final last = trimmed.isEmpty ? '' : trimmed[trimmed.length - 1];
    final opens = _pairs.containsKey(last) || (last == ':' && (language == 'python' || language == 'yaml'));
    final inner = opens ? '$indent$tab' : indent;
    if (opens && after.isNotEmpty && _pairs[last] == after[0]) {
      final text = '$before\n$inner\n$indent$after';
      return TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: before.length + 1 + inner.length),
      );
    }
    if (inner.isEmpty) return null;
    final text = '$before\n$inner$after';
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: before.length + 1 + inner.length),
    );
  }
  if (_closers.contains(ch) && after.startsWith(ch) && sel.isCollapsed) {
    return TextEditingValue(
      text: old.text,
      selection: TextSelection.collapsed(offset: before.length + 1),
    );
  }
  final close = _pairs[ch];
  if (close != null && sel.isCollapsed && (after.isEmpty || RegExp(r'^[\s\)\]\},;]').hasMatch(after))) {
    return TextEditingValue(
      text: '$before$ch$close$after',
      selection: TextSelection.collapsed(offset: before.length + 1),
    );
  }
  return null;
}

/// Indents (or with [outdent], outdents) every line the selection touches;
/// a collapsed selection with no outdent inserts [tab] at the cursor.
TextEditingValue indentLines(TextEditingValue v, {bool outdent = false, String tab = '  '}) {
  final text = v.text;
  final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: text.length);
  if (sel.isCollapsed && !outdent) {
    final t = text.replaceRange(sel.start, sel.end, tab);
    return TextEditingValue(
      text: t,
      selection: TextSelection.collapsed(offset: sel.start + tab.length),
    );
  }
  final first = lineStart(text, sel.start);
  var lineEnd = text.indexOf('\n', sel.end > sel.start && text[sel.end - 1] == '\n' ? sel.end - 1 : sel.end);
  if (lineEnd < 0) lineEnd = text.length;
  final lines = text.substring(first, lineEnd).split('\n');
  var startShift = 0, total = 0;
  final out = <String>[];
  for (final (i, line) in lines.indexed) {
    if (outdent) {
      var n = 0;
      while (n < tab.length && n < line.length && (line[n] == ' ' || line[n] == '\t')) {
        if (line[n] == '\t') {
          n++;
          break;
        }
        n++;
      }
      out.add(line.substring(n));
      if (i == 0) startShift = -n;
      total -= n;
    } else {
      out.add('$tab$line');
      if (i == 0) startShift = tab.length;
      total += tab.length;
    }
  }
  final t = text.replaceRange(first, lineEnd, out.join('\n'));
  final start = (sel.start + startShift).clamp(first, t.length);
  final end = (sel.end + total).clamp(start, t.length);
  return TextEditingValue(
    text: t,
    selection: TextSelection(baseOffset: start, extentOffset: end),
  );
}

final _word = RegExp(r'[A-Za-z_$][A-Za-z0-9_$]*');

/// The identifier being typed just before [offset] (empty if none).
String wordBefore(String text, int offset) {
  var i = offset;
  while (i > 0 && RegExp(r'[A-Za-z0-9_$]').hasMatch(text[i - 1])) {
    i--;
  }
  return text.substring(i, offset);
}

/// Word completion: identifiers already in the file (most frequent first),
/// then the language's keywords, that start with what is being typed.
class WordCompleter {
  String _indexed = '';
  Map<String, int> _counts = const {};
  DateTime _at = DateTime.fromMillisecondsSinceEpoch(0);

  List<String> suggest(String text, int offset, String? language, {int max = 8}) {
    final prefix = wordBefore(text, offset);
    if (prefix.length < 2 || RegExp(r'^[0-9]').hasMatch(prefix)) return const [];
    // Re-index at most once a second while typing (large files).
    if (!identical(text, _indexed) && DateTime.now().difference(_at) > const Duration(seconds: 1) || _counts.isEmpty) {
      final counts = <String, int>{};
      for (final m in _word.allMatches(text)) {
        final w = m[0]!;
        if (w.length > 2) counts[w] = (counts[w] ?? 0) + 1;
      }
      _counts = counts;
      _indexed = text;
      _at = DateTime.now();
    }
    final lower = prefix.toLowerCase();
    bool fits(String w) => w != prefix && w.toLowerCase().startsWith(lower);
    final words = _counts.entries.where((e) => fits(e.key)).toList()
      ..sort((a, b) {
        final exact = (b.key.startsWith(prefix) ? 1 : 0) - (a.key.startsWith(prefix) ? 1 : 0);
        return exact != 0 ? exact : b.value.compareTo(a.value);
      });
    // A word typed once is the one being typed now: not a suggestion.
    final out = <String>[
      for (final e in words)
        if (!(e.value == 1 &&
            e.key.startsWith(prefix) &&
            text.substring(offset).startsWith(e.key.substring(prefix.length))))
          e.key,
    ];
    for (final k in languageKeywords(language)) {
      if (fits(k) && !out.contains(k)) out.add(k);
    }
    return out.take(max).toList();
  }
}

/// Replaces the word before the cursor with [word].
TextEditingValue acceptCompletion(TextEditingValue v, String word) {
  final at = v.selection.baseOffset;
  final prefix = wordBefore(v.text, at);
  final start = at - prefix.length;
  final text = v.text.replaceRange(start, at, word);
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: start + word.length),
  );
}

/// A text controller for code: syntax colouring, and [assistEdit] on typing.
class CodeController extends TextEditingController {
  CodeController({super.text, this.language});

  String? language;

  /// Larger files are shown plain (colouring them on every key is slow).
  static const highlightLimit = 120 * 1000;

  @override
  set value(TextEditingValue next) {
    final assisted = assistEdit(super.value, next, language: language);
    super.value = assisted ?? next;
  }

  /// Sets the text without the typing helpers (loading, completion).
  void replace(TextEditingValue v) => super.value = v;

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final base = style ?? const TextStyle();
    if (value.composing.isValid && withComposing || text.length > highlightLimit || !hasGrammar(language)) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    return highlightCode(context, text, language, base);
  }
}
