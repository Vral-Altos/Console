import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:va_console/data/attachments.dart';
import 'package:va_console/data/models.dart';
import 'package:va_console/data/providers.dart';
import 'package:va_console/ui/app.dart';
import 'package:va_console/ui/billing_page.dart';
import 'package:va_console/ui/chat/chat_page.dart';
import 'package:va_console/ui/chat/code_highlight.dart';
import 'package:va_console/ui/chat/composer.dart';
import 'package:va_console/ui/chat/markdown_view.dart';
import 'package:va_console/ui/chat/message_tiles.dart';
import 'package:va_console/ui/chat/thread_sidebar.dart';
import 'package:va_console/ui/logs_page.dart';
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
class MemoryStore implements AttachmentStore {
  final uploads = <String, Uint8List>{};
  final discarded = <String>[];
  Completer<void> gate = Completer<void>()..complete();
  var _n = 0;

  @override
  Future<AttachmentRef> upload(PickedFile file, {void Function(double progress)? onProgress}) async {
    onProgress?.call(.5);
    await gate.future;
    final path = 'attachments/upload${_n++}/${file.name}';
    uploads[path] = file.bytes;
    return AttachmentRef(path: path, name: file.name, contentType: contentTypeFor(file.name, file.contentType), size: file.size);
  }

  @override
  Future<Uint8List?> read(AttachmentRef ref) async => uploads[ref.path];

  @override
  Future<void> discard(AttachmentRef ref) async => discarded.add(ref.path);
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
    // Tools fold to one line and open to the list.
    expect(find.text('Used Read ×2 · 4s'), findsOneWidget);
    expect(find.text('Read ×2'), findsNothing);
    await tester.tap(find.text('Used Read ×2 · 4s'));
    await tester.pump(const Duration(milliseconds: 300));
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

  testWidgets('keys: Esc stops the running turn, ↑ in an empty box edits the last message', (tester) async {
    size(tester, const Size(1300, 1200));
    final stopped = <String>[];
    final messages = [
      ChatMessage(id: '1', threadId: 't1', fromOperator: true, text: 'first question', status: MessageStatus.done, createdAt: now),
      ChatMessage(id: '2', threadId: 't1', fromOperator: false, text: 'answer', createdAt: now),
      ChatMessage(id: '3', threadId: 't1', fromOperator: true, text: 'second question', status: MessageStatus.running, claimedAt: now, createdAt: now),
    ];
    final c = GlobalKey<ComposerState>();
    await tester.pumpWidget(host(
      Column(children: [
        Expanded(
          child: Composer(
            key: c,
            draftKey: 'k',
            hint: 'h',
            onSend: (_, _, _) async {},
            onStop: () => stopped.add('stop'),
            onEditLast: () => c.currentState!.restore(messages[2].text),
            autofocus: true,
          ),
        ),
      ]),
      overridesWith(),
    ));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(stopped, ['stop']);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(find.text('second question'), findsOneWidget, reason: 'the last message is back in the box');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(find.text('second question'), findsOneWidget, reason: '↑ only edits from an empty box');
  });

  testWidgets('a conversation loads with a placeholder, then new messages rise in', (tester) async {
    size(tester, const Size(1300, 1200));
    final ctl = StreamController<List<ChatMessage>>();
    await tester.pumpWidget(host(const ConversationView(threadId: 't1'), [
      ...overridesWith(threads: const [ChatThread(id: 't1', agent: 'genie', title: 'Plans')]),
      messagesProvider('t1').overrideWith((ref) => ctl.stream),
    ]));
    await tester.pump();
    expect(find.byType(ConversationSkeleton), findsOneWidget);
    final first = ChatMessage(id: '1', threadId: 't1', fromOperator: true, text: 'hello', status: MessageStatus.running, claimedAt: now, createdAt: now);
    ctl.add([first]);
    await tester.pump();
    expect(find.byType(ConversationSkeleton), findsNothing);
    double opacityOf(String text) => tester
        .widget<FadeTransition>(find.ancestor(of: find.textContaining(text), matching: find.byType(FadeTransition)).first)
        .opacity
        .value;
    expect(opacityOf('hello'), 1, reason: 'what the conversation opened with does not animate');
    // The streamed answer turns into the finished reply in place.
    ctl.add([first.copyWith(partial: 'Hi there')]);
    await tester.pump();
    expect(find.byType(PendingReply), findsOneWidget);
    ctl.add([
      first.copyWith(status: MessageStatus.done),
      ChatMessage(id: '2', threadId: 't1', fromOperator: false, text: 'Hi there', createdAt: now),
    ]);
    await tester.pump();
    expect(find.byType(PendingReply), findsNothing);
    expect(find.byType(AgentReply), findsOneWidget);
    // A question sent later rises in.
    ctl.add([
      first.copyWith(status: MessageStatus.done),
      ChatMessage(id: '2', threadId: 't1', fromOperator: false, text: 'Hi there', createdAt: now),
      ChatMessage(id: '3', threadId: 't1', fromOperator: true, text: 'next one', status: MessageStatus.queued, createdAt: now),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(opacityOf('next one'), lessThan(1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(opacityOf('next one'), 1);
    await ctl.close();
  });

  test('half-written Markdown: an open code fence is closed while it streams', () {
    expect(streamingMarkdown('Here:\n```dart\nvoid main'), 'Here:\n```dart\nvoid main\n```');
    expect(streamingMarkdown('Done.\n```\nx\n```\nMore'), 'Done.\n```\nx\n```\nMore ▍');
  });

  testWidgets('code is coloured for known languages and plain otherwise', (tester) async {
    late TextSpan dart, plain, unknown;
    await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(Brightness.light, fonts: false),
      home: Builder(builder: (context) {
        dart = highlightCode(context, 'final x = "a"; // note', 'dart', const TextStyle());
        plain = highlightCode(context, 'final x', null, const TextStyle());
        unknown = highlightCode(context, 'final x', 'nosuchlang', const TextStyle());
        return const SizedBox();
      }),
    ));
    final colours = <Color>{};
    void walk(InlineSpan s) {
      if (s.style?.color != null) colours.add(s.style!.color!);
      if (s is TextSpan) s.children?.forEach(walk);
    }

    walk(dart);
    expect(dart.toPlainText(), 'final x = "a"; // note');
    expect(colours.length, greaterThanOrEqualTo(3), reason: 'keyword, string and comment differ');
    expect(plain.children, isNull);
    expect(unknown.toPlainText(), 'final x');
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
        breakdown: breakdown(),
        days: [UsageDay(day: today, turns: 3)],
        stats: const UsageStats(turns: 3, byAgent: {'genie': UsageSlice(turns: 3)}, byPlacement: {'mac': UsageSlice(turns: 3)}),
        mesh: MeshView(sessions: [
          SessionView(sessionId: 's', agent: 'genie', taskId: 'console-t1', accountId: 'mac', status: 'active', contextTokens: 900, turns: 2, compactions: 0, lastUsedAt: now),
        ]),
      );
      for (final page in [const OverviewPage(), const ProjectsPage(), const BillingPage(), const SystemPage(), const ChatPage(), const LogsPage()]) {
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

  group('attachments and mentions', () {
    final threads = [
      ChatThread(id: 't1', agent: 'genie', title: 'Current', updatedAt: now),
      ChatThread(id: 't2', agent: 'roman', title: 'Q4 negotiation plan', updatedAt: now),
      const ChatThread(id: 't3', agent: 'genie', title: 'Old stuff', archived: true),
    ];
    const devstations = [Devstation(id: 'sky', project: 'Skyhorse', state: 'running', desired: 'running')];

    Future<({GlobalKey<ComposerState> key, List<(String, List<AttachmentRef>, List<MentionRef>)> sent})> pumpComposer(
      WidgetTester tester,
      MemoryStore store,
    ) async {
      size(tester, const Size(1000, 900));
      final key = GlobalKey<ComposerState>();
      final sent = <(String, List<AttachmentRef>, List<MentionRef>)>[];
      await tester.pumpWidget(host(
        Column(children: [
          const Spacer(),
          Composer(
            key: key,
            draftKey: 't1',
            threadId: 't1',
            hint: 'Reply…',
            onSend: (t, a, m) async => sent.add((t, a, m)),
          ),
        ]),
        [
          ...overridesWith(threads: threads, devstations: devstations),
          attachmentStoreProvider.overrideWithValue(store),
        ],
      ));
      await tester.pump();
      await tester.pump();
      return (key: key, sent: sent);
    }

    testWidgets('files upload at once; send waits for them and carries them', (tester) async {
      final store = MemoryStore()..gate = Completer<void>();
      final c = await pumpComposer(tester, store);
      c.key.currentState!.add([
        PickedFile(name: 'chart.png', bytes: Uint8List.fromList(List.filled(10, 1))),
        PickedFile(name: 'q3.pdf', bytes: Uint8List(2048)),
        PickedFile(name: 'empty.txt', bytes: Uint8List(0)),
      ]);
      await tester.pump();
      expect(find.text('chart.png'), findsOneWidget);
      expect(find.text('2 KB · 50%'), findsOneWidget, reason: 'progress while uploading');
      expect(find.text('empty.txt is empty.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'what do these show?');
      await tester.pump();
      expect(find.byTooltip('Waiting for uploads…'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      expect(c.sent, isEmpty);

      store.gate.complete();
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(c.sent.single.$1, 'what do these show?');
      expect([for (final a in c.sent.single.$2) a.name], ['chart.png', 'q3.pdf']);
      expect(c.sent.single.$2.last.contentType, 'application/pdf');
      expect(find.text('chart.png'), findsNothing, reason: 'cleared once sent');
      expect(store.discarded, isEmpty, reason: 'sent files stay');
    });

    testWidgets('a file can be sent without text, and a removed one is discarded', (tester) async {
      final store = MemoryStore();
      final c = await pumpComposer(tester, store);
      c.key.currentState!.add([
        PickedFile(name: 'a.csv', bytes: Uint8List(5)),
        PickedFile(name: 'b.csv', bytes: Uint8List(5)),
      ]);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byTooltip('Remove b.csv'));
      await tester.pump();
      expect(store.discarded.single, endsWith('b.csv'));
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(c.sent.single.$1, '');
      expect(c.sent.single.$2.single.name, 'a.csv');
    });

    testWidgets('limits: ten files, 25 MB each', (tester) async {
      final store = MemoryStore();
      final c = await pumpComposer(tester, store);
      c.key.currentState!.add([
        PickedFile(name: 'huge.mov', bytes: Uint8List(AttachmentLimits.maxBytes + 1)),
        for (var i = 0; i < 11; i++) PickedFile(name: 'f$i.txt', bytes: Uint8List(1)),
      ]);
      await tester.pump();
      expect(find.textContaining('At most 10 files per message.'), findsOneWidget);
      expect(find.textContaining('huge.mov is over 25 MB.'), findsOneWidget);
      expect(store.uploads.length + 0, lessThanOrEqualTo(10));
    });

    testWidgets('@ suggests conversations, projects and agents; picking one mentions it', (tester) async {
      final c = await pumpComposer(tester, MemoryStore());
      await tester.enterText(find.byType(TextField), 'compare with @');
      await tester.pump();
      expect(find.text('Conversations'), findsOneWidget);
      expect(find.text('Q4 negotiation plan'), findsOneWidget);
      expect(find.text('Current'), findsNothing, reason: 'not the conversation itself');
      expect(find.text('Old stuff'), findsNothing, reason: 'not archived ones');
      expect(find.text('Skyhorse'), findsOneWidget);
      expect(find.text('Genie'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'compare with @neg');
      await tester.pump();
      expect(find.text('Skyhorse'), findsNothing);
      await tester.tap(find.text('Q4 negotiation plan'));
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'compare with @Q4 negotiation plan ');

      // Keyboard: arrows and Enter pick; Escape closes.
      await tester.enterText(find.byType(TextField), '${field.controller!.text}and @sky');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(field.controller!.text, 'compare with @Q4 negotiation plan and @Skyhorse ');
      await tester.enterText(find.byType(TextField), '${field.controller!.text}ask @');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('Agents'), findsNothing);
      await tester.enterText(find.byType(TextField), '${field.controller!.text}x');
      await tester.pump();
      expect(find.text('Agents'), findsNothing, reason: 'dismissed until a new @');
      final typed = field.controller!.text;
      await tester.enterText(find.byType(TextField), typed.substring(0, typed.length - 2));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '${field.controller!.text}@fin');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(c.sent.single.$1, 'compare with @Q4 negotiation plan and @Skyhorse ask @Financier');
      expect(c.sent.single.$3, const [
        MentionRef(kind: MentionKind.thread, id: 't2', label: 'Q4 negotiation plan'),
        MentionRef(kind: MentionKind.project, id: 'sky', label: 'Skyhorse'),
        MentionRef(kind: MentionKind.agent, id: 'financier', label: 'Financier'),
      ]);
    });

    testWidgets('a mention deleted from the text is not sent', (tester) async {
      final c = await pumpComposer(tester, MemoryStore());
      await tester.enterText(find.byType(TextField), '@Sky');
      await tester.pump();
      await tester.tap(find.text('Skyhorse'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'never mind');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(c.sent.single.$3, isEmpty);
    });

    testWidgets('sent messages show their files, images and highlighted mentions; edit restores them', (tester) async {
      size(tester, const Size(1300, 1400));
      final store = MemoryStore();
      store.uploads['attachments/x/shot.png'] = Uint8List.fromList(_png);
      const shot = AttachmentRef(path: 'attachments/x/shot.png', name: 'shot.png', contentType: 'image/png', size: 67);
      const pdf = AttachmentRef(path: 'attachments/y/q3.pdf', name: 'q3.pdf', contentType: 'application/pdf', size: 2048);
      const plan = MentionRef(kind: MentionKind.thread, id: 't2', label: 'Plan');
      final messages = [
        ChatMessage(
          id: '1', threadId: 't1', fromOperator: true, text: 'see @Plan', status: MessageStatus.done, createdAt: now,
          attachments: const [shot, pdf], mentions: const [plan],
        ),
        ChatMessage(id: '2', threadId: 't1', fromOperator: false, text: 'Seen.', createdAt: now),
        ChatMessage(id: '3', threadId: 't1', fromOperator: true, text: '', status: MessageStatus.done, createdAt: now, attachments: const [pdf]),
      ];
      await tester.pumpWidget(host(const ConversationView(threadId: 't1'), [
        ...overridesWith(threads: threads),
        attachmentStoreProvider.overrideWithValue(store),
        messagesProvider('t1').overrideWith((ref) => Stream.value(messages)),
      ]));
      await tester.pump();
      await tester.pump();
      expect(find.bySemanticsLabel('Image shot.png'), findsOneWidget);
      expect(find.text('q3.pdf'), findsNWidgets(2));
      expect(find.text('2 KB'), findsNWidgets(2));
      final rich = tester.widgetList<RichText>(find.byType(RichText)).firstWhere((r) => r.text.toPlainText() == 'see @Plan');
      final spans = <TextSpan>[];
      rich.text.visitChildren((s) {
        if (s is TextSpan && s.text == '@Plan') spans.add(s);
        return true;
      });
      expect(spans.single.style?.fontWeight, FontWeight.w600, reason: 'the mention is highlighted');

      final bubble = find.ancestor(of: find.text('see @Plan', findRichText: true), matching: find.byType(OperatorBubble));
      await tester.tap(find.descendant(of: bubble, matching: find.byTooltip('Edit and resend')));
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'see @Plan');
      expect(find.byTooltip('Remove shot.png'), findsOneWidget, reason: 'files come back too');
      expect(tester.takeException(), isNull);
    });
  });
}

/// A 1×1 PNG.
const _png = [
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84,
  120, 156, 99, 248, 207, 192, 240, 31, 0, 5, 0, 1, 255, 137, 153, 61, 29, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
];
