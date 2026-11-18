import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chat_mesh/chat_mesh.dart' show threadsProvider, activeMessagesProvider, ChatThread, ChatMessage, MessageStatus;
import 'package:va_console/data/models.dart';
import 'package:va_console/data/providers.dart';
import 'package:va_console/ui/app.dart';
import 'package:va_console/ui/billing_page.dart';
import 'package:va_console/ui/logs_page.dart';
import 'package:va_console/ui/overview_page.dart';
import 'package:va_console/ui/projects_page.dart';
import 'package:va_console/ui/system_page.dart';
import 'package:ui_mesh/ui_mesh.dart';

Widget host(Widget child, List overrides) => ProviderScope(
  overrides: [...overrides],
  child: MaterialApp(
    theme: vaTheme(),
    home: Scaffold(body: child),
  ),
);

void size(WidgetTester tester, Size s) {
  tester.view.physicalSize = s;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

final now = DateTime.now();
final today = operatorDay(now);

HostStatus macStatus() => HostStatus(
  agentModels: const {'financier': 'claude-opus-5-5'},
  agentEfforts: const {'financier': 'medium'},
  lastSeen: now,
  host: 'air',
  agents: const ['genie', 'financier'],
  agentInfo: const {'genie': 'Your personal assistant', 'financier': 'Finance and trading'},
  claudeVersion: '2.1.318 (Claude Code)',
  startedAt: now.subtract(const Duration(hours: 3)),
  metrics: HostMetricsView(at: now, cores: 8, cpu: .25, memUsed: 6 << 30, memTotal: 8 << 30, diskUsed: 200 << 30, diskTotal: 240 << 30),
  history: [for (var i = 0; i < 5; i++) MetricPoint(at: now.subtract(Duration(minutes: 5 - i)), cpu: i / 10, mem: .7)],
);

/// Every stream the pages read, with data (or empty), so pages render
/// without Firebase.
List overridesWith({
  List<ChatThread> threads = const [],
  List<ChatMessage> active = const [],
  Map<String, HostStatus>? hosts,
  MeshView? mesh,
  UsageStats? stats,
  List<UsageDay> days = const [],
  BillingView? billing,
  BillingBreakdown? breakdown,
  List<Devstation> devstations = const [],
  List<FactoryRequest> requests = const [],
  List<Approval> approvals = const [],
  List<LogEntry> logs = const [],
  List<MetricHour> metrics = const [],
}) {
  final h = hosts ?? {'mac': macStatus()};
  return [
    threadsProvider.overrideWith((ref) => Stream.value(threads)),
    activeMessagesProvider.overrideWith((ref) => Stream.value(active)),
    allStatusProvider.overrideWith((ref) => Stream.value(h)),
    macStatusProvider.overrideWith((ref) => Stream.value(h['mac'])),
    cloudStatusProvider.overrideWith((ref) => Stream.value(h['cloud'])),
    meshProvider.overrideWith((ref) => Stream.value(mesh)),
    usageStatsProvider.overrideWith((ref) => Stream.value(stats)),
    usageDaysProvider.overrideWith((ref) => Stream.value(days)),
    billingProvider.overrideWith((ref) => Stream.value(billing)),
    billingBreakdownProvider.overrideWith((ref) => Stream.value(breakdown)),
    devstationsProvider.overrideWith((ref) => Stream.value(devstations)),
    factoryRequestsProvider.overrideWith((ref) => Stream.value(requests)),
    approvalsProvider.overrideWith((ref) => Stream.value(approvals)),
    portfolioSyncProvider.overrideWith((ref) => Stream.value(PortfolioSync(syncedAt: now, source: 'statement'))),
    clockProvider.overrideWith((ref) => const Stream.empty()),
    authStateProvider.overrideWith((ref) => Stream.value(null)),
    logsProvider.overrideWith((ref, q) => Stream.value(logs.where((l) => q.components.isEmpty || q.components.contains(l.component)).toList())),
    metricsProvider.overrideWith((ref, from) => Stream.value(metrics)),
  ];
}

/// A month of the billing export: two projects, credits, last month.
BillingBreakdown breakdown() => BillingBreakdown(
  status: 'ok',
  at: now,
  exportedAt: now.subtract(const Duration(hours: 2)),
  dataset: 'vral-altos.va_billing',
  table: 'gcp_billing_export_v1_X',
  currency: 'SGD',
  month: '2026-11',
  previousMonth: '2026-10',
  total: 4.25,
  cost: 4.75,
  credits: -.5,
  previousTotal: 8.5,
  projects: const [
    BillingProject(id: 'cortado-ide', name: 'cortado-ide', net: 3, cost: 3, previous: 2),
    BillingProject(id: 'vral-altos', name: 'Vral Altos', net: 1.25, cost: 1.75, credits: -.5, previous: 6.5),
  ],
  services: const [
    BillingService(name: 'Cloud Run', net: 3.5, previous: 7, projects: {'cortado-ide': 3, 'vral-altos': .5}),
    BillingService(name: 'Cloud Storage', net: .75, previous: 1.5, projects: {'vral-altos': .75}),
  ],
  skus: const [
    BillingSku(service: 'Cloud Run', sku: 'Memory allocation time', project: 'cortado-ide', net: 3),
    BillingSku(service: 'Cloud Storage', sku: 'Standard Storage Singapore', project: 'vral-altos', net: .75),
  ],
  days: {
    today: const {'cortado-ide': 1, 'vral-altos': .25, '~account': .05},
    operatorDay(now.subtract(const Duration(days: 1))): const {'cortado-ide': 2},
  },
);

/// Test-mode attachments: uploads complete when [release] is called.
void main() {
  testWidgets('without Firebase configured the app says so', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ConsoleApp()));
    await tester.pump();
    expect(find.text('No Firebase configured'), findsOneWidget);
  });

  testWidgets('overview: live work, usage, cost, hosts and accounts', (tester) async {
    size(tester, const Size(1400, 2600));
    await tester.pumpWidget(host(const OverviewPage(), overridesWith(
      threads: const [ChatThread(id: 't1', agent: 'financier', title: 'November budget', folder: 'area/finance')],
      active: [ChatMessage(id: 'm', threadId: 't1', fromOperator: true, text: 'q', status: MessageStatus.running, claimedBy: 'mac', activity: 'Using Read', createdAt: now)],
      days: [UsageDay(day: today, turns: 7, costUsd: 1.5, outputTokens: 4200, failed: 1)],
      stats: const UsageStats(turns: 9, costUsd: 2, byAgent: {'genie': UsageSlice(turns: 6, costUsd: 1), 'financier': UsageSlice(turns: 3, costUsd: 1)}),
      billing: BillingView(costAmount: 2.5, budgetAmount: 30, currencyCode: 'SGD', month: today.substring(0, 7), updatedAt: now, days: {today: 2.5}),
      mesh: MeshView(
        accounts: const [AccountView(id: 'pers', label: 'pers', fiveHour: UsageView(utilization: .36))],
        sessions: [SessionView(sessionId: 's', agent: 'financier', taskId: 'console-t1', accountId: 'pers', status: 'active', contextTokens: 12000, turns: 4, compactions: 0, costUsd: .4, lastUsedAt: now)],
      ),
    )));
    await tester.pump();
    expect(find.text('Live now'), findsOneWidget);
    expect(find.text('7'), findsOneWidget, reason: 'turns today');
    expect(find.text(r'$1.50'), findsOneWidget, reason: 'chat cost this month');
    expect(find.text(r'S$2.50'), findsNWidgets(2), reason: 'GCP tile and spend panel');
    expect(find.text('Serving'), findsOneWidget);
    expect(find.text('Mac worker'), findsOneWidget);
    expect(find.textContaining('Using Read on the mac'), findsOneWidget);
    expect(find.textContaining('4 turns · 12k context'), findsOneWidget);
    expect(find.textContaining('36%'), findsOneWidget);
    expect(find.text('Genie'), findsOneWidget, reason: 'usage by agent');
    expect(tester.takeException(), isNull);
  });

  testWidgets('overview with no data says so instead of inventing any', (tester) async {
    size(tester, const Size(1400, 2600));
    await tester.pumpWidget(host(const OverviewPage(), overridesWith(hosts: const {})));
    await tester.pump();
    expect(find.textContaining('Waiting for the budget'), findsOneWidget);
    expect(find.textContaining('No report yet'), findsOneWidget);
    expect(find.text('Nothing running. The agents are idle.'), findsOneWidget);
    expect(find.text('No open sessions.'), findsOneWidget);
    expect(find.textContaining('No chat turns'), findsOneWidget);
    expect(find.text('This host has not reported yet.'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('projects: Devstations by project, with directors and controls', (tester) async {
    size(tester, const Size(1400, 1600));
    await tester.pumpWidget(host(const ProjectsPage(), overridesWith(
      devstations: const [
        Devstation(id: 'atlas', project: 'Atlas', state: 'running', desired: 'running', machineType: 'e2-standard-2',
            diskGb: 60, identity: 'va-ds-atlas@vral-altos.iam.gserviceaccount.com'),
        Devstation(id: 'nova', project: 'Nova', state: 'stopped', desired: 'stopped'),
      ],
      requests: const [FactoryRequest(id: 'r', action: 'create', devstationId: 'atlas', status: 'done')],
      hosts: {
        'mac': macStatus(),
        'devstation-atlas': HostStatus(lastSeen: now, claudeVersion: '2.1.318 (Claude Code)', metrics: HostMetricsView(at: now, cores: 2, cpu: .1, memUsed: 1 << 30, memTotal: 8 << 30)),
      },
    )));
    await tester.pump();
    expect(find.text('Running · director serving'), findsOneWidget);
    expect(find.text('Stopped'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Stop'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Start'), findsOneWidget);
    expect(find.byTooltip('Tear down'), findsNWidgets(2));
    expect(find.text('Chat with director'), findsNWidgets(2));
    expect(find.text('Create atlas'), findsOneWidget);
    expect(find.text('2.1.318'), findsOneWidget);
    expect(find.textContaining('e2-standard-2 · 60 GB'), findsOneWidget);
    expect(find.text('va-ds-atlas'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system: approvals, sessions and usage split', (tester) async {
    size(tester, const Size(1400, 3000));
    await tester.pumpWidget(host(const SystemPage(), overridesWith(
      approvals: const [
        Approval(id: 'a', requestedBy: 'director-atlas', action: 'Create Cloud SQL', details: r'S$10/month', status: 'pending'),
        Approval(id: 'b', requestedBy: 'rhog', action: 'Old', details: '', status: 'approved'),
      ],
      stats: const UsageStats(turns: 5, costUsd: .5, durationMs: 10000, byPlacement: {'mac': UsageSlice(turns: 4), 'cloud': UsageSlice(turns: 1)}),
      mesh: MeshView(sessions: [
        SessionView(sessionId: 's', agent: 'genie', taskId: 'genie-1', accountId: 'mac', status: 'active', contextTokens: 900, turns: 2, compactions: 0, lastUsedAt: now),
      ]),
    )));
    await tester.pump();
    expect(find.text('Director · atlas: Create Cloud SQL'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Approve'), findsNothing, reason: 'no repository in this test, so no actions');
    expect(find.text('genie-1'), findsOneWidget);
    expect(find.text('By host'), findsOneWidget);
    expect(find.text('Avg. turn'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  {
    testWidgets('every page fits a phone', (tester) async {
      size(tester, const Size(390, 844));
      final o = overridesWith(
        threads: const [ChatThread(id: 't1', agent: 'genie', title: 'A rather long conversation title that must ellipsize', folder: 'area/genie')],
        devstations: const [Devstation(id: 'atlas', project: 'Atlas', state: 'running', desired: 'running', machineType: 'e2-standard-2')],
        billing: BillingView(costAmount: 2.5, budgetAmount: 30, currencyCode: 'SGD', updatedAt: now, days: {today: 2.5}),
        breakdown: breakdown(),
        days: [UsageDay(day: today, turns: 3)],
        stats: const UsageStats(turns: 3, byAgent: {'genie': UsageSlice(turns: 3)}, byPlacement: {'mac': UsageSlice(turns: 3)}),
        mesh: MeshView(sessions: [
          SessionView(sessionId: 's', agent: 'genie', taskId: 'console-t1', accountId: 'mac', status: 'active', contextTokens: 900, turns: 2, compactions: 0, lastUsedAt: now),
        ]),
      );
      for (final page in [const OverviewPage(), const ProjectsPage(), const BillingPage(), const SystemPage(), const LogsPage()]) {
        await tester.pumpWidget(host(page, o));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '${page.runtimeType}');
      }
    });
  }

  testWidgets('billing: totals, pace, projects narrow services and SKUs', (tester) async {
    size(tester, const Size(1400, 2200));
    await tester.pumpWidget(host(const BillingPage(), overridesWith(breakdown: breakdown())));
    await tester.pump();
    expect(find.text(r'S$4.25'), findsOneWidget, reason: 'this month, net');
    expect(find.textContaining(r'S$4.75 before S$0.50 credits'), findsOneWidget);
    expect(find.text(r'S$8.50'), findsOneWidget, reason: 'last month');
    expect(find.textContaining('this month so far is 50% of it'), findsOneWidget);
    expect(find.text('Daily cost'), findsOneWidget);
    expect(find.text('Memory allocation time'), findsOneWidget);
    expect(find.text('Standard Storage Singapore'), findsOneWidget);
    expect(find.textContaining('Exported by Google 2 h ago'), findsOneWidget);

    // Narrow to Vral Altos: its services and SKUs only.
    await tester.tap(find.bySemanticsLabel(RegExp('^Project Vral Altos:')));
    await tester.pumpAndSettle();
    expect(find.text('Memory allocation time'), findsNothing);
    expect(find.text('Standard Storage Singapore'), findsOneWidget);
    expect(find.text(r'S$0.50'), findsWidgets, reason: 'Cloud Run in Vral Altos');
    expect(find.textContaining('Showing Vral Altos below'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(RegExp('^Project Vral Altos:')));
    await tester.pumpAndSettle();
    expect(find.text('Memory allocation time'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('billing without the export says how to switch it on, and shows the budget', (tester) async {
    size(tester, const Size(1200, 1400));
    await tester.pumpWidget(host(const BillingPage(), overridesWith(
      breakdown: BillingBreakdown(status: 'no-export', at: now, dataset: 'vral-altos.va_billing'),
      billing: BillingView(costAmount: 2.5, currencyCode: 'SGD', updatedAt: now),
    )));
    await tester.pump();
    await tester.pump();
    expect(find.text('Switch on the billing export'), findsOneWidget);
    expect(find.textContaining('dataset va_billing'), findsOneWidget);
    expect(find.text(r'S$2.50'), findsOneWidget);
    expect(find.text('Daily cost'), findsNothing, reason: 'no numbers are invented');

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(host(const BillingPage(), overridesWith(breakdown: BillingBreakdown(status: 'empty', at: now, table: 'gcp_billing_export_v1_X'))));
    await tester.pump();
    expect(find.text('Waiting for the first export'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(host(const BillingPage(), overridesWith()));
    await tester.pump();
    expect(find.text('Switch on the billing export'), findsOneWidget, reason: 'nothing recorded yet');
  });

  testWidgets('before data arrives the overview says loading, not zero or "never seen"', (tester) async {
    size(tester, const Size(1400, 2600));
    Stream<T> never<T>() => StreamController<T>().stream;
    await tester.pumpWidget(host(const OverviewPage(), [
      threadsProvider.overrideWith((ref) => never()),
      activeMessagesProvider.overrideWith((ref) => never()),
      allStatusProvider.overrideWith((ref) => never()),
      macStatusProvider.overrideWith((ref) => never()),
      meshProvider.overrideWith((ref) => never()),
      usageStatsProvider.overrideWith((ref) => never()),
      usageDaysProvider.overrideWith((ref) => never()),
      billingProvider.overrideWith((ref) => never()),
      devstationsProvider.overrideWith((ref) => never()),
      factoryRequestsProvider.overrideWith((ref) => never()),
      approvalsProvider.overrideWith((ref) => never()),
      clockProvider.overrideWith((ref) => const Stream.empty()),
      authStateProvider.overrideWith((ref) => Stream.value(null)),
    ]));
    await tester.pump();
    expect(find.text('Loading…'), findsNWidgets(4));
    expect(find.text('0'), findsNothing);
    expect(find.text('Never seen'), findsNothing);
    expect(find.textContaining('Agents in the cloud'), findsNothing);
    expect(find.textContaining('Waiting for the budget'), findsNothing);
  });

  testWidgets('logs explorer lists entries, expands one, and filters by search', (tester) async {
    size(tester, const Size(1400, 1400));
    final logs = [
      LogEntry(id: '1', at: now, source: 'mac-worker', component: 'mailbox', severity: LogSeverity.info,
          message: 'Turn done with genie in 4.2 s', host: 'air', fields: const {'threadId': 't1', 'costUsd': 0.05}),
      LogEntry(id: '2', at: now, source: 'cloud-runner', component: 'factory', severity: LogSeverity.error, message: 'Factory build b1 FAILURE'),
    ];
    final hour = DateTime.utc(now.toUtc().year, now.toUtc().month, now.toUtc().day, now.toUtc().hour);
    final metrics = [MetricHour(source: 'mac-worker', hour: hour, minutes: {now.toUtc().minute: const {'log_info': 1, 'log_error': 1}})];
    await tester.pumpWidget(host(const LogsPage(), overridesWith(logs: logs, metrics: metrics)));
    await tester.pump();
    expect(find.text('Turn done with genie in 4.2 s'), findsOneWidget);
    expect(find.text('Factory build b1 FAILURE'), findsOneWidget);
    expect(find.textContaining('2 entries'), findsOneWidget);
    await tester.tap(find.text('Turn done with genie in 4.2 s'));
    await tester.pump();
    expect(find.text('Copy JSON'), findsOneWidget);
    expect(find.text('Open conversation'), findsOneWidget);
    expect(find.text('0.05'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'factory');
    await tester.pump();
    expect(find.text('Turn done with genie in 4.2 s'), findsNothing);
    expect(find.textContaining('1 entry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('monitoring charts the metric hours; activity shows the trail', (tester) async {
    size(tester, const Size(1400, 2400));
    final u = now.toUtc();
    final hour = DateTime.utc(u.year, u.month, u.day, u.hour);
    final metrics = [
      MetricHour(source: 'mac-worker', hour: hour, minutes: {u.minute: const {'turns': 4, 'turn_ms': 8000, 'turns_failed': 1, 'cpu': .3, 'mem': .6, 'cost_usd': .2, 'log_error': 1}}),
      MetricHour(source: 'cloud-runner', hour: hour, minutes: {u.minute: const {'http_requests': 3, 'cpu': .05}}),
    ];
    final logs = [
      LogEntry(id: 'a', at: now, source: 'console', component: 'audit', severity: LogSeverity.info, message: 'Sent a message', fields: const {'threadId': 't1'}),
      LogEntry(id: 'b', at: now, source: 'mac-worker', component: 'lifecycle', severity: LogSeverity.info, message: 'Worker started'),
    ];
    await tester.pumpWidget(host(const LogsPage(), overridesWith(logs: logs, metrics: metrics)));
    await tester.pump();
    await tester.tap(find.text('Monitoring'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Chat turns'), findsWidgets);
    expect(find.text('4'), findsOneWidget, reason: 'turns in range');
    expect(find.text('2s'), findsOneWidget, reason: 'average turn');
    expect(find.text('3'), findsOneWidget, reason: 'runner wake-ups');
    expect(find.text('CPU by host'), findsOneWidget);
    await tester.tap(find.text('Activity'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(find.text('Sent a message'), findsOneWidget);
    expect(find.text('Worker started'), findsOneWidget);
    expect(find.textContaining('You, in the Console'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

}

