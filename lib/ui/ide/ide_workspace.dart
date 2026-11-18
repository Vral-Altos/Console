import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../data/ide_connection.dart';
import 'code_editing.dart';

String baseName(String path) => path.substring(path.lastIndexOf('/') + 1);
String dirName(String path) {
  final i = path.lastIndexOf('/');
  return i <= 0 ? '/' : path.substring(0, i);
}

String joinPath(String dir, String name) => dir.endsWith('/') ? '$dir$name' : '$dir/$name';

/// A file open in the editor.
class OpenFile extends ChangeNotifier {
  OpenFile(this.path, {String text = '', this.mtime, this.note})
    : controller = CodeController(text: text, language: languageForFile(baseName(path))),
      _saved = text {
    controller.addListener(_edited);
  }

  String path;
  final CodeController controller;
  int? mtime;

  /// Why it is not editable (binary, too large), or null.
  final String? note;
  String _saved;
  bool saving = false;
  bool _wasDirty = false;

  String get name => baseName(path);
  bool get dirty => controller.text != _saved;
  bool get readOnly => note != null;

  void _edited() {
    if (dirty != _wasDirty) {
      _wasDirty = dirty;
      notifyListeners();
    }
  }

  void markSaved(String text, int? m) {
    _saved = text;
    mtime = m;
    _wasDirty = dirty;
    notifyListeners();
  }

  void reload(String text, int? m) {
    controller.replace(
      controller.value.copyWith(
        text: text,
        selection: controller.selection.isValid && controller.selection.end <= text.length
            ? controller.selection
            : const TextSelection.collapsed(offset: 0),
        composing: TextRange.empty,
      ),
    );
    markSaved(text, m);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}

/// The save was refused: the file changed on the Devstation since it was opened.
class SaveConflict implements Exception {
  const SaveConflict(this.file);
  final OpenFile file;
}

/// The IDE's open files and the file tree.
class IdeWorkspace extends ChangeNotifier {
  IdeWorkspace(this.conn);

  final IdeConnection conn;
  final files = <OpenFile>[];
  int active = -1;

  /// Folder listings by path, and which folders are open.
  final listings = <String, List<IdeEntry>>{};
  final expanded = <String>{};
  final loading = <String>{};
  final failed = <String, String>{};
  String? root;
  bool showHidden = false;

  OpenFile? get current => active >= 0 && active < files.length ? files[active] : null;
  bool get anyDirty => files.any((f) => f.dirty);

  Future<void> setRoot(String path) async {
    root = path;
    expanded
      ..clear()
      ..add(path);
    listings.clear();
    await refresh(path);
  }

  Future<void> refresh(String dir) async {
    loading.add(dir);
    notifyListeners();
    try {
      listings[dir] = await conn.list(dir);
      failed.remove(dir);
    } catch (e) {
      failed[dir] = '$e';
    } finally {
      loading.remove(dir);
      notifyListeners();
    }
  }

  /// Re-lists every open folder (after a reconnect, or on request).
  Future<void> refreshAll() async {
    await Future.wait([for (final d in expanded) refresh(d)]);
  }

  Future<void> toggle(String dir) async {
    if (expanded.remove(dir)) {
      notifyListeners();
      return;
    }
    expanded.add(dir);
    notifyListeners();
    if (!listings.containsKey(dir)) await refresh(dir);
  }

  bool hidden(IdeEntry e) => !showHidden && (e.name == '.git' || e.name == '.dart_tool' || e.name == '.DS_Store');

  /// The visible tree rows, depth-first.
  List<({String path, IdeEntry entry, int depth})> rows() {
    final out = <({String path, IdeEntry entry, int depth})>[];
    void walk(String dir, int depth) {
      for (final e in listings[dir] ?? const <IdeEntry>[]) {
        if (hidden(e)) continue;
        final path = joinPath(dir, e.name);
        out.add((path: path, entry: e, depth: depth));
        if (e.dir && expanded.contains(path)) walk(path, depth + 1);
      }
    }

    if (root != null) walk(root!, 0);
    return out;
  }

  Future<OpenFile> open(String path) async {
    final i = files.indexWhere((f) => f.path == path);
    if (i >= 0) {
      active = i;
      notifyListeners();
      return files[i];
    }
    final r = await conn.read(path);
    final f = r.content != null
        ? OpenFile(path, text: r.content!, mtime: r.mtime)
        : OpenFile(
            path,
            mtime: r.mtime,
            note: r.binary
                ? 'A binary file (${_size(r.size)}): not shown.'
                : 'Too large to edit here (${_size(r.size)}). Use a terminal.',
          );
    f.addListener(notifyListeners);
    files.add(f);
    active = files.length - 1;
    notifyListeners();
    return f;
  }

  void select(int i) {
    active = i;
    notifyListeners();
  }

  void close(OpenFile f) {
    final i = files.indexOf(f);
    if (i < 0) return;
    files.removeAt(i);
    f.dispose();
    if (active >= files.length) active = files.length - 1;
    if (active > i) active--;
    notifyListeners();
  }

  /// Saves [f]; throws [SaveConflict] if it changed on the Devstation since
  /// (save again with [force] to overwrite).
  Future<void> save(OpenFile f, {bool force = false}) async {
    if (f.readOnly) return;
    final text = f.controller.text;
    f.saving = true;
    notifyListeners();
    try {
      final m = await conn.write(f.path, text, mtime: f.mtime, force: force);
      f.markSaved(text, m);
    } on IdeException catch (e) {
      if (e.code == 'conflict') throw SaveConflict(f);
      rethrow;
    } finally {
      f.saving = false;
      notifyListeners();
    }
  }

  /// Takes the Devstation's copy of [f], dropping local edits.
  Future<void> revert(OpenFile f) async {
    final r = await conn.read(f.path);
    if (r.content != null) f.reload(r.content!, r.mtime);
  }

  Future<void> create(String dir, String name, {bool folder = false}) async {
    final path = joinPath(dir, name);
    await conn.create(path, dir: folder);
    expanded.add(dir);
    await refresh(dir);
    if (!folder) await open(path);
  }

  Future<void> rename(String from, String to) async {
    await conn.rename(from, to);
    for (final f in files) {
      if (f.path == from || f.path.startsWith('$from/')) f.path = to + f.path.substring(from.length);
    }
    await Future.wait({dirName(from), dirName(to)}.map(refresh));
  }

  Future<String?> delete(String path) async {
    final trash = await conn.delete(path);
    for (final f in [...files]) {
      if (f.path == path || f.path.startsWith('$path/')) close(f);
    }
    await refresh(dirName(path));
    return trash;
  }

  @override
  void dispose() {
    for (final f in files) {
      f.dispose();
    }
    super.dispose();
  }
}

String _size(int? b) {
  if (b == null) return '?';
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
}
