import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';

import 'models.dart';

/// A file the operator picked, pasted or dropped, before it is uploaded.
class PickedFile {
  const PickedFile({required this.name, required this.bytes, this.contentType});
  final String name;
  final Uint8List bytes;
  final String? contentType;
  int get size => bytes.length;
}

/// Where uploads go and come back from. The Console's implementation is
/// Cloud Storage for Firebase; tests substitute their own.
abstract interface class AttachmentStore {
  /// Uploads [file], reporting progress (0–1); returns its reference.
  Future<AttachmentRef> upload(PickedFile file, {void Function(double progress)? onProgress});

  /// The file's contents (null: gone).
  Future<Uint8List?> read(AttachmentRef ref);

  /// Removes an upload that was never sent.
  Future<void> discard(AttachmentRef ref);
}

/// Upload limits (`storage.rules` holds the same numbers).
abstract final class AttachmentLimits {
  static const maxBytes = 25 * 1024 * 1024;
  static const maxFiles = 10;
}

/// The content type for a file name, where the browser gave none.
String? contentTypeFor(String name, [String? given]) {
  if (given != null && given.isNotEmpty) return given;
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return const {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'svg': 'image/svg+xml',
    'pdf': 'application/pdf',
    'txt': 'text/plain',
    'md': 'text/markdown',
    'csv': 'text/csv',
    'json': 'application/json',
    'html': 'text/html',
    'zip': 'application/zip',
    'mp3': 'audio/mpeg',
    'wav': 'audio/wav',
    'm4a': 'audio/mp4',
    'mp4': 'video/mp4',
    'mov': 'video/quicktime',
    'webm': 'video/webm',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  }[ext];
}

/// A name safe as one path segment.
String safeFileName(String name) {
  final base = name.split(RegExp(r'[/\\]')).last;
  final clean = base.replaceAll(RegExp(r'[^A-Za-z0-9._ ()-]'), '_').replaceFirst(RegExp(r'^[. ]+'), '');
  final cut = clean.length > 120 ? clean.substring(clean.length - 120) : clean;
  return cut.isEmpty ? 'file' : cut;
}

final _random = Random.secure();
String _uploadId() {
  const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  return List.generate(20, (_) => chars[_random.nextInt(chars.length)]).join();
}

/// Cloud Storage for Firebase (the `vral-altos-attachments` bucket;
/// `storage.rules` admit only the operator). Reads go through the rules
/// too, never a shareable download URL; recent files stay in memory.
class FirebaseAttachmentStore implements AttachmentStore {
  FirebaseAttachmentStore(this._storage);

  final FirebaseStorage _storage;
  final _cache = <String, Uint8List>{}; // insertion order: oldest first
  static const _cacheBytes = 80 * 1024 * 1024;
  int _cached = 0;

  @override
  Future<AttachmentRef> upload(PickedFile file, {void Function(double progress)? onProgress}) async {
    if (file.size > AttachmentLimits.maxBytes) {
      throw ArgumentError('${file.name} is over ${AttachmentLimits.maxBytes ~/ (1024 * 1024)} MB.');
    }
    final name = safeFileName(file.name);
    final path = 'attachments/${_uploadId()}/$name';
    final type = contentTypeFor(file.name, file.contentType) ?? 'application/octet-stream';
    final task = _storage.ref(path).putData(file.bytes, SettableMetadata(contentType: type));
    final sub = task.snapshotEvents.listen((s) {
      if (s.totalBytes > 0) onProgress?.call(s.bytesTransferred / s.totalBytes);
    }, onError: (_) {});
    try {
      await task;
    } finally {
      await sub.cancel();
    }
    _remember(path, file.bytes);
    return AttachmentRef(path: path, name: file.name, contentType: type, size: file.size);
  }

  @override
  Future<Uint8List?> read(AttachmentRef ref) async {
    final hit = _cache.remove(ref.path);
    if (hit != null) return _cache[ref.path] = hit;
    try {
      final bytes = await _storage.ref(ref.path).getData(AttachmentLimits.maxBytes + 1024);
      if (bytes != null) _remember(ref.path, bytes);
      return bytes;
    } on FirebaseException catch (e) {
      if (e.code == 'object-not-found') return null;
      rethrow;
    }
  }

  @override
  Future<void> discard(AttachmentRef ref) async {
    final gone = _cache.remove(ref.path);
    if (gone != null) _cached -= gone.length;
    try {
      await _storage.ref(ref.path).delete();
    } on FirebaseException {
      // Already gone; an orphan costs nothing that matters.
    }
  }

  void _remember(String path, Uint8List bytes) {
    if (bytes.length > _cacheBytes ~/ 4) return;
    _cache[path] = bytes;
    _cached += bytes.length;
    while (_cached > _cacheBytes && _cache.isNotEmpty) {
      final first = _cache.keys.first;
      _cached -= _cache.remove(first)!.length;
    }
  }
}
