/// The browser's file picker, pasted and dropped files, and saving a file;
/// stand-ins elsewhere (tests run on the VM).
library;

export 'file_io_stub.dart' if (dart.library.js_interop) 'file_io_web.dart';
