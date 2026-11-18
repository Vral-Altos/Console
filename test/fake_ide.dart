import 'dart:async';
import 'dart:convert';

import 'package:async/async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// An in-memory Devstation IDE server speaking the protocol of
/// meshes/agent_mesh `IdeServer` (files in a map, echoing terminals).
class FakeIde {
  FakeIde({Map<String, String>? files}) : files = files ?? {};

  final Map<String, String> files;
  final mtimes = <String, int>{};
  final writes = <String>[];
  final opened = <Uri>[];
  final input = <int, StringBuffer>{};
  final terminals = <int>{};
  final connections = <FakeSocket>[];
  var _clock = 1000;
  var _nextTerm = 1;

  /// What the next connection's sign-in gets, if not accepted.
  ({String code, String error})? refuse;

  String home = '/home/va';
  String get workspace => '$home/workspace';

  FakeSocket get last => connections.last;

  WebSocketChannel connect(Uri uri) {
    opened.add(uri);
    final s = FakeSocket(this);
    connections.add(s);
    return s;
  }

  int mtime(String path) => mtimes.putIfAbsent(path, () => ++_clock);

  /// Changes a file "on the Devstation".
  void touch(String path, String content) {
    files[path] = content;
    mtimes[path] = ++_clock;
  }

  List<Map<String, Object?>> _ls(String dir) {
    final names = <String, bool>{};
    for (final p in files.keys) {
      if (!p.startsWith('$dir/')) continue;
      final rest = p.substring(dir.length + 1);
      final i = rest.indexOf('/');
      if (i < 0) {
        names.putIfAbsent(rest, () => false);
      } else {
        names[rest.substring(0, i)] = true;
      }
    }
    final list = [for (final e in names.entries) {'name': e.key, 'dir': e.value}];
    list.sort((a, b) {
      final d = (b['dir'] == true ? 1 : 0) - (a['dir'] == true ? 1 : 0);
      return d != 0 ? d : (a['name'] as String).compareTo(b['name'] as String);
    });
    return list;
  }

  Object? handle(FakeSocket s, Map<String, dynamic> m) {
    switch (m['op']) {
      case 'auth':
        if (refuse case final r?) throw _Err(r.error, r.code);
        if (m['token'] != 'tok') throw _Err('this account may not use Devstations', 'auth');
        return {'home': home, 'workspace': workspace, 'terminals': [for (final t in terminals) {'t': t}]};
      case 'ls':
        return _ls(m['path'] as String);
      case 'read':
        final p = m['path'] as String;
        final c = files[p];
        if (c == null) throw _Err('no such file', 'missing');
        if (c.startsWith('\u0000')) return {'binary': true, 'size': c.length, 'mtime': mtime(p)};
        return {'content': c, 'mtime': mtime(p), 'size': c.length};
      case 'write':
        final p = m['path'] as String;
        if (m['mtime'] != null && m['force'] != true && files.containsKey(p) && mtime(p) != m['mtime']) {
          throw _Err('changed on the Devstation since it was opened', 'conflict');
        }
        files[p] = m['content'] as String;
        writes.add(p);
        return {'mtime': mtimes[p] = ++_clock};
      case 'create':
        final p = m['path'] as String;
        if (files.containsKey(p)) throw _Err('already exists', 'exists');
        files[m['dir'] == true ? '$p/.keep' : p] = '';
        return null;
      case 'rename':
        final from = m['from'] as String, to = m['to'] as String;
        for (final k in files.keys.where((k) => k == from || k.startsWith('$from/')).toList()) {
          files['$to${k.substring(from.length)}'] = files.remove(k)!;
        }
        return null;
      case 'delete':
        final p = m['path'] as String;
        files.removeWhere((k, _) => k == p || k.startsWith('$p/'));
        return {'trash': '$home/.ide-trash/x-${p.split('/').last}'};
      case 'find':
        final q = (m['query'] as String).toLowerCase();
        return [for (final k in files.keys) if (k.startsWith(m['root'] as String) && k.toLowerCase().contains(q)) k];
      case 'term.open':
        final t = _nextTerm++;
        terminals.add(t);
        input[t] = StringBuffer();
        s.attached.add(t);
        Timer.run(() => s.event({'ev': 'out', 't': t, 'd': r'va@ds:~/workspace$ '}));
        return {'t': t};
      case 'term.attach':
        final t = m['t'] as int;
        if (!terminals.contains(t)) throw _Err('that terminal has closed', 'gone');
        s.attached.add(t);
        Timer.run(() => s.event({'ev': 'out', 't': t, 'd': 'replayed-$t ', 'replay': true}));
        return {'t': t};
      case 'term.in':
        final t = m['t'] as int;
        input[t]!.write(m['d']);
        Timer.run(() => s.event({'ev': 'out', 't': t, 'd': m['d']}));
        return null;
      case 'term.resize':
        return null;
      case 'term.close':
        terminals.remove(m['t']);
        return null;
      default:
        throw _Err('unknown op ${m['op']}');
    }
  }
}

class _Err implements Exception {
  _Err(this.message, [this.code]);
  final String message;
  final String? code;
}

class _Sink extends DelegatingStreamSink<dynamic> implements WebSocketSink {
  _Sink(super.sink);
  @override
  Future<void> close([int? closeCode, String? closeReason]) => super.close();
}

/// One connection to [FakeIde].
class FakeSocket extends StreamChannelMixin<dynamic> implements WebSocketChannel {
  FakeSocket(this.server) {
    _toServer.stream.listen((raw) {
      final m = jsonDecode(raw as String) as Map<String, dynamic>;
      try {
        final r = server.handle(this, m);
        _reply({'id': m['id'], 'ok': true, 'result': r});
      } on _Err catch (e) {
        _reply({'id': m['id'], 'ok': false, 'error': e.message, 'code': ?e.code});
      }
    }, onDone: () => closed = true);
  }

  final FakeIde server;
  final _toClient = StreamController<dynamic>();
  final _toServer = StreamController<dynamic>();
  late final _sink = _Sink(_toServer.sink);
  final attached = <int>{};
  bool closed = false;

  void _reply(Map<String, Object?> m) {
    if (!_toClient.isClosed) _toClient.add(jsonEncode(m));
  }

  void event(Map<String, Object?> m) {
    if (attached.contains(m['t'])) _reply(m);
  }

  /// The gateway or the Devstation drops the connection.
  Future<void> drop() => _toClient.close();

  @override
  Stream<dynamic> get stream => _toClient.stream;
  @override
  WebSocketSink get sink => _sink;
  @override
  Future<void> get ready => Future.value();
  @override
  String? get protocol => null;
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
}
