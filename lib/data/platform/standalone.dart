/// Whether the Console runs as an installed app (home screen / PWA).
library;

export 'standalone_stub.dart' if (dart.library.js_interop) 'standalone_web.dart';
