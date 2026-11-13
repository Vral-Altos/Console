import 'package:flutter/material.dart';
import 'package:highlight/highlight_core.dart';
import 'package:highlight/languages/bash.dart';
import 'package:highlight/languages/cpp.dart';
import 'package:highlight/languages/css.dart';
import 'package:highlight/languages/dart.dart';
import 'package:highlight/languages/diff.dart';
import 'package:highlight/languages/dockerfile.dart';
import 'package:highlight/languages/go.dart';
import 'package:highlight/languages/ini.dart';
import 'package:highlight/languages/java.dart';
import 'package:highlight/languages/javascript.dart';
import 'package:highlight/languages/json.dart';
import 'package:highlight/languages/kotlin.dart';
import 'package:highlight/languages/markdown.dart';
import 'package:highlight/languages/python.dart';
import 'package:highlight/languages/rust.dart';
import 'package:highlight/languages/shell.dart';
import 'package:highlight/languages/sql.dart';
import 'package:highlight/languages/swift.dart';
import 'package:highlight/languages/typescript.dart';
import 'package:highlight/languages/xml.dart';
import 'package:highlight/languages/yaml.dart';

import '../theme.dart';

/// Syntax colouring for fenced code. Only the languages the agents
/// commonly write are bundled (the full set would add ~1 MB to the web
/// build); anything else is shown as plain text.
final Highlight _hl = Highlight()
  ..registerLanguages({
    'bash': bash,
    'cpp': cpp,
    'css': css,
    'dart': dart,
    'diff': diff,
    'dockerfile': dockerfile,
    'go': go,
    'ini': ini,
    'java': java,
    'javascript': javascript,
    'json': json,
    'kotlin': kotlin,
    'markdown': markdown,
    'python': python,
    'rust': rust,
    'shell': shell,
    'sql': sql,
    'swift': swift,
    'typescript': typescript,
    'xml': xml,
    'yaml': yaml,
  });

/// Fence names the bundled grammars do not alias themselves.
const _extraAliases = {'toml': 'ini', 'hcl': 'ini', 'tf': 'ini', 'terraform': 'ini', 'zsh': 'bash', 'sh': 'bash', 'html': 'xml'};

/// The colours of each token class, derived from the Console's palette so
/// code reads in both themes.
Map<String, TextStyle> _styles(BuildContext context) {
  final t = Tokens.of(context);
  final dark = Theme.of(context).brightness == Brightness.dark;
  final keyword = TextStyle(color: dark ? const Color(0xFFC79BFF) : const Color(0xFF8A3FD1));
  final string = TextStyle(color: dark ? const Color(0xFF8BD49C) : const Color(0xFF1C7C4A));
  final number = TextStyle(color: dark ? const Color(0xFFF0A35E) : const Color(0xFFB0571B));
  final title = TextStyle(color: dark ? const Color(0xFF7FB4FF) : const Color(0xFF2F5FC4));
  final type = TextStyle(color: dark ? const Color(0xFF5FD0C0) : const Color(0xFF137A6E));
  final comment = TextStyle(color: t.faint, fontStyle: FontStyle.italic);
  final meta = TextStyle(color: t.muted);
  return {
    'keyword': keyword,
    'selector-tag': keyword,
    'built_in': type,
    'type': type,
    'class': type,
    'literal': number,
    'number': number,
    'symbol': number,
    'string': string,
    'regexp': string,
    'addition': string,
    'subst': const TextStyle(),
    'title': title,
    'function': title,
    'section': title.copyWith(fontWeight: FontWeight.w600),
    'name': keyword,
    'tag': meta,
    'attr': title,
    'attribute': title,
    'variable': number,
    'template-variable': number,
    'params': const TextStyle(),
    'comment': comment,
    'quote': comment,
    'doctag': comment.copyWith(fontStyle: FontStyle.normal),
    'meta': meta,
    'meta-keyword': keyword,
    'meta-string': string,
    'deletion': TextStyle(color: t.bad),
    'emphasis': const TextStyle(fontStyle: FontStyle.italic),
    'strong': const TextStyle(fontWeight: FontWeight.w600),
    'bullet': number,
    'link': title,
  };
}

final _cache = <String, List<Node>>{};

List<Node>? _parse(String code, String language) {
  final key = '$language\u0000$code';
  final hit = _cache.remove(key);
  if (hit != null) return _cache[key] = hit; // most recent last
  try {
    final nodes = _hl.parse(code, language: _extraAliases[language] ?? language).nodes;
    if (nodes == null) return null;
    if (_cache.length >= 48) _cache.remove(_cache.keys.first);
    return _cache[key] = nodes;
  } catch (_) {
    return null; // a grammar choked on half-written code: show it plain
  }
}

/// [code] as coloured spans in [base], or plain when [language] is unknown.
TextSpan highlightCode(BuildContext context, String code, String? language, TextStyle base) {
  final lang = language?.toLowerCase().trim();
  final nodes = lang == null || lang.isEmpty || lang == 'text' || lang == 'plaintext' ? null : _parse(code, lang);
  if (nodes == null) return TextSpan(text: code, style: base);
  final styles = _styles(context);
  List<InlineSpan> walk(List<Node> list) => [
    for (final n in list)
      if (n.value != null)
        TextSpan(text: n.value, style: styles[n.className])
      else
        TextSpan(style: styles[n.className], children: walk(n.children ?? const [])),
  ];
  return TextSpan(style: base, children: walk(nodes));
}
