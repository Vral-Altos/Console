import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'providers.dart';

/// The IDE gateway (infra/devstation_ide.tf, output `ide_gateway_url`).
const ideGatewayUrl = String.fromEnvironment(
  'IDE_GATEWAY_URL',
  defaultValue: 'wss://va-ide-gateway-869655882631.us-central1.run.app',
);

/// Opens a WebSocket (a seam for tests).
typedef IdeSocketFactory = WebSocketChannel Function(Uri uri);

/// The operator's current Firebase ID token.
typedef IdTokenSource = Future<String?> Function();

final ideSocketFactoryProvider = Provider<IdeSocketFactory>((ref) => WebSocketChannel.connect);

final ideTokenProvider = Provider<IdTokenSource>((ref) {
  final auth = ref.watch(firebaseAuthProvider);
  return () async => auth?.currentUser?.getIdToken();
});

enum IdePhase { connecting, ready, reconnecting, failed }

class IdeException implements Exception {
  IdeException(this.message, [this.code]);
  final String message;
  final String? code;
  @override
  String toString() => message;
}

/// A file or folder on the Devstation.
class IdeEntry {
  const IdeEntry({required this.name, required this.dir, this.link = false, this.size, this.mtime});
  factory IdeEntry.fromJson(Map<String, dynamic> j) => IdeEntry(
    name: j['name'] as String,
    dir: j['dir'] == true,
    link: j['link'] == true,
    size: j['size'] as int?,
    mtime: j['mtime'] as int?,
  );
  final String name;
  final bool dir;
  final bool link;
  final int? size;
  final int? mtime;
}

/// A file's content as read: text, or why it is not shown.
class IdeFile {
  const IdeFile({this.content, required this.mtime, this.binary = false, this.tooLarge = false, this.size});
  final String? content;
  final int? mtime;
  final bool binary;
  final bool tooLarge;
  final int? size;
}

/// One terminal event: output (`out`) or the shell ending (`exit`).
class IdeTermEvent {
  const IdeTermEvent(this.terminal, {this.data, this.exitCode, this.replay = false});
  final int terminal;
  final String? data;
  final int? exitCode;
  final bool replay;
  bool get isExit => data == null;
}

/// The Console's side of a Devstation IDE session (the protocol is
/// `IdeServer` in meshes/agent_mesh): requests with answers, terminal events,
/// and reconnecting (with a fresh sign-in) when the socket drops. Terminals
/// live on the Devstation, so a reconnect only reattaches them.
class IdeConnection extends ChangeNotifier {
  IdeConnection({
    required this.devstationId,
    required this.connect,
    required this.token,
    this.gateway = ideGatewayUrl,
    this.retryDelays = const [Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 5), Duration(seconds: 10)],
  });

  final String devstationId;
  final IdeSocketFactory connect;
  final IdTokenSource token;

  /// The gateway's base URL (wss://…).
  final String gateway;
  final List<Duration> retryDelays;

  IdePhase phase = IdePhase.connecting;
  String? error;
  String? errorCode;
  String home = '/home/va';
  String workspace = '/home/va/workspace';

  /// Terminals the Devstation already had when this session signed in.
  List<int> existingTerminals = const [];

  /// Terminals this page shows: reattached after every reconnect.
  final attached = <int>{};

  final _events = StreamController<IdeTermEvent>.broadcast();
  Stream<IdeTermEvent> get terminalEvents => _events.stream;

  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  final _pending = <int, Completer<Object?>>{};
  var _nextId = 0;
  var _attempt = 0;
  var _disposed = false;
  Timer? _retry;
  Completer<void> _ready = Completer();

  /// Resolves once signed in (again).
  Future<void> get ready => _ready.future;

  Future<void> start() => _open();

  Future<void> _open() async {
    if (_disposed) return;
    _retry?.cancel();
    _set(_attempt == 0 ? IdePhase.connecting : IdePhase.reconnecting);
    final String? idToken;
    try {
      idToken = await token();
    } catch (e) {
      return _fail('Could not get the sign-in: $e', 'auth');
    }
    if (idToken == null) return _fail('Not signed in', 'auth');
    final WebSocketChannel ch;
    try {
      ch = _ch = connect(Uri.parse('${gateway.replaceAll(RegExp(r'/$'), '')}/ide/$devstationId'));
      await ch.ready;
    } catch (_) {
      return _dropped();
    }
    _sub = ch.stream.listen(_onMessage, onDone: _dropped, onError: (_) => _dropped());
    try {
      final r = await _send('auth', {'token': idToken}) as Map<String, dynamic>;
      home = r['home'] as String? ?? home;
      workspace = r['workspace'] as String? ?? workspace;
      existingTerminals = [for (final t in (r['terminals'] as List? ?? const [])) (t as Map)['t'] as int];
      _attempt = 0;
      error = errorCode = null;
      for (final t in attached.toList()) {
        try {
          await _send('term.attach', {'t': t});
        } on IdeException {
          attached.remove(t);
          _events.add(IdeTermEvent(t, exitCode: -1));
        }
      }
      _set(IdePhase.ready);
      if (!_ready.isCompleted) _ready.complete();
    } on IdeException catch (e) {
      // Signed out, not the operator, no such Devstation, or it is down:
      // retrying will not help until something changes.
      if (e.code == 'auth' || e.code == 'missing') return _fail(e.message, e.code);
      if (e.code == 'not-running') return _fail(e.message, e.code);
      _dropped();
    }
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    final Map<String, dynamic> m;
    try {
      m = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (m['ev']) {
      case 'out':
        _events.add(IdeTermEvent(m['t'] as int, data: m['d'] as String? ?? '', replay: m['replay'] == true));
        return;
      case 'exit':
        attached.remove(m['t']);
        _events.add(IdeTermEvent(m['t'] as int, exitCode: m['code'] as int? ?? 0));
        return;
    }
    final c = _pending.remove(m['id']);
    if (c == null) return;
    if (m['ok'] == true) {
      c.complete(m['result']);
    } else {
      c.completeError(IdeException(m['error'] as String? ?? 'failed', m['code'] as String?));
    }
  }

  void _dropped() {
    if (_disposed || phase == IdePhase.failed) return;
    _teardown('connection lost');
    final delay = retryDelays[_attempt.clamp(0, retryDelays.length - 1)];
    _attempt++;
    _set(IdePhase.reconnecting);
    _retry = Timer(delay, _open);
  }

  void _fail(String message, [String? code]) {
    _teardown(message);
    error = message;
    errorCode = code;
    final r = _ready;
    if (!r.isCompleted) {
      r.future.ignore();
      r.completeError(IdeException(message, code));
    }
    _set(IdePhase.failed);
  }

  void _teardown(String why) {
    _sub?.cancel();
    _sub = null;
    _ch?.sink.close();
    _ch = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(IdeException(why, 'disconnected'));
    }
    _pending.clear();
    if (_ready.isCompleted) _ready = Completer();
  }

  /// Tries again after a failure (e.g. once the Devstation has started).
  Future<void> retry() {
    _attempt = 0;
    error = errorCode = null;
    if (_ready.isCompleted) _ready = Completer();
    return _open();
  }

  void _set(IdePhase p) {
    phase = p;
    if (!_disposed) notifyListeners();
  }

  Future<Object?> _send(String op, [Map<String, Object?> args = const {}]) {
    final ch = _ch;
    if (ch == null) return Future.error(IdeException('not connected', 'disconnected'));
    final id = ++_nextId;
    final c = _pending[id] = Completer<Object?>();
    ch.sink.add(jsonEncode({'id': id, 'op': op, ...args}));
    return c.future;
  }

  /// A request once connected; waits through a reconnect.
  Future<Object?> call(String op, [Map<String, Object?> args = const {}]) async {
    if (phase == IdePhase.failed) throw IdeException(error ?? 'not connected', errorCode);
    await ready;
    return _send(op, args);
  }

  Future<List<IdeEntry>> list(String path) async => [
    for (final e in (await call('ls', {'path': path}) as List)) IdeEntry.fromJson(e as Map<String, dynamic>),
  ];

  Future<IdeFile> read(String path) async {
    final r = await call('read', {'path': path}) as Map<String, dynamic>;
    return IdeFile(
      content: r['content'] as String?,
      mtime: r['mtime'] as int?,
      binary: r['binary'] == true,
      tooLarge: r['tooLarge'] == true,
      size: r['size'] as int?,
    );
  }

  /// Saves [content]; with [mtime] it is refused (code `conflict`) if the
  /// file changed on the Devstation since, unless [force]. Returns the new mtime.
  Future<int?> write(String path, String content, {int? mtime, bool force = false}) async {
    final r = await call('write', {'path': path, 'content': content, 'mtime': ?mtime, if (force) 'force': true}) as Map;
    return r['mtime'] as int?;
  }

  Future<void> create(String path, {bool dir = false}) => call('create', {'path': path, if (dir) 'dir': true});
  Future<void> rename(String from, String to) => call('rename', {'from': from, 'to': to});
  Future<String?> delete(String path) async => (await call('delete', {'path': path}) as Map?)?['trash'] as String?;
  Future<List<String>> find(String root, String query) async => [
    for (final f in (await call('find', {'root': root, 'query': query}) as List)) f as String,
  ];

  Future<int> openTerminal({int cols = 80, int rows = 24, String? cwd}) async {
    final r = await call('term.open', {'cols': cols, 'rows': rows, 'cwd': ?cwd}) as Map;
    final t = r['t'] as int;
    attached.add(t);
    return t;
  }

  Future<void> attachTerminal(int t) async {
    await call('term.attach', {'t': t});
    attached.add(t);
  }

  void input(int t, String data) => call('term.in', {'t': t, 'd': data}).ignore();
  void resize(int t, int cols, int rows) => call('term.resize', {'t': t, 'cols': cols, 'rows': rows}).ignore();
  Future<void> closeTerminal(int t) async {
    attached.remove(t);
    await call('term.close', {'t': t});
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _teardown('closed');
    _events.close();
    super.dispose();
  }
}
