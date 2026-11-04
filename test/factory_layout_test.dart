import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:va_console/data/models.dart';
import 'package:va_console/data/providers.dart';
import 'package:va_console/ui/factory_page.dart';

void main() {
  testWidgets('Devstation controls are laid out on screen', (tester) async {
    tester.view.physicalSize = const Size(1440, 813);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        devstationsProvider.overrideWith((ref) => Stream.value(const [
              Devstation(id: 'probe', project: 'Vral Probe', state: 'running', desired: 'running',
                  machineType: 'e2-standard-2', repoUrl: 'https://github.com/octocat/Hello-World.git'),
            ])),
        factoryRequestsProvider.overrideWith((ref) => Stream.value(const [
              FactoryRequest(id: 'r', action: 'start', devstationId: 'probe', status: 'done'),
            ])),
        allStatusProvider.overrideWith((ref) => Stream.value({
              'devstation-probe': HostStatus(lastSeen: DateTime.now(), claudeVersion: '2.1.318 (Claude Code)'),
            })),
        clockProvider.overrideWith((ref) => const Stream.empty()),
      ],
      child: const MaterialApp(home: Scaffold(body: FactoryPage())),
    ));
    await tester.pump();
    for (final t in ['Stop', 'Tear down']) {
      final r = tester.getRect(find.byTooltip(t));
      expect(r.width, greaterThan(20), reason: t);
      expect(r.right, lessThanOrEqualTo(1440), reason: t);
    }
    expect(tester.takeException(), isNull);
  });
}
