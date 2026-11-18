import 'dart:js_interop';

import 'package:web/web.dart' as web;

@JS('navigator.standalone')
external JSBoolean? get _iosStandalone;

/// Installed to the home screen: iOS sets `navigator.standalone`; others
/// match the manifest's display mode.
bool get runningStandalone =>
    (_iosStandalone?.toDart ?? false) || web.window.matchMedia('(display-mode: standalone)').matches;

String? get pageHost => web.window.location.host;
