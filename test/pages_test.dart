import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:va_console/data/models.dart';
import 'package:va_console/data/providers.dart';
import 'package:va_console/ui/app.dart';
import 'package:va_console/ui/chat_page.dart';
import 'package:va_console/ui/factory_page.dart';
import 'package:va_console/ui/maintenance_page.dart';

Widget host(Widget child, List overrides) => ProviderScope(
  overrides: [...overrides],
  child: MaterialApp(home: Scaffold(body: child)),
);

void main() {
  testWidgets('without Firebase configured the app says so', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ConsoleApp()));
    await tester.pump();
    expect(find.text('No Firebase configured'), findsOneWidget);
  });

  testWidgets('maintenance shows hosts, the empty account pool and syncs', (tester) async {
    final now = DateTime.now();
    await tester.pumpWidget(host(const MaintenancePage(), [
      macStatusProvider.overrideWith((ref) => Stream.value(HostStatus(lastSeen: now, host: 'air'))),
      cloudStatusProvider.overrideWith((ref) => Stream.value(null)),
      meshProvider.overrideWith((ref) => Stream.value(const MeshView())),
      portfolioSyncProvider.overrideWith(
          (ref) => Stream.value(PortfolioSync(syncedAt: now, source: 'statement'))),
    ]));
    await tester.pump();
    expect(find.textContaining('Serving · air'), findsOneWidget);
    expect(find.textContaining('Has not started yet'), findsOneWidget);
    expect(find.textContaining('No account registered'), findsOneWidget);
    expect(find.textContaining('statement · synced just now'), findsOneWidget);
  });

  testWidgets('factory says when there are no Devstations', (tester) async {
    await tester.pumpWidget(host(const FactoryPage(), [
      devstationsProvider.overrideWith((ref) => Stream.value(const <Devstation>[])),
    ]));
    await tester.pump();
    expect(find.textContaining('No Devstations'), findsOneWidget);
  });

  testWidgets('a thread shows replies, progress and failures', (tester) async {
    await tester.pumpWidget(host(const ThreadView(threadId: 't1'), [
      threadsProvider.overrideWith((ref) => Stream.value(const [
            ChatThread(id: 't1', agent: 'financier', title: 'Budget'),
          ])),
      messagesProvider('t1').overrideWith((ref) => Stream.value(const [
            ChatMessage(id: '1', threadId: 't1', fromOperator: true, text: 'q1', status: MessageStatus.done),
            ChatMessage(id: '2', threadId: 't1', fromOperator: false, text: 'a1', placement: 'mac', accountId: 'default'),
            ChatMessage(id: '3', threadId: 't1', fromOperator: true, text: 'q2', status: MessageStatus.running, claimedBy: 'cloud'),
            ChatMessage(id: '4', threadId: 't1', fromOperator: true, text: 'q3', status: MessageStatus.failed, error: 'No Claude account'),
          ])),
    ]));
    await tester.pump();
    expect(find.text('a1'), findsOneWidget);
    expect(find.textContaining('Answered on the mac'), findsOneWidget);
    expect(find.text('Answering on the cloud…'), findsOneWidget);
    expect(find.text('Failed: No Claude account'), findsOneWidget);
    // Closing waits while a message is in flight.
    final close = tester.widget<TextButton>(find.widgetWithText(TextButton, 'Close'));
    expect(close.onPressed, isNull);
  });
}
