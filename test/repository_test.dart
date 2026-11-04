import 'dart:convert';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:va_console/data/console_repository.dart';
import 'package:va_console/data/models.dart';
import 'package:va_console/data/providers.dart';

void main() {
  late FakeFirebaseFirestore db;
  late ConsoleRepository repo;

  setUp(() {
    db = FakeFirebaseFirestore();
    repo = ConsoleRepository(db);
  });

  test('starting a thread writes the thread and its first queued message', () async {
    final id = await repo.startThread(agent: 'financier', text: 'How is my budget for November looking?');
    final thread = (await db.doc('threads/$id').get()).data()!;
    expect(thread['agent'], 'financier');
    expect(thread['title'], 'How is my budget for November looking?');
    expect(thread['closed'], false);
    final msgs = (await db.collection('messages').get()).docs.map((d) => d.data()).toList();
    expect(msgs, hasLength(1));
    expect(msgs.single, containsPair('status', 'queued'));
    expect(msgs.single, containsPair('role', 'operator'));
    expect(msgs.single, containsPair('kind', 'turn'));
    expect(msgs.single, containsPair('threadId', id));
    // Exactly the fields the security rules allow.
    expect(msgs.single.keys.toSet(), {'threadId', 'role', 'kind', 'text', 'status', 'createdAt'});
    expect(thread.keys.toSet(), {'agent', 'title', 'createdAt', 'updatedAt', 'closed'});
  });

  test('long first messages make a short title', () async {
    final id = await repo.startThread(agent: 'genie', text: 'x' * 200);
    expect(((await db.doc('threads/$id').get()).data()!['title'] as String).length, 60);
  });

  test('send and close queue operator messages', () async {
    await repo.send('t1', 'more');
    await repo.close('t1');
    final kinds = (await db.collection('messages').get()).docs.map((d) => d['kind']).toSet();
    expect(kinds, {'turn', 'close'});
  });

  test('a thread streams its messages in order with their status', () async {
    await db.collection('messages').add({
      'threadId': 't1', 'role': 'agent', 'text': 'b', 'createdAt': DateTime.utc(2026, 1, 2),
      'placement': 'cloud',
    });
    await db.collection('messages').add({
      'threadId': 't1', 'role': 'operator', 'text': 'a', 'createdAt': DateTime.utc(2026, 1, 1),
      'status': 'failed', 'error': 'boom', 'kind': 'turn',
    });
    await db.collection('messages').add({'threadId': 'other', 'role': 'operator', 'text': 'z', 'createdAt': DateTime.utc(2026)});
    final list = await repo.messages('t1').first;
    expect(list.map((m) => m.text), ['a', 'b']);
    expect(list.first.status, MessageStatus.failed);
    expect(list.first.error, 'boom');
    expect(list.last.fromOperator, isFalse);
    expect(list.last.placement, 'cloud');
  });

  test('the registry is read from its JSON document', () {
    final mesh = meshFrom({
      'json': jsonEncode({
        'accounts': [
          {'id': 'a', 'label': 'Main', 'tokenRef': 'account-a'},
        ],
        'usage': {
          'a': {
            'accountId': 'a',
            'fiveHour': {'utilization': 0.42, 'resetsAt': '2026-11-04T10:00:00.000Z', 'status': 'allowed'},
            'updatedAt': '2026-11-04T08:00:00.000Z',
          },
        },
        'sessions': [
          {
            'sessionId': 's', 'agent': 'genie', 'taskId': 'console-t1', 'accountId': 'a',
            'status': 'active', 'contextTokens': 1200, 'turns': 3, 'compactions': 0, 'costUsd': 0.25,
            'createdAt': '2026-11-04T08:00:00.000Z', 'lastUsedAt': '2026-11-04T08:05:00.000Z',
          },
        ],
      }),
    });
    expect(mesh.accounts.single.label, 'Main');
    expect(mesh.accounts.single.fiveHour!.utilization, 0.42);
    expect(mesh.accounts.single.sevenDay, isNull);
    expect(mesh.sessions.single.turns, 3);
    expect(mesh.sessions.single.costUsd, 0.25);
  });

  test("with no accounts, the host login's usage is shown", () {
    final mesh = meshFrom({
      'json': jsonEncode({
        'usage': {
          'default': {'accountId': 'default', 'sevenDay': {'utilization': 0.1}, 'updatedAt': '2026-11-04T08:00:00.000Z'},
        },
      }),
    });
    expect(mesh.accounts.single.id, 'default');
    expect(mesh.accounts.single.sevenDay!.utilization, 0.1);
  });

  test('the Mac counts as on only while its heartbeat is fresh', () {
    final now = DateTime.utc(2026, 11, 4, 12);
    expect(macIsOn(null, now), isFalse);
    expect(macIsOn(HostStatus(lastSeen: now.subtract(const Duration(seconds: 50))), now), isTrue);
    expect(macIsOn(HostStatus(lastSeen: now.subtract(const Duration(minutes: 5))), now), isFalse);
  });

  test('stop cancels a queued message and asks a running one to stop', () async {
    await db.doc('messages/q').set({'threadId': 't', 'role': 'operator', 'status': 'queued'});
    await db.doc('messages/r').set({'threadId': 't', 'role': 'operator', 'status': 'running'});
    await db.doc('messages/d').set({'threadId': 't', 'role': 'operator', 'status': 'done'});
    await repo.stop('q');
    await repo.stop('r');
    await repo.stop('d');
    expect((await db.doc('messages/q').get()).data(), {'threadId': 't', 'role': 'operator', 'status': 'cancelled'});
    expect((await db.doc('messages/r').get()).data()!['cancelRequested'], true);
    expect((await db.doc('messages/r').get()).data()!['status'], 'running');
    expect((await db.doc('messages/d').get()).data(), {'threadId': 't', 'role': 'operator', 'status': 'done'},
        reason: 'a finished message is left alone');
  });

  test('threads are renamed, pinned and archived with only those fields', () async {
    final id = await repo.startThread(agent: 'genie', text: 'hello');
    await repo.rename(id, '  Weekly   plan ');
    await repo.setPinned(id, true);
    await repo.setArchived(id, true);
    final th = threadFrom(id, (await db.doc('threads/$id').get()).data()!);
    expect(th.title, 'Weekly plan');
    expect(th.pinned, isTrue);
    expect(th.archived, isTrue);
    expect(() => repo.rename(id, '   '), throwsArgumentError);
  });

  test('only queued and running messages are active', () async {
    for (final (id, status) in [('a', 'queued'), ('b', 'running'), ('c', 'done'), ('d', 'cancelled')]) {
      await db.doc('messages/$id').set({'threadId': 't', 'role': 'operator', 'status': status, 'createdAt': DateTime.utc(2026)});
    }
    expect((await repo.activeMessages().first).map((m) => m.id).toSet(), {'a', 'b'});
  });

  test('live progress and turn details are read from messages', () {
    final m = messageFrom('m', {
      'threadId': 't', 'role': 'operator', 'status': 'running', 'partial': 'Half', 'activity': 'Using Read',
      'tools': ['Read'], 'cancelRequested': true,
    });
    expect((m.partial, m.activity, m.tools.join(), m.cancelRequested), ('Half', 'Using Read', 'Read', true));
    final r = messageFrom('r', {
      'threadId': 't', 'role': 'agent', 'text': 'x', 'costUsd': 0.05, 'outputTokens': 21, 'durationMs': 2725,
      'model': 'claude-opus-5-5', 'stopped': true,
    });
    expect((r.costUsd, r.outputTokens, r.durationMs, r.model, r.stopped), (0.05, 21, 2725, 'claude-opus-5-5', true));
  });

  test('host metrics, history and agent descriptions are read from status', () {
    final h = hostFrom({
      'lastSeen': DateTime.utc(2026, 11, 4),
      'agents': ['genie'],
      'agentInfo': {'genie': {'description': 'Your assistant'}, 'x': <String, Object?>{}},
      'metrics': {'cores': 8, 'cpu': 0.25, 'memUsed': 4, 'memTotal': 8, 'at': DateTime.utc(2026, 11, 4)},
      'history': [
        {'t': 1793800000, 'c': 0.1, 'm': 0.5},
        {'t': 1793800050, 'c': 0.2},
      ],
    });
    expect(h.agentInfo, {'genie': 'Your assistant'});
    expect(h.metrics!.cores, 8);
    expect(h.metrics!.cpu, 0.25);
    expect(h.history.map((p) => p.cpu), [0.1, 0.2]);
    expect(h.history.last.mem, isNull);
  });

  test('usage stats, days and billing are read', () async {
    final u = usageStatsFrom({
      'turns': 3, 'costUsd': 0.5, 'byAgent': {'genie': {'turns': 2, 'costUsd': 0.4}}, 'byPlacement': {'mac': {'turns': 3}},
    });
    expect(u.byAgent['genie']!.turns, 2);
    expect(u.byPlacement['mac']!.costUsd, 0);
    for (final d in ['2026-11-02', '2026-11-04', '2026-11-03']) {
      await db.doc('usage_days/$d').set({'turns': int.parse(d.substring(8))});
    }
    final days = await repo.usageDays(days: 2, now: DateTime.utc(2026, 11, 4, 3)).first;
    expect(days.map((d) => d.day), ['2026-11-03', '2026-11-04'], reason: 'the latest days, oldest first');
    final b = billingFrom({'costAmount': 2.5, 'budgetAmount': 30, 'currencyCode': 'SGD', 'days': {'2026-11-04': 2.5}})!;
    expect((b.costAmount, b.budgetAmount, b.days['2026-11-04']), (2.5, 30.0, 2.5));
    expect(billingFrom({'month': '2026-11'}), isNull);
  });

  test('the operator day is Singapore time', () {
    expect(operatorDay(DateTime.utc(2026, 11, 4, 15, 59)), '2026-11-04');
    expect(operatorDay(DateTime.utc(2026, 11, 4, 16)), '2026-11-05');
  });
}
