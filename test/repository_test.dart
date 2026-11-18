import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:va_console/data/console_repository.dart';
import 'package:va_console/data/models.dart';
import 'package:va_console/data/providers.dart';
import 'package:va_console/data/telemetry.dart';

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

  test('attachments and mentions go with the message; unwritten mentions are dropped', () async {
    const file = AttachmentRef(path: 'attachments/abcdefghij0123456789/q3.pdf', name: 'q3.pdf', contentType: 'application/pdf', size: 2048);
    const plan = MentionRef(kind: MentionKind.thread, id: 't9', label: 'Plan');
    const roman = MentionRef(kind: MentionKind.agent, id: 'roman', label: 'Roman');
    final id = await repo.startThread(agent: 'genie', text: '', attachments: const [file]);
    expect((await db.doc('threads/$id').get()).data()!['title'], 'q3.pdf', reason: 'no text: the file names it');
    await repo.send(id, 'compare with @Plan', attachments: const [file], mentions: const [plan, roman, plan]);
    final msgs = (await db.collection('messages').orderBy('text').get()).docs.map((d) => d.data()).toList();
    expect(msgs[0]['attachments'], [
      {'path': file.path, 'name': 'q3.pdf', 'contentType': 'application/pdf', 'size': 2048},
    ]);
    expect(msgs[0].containsKey('mentions'), isFalse);
    expect(msgs[1]['mentions'], [
      {'kind': 'thread', 'id': 't9', 'label': 'Plan'},
    ]);
    final back = messageFrom('m', msgs[1]);
    expect(back.attachments.single, file);
    expect(back.mentions.single, plan);
    expect(() => repo.send(id, 'x', attachments: List.filled(11, file)), throwsArgumentError);
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

  test('a renamed topic is kept from the namer; filing sets project and purpose', () async {
    final id = await repo.startThread(agent: 'genie', text: 'hello');
    await repo.rename(id, 'Weekly plan');
    await repo.setProject(id, 'Financier');
    await repo.setPurpose(id, ChatPurpose.plan);
    final raw = (await db.doc('threads/$id').get()).data()!;
    expect(raw['titleSet'], isTrue);
    expect(raw['projectSet'], isTrue);
    final th = threadFrom(id, raw);
    expect((th.project, th.purpose, th.projectName), ('Financier', ChatPurpose.plan, 'Financier'));
    await repo.setProject(id, null);
    expect(threadFrom(id, (await db.doc('threads/$id').get()).data()!).projectName, 'General');
  });

  test('a conversation\'s model and effort are set, cleared, and only from the offered ones', () async {
    final id = await repo.startThread(agent: 'genie', text: 'hello');
    await repo.setModelEffort(id, model: 'claude-sonnet-5-5', effort: 'high');
    var th = threadFrom(id, (await db.doc('threads/$id').get()).data()!);
    expect((th.model, th.effort), ('claude-sonnet-5-5', 'high'));
    await repo.setModelEffort(id, model: null, effort: 'low');
    final raw = (await db.doc('threads/$id').get()).data()!;
    expect(raw.containsKey('model'), isFalse);
    th = threadFrom(id, raw);
    expect((th.model, th.effort), (null, 'low'));
    expect(() => repo.setModelEffort(id, model: 'gpt-5', effort: null), throwsArgumentError);
    expect(threadFrom('x', {'agent': 'genie', 'title': 't', 'model': 'gpt-5'}).model, isNull);
  });

  test('a new thread is filed when the operator picks a project, else left to the namer', () async {
    final auto = await repo.startThread(agent: 'genie', text: 'a');
    final general = await repo.startThread(agent: 'genie', text: 'b', filing: (project: null));
    final eos = await repo.startThread(agent: 'genie', text: 'c', filing: (project: 'EOS'));
    expect((await db.doc('threads/$auto').get()).data()!.containsKey('projectSet'), isFalse);
    expect((await db.doc('threads/$general').get()).data(), allOf(containsPair('project', null), containsPair('projectSet', true)));
    expect((await db.doc('threads/$eos').get()).data(), allOf(containsPair('project', 'EOS'), containsPair('projectSet', true)));
  });

  test('the workers\' cost, filing and quota are read', () {
    final th = threadFrom('t', {
      'agent': 'genie', 'title': 'Topic', 'project': ' ', 'purpose': 'research', 'costUsd': 0.51,
      'namedAt': Timestamp.fromDate(DateTime.utc(2026, 11, 16)), 'from': 'roman',
    });
    expect((th.project, th.purpose, th.costUsd, th.from), (null, ChatPurpose.research, 0.51, 'roman'));
    expect(threadFrom('t', {'purpose': 'dance'}).purpose, isNull);
    final m = messageFrom('m', {
      'role': 'agent', 'text': 'x',
      'quota': {'fiveHour': {'utilization': 0.42, 'resetsAt': Timestamp.fromDate(DateTime.utc(2026, 11, 16, 12)), 'status': 'allowed'}},
    });
    expect(m.quota!.fiveHour!.utilization, 0.42);
    expect(m.quota!.fiveHour!.resetsAt!.isAtSameMomentAs(DateTime.utc(2026, 11, 16, 12)), isTrue);
    expect(m.quota!.sevenDay, isNull);
    expect(messageFrom('m', {'quota': {'fiveHour': {}}}).quota, isNull);
  });

  test('chat projects: add, rename (refiling), delete (to General)', () async {
    await repo.addProject('  Vral   Altos ');
    var projects = await repo.chatProjects().first;
    expect(projects.single, isA<ChatProject>().having((p) => p.id, 'id', 'vral-altos').having((p) => p.name, 'name', 'Vral Altos'));
    expect(() => repo.addProject('vral altos', existing: projects), throwsArgumentError);
    expect(() => repo.addProject('General'), throwsArgumentError);
    expect(() => repo.addProject('  '), throwsArgumentError);
    final a = await repo.startThread(agent: 'genie', text: 'a', filing: (project: 'Vral Altos'));
    final b = await repo.startThread(agent: 'genie', text: 'b', filing: (project: 'EOS'));
    await repo.renameProject(projects.single, 'Vral Altos HQ', existing: projects);
    projects = await repo.chatProjects().first;
    expect(projects.single.name, 'Vral Altos HQ');
    expect((await db.doc('threads/$a').get()).data()!['project'], 'Vral Altos HQ');
    expect((await db.doc('threads/$b').get()).data()!['project'], 'EOS');
    await repo.deleteProject(projects.single);
    expect(await repo.chatProjects().first, isEmpty);
    expect((await db.doc('threads/$a').get()).data()!['project'], isNull);
    expect(ConsoleRepository.projectId('Café & Co!'), 'caf-co');
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

  test('the billing breakdown as the runner writes it', () {
    final b = billingBreakdownFrom({
      'status': 'ok',
      'currency': 'SGD',
      'month': '2026-11',
      'total': 4,
      'previousTotal': 8.5,
      'projects': [
        {'id': 'vral-altos', 'name': 'Vral Altos', 'net': 1.25, 'cost': 1.75, 'credits': -0.5, 'previous': 6},
      ],
      'services': [
        {'name': 'Cloud Run', 'net': 3, 'previous': 7, 'projects': {'vral-altos': 0.5, 'cortado-ide': 2.5}},
      ],
      'skus': [
        {'service': 'Cloud Run', 'sku': 'CPU', 'project': 'cortado-ide', 'net': 2},
      ],
      'days': {
        '2026-11-12': {'vral-altos': 0.25, '~account': 0.05},
        'bad': 3,
      },
    });
    expect((b.total, b.previousTotal, b.currency), (4.0, 8.5, 'SGD'));
    expect(b.projects.single.credits, -.5);
    expect(b.services.single.projects, {'vral-altos': .5, 'cortado-ide': 2.5});
    expect(b.skus.single.project, 'cortado-ide');
    expect(b.days, {'2026-11-12': {'vral-altos': .25, '~account': .05}});
    expect(billingBreakdownFrom({'status': 'no-export'}).projects, isEmpty);
  });

  test('the operator day is Singapore time', () {
    expect(operatorDay(DateTime.utc(2026, 11, 4, 15, 59)), '2026-11-04');
    expect(operatorDay(DateTime.utc(2026, 11, 4, 16)), '2026-11-05');
  });

  test('operator actions leave an audit trail in the shape the rules allow', () async {
    final id = await repo.startThread(agent: 'genie', text: 'hi');
    await repo.send(id, 'more');
    await repo.setPinned(id, true);
    await repo.requestFactory(action: 'stop', devstationId: 'atlas');
    await repo.requestFactory(action: 'create', devstationId: 'citadel', project: 'Citadel Platform',
        machineType: 'e2-standard-4', diskGb: 60, repoUrl: '');
    final create = (await db.collection('factory_requests').where('devstationId', isEqualTo: 'citadel').get()).docs.single.data();
    expect(create.keys.toSet(), {'action', 'devstationId', 'project', 'machineType', 'diskGb', 'repoUrl', 'status', 'createdAt'});
    expect(create['diskGb'], 60);
    await Future<void>.delayed(Duration.zero);
    final logs = (await db.collection('logs').get()).docs.map((d) => d.data()).toList();
    expect(logs.map((l) => l['message']), containsAll([
      'Started a conversation with genie', 'Sent a message', 'Pinned a conversation', 'Requested Factory stop of atlas',
    ]));
    for (final l in logs) {
      expect(l.keys.toSet(), {'at', 'source', 'component', 'severity', 'message', 'fields', 'expireAt'});
      expect((l['source'], l['component'], l['severity']), ('console', 'audit', 'info'));
    }
  });

  test('logs are read newest first, filtered by source and severity', () async {
    final base = DateTime.utc(2026, 11, 4, 10);
    for (final (i, src, sev) in [(0, 'mac-worker', 'info'), (1, 'cloud-runner', 'error'), (2, 'mac-worker', 'error')]) {
      await db.collection('logs').add({
        'at': Timestamp.fromDate(base.add(Duration(minutes: i))), 'source': src, 'component': 'mailbox',
        'severity': sev, 'message': 'm$i', 'fields': {'threadId': 't'},
      });
    }
    final all = await repo.logs(from: base).first;
    expect(all.map((e) => e.message), ['m2', 'm1', 'm0']);
    expect(all.first.fields['threadId'], 't');
    expect((await repo.logs(from: base, source: 'mac-worker', severities: ['error']).first).single.message, 'm2');
  });

  test('metrics are bucketed: counters summed, gauges averaged', () {
    final h = metricFrom({
      'source': 'mac-worker', 'hour': Timestamp.fromDate(DateTime.utc(2026, 11, 4, 10)),
      'h': {'turns': 3},
      'm': {'m00': {'turns': 1, 'cpu': .2}, 'm01': {'turns': 2, 'cpu': .4}, 'm30': {'cpu': .9}},
    })!;
    expect(h.totals['turns'], 3);
    final from = DateTime.utc(2026, 11, 4, 10);
    final to = from.add(const Duration(hours: 1));
    expect(bucketed([h], 'turns', from: from, to: to, bucket: const Duration(minutes: 30)), [3, null]);
    expect(bucketed([h], 'cpu', from: from, to: to, bucket: const Duration(minutes: 30), gauge: true).map((v) => v?.toStringAsFixed(2)), ['0.30', '0.90']);
    expect(bucketed([h], 'turns', from: from, to: to, bucket: const Duration(minutes: 30), source: 'cloud-runner'), [null, null]);
    expect(total([h], 'turns', from: from, to: to), 3);
  });
}
