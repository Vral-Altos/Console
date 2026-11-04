import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:va_console/data/models.dart';
import 'package:va_console/data/providers.dart';
import 'package:va_console/ui/app.dart';
import 'package:va_console/ui/chat/chat_page.dart';
import 'package:va_console/ui/chat/thread_sidebar.dart';
import 'package:va_console/ui/overview_page.dart';
import 'package:va_console/ui/projects_page.dart';
import 'package:va_console/ui/system_page.dart';
import 'package:va_console/ui/theme.dart';

Widget host(Widget child, List overrides, {ThemeMode mode = ThemeMode.light}) => ProviderScope(
  overrides: [...overrides],
  child: MaterialApp(
    theme: consoleTheme(Brightness.light, fonts: false),
    darkTheme: consoleTheme(Brightness.dark, fonts: false),
    themeMode: mode,
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
  List<Devstation> devstations = const [],
  List<FactoryRequest> requests = const [],
  List<Approval> approvals = const [],
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
    devstationsProvider.overrideWith((ref) => Stream.value(devstations)),
    factoryRequestsProvider.overrideWith((ref) => Stream.value(requests)),
    approvalsProvider.overrideWith((ref) => Stream.value(approvals)),
    portfolioSyncProvider.overrideWith((ref) => Stream.value(PortfolioSync(syncedAt: now, source: 'statement'))),
    clockProvider.overrideWith((ref) => const Stream.empty()),
    authStateProvider.overrideWith((ref) => Stream.value(null)),
  ];
}

void main() {
  testWidgets('without Firebase configured the app says so', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ConsoleApp(fonts: false)));
    await tester.pump();
    expect(find.text('No Firebase configured'), findsOneWidget);
  });

  testWidgets('overview: live work, usage, cost, hosts and accounts', (tester) async {
    size(tester, const Size(1400, 2600));
    await tester.pumpWidget(host(const OverviewPage(), overridesWith(
      threads: const [ChatThread(id: 't1', agent: 'financier', title: 'November budget')],
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

  testWidgets('a conversation shows replies, live progress, failures and stops', (tester) async {
    size(tester, const Size(1300, 1800));
    final messages = [
      ChatMessage(id: '1', threadId: 't1', fromOperator: true, text: 'q1', status: MessageStatus.done, createdAt: now),
      ChatMessage(
        id: '2', threadId: 't1', fromOperator: false, text: '**a1** with `code`', placement: 'mac', accountId: 'pers',
        costUsd: .05, outputTokens: 1200, durationMs: 4200, model: 'claude-opus-5-5', tools: const ['Read', 'Read'], createdAt: now,
      ),
      ChatMessage(id: '3', threadId: 't1', fromOperator: true, text: 'q2', status: MessageStatus.failed, error: 'No Claude account', createdAt: now),
      ChatMessage(id: '4', threadId: 't1', fromOperator: true, text: 'q3', status: MessageStatus.cancelled, createdAt: now),
      ChatMessage(id: '5', threadId: 't1', fromOperator: false, text: 'partial essay', stopped: true, createdAt: now),
      ChatMessage(
        id: '6', threadId: 't1', fromOperator: true, text: 'q4', status: MessageStatus.running, claimedBy: 'cloud',
        claimedAt: now, partial: 'Writing now', activity: 'Using consult (va-mesh)', createdAt: now,
      ),
    ];
    await tester.pumpWidget(host(const ConversationView(threadId: 't1'), [
      ...overridesWith(threads: const [ChatThread(id: 't1', agent: 'financier', title: 'Budget')]),
      messagesProvider('t1').overrideWith((ref) => Stream.value(messages)),
    ]));
    await tester.pump();
    expect(find.textContaining('a1'), findsWidgets);
    expect(find.textContaining('Mac · pers · Opus 5.5 · 1.2k tokens · \$0.05 · 4s'), findsOneWidget);
    expect(find.text('Read ×2'), findsOneWidget);
    expect(find.text('This turn failed'), findsOneWidget);
    expect(find.text('No Claude account'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
    expect(find.text('Stopped'), findsOneWidget);
    expect(find.textContaining('Using consult (va-mesh)'), findsOneWidget);
    expect(find.textContaining('Writing now'), findsOneWidget);
    expect(find.byTooltip('Stop'), findsOneWidget, reason: 'the composer stops the running turn');
    expect(find.text('Budget'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a closed conversation offers a new chat instead of a composer', (tester) async {
    size(tester, const Size(1300, 1000));
    await tester.pumpWidget(host(const ConversationView(threadId: 't1'), [
      ...overridesWith(threads: const [ChatThread(id: 't1', agent: 'roman', title: 'Deal', closed: true)]),
      messagesProvider('t1').overrideWith((ref) => Stream.value([
            ChatMessage(id: '1', threadId: 't1', fromOperator: true, text: 'Close this conversation.', kind: 'close', status: MessageStatus.done, createdAt: now),
          ])),
    ]));
    await tester.pump();
    expect(find.text('This conversation is closed.'), findsOneWidget);
    expect(find.text('New chat with Roman'), findsOneWidget);
    expect(find.textContaining('journal entry'), findsOneWidget);
    expect(find.byTooltip('Send'), findsNothing);
  });

  testWidgets('a new chat lists the agents the hosts run, with descriptions', (tester) async {
    size(tester, const Size(1300, 1000));
    await tester.pumpWidget(host(const NewChatView(), overridesWith()));
    await tester.pump();
    expect(find.text('Who do you want to talk to?'), findsOneWidget);
    expect(find.text('Finance and trading'), findsOneWidget);
    expect(find.text('Your personal assistant'), findsOneWidget);
    expect(find.text('On the Mac'), findsNWidgets(2));
    expect(find.byTooltip('Send'), findsOneWidget);
  });

  test('conversations group by pinned, then by age', () {
    final n = DateTime(2026, 11, 4, 12);
    final groups = ThreadSidebarGroups.of([
      ChatThread(id: 'p', agent: 'g', title: 'p', pinned: true, updatedAt: DateTime(2026, 1, 1)),
      ChatThread(id: 'a', agent: 'g', title: 'a', updatedAt: n),
      ChatThread(id: 'b', agent: 'g', title: 'b', updatedAt: n.subtract(const Duration(days: 1))),
      ChatThread(id: 'c', agent: 'g', title: 'c', updatedAt: n.subtract(const Duration(days: 3))),
      ChatThread(id: 'd', agent: 'g', title: 'd', updatedAt: n.subtract(const Duration(days: 90))),
    ], n);
    expect([for (final (k, l) in groups) '$k:${l.map((t) => t.id).join()}'],
        ['Pinned:p', 'Today:a', 'Yesterday:b', 'Previous 7 days:c', 'Older:d']);
  });

  testWidgets('projects: Devstations by project, with directors and controls', (tester) async {
    size(tester, const Size(1400, 1600));
    await tester.pumpWidget(host(const ProjectsPage(), overridesWith(
      devstations: const [
        Devstation(id: 'atlas', project: 'Atlas', state: 'running', desired: 'running', machineType: 'e2-standard-2'),
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

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('every page fits a phone ($mode)', (tester) async {
      size(tester, const Size(390, 844));
      final o = overridesWith(
        threads: const [ChatThread(id: 't1', agent: 'genie', title: 'A rather long conversation title that must ellipsize')],
        devstations: const [Devstation(id: 'atlas', project: 'Atlas', state: 'running', desired: 'running', machineType: 'e2-standard-2')],
        billing: BillingView(costAmount: 2.5, budgetAmount: 30, currencyCode: 'SGD', updatedAt: now, days: {today: 2.5}),
        days: [UsageDay(day: today, turns: 3)],
        stats: const UsageStats(turns: 3, byAgent: {'genie': UsageSlice(turns: 3)}, byPlacement: {'mac': UsageSlice(turns: 3)}),
        mesh: MeshView(sessions: [
          SessionView(sessionId: 's', agent: 'genie', taskId: 'console-t1', accountId: 'mac', status: 'active', contextTokens: 900, turns: 2, compactions: 0, lastUsedAt: now),
        ]),
      );
      for (final page in [const OverviewPage(), const ProjectsPage(), const SystemPage(), const ChatPage()]) {
        await tester.pumpWidget(host(page, [
          ...o,
          messagesProvider('t1').overrideWith((ref) => Stream.value([
                ChatMessage(id: '1', threadId: 't1', fromOperator: true, text: 'hello', status: MessageStatus.done, createdAt: now),
                ChatMessage(id: '2', threadId: 't1', fromOperator: false, text: '| a | b |\n|---|---|\n| 1 | 2 |\n\n```dart\nfinal x = 1;\n```', createdAt: now),
              ])),
        ], mode: mode));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '${page.runtimeType}');
      }
    });
  }

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
}
