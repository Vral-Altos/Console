import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'models.dart';

/// Every read and write the Console makes, against the platform database.
/// The Console only ever creates threads and queued operator messages; the
/// Mac worker or the cloud runner does the rest (`meshes/agent_mesh`,
/// Mailbox).
class ConsoleRepository {
  ConsoleRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _threads => _db.collection('threads');
  CollectionReference<Map<String, dynamic>> get _messages => _db.collection('messages');

  Stream<List<ChatThread>> threads() => _threads
      .orderBy('updatedAt', descending: true)
      .limit(100)
      .snapshots()
      .map((s) => [for (final d in s.docs) threadFrom(d.id, d.data())]);

  Stream<List<ChatMessage>> messages(String threadId) => _messages
      .where('threadId', isEqualTo: threadId)
      .orderBy('createdAt')
      .snapshots()
      .map((s) => [for (final d in s.docs) messageFrom(d.id, d.data())]);

  /// Starts a thread with [agent] and queues its first message.
  Future<String> startThread({required String agent, required String text}) async {
    final ref = _threads.doc();
    final batch = _db.batch()
      ..set(ref, {
        'agent': agent,
        'title': _title(text),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'closed': false,
      })
      ..set(_messages.doc(), _queued(ref.id, text, 'turn'));
    await batch.commit();
    return ref.id;
  }

  Future<void> send(String threadId, String text) =>
      _messages.doc().set(_queued(threadId, text, 'turn'));

  /// Asks the agent to close the task: it writes a journal entry, and the
  /// thread is marked closed.
  Future<void> close(String threadId) =>
      _messages.doc().set(_queued(threadId, 'Close this conversation.', 'close'));

  Map<String, Object?> _queued(String threadId, String text, String kind) => {
    'threadId': threadId,
    'role': 'operator',
    'kind': kind,
    'text': text,
    'status': 'queued',
    'createdAt': FieldValue.serverTimestamp(),
  };

  Stream<HostStatus?> hostStatus(String host) => _db
      .doc('status/$host')
      .snapshots()
      .map((d) => d.exists ? hostFrom(d.data()!) : null);

  Stream<MeshView?> mesh() => _db
      .doc('agent_mesh/state')
      .snapshots()
      .map((d) => d.exists ? meshFrom(d.data()!) : null);

  Stream<PortfolioSync?> portfolioSync() => _db.doc('autobench/latest').snapshots().map(
    (d) => d.exists
        ? PortfolioSync(
            syncedAt: _time(d.data()!['synced_at']),
            source: d.data()!['source'] as String?,
            account: d.data()!['account'] as String?,
          )
        : null,
  );

  Stream<List<Devstation>> devstations() => _db.collection('devstations').snapshots().map(
    (s) => [
      for (final d in s.docs)
        Devstation(
          id: d.id,
          project: d.data()['project'] as String? ?? d.id,
          state: d.data()['state'] as String? ?? 'unknown',
          machineType: d.data()['machineType'] as String?,
          zone: d.data()['zone'] as String?,
          lastActiveAt: _time(d.data()['lastActiveAt']),
        ),
    ],
  );

  static String _title(String text) {
    final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 60 ? one : '${one.substring(0, 59)}…';
  }
}

DateTime? _time(Object? v) => switch (v) {
  Timestamp t => t.toDate(),
  DateTime d => d,
  String s => DateTime.tryParse(s),
  _ => null,
};

ChatThread threadFrom(String id, Map<String, dynamic> d) => ChatThread(
  id: id,
  agent: d['agent'] as String? ?? 'genie',
  title: d['title'] as String? ?? '',
  createdAt: _time(d['createdAt']),
  updatedAt: _time(d['updatedAt']),
  lastMessage: d['lastMessage'] as String?,
  closed: d['closed'] as bool? ?? false,
);

ChatMessage messageFrom(String id, Map<String, dynamic> d) => ChatMessage(
  id: id,
  threadId: d['threadId'] as String,
  fromOperator: d['role'] == 'operator',
  text: d['text'] as String? ?? '',
  kind: d['kind'] as String? ?? 'turn',
  createdAt: _time(d['createdAt']),
  status: MessageStatus.values.asNameMap()[d['status']],
  claimedBy: d['claimedBy'] as String?,
  error: d['error'] as String?,
  placement: d['placement'] as String?,
  accountId: d['accountId'] as String?,
);

HostStatus hostFrom(Map<String, dynamic> d) => HostStatus(
  lastSeen: _time(d['lastSeen']),
  host: d['host'] as String?,
  agents: [for (final a in d['agents'] as List? ?? const []) a as String],
  startedAt: _time(d['startedAt']),
  revision: d['revision'] as String?,
  lastRunAt: _time(d['lastRunAt']),
  lastResult: d['lastResult'] as String?,
);

/// Reads the registry the agent mesh writes (a JSON string field).
MeshView meshFrom(Map<String, dynamic> d) {
  final raw = d['json'] as String?;
  if (raw == null) return const MeshView();
  final j = jsonDecode(raw) as Map<String, dynamic>;
  final usage = (j['usage'] as Map? ?? const {}).cast<String, dynamic>();
  UsageView? window(Object? w) => w is Map
      ? UsageView(
          utilization: (w['utilization'] as num).toDouble(),
          resetsAt: _time(w['resetsAt']),
          status: w['status'] as String?,
        )
      : null;
  final accounts = [
    for (final a in (j['accounts'] as List? ?? const []).cast<Map<String, dynamic>>())
      AccountView(
        id: a['id'] as String,
        label: a['label'] as String? ?? a['id'] as String,
        fiveHour: window((usage[a['id']] as Map?)?['fiveHour']),
        sevenDay: window((usage[a['id']] as Map?)?['sevenDay']),
        limitedUntil: _time((usage[a['id']] as Map?)?['limitedUntil']),
      ),
  ];
  // With no account registered, runs use the host's own login ("default").
  if (accounts.isEmpty && usage.containsKey('default')) {
    accounts.add(AccountView(
      id: 'default',
      label: "Host's own login",
      fiveHour: window((usage['default'] as Map)['fiveHour']),
      sevenDay: window((usage['default'] as Map)['sevenDay']),
    ));
  }
  return MeshView(
    accounts: accounts,
    sessions: [
      for (final s in (j['sessions'] as List? ?? const []).cast<Map<String, dynamic>>())
        SessionView(
          sessionId: s['sessionId'] as String,
          agent: s['agent'] as String,
          taskId: s['taskId'] as String,
          accountId: s['accountId'] as String,
          status: s['status'] as String,
          contextTokens: (s['contextTokens'] as num?)?.toInt() ?? 0,
          turns: (s['turns'] as num?)?.toInt() ?? 0,
          compactions: (s['compactions'] as num?)?.toInt() ?? 0,
          lastUsedAt: _time(s['lastUsedAt']),
        ),
    ],
    updatedAt: _time(d['updatedAt']),
  );
}
