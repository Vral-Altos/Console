import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../theme.dart';
import '../widgets.dart';
import 'file_io.dart';

String fileSize(int? b) => b == null
    ? ''
    : b < 1024
    ? '$b B'
    : b < 1024 * 1024
    ? '${(b / 1024).toStringAsFixed(0)} KB'
    : '${(b / 1024 / 1024).toStringAsFixed(1)} MB';

IconData fileIcon(String? type, String name) {
  final t = type ?? '';
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  if (t.startsWith('image/')) return Icons.image_outlined;
  if (t.startsWith('audio/')) return Icons.audiotrack_outlined;
  if (t.startsWith('video/')) return Icons.movie_outlined;
  if (t == 'application/pdf') return Icons.picture_as_pdf_outlined;
  if (const {'csv', 'xlsx', 'xls', 'tsv'}.contains(ext)) return Icons.table_chart_outlined;
  if (const {'zip', 'gz', 'tar', '7z'}.contains(ext)) return Icons.folder_zip_outlined;
  if (const {'dart', 'py', 'js', 'ts', 'json', 'yaml', 'yml', 'tf', 'sh', 'html', 'css', 'go', 'rs', 'java', 'kt', 'swift'}.contains(ext)) {
    return Icons.code;
  }
  return Icons.insert_drive_file_outlined;
}

/// A file chip: an icon or thumbnail, the name and size; optional progress
/// and remove (in the composer) or tap to open (in a message).
class FileChip extends StatelessWidget {
  const FileChip({
    super.key,
    required this.name,
    this.contentType,
    this.size,
    this.thumbnail,
    this.progress,
    this.error,
    this.onTap,
    this.onRemove,
  });

  final String name;
  final String? contentType;
  final int? size;
  final Widget? thumbnail;

  /// 0–1 while uploading.
  final double? progress;
  final String? error;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final failed = error != null;
    final sub = failed ? error! : [fileSize(size), if (progress != null) '${(progress! * 100).round()}%'].where((s) => s.isNotEmpty).join(' · ');
    return Semantics(
      label: 'Attachment $name',
      button: onTap != null,
      child: Material(
        color: t.sunken,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: failed ? t.bad.withValues(alpha: .6) : t.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(children: [
            Padding(
              padding: EdgeInsets.fromLTRB(6, 6, onRemove == null ? 12 : 4, 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: thumbnail ??
                        ColoredBox(
                          color: t.panel,
                          child: Icon(failed ? Icons.error_outline : fileIcon(contentType, name), size: 19, color: failed ? t.bad : t.muted),
                        ),
                  ),
                ),
                const SizedBox(width: 9),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 170),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
                    if (sub.isNotEmpty)
                      Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.labelSmall?.copyWith(color: failed ? t.bad : t.faint)),
                  ]),
                ),
                if (onRemove != null)
                  IconButton(
                    tooltip: 'Remove $name',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    onPressed: onRemove,
                    icon: Icon(Icons.close, color: t.muted),
                  ),
              ]),
            ),
            if (progress != null && progress! < 1)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(value: progress, minHeight: 2, backgroundColor: Colors.transparent),
              ),
          ]),
        ),
      ),
    );
  }
}

/// A sent message's attachments: image thumbnails and file chips; tapping
/// opens an image or saves a file.
class MessageAttachments extends StatelessWidget {
  const MessageAttachments({super.key, required this.attachments, this.alignEnd = true});
  final List<AttachmentRef> attachments;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final images = attachments.where((a) => a.isImage).toList();
    final files = attachments.where((a) => !a.isImage).toList();
    return Column(crossAxisAlignment: alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
      if (images.isNotEmpty)
        Wrap(
          alignment: alignEnd ? WrapAlignment.end : WrapAlignment.start,
          spacing: 6,
          runSpacing: 6,
          children: [for (final a in images) _ImageTile(attachment: a, size: images.length == 1 ? 220 : 120)],
        ),
      if (images.isNotEmpty && files.isNotEmpty) const SizedBox(height: 6),
      if (files.isNotEmpty)
        Wrap(
          alignment: alignEnd ? WrapAlignment.end : WrapAlignment.start,
          spacing: 6,
          runSpacing: 6,
          children: [for (final a in files) _SentFile(attachment: a)],
        ),
    ]);
  }
}

class _SentFile extends ConsumerWidget {
  const _SentFile({required this.attachment});
  final AttachmentRef attachment;

  @override
  Widget build(BuildContext context, WidgetRef ref) => FileChip(
    name: attachment.name,
    contentType: attachment.contentType,
    size: attachment.size,
    onTap: () => saveAttachment(context, ref, attachment),
  );
}

Future<void> saveAttachment(BuildContext context, WidgetRef ref, AttachmentRef a) => guarded(context, () async {
  final bytes = await ref.read(attachmentStoreProvider)?.read(a);
  if (bytes == null) throw StateError('${a.name} is no longer stored.');
  saveFile(a.name, bytes, a.contentType);
});

class _ImageTile extends ConsumerWidget {
  const _ImageTile({required this.attachment, required this.size});
  final AttachmentRef attachment;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Tokens.of(context);
    final bytes = ref.watch(attachmentBytesProvider(attachment));
    return Semantics(
      label: 'Image ${attachment.name}',
      button: true,
      child: Material(
        color: t.sunken,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: bytes.value == null ? null : () => showImage(context, attachment, bytes.value!),
          child: SizedBox(
            width: size,
            height: size * .75,
            child: switch (bytes) {
              AsyncData(value: final b?) => Image.memory(b, fit: BoxFit.cover, gaplessPlayback: true),
              AsyncData() || AsyncError() => Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.broken_image_outlined, color: t.muted),
                  const SizedBox(height: 4),
                  Text(attachment.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall),
                ]),
              ),
              _ => const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            },
          ),
        ),
      ),
    );
  }
}

/// An image, full size: pinch or scroll to zoom; save.
void showImage(BuildContext context, AttachmentRef a, Uint8List bytes) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: .85),
    builder: (context) => Dialog.fullscreen(
      backgroundColor: Colors.transparent,
      child: Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => Navigator.pop(context),
            child: InteractiveViewer(maxScale: 6, child: Center(child: Image.memory(bytes))),
          ),
        ),
        Positioned(
          top: 12,
          left: 16,
          right: 12,
          child: SafeArea(
            child: Row(children: [
              Expanded(
                child: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              ),
              IconButton(
                tooltip: 'Save',
                color: Colors.white,
                onPressed: () => saveFile(a.name, bytes, a.contentType),
                icon: const Icon(Icons.download),
              ),
              IconButton(tooltip: 'Close', color: Colors.white, onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ]),
          ),
        ),
      ]),
    ),
  );
}

/// [text] with its @mentions highlighted.
TextSpan mentionSpan(BuildContext context, String text, List<MentionRef> mentions, TextStyle? style) {
  final tokens = {for (final m in mentions) m.token: m}..removeWhere((k, _) => !text.contains(k));
  if (tokens.isEmpty) return TextSpan(text: text, style: style);
  final scheme = Theme.of(context).colorScheme;
  final pattern = RegExp([for (final k in tokens.keys.toList()..sort((a, b) => b.length.compareTo(a.length))) RegExp.escape(k)].join('|'));
  final spans = <InlineSpan>[];
  var at = 0;
  for (final m in pattern.allMatches(text)) {
    if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
    spans.add(TextSpan(
      text: m[0],
      style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600, backgroundColor: scheme.primary.withValues(alpha: .08)),
    ));
    at = m.end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return TextSpan(style: style, children: spans);
}

IconData mentionIcon(MentionKind k) => switch (k) {
  MentionKind.thread => Icons.chat_bubble_outline,
  MentionKind.project => Icons.folder_outlined,
  MentionKind.agent => Icons.smart_toy_outlined,
};
