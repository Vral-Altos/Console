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
            'status': 'active', 'contextTokens': 1200, 'turns': 3, 'compactions': 0,
            'createdAt': '2026-11-04T08:00:00.000Z', 'lastUsedAt': '2026-11-04T08:05:00.000Z',
          },
        ],
      }),
    });
    expect(mesh.accounts.single.label, 'Main');
    expect(mesh.accounts.single.fiveHour!.utilization, 0.42);
    expect(mesh.accounts.single.sevenDay, isNull);
    expect(mesh.sessions.single.turns, 3);
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
}
