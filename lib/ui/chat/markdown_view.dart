import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';

/// An agent's reply as rendered Markdown (GitHub flavour: tables, task
/// lists, fenced code with a copy button). Links open in a new tab. Text is
/// selectable through the conversation's SelectionArea.
class MarkdownView extends StatelessWidget {
  const MarkdownView({super.key, required this.data, this.selectable = false});
  final String data;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = Tokens.of(context);
    final body = theme.textTheme.bodyLarge!;
    final sheet = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: body,
      pPadding: EdgeInsets.zero,
      blockSpacing: 12,
      h1: theme.textTheme.titleLarge?.copyWith(fontSize: 21),
      h2: theme.textTheme.titleLarge?.copyWith(fontSize: 18.5),
      h3: theme.textTheme.titleMedium?.copyWith(fontSize: 16.5),
      h4: theme.textTheme.titleSmall,
      h1Padding: const EdgeInsets.only(top: 6),
      h2Padding: const EdgeInsets.only(top: 6),
      h3Padding: const EdgeInsets.only(top: 4),
      listBullet: body,
      listIndent: 22,
      strong: const TextStyle(fontWeight: FontWeight.w600),
      a: TextStyle(color: theme.colorScheme.primary, decoration: TextDecoration.underline, decorationColor: theme.colorScheme.primary.withValues(alpha: .4)),
      code: TextStyle(
        fontFamily: t.mono,
        fontSize: body.fontSize! * .86,
        backgroundColor: t.sunken,
        color: theme.colorScheme.onSurface,
      ),
      blockquote: body.copyWith(color: t.muted),
      blockquoteDecoration: BoxDecoration(border: Border(left: BorderSide(color: t.border, width: 3))),
      blockquotePadding: const EdgeInsets.fromLTRB(14, 2, 0, 2),
      tableHead: body.copyWith(fontWeight: FontWeight.w600, fontSize: 14),
      tableBody: body.copyWith(fontSize: 14),
      tableBorder: TableBorder.all(color: t.border, width: 1),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      tableColumnWidth: const IntrinsicColumnWidth(),
      horizontalRuleDecoration: BoxDecoration(border: Border(top: BorderSide(color: t.border))),
      checkbox: body.copyWith(color: theme.colorScheme.primary),
    );
    return MarkdownBody(
      data: data,
      selectable: selectable,
      styleSheet: sheet,
      softLineBreak: true,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      builders: {'pre': _CodeBuilder()},
      onTapLink: (text, href, title) {
        final uri = href == null ? null : Uri.tryParse(href);
        if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http' || uri.scheme == 'mailto')) {
          unawaited(launchUrl(uri, webOnlyWindowName: '_blank'));
        }
      },
    );
  }
}

class _CodeBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = element.children?.whereType<md.Element>().firstOrNull;
    final lang = (code?.attributes['class'] ?? '').replaceFirst('language-', '');
    var text = element.textContent;
    if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
    return CodeBlock(code: text, language: lang.isEmpty ? null : lang);
  }
}

/// A fenced code block: language, copy button, horizontal scroll.
class CodeBlock extends StatefulWidget {
  const CodeBlock({super.key, required this.code, this.language});
  final String code;
  final String? language;

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  bool _copied = false;
  Timer? _reset;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _reset?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: t.sunken,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
          child: Row(children: [
            Text(widget.language ?? 'text', style: text.labelSmall?.copyWith(fontFamily: t.mono)),
            const Spacer(),
            TextButton.icon(
              onPressed: _copy,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: t.muted,
                textStyle: text.labelSmall,
              ),
              icon: Icon(_copied ? Icons.check : Icons.content_copy, size: 14),
              label: Text(_copied ? 'Copied' : 'Copy'),
            ),
          ]),
        ),
        Scrollbar(
          controller: _scroll,
          child: SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Text(
              widget.code,
              style: TextStyle(fontFamily: t.mono, fontSize: 13, height: 1.5, color: Theme.of(context).colorScheme.onSurface),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Text that is still arriving: it shows the new part over ~1 s instead of
/// jumping a paragraph at a time, then renders as Markdown.
class StreamingMarkdown extends StatefulWidget {
  const StreamingMarkdown({super.key, required this.text});
  final String text;

  @override
  State<StreamingMarkdown> createState() => _StreamingMarkdownState();
}

class _StreamingMarkdownState extends State<StreamingMarkdown> {
  int _shown = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _shown = widget.text.length;
  }

  @override
  void didUpdateWidget(StreamingMarkdown old) {
    super.didUpdateWidget(old);
    final target = widget.text.length;
    if (!widget.text.startsWith(old.text.substring(0, math.min(_shown, old.text.length))) || target < _shown) {
      _shown = target; // A new message started: no animation back.
      return;
    }
    if (target == _shown) return;
    // Reveal the rest in ~1.2 s at 20 frames a second.
    final step = math.max(1, ((target - _shown) / 24).ceil());
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _shown = math.min(widget.text.length, _shown + step));
      if (_shown >= widget.text.length) timer.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = widget.text.substring(0, math.min(_shown, widget.text.length));
    return MarkdownView(data: '$shown ▍', selectable: false);
  }
}
