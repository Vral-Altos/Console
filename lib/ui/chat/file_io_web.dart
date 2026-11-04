import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../data/attachments.dart';

Future<List<PickedFile>> _read(web.FileList? list, {bool pasted = false}) async {
  final out = <PickedFile>[];
  for (var i = 0; i < (list?.length ?? 0); i++) {
    final f = list!.item(i);
    if (f == null) continue;
    final buffer = await f.arrayBuffer().toDart;
    var name = f.name;
    if (pasted && (name.isEmpty || name == 'image.png')) {
      final t = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final ext = f.type.startsWith('image/') ? f.type.substring(6).replaceAll('jpeg', 'jpg') : 'bin';
      name = 'pasted-${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}${i == 0 ? '' : '-$i'}.$ext';
    }
    out.add(PickedFile(name: name, bytes: buffer.toDart.asUint8List(), contentType: f.type.isEmpty ? null : f.type));
  }
  return out;
}

Future<List<PickedFile>> pickFiles() {
  final done = Completer<List<PickedFile>>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..multiple = true;
  input.addEventListener('change', ((web.Event _) {
    _read(input.files).then(done.complete, onError: done.completeError);
  }).toJS);
  input.addEventListener('cancel', ((web.Event _) {
    if (!done.isCompleted) done.complete(const []);
  }).toJS);
  input.click();
  return done.future;
}

bool _hasFiles(web.DragEvent e) {
  final types = e.dataTransfer?.types.toDart ?? const <JSString>[];
  return types.any((t) => t.toDart == 'Files');
}

void Function() listenForFiles({
  required void Function(List<PickedFile> files) onFiles,
  required void Function(bool dragging) onDragging,
}) {
  var depth = 0;
  final over = ((web.DragEvent e) {
    if (!_hasFiles(e)) return;
    e.preventDefault(); // allows the drop
    e.dataTransfer?.dropEffect = 'copy';
  }).toJS;
  final enter = ((web.DragEvent e) {
    if (!_hasFiles(e)) return;
    if (depth++ == 0) onDragging(true);
  }).toJS;
  final leave = ((web.DragEvent e) {
    if (!_hasFiles(e)) return;
    if (--depth <= 0) {
      depth = 0;
      onDragging(false);
    }
  }).toJS;
  final drop = ((web.DragEvent e) {
    if (!_hasFiles(e)) return;
    e.preventDefault();
    depth = 0;
    onDragging(false);
    _read(e.dataTransfer?.files).then(onFiles);
  }).toJS;
  final paste = ((web.ClipboardEvent e) {
    final files = e.clipboardData?.files;
    if (files == null || files.length == 0) return; // text: the text field's
    e.preventDefault();
    _read(files, pasted: true).then(onFiles);
  }).toJS;
  final w = web.window;
  w.addEventListener('dragover', over);
  w.addEventListener('dragenter', enter);
  w.addEventListener('dragleave', leave);
  w.addEventListener('drop', drop);
  w.addEventListener('paste', paste);
  return () {
    w.removeEventListener('dragover', over);
    w.removeEventListener('dragenter', enter);
    w.removeEventListener('dragleave', leave);
    w.removeEventListener('drop', drop);
    w.removeEventListener('paste', paste);
  };
}

void saveFile(String name, Uint8List bytes, String? contentType) {
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: contentType ?? 'application/octet-stream'));
  final url = web.URL.createObjectURL(blob);
  final a = web.HTMLAnchorElement()
    ..href = url
    ..download = name;
  web.document.body?.append(a);
  a.click();
  a.remove();
  Timer(const Duration(seconds: 30), () => web.URL.revokeObjectURL(url));
}
