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
    await repo.requestFactory(action: 'stop', devstationId: 'atlas');
    await repo.requestFactory(action: 'create', devstationId: 'citadel', project: 'Citadel Platform',
        machineType: 'e2-standard-4', diskGb: 60, repoUrl: '');
    final create = (await db.collection('factory_requests').where('devstationId', isEqualTo: 'citadel').get()).docs.single.data();
    expect(create.keys.toSet(), {'action', 'devstationId', 'project', 'machineType', 'diskGb', 'repoUrl', 'status', 'createdAt'});
    expect(create['diskGb'], 60);
    await Future<void>.delayed(Duration.zero);
    final logs = (await db.collection('logs').get()).docs.map((d) => d.data()).toList();
    expect(logs.map((l) => l['message']), contains('Requested Factory stop of atlas'));
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
