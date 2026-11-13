import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'models.dart';

/// Every read and write the Console makes, against the platform database.
/// The Console creates threads, queued operator messages and Factory
/// requests; it may rename, pin and archive threads, cancel a queued message
/// or ask a running one to stop, and decide approvals. The workers do the
/// rest (`meshes/agent_mesh`, Mailbox). `firestore.rules` allows exactly
/// these writes.
class ConsoleRepository {
  ConsoleRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _threads => _db.collection('threads');
  CollectionReference<Map<String, dynamic>> get _messages => _db.collection('messages');

  Stream<List<ChatThread>> threads() => _threads
      .orderBy('updatedAt', descending: true)
      .limit(300)
      .snapshots()
      .map((s) => [for (final d in s.docs) threadFrom(d.id, d.data())]);

  Stream<List<ChatMessage>> messages(String threadId) => _messages
      .where('threadId', isEqualTo: threadId)
      .orderBy('createdAt')
      .snapshots()
      .map((s) => [for (final d in s.docs) messageFrom(d.id, d.data())]);

  /// Operator messages waiting for, or being answered by, a worker.
  Stream<List<ChatMessage>> activeMessages() => _messages
      .where('status', whereIn: ['queued', 'running'])
      .orderBy('createdAt')
      .snapshots()
      .map((s) => [for (final d in s.docs) messageFrom(d.id, d.data())]);

  /// Starts a thread with [agent] and queues its first message.
  Future<String> startThread({
    required String agent,
    required String text,
    List<AttachmentRef> attachments = const [],
    List<MentionRef> mentions = const [],
  }) async {
    final ref = _threads.doc();
    final batch = _db.batch()
      ..set(ref, {
        'agent': agent,
        'title': titleFor(text.trim().isNotEmpty || attachments.isEmpty ? text : attachments.first.name),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'closed': false,
      })
      ..set(_messages.doc(), _queued(ref.id, text, 'turn', attachments: attachments, mentions: mentions));
    await batch.commit();
    unawaited(_audit('Started a conversation with $agent', {'threadId': ref.id, 'agent': agent}));
    return ref.id;
  }

  Future<void> send(
    String threadId,
    String text, {
    List<AttachmentRef> attachments = const [],
    List<MentionRef> mentions = const [],
  }) async {
    await _messages.doc().set(_queued(threadId, text, 'turn', attachments: attachments, mentions: mentions));
    unawaited(_audit('Sent a message', {
      'threadId': threadId,
      'chars': text.length,
      if (attachments.isNotEmpty) 'attachments': attachments.length,
      if (mentions.isNotEmpty) 'mentions': mentions.length,
    }));
  }

  /// Asks the agent to close the task: it writes a journal entry, and the
  /// thread is marked closed.
  Future<void> close(String threadId) async {
    await _messages.doc().set(_queued(threadId, 'Close this conversation.', 'close'));
    unawaited(_audit('Closed a conversation', {'threadId': threadId}));
  }

  /// Messages carry at most this many attachments and mentions
  /// (`firestore.rules`).
  static const maxAttachments = 10;
  static const maxMentions = 10;

  Map<String, Object?> _queued(
    String threadId,
    String text,
    String kind, {
    List<AttachmentRef> attachments = const [],
    List<MentionRef> mentions = const [],
  }) {
    if (attachments.length > maxAttachments) throw ArgumentError('At most $maxAttachments files per message.');
    // Only mentions still written in the text count.
    final kept = {for (final m in mentions) if (text.contains(m.token)) '${m.kind.name}:${m.id}': m}.values.take(maxMentions);
    return {
      'threadId': threadId,
      'role': 'operator',
      'kind': kind,
      'text': text,
      'status': 'queued',
      'createdAt': FieldValue.serverTimestamp(),
      if (attachments.isNotEmpty) 'attachments': [for (final a in attachments) a.toFirestore()],
      if (kept.isNotEmpty) 'mentions': [for (final m in kept) m.toFirestore()],
    };
  }

  Future<void> rename(String threadId, String title) {
    final t = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) throw ArgumentError('A title cannot be empty.');
    return _threads.doc(threadId).update({'title': t.length <= 200 ? t : t.substring(0, 200)}).then(
      (_) => unawaited(_audit('Renamed a conversation', {'threadId': threadId, 'title': t})),
    );
  }

  Future<void> setPinned(String threadId, bool pinned) async {
    await _threads.doc(threadId).update({'pinned': pinned});
    unawaited(_audit(pinned ? 'Pinned a conversation' : 'Unpinned a conversation', {'threadId': threadId}));
  }

  Future<void> setArchived(String threadId, bool archived) async {
    await _threads.doc(threadId).update({'archived': archived});
    unawaited(_audit(archived ? 'Archived a conversation' : 'Unarchived a conversation', {'threadId': threadId}));
  }

  /// Stops a message: a queued one is cancelled outright (no worker has it
  /// yet); a running one is asked to stop, and its worker stops the turn,
  /// keeping what it wrote.
  Future<void> stop(String messageId) async {
    final what = await _db.runTransaction((tx) async {
      final ref = _messages.doc(messageId);
      final snap = await tx.get(ref);
      switch (snap.data()?['status']) {
        case 'queued':
          tx.update(ref, {'status': 'cancelled'});
          return 'Cancelled a queued message';
        case 'running':
          tx.update(ref, {'cancelRequested': true});
          return 'Stopped a running turn';
      }
      return null;
    });
    if (what != null) unawaited(_audit(what, {'messageId': messageId}));
  }

  Stream<HostStatus?> hostStatus(String host) => _db
      .doc('status/$host')
      .snapshots()
      .map((d) => d.exists ? hostFrom(d.data()!) : null);

  /// Every host's status (`status/mac`, `status/cloud`,
  /// `status/devstation-*`).
  Stream<Map<String, HostStatus>> allStatus() => _db.collection('status').snapshots().map(
    (s) => {for (final d in s.docs) d.id: hostFrom(d.data())},
  );

  /// Cost breakdowns from the billing export (`billing/breakdown`).
  Stream<BillingBreakdown?> billingBreakdown() => _db
      .doc('billing/breakdown')
      .snapshots()
      .map((d) => d.exists ? billingBreakdownFrom(d.data()!) : null);

  /// The estate's inventory (`topology/current`).
  Stream<TopologyInventory?> topology() => _db
      .doc('topology/current')
      .snapshots()
      .map((d) => d.exists ? topologyFrom(d.data()!) : null);

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

  Stream<UsageStats?> usageStats() => _db
      .doc('stats/usage')
      .snapshots()
      .map((d) => d.exists ? usageStatsFrom(d.data()!) : null);

  /// The operator days (ids `yyyy-mm-dd`) of the last [days] days that had
  /// chat turns, oldest first.
  Stream<List<UsageDay>> usageDays({int days = 31, DateTime? now}) {
    final from = (now ?? DateTime.now()).toUtc().add(const Duration(hours: 8)).subtract(Duration(days: days - 1));
    return _db
        .collection('usage_days')
        .where(FieldPath.documentId, isGreaterThanOrEqualTo: from.toIso8601String().substring(0, 10))
        .snapshots()
        .map((s) => [for (final d in s.docs) usageDayFrom(d.id, d.data())]..sort((a, b) => a.day.compareTo(b.day)));
  }

  Stream<BillingView?> billing() => _db
      .doc('billing/current')
      .snapshots()
      .map((d) => d.exists ? billingFrom(d.data()!) : null);

  Stream<List<Devstation>> devstations() => _db.collection('devstations').snapshots().map(
    (s) => [
      for (final d in s.docs)
        if (d.data()['state'] != 'deleted') devstationFrom(d.id, d.data()),
    ]..sort((a, b) => a.id.compareTo(b.id)),
  );

  Stream<List<FactoryRequest>> factoryRequests() => _db
      .collection('factory_requests')
      .orderBy('createdAt', descending: true)
      .limit(30)
      .snapshots()
      .map((s) => [
            for (final d in s.docs)
              FactoryRequest(
                id: d.id,
                action: d.data()['action'] as String? ?? '',
                devstationId: d.data()['devstationId'] as String? ?? '',
                status: d.data()['status'] as String? ?? '',
                project: d.data()['project'] as String?,
                createdAt: _time(d.data()['createdAt']),
                finishedAt: _time(d.data()['finishedAt']),
                error: d.data()['error'] as String?,
                buildId: d.data()['buildId'] as String?,
              ),
          ]);

  /// Queues a Factory request; the cloud runner applies it.
  Future<void> requestFactory({
    required String action,
    required String devstationId,
    String? project,
    String? machineType,
    String? repoUrl,
  }) => _db.collection('factory_requests').doc().set({
    'action': action,
    'devstationId': devstationId,
    if (action == 'create') ...{
      'project': project,
      'machineType': machineType,
      'repoUrl': repoUrl ?? '',
    },
    'status': 'queued',
    'createdAt': FieldValue.serverTimestamp(),
  }).then((_) => unawaited(_audit('Requested Factory $action of $devstationId', {
    'action': action,
    'devstation': devstationId,
    'project': ?project,
    'machineType': ?machineType,
  })));

  Stream<List<Approval>> approvals() => _db
      .collection('approvals')
      .orderBy('createdAt', descending: true)
      .limit(50)
      .snapshots()
      .map((s) => [
            for (final d in s.docs)
              Approval(
                id: d.id,
                requestedBy: d.data()['requestedBy'] as String? ?? '',
                action: d.data()['action'] as String? ?? '',
                details: d.data()['details'] as String? ?? '',
                status: d.data()['status'] as String? ?? 'pending',
                createdAt: _time(d.data()['createdAt']),
                decidedAt: _time(d.data()['decidedAt']),
              ),
          ]);

  Future<void> decide(String approvalId, {required bool approve}) async {
    await _db.doc('approvals/$approvalId').update({
      'status': approve ? 'approved' : 'rejected',
      'decidedAt': FieldValue.serverTimestamp(),
    });
    unawaited(_audit(approve ? 'Approved a request' : 'Rejected a request', {'approvalId': approvalId}));
  }

  // ------------------------------------------------------------- telemetry

  /// Log entries, newest first, between [from] and [to] (open: now), at most
  /// [limit]. [source] and [severities] filter on the server (indexed);
  /// [components] selects e.g. the Activity tab's `audit` and `lifecycle`.
  Stream<List<LogEntry>> logs({
    required DateTime from,
    DateTime? to,
    String? source,
    List<String>? severities,
    List<String>? components,
    int limit = 200,
  }) {
    Query<Map<String, dynamic>> q = _db.collection('logs');
    if (source != null) q = q.where('source', isEqualTo: source);
    if (severities != null && severities.isNotEmpty) q = q.where('severity', whereIn: severities);
    if (components != null && components.isNotEmpty) q = q.where('component', whereIn: components);
    q = q.where('at', isGreaterThanOrEqualTo: Timestamp.fromDate(from));
    if (to != null) q = q.where('at', isLessThanOrEqualTo: Timestamp.fromDate(to));
    return q
        .orderBy('at', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => [for (final d in s.docs) ?logFrom(d.id, d.data())]);
  }

  /// Every source's metric hours since [from].
  Stream<List<MetricHour>> metrics({required DateTime from}) => _db
      .collection('metrics')
      .where('hour', isGreaterThanOrEqualTo: Timestamp.fromDate(DateTime.utc(from.year, from.month, from.day, from.hour)))
      .snapshots()
      .map((s) => [for (final d in s.docs) ?metricFrom(d.data())]);

  /// Writes a Console entry (`source: console`): `audit` for what the
  /// operator did, `client` for errors in the Console itself. Best effort.
  Future<void> writeLog(String component, LogSeverity severity, String message, [Map<String, Object?> fields = const {}]) async {
    try {
      final now = DateTime.now();
      await _db.collection('logs').add({
        'at': FieldValue.serverTimestamp(),
        'source': 'console',
        'component': component,
        'severity': severity.name,
        'message': message.length <= 2000 ? message : '${message.substring(0, 1999)}…',
        if (fields.isNotEmpty)
          'fields': {
            for (final e in fields.entries.take(20))
              e.key: switch (e.value) {
                String v => v.length <= 1000 ? v : '${v.substring(0, 999)}…',
                num() || bool() || null => e.value,
                _ => '${e.value}',
              },
          },
        'expireAt': Timestamp.fromDate(now.add(const Duration(days: 14))),
      });
    } catch (_) {
      // The audit trail never blocks or fails an action.
    }
  }

  Future<void> _audit(String message, [Map<String, Object?> fields = const {}]) =>
      writeLog('audit', LogSeverity.info, message, fields);

  static String titleFor(String text) {
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

int? _int(Object? v) => v is num ? v.toInt() : null;
double? _double(Object? v) => v is num ? v.toDouble() : null;

ChatThread threadFrom(String id, Map<String, dynamic> d) => ChatThread(
  id: id,
  agent: d['agent'] as String? ?? 'genie',
  title: d['title'] as String? ?? '',
  createdAt: _time(d['createdAt']),
  updatedAt: _time(d['updatedAt']),
  lastMessage: d['lastMessage'] as String?,
  closed: d['closed'] as bool? ?? false,
  pinned: d['pinned'] as bool? ?? false,
  archived: d['archived'] as bool? ?? false,
);

ChatMessage messageFrom(String id, Map<String, dynamic> d) => ChatMessage(
  id: id,
  threadId: d['threadId'] as String? ?? '',
  fromOperator: d['role'] == 'operator',
  text: d['text'] as String? ?? '',
  kind: d['kind'] as String? ?? 'turn',
  createdAt: _time(d['createdAt']),
  status: MessageStatus.values.asNameMap()[d['status']],
  claimedBy: d['claimedBy'] as String?,
  claimedAt: _time(d['claimedAt']),
  finishedAt: _time(d['finishedAt']),
  error: d['error'] as String?,
  placement: d['placement'] as String?,
  accountId: d['accountId'] as String?,
  partial: d['partial'] as String?,
  activity: d['activity'] as String?,
  tools: [for (final t in d['tools'] as List? ?? const []) '$t'],
  cancelRequested: d['cancelRequested'] as bool? ?? false,
  costUsd: _double(d['costUsd']),
  outputTokens: _int(d['outputTokens']),
  contextTokens: _int(d['contextTokens']),
  durationMs: _int(d['durationMs']),
  model: d['model'] as String?,
  stopped: d['stopped'] as bool? ?? false,
  attachments: [
    for (final a in d['attachments'] as List? ?? const [])
      if (a is Map && a['path'] is String)
        AttachmentRef(
          path: a['path'] as String,
          name: a['name'] as String? ?? 'file',
          contentType: a['contentType'] as String?,
          size: _int(a['size']),
        ),
  ],
  mentions: [
    for (final m in d['mentions'] as List? ?? const [])
      if (m is Map && MentionKind.values.asNameMap()[m['kind']] != null && m['id'] is String)
        MentionRef(kind: MentionKind.values.asNameMap()[m['kind']]!, id: m['id'] as String, label: m['label'] as String? ?? m['id'] as String),
  ],
);

Devstation devstationFrom(String id, Map<String, dynamic> d) => Devstation(
  id: id,
  project: d['project'] as String? ?? id,
  state: d['state'] as String? ?? 'unknown',
  desired: d['desired'] as String? ?? 'running',
  machineType: d['machineType'] as String?,
  zone: d['zone'] as String?,
  repoUrl: d['repoUrl'] as String?,
  instance: d['instance'] as String?,
  ip: d['ip'] as String?,
  error: d['error'] as String?,
  createdAt: _time(d['createdAt']),
  updatedAt: _time(d['updatedAt']),
);

HostStatus hostFrom(Map<String, dynamic> d) {
  final m = d['metrics'] as Map?;
  return HostStatus(
    localServices: [
      for (final x in (d['localServices'] as List? ?? const []))
        if (x is Map && x['label'] is String)
          LocalServiceView(
            label: x['label'] as String,
            running: x['running'] == true,
            lastExit: _int(x['lastExit']),
            connected: x['connected'] as bool?,
            detail: x['detail'] as String?,
          ),
    ],
    lastSeen: _time(d['lastSeen']),
    host: d['host'] as String?,
    agents: [for (final a in d['agents'] as List? ?? const []) '$a'],
    agentInfo: {
      for (final e in ((d['agentInfo'] as Map?) ?? const {}).entries)
        if ((e.value as Map?)?['description'] is String) '${e.key}': (e.value as Map)['description'] as String,
    },
    startedAt: _time(d['startedAt']),
    revision: d['revision'] as String?,
    lastRunAt: _time(d['lastRunAt']),
    lastResult: d['lastResult'] as String?,
    claudeVersion: d['claudeVersion'] as String?,
    devstation: d['devstation'] as String?,
    metrics: m == null
        ? null
        : HostMetricsView(
            at: _time(m['at']),
            cores: _int(m['cores']) ?? 0,
            cpu: _double(m['cpu']),
            memUsed: _int(m['memUsed']),
            memTotal: _int(m['memTotal']),
            diskUsed: _int(m['diskUsed']),
            diskTotal: _int(m['diskTotal']),
            load1: _double(m['load1']),
            rss: _int(m['rss']),
          ),
    history: [
      for (final p in d['history'] as List? ?? const [])
        if (p is Map && p['t'] is num)
          MetricPoint(
            at: DateTime.fromMillisecondsSinceEpoch((p['t'] as num).toInt() * 1000),
            cpu: _double(p['c']),
            mem: _double(p['m']),
          ),
    ],
  );
}

Map<String, UsageSlice> _slices(Object? raw) => {
  for (final e in ((raw as Map?) ?? const {}).entries)
    if (e.value is Map)
      '${e.key}': UsageSlice(
        turns: _int((e.value as Map)['turns']) ?? 0,
        costUsd: _double((e.value as Map)['costUsd']) ?? 0,
        failed: _int((e.value as Map)['failed']) ?? 0,
      ),
};

UsageStats usageStatsFrom(Map<String, dynamic> d) => UsageStats(
  turns: _int(d['turns']) ?? 0,
  costUsd: _double(d['costUsd']) ?? 0,
  outputTokens: _int(d['outputTokens']) ?? 0,
  durationMs: _int(d['durationMs']) ?? 0,
  failed: _int(d['failed']) ?? 0,
  byAgent: _slices(d['byAgent']),
  byPlacement: _slices(d['byPlacement']),
  byAccount: _slices(d['byAccount']),
);

UsageDay usageDayFrom(String id, Map<String, dynamic> d) => UsageDay(
  day: id,
  turns: _int(d['turns']) ?? 0,
  costUsd: _double(d['costUsd']) ?? 0,
  outputTokens: _int(d['outputTokens']) ?? 0,
  durationMs: _int(d['durationMs']) ?? 0,
  failed: _int(d['failed']) ?? 0,
  byAgent: _slices(d['byAgent']),
);

BillingView? billingFrom(Map<String, dynamic> d) {
  final cost = _double(d['costAmount']);
  if (cost == null) return null;
  return BillingView(
    costAmount: cost,
    budgetAmount: _double(d['budgetAmount']),
    currencyCode: d['currencyCode'] as String?,
    month: d['month'] as String?,
    updatedAt: _time(d['updatedAt']),
    days: {
      for (final e in ((d['days'] as Map?) ?? const {}).entries)
        if (e.value is num) '${e.key}': (e.value as num).toDouble(),
    },
  );
}

BillingBreakdown billingBreakdownFrom(Map<String, dynamic> d) {
  double n(Object? v) => _double(v) ?? 0;
  List<Map<String, dynamic>> list(Object? v) => [for (final x in (v as List? ?? const [])) if (x is Map) x.cast<String, dynamic>()];
  Map<String, double> amounts(Object? v) => {
    for (final e in ((v as Map?) ?? const {}).entries)
      if (e.value is num) '${e.key}': (e.value as num).toDouble(),
  };
  return BillingBreakdown(
    status: d['status'] as String? ?? 'no-export',
    at: _time(d['at']),
    exportedAt: _time(d['exportedAt']),
    dataset: d['dataset'] as String?,
    table: d['table'] as String?,
    currency: d['currency'] as String?,
    month: d['month'] as String?,
    previousMonth: d['previousMonth'] as String?,
    total: n(d['total']),
    cost: n(d['cost']),
    credits: n(d['credits']),
    previousTotal: n(d['previousTotal']),
    projects: [
      for (final p in list(d['projects']))
        BillingProject(
          id: p['id'] as String? ?? '',
          name: p['name'] as String? ?? '',
          net: n(p['net']),
          cost: n(p['cost']),
          credits: n(p['credits']),
          previous: n(p['previous']),
        ),
    ],
    services: [
      for (final s in list(d['services']))
        BillingService(name: s['name'] as String? ?? '', net: n(s['net']), previous: n(s['previous']), projects: amounts(s['projects'])),
    ],
    skus: [
      for (final k in list(d['skus']))
        BillingSku(service: k['service'] as String? ?? '', sku: k['sku'] as String? ?? '', project: k['project'] as String? ?? '', net: n(k['net'])),
    ],
    days: {
      for (final e in ((d['days'] as Map?) ?? const {}).entries)
        if (e.value is Map) '${e.key}': amounts(e.value),
    },
  );
}

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
          costUsd: (s['costUsd'] as num?)?.toDouble() ?? 0,
          outputTokens: (s['outputTokens'] as num?)?.toInt() ?? 0,
          createdAt: _time(s['createdAt']),
          lastUsedAt: _time(s['lastUsedAt']),
        ),
    ],
    updatedAt: _time(d['updatedAt']),
  );
}

double? _num(Object? v) => v is num ? v.toDouble() : null;

LogEntry? logFrom(String id, Map<String, dynamic> d) {
  final at = _time(d['at']);
  if (at == null) return null; // a Console entry whose server time is pending
  return LogEntry(
    id: id,
    at: at,
    source: d['source'] as String? ?? '?',
    component: d['component'] as String? ?? '',
    severity: LogSeverity.values.asNameMap()[d['severity']] ?? LogSeverity.info,
    message: d['message'] as String? ?? '',
    host: d['host'] as String?,
    fields: {
      for (final e in ((d['fields'] as Map?) ?? const {}).entries)
        '${e.key}': switch (e.value) { Timestamp t => t.toDate(), final v => v },
    },
  );
}

MetricHour? metricFrom(Map<String, dynamic> d) {
  final hour = _time(d['hour']);
  if (hour == null) return null;
  Map<String, double> numbers(Object? m) => {
    for (final e in ((m as Map?) ?? const {}).entries)
      if (_num(e.value) != null) '${e.key}': _num(e.value)!,
  };
  return MetricHour(
    source: d['source'] as String? ?? '?',
    hour: hour,
    totals: numbers(d['h']),
    minutes: {
      for (final e in ((d['m'] as Map?) ?? const {}).entries)
        if (int.tryParse('${e.key}'.replaceFirst('m', '')) case final int minute) minute: numbers(e.value),
    },
  );
}

Map<String, String> _strings(Object? m) =>
    m is Map ? {for (final e in m.entries) '${e.key}': '${e.value}'} : const {};

TopologyInventory topologyFrom(Map<String, dynamic> d) => TopologyInventory(
  at: _time(d['at']),
  projects: [
    for (final p in d['projects'] as List? ?? const [])
      if (p is Map && p['id'] is String)
        GcpProjectView(
          id: p['id'] as String,
          name: '${p['name'] ?? p['id']}',
          number: p['number']?.toString(),
          access: p['access'] as String? ?? 'full',
          labels: _strings(p['labels']),
        ),
  ],
  resources: [
    for (final r in d['resources'] as List? ?? const [])
      if (r is Map && r['id'] is String)
        CloudResource(
          id: r['id'] as String,
          project: '${r['project'] ?? ''}',
          type: '${r['type'] ?? ''}',
          name: '${r['name'] ?? ''}',
          location: r['location'] as String?,
          state: r['state'] as String?,
          public: r['public'] == true,
          publicRoles: [for (final x in r['publicRoles'] as List? ?? const []) '$x'],
          labels: _strings(r['labels']),
          url: r['url'] as String?,
          ingress: r['ingress'] as String?,
          health: r['health'] as String?,
          detail: r['detail'] as String?,
          schedule: r['schedule'] as String?,
          lastRun: _time(r['lastRun']),
        ),
  ],
  repos: [
    for (final r in d['repos'] as List? ?? const [])
      if (r is Map && r['path'] is String)
        RepoView(
          name: '${r['name'] ?? r['path']}',
          path: r['path'] as String,
          host: (r['remote'] as Map?)?['host'] as String?,
          owner: (r['remote'] as Map?)?['owner'] as String?,
          repo: (r['remote'] as Map?)?['repo'] as String?,
          branch: r['branch'] as String?,
          lastCommit: _time(r['lastCommit']),
          dirty: r['dirty'] == true,
          stack: [for (final x in r['stack'] as List? ?? const []) '$x'],
        ),
  ],
  errors: [for (final e in d['errors'] as List? ?? const []) '$e'],
);
