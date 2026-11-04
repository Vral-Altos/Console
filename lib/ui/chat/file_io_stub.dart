import 'dart:typed_data';

import '../../data/attachments.dart';

Future<List<PickedFile>> pickFiles() async => const [];

/// Calls [onFiles] with files pasted or dropped on the page and
/// [onDragging] while files are dragged over it. Returns the cancel.
void Function() listenForFiles({
  required void Function(List<PickedFile> files) onFiles,
  required void Function(bool dragging) onDragging,
}) => () {};

void saveFile(String name, Uint8List bytes, String? contentType) {}
