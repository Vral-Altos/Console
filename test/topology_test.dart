import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:va_console/data/models.dart';
import 'package:va_console/ui/topology/graph.dart';
import 'package:va_console/ui/topology/layout.dart';
import 'package:va_console/ui/topology/topology_page.dart';
import 'package:ui_mesh/ui_mesh.dart';

final now = DateTime.now();

TopologyInventory inventory() => TopologyInventory(
  at: now.subtract(const Duration(minutes: 3)),
  projects: const [
    GcpProjectView(id: 'vral-altos', name: 'vral-altos'),
    GcpProjectView(id: 'cortado-ide', name: 'cortado-ide'),
    GcpProjectView(id: 'luminary-axis-dashboard', name: 'luminary-axis-dashboard', access: 'limited'),
  ],
  resources: const [
    CloudResource(
      id: '//firebasehosting.googleapis.com/projects/vral-altos/sites/va-console',
      project: 'vral-altos',
      type: 'hosting.site',
      name: 'va-console',
      public: true,
      publicRoles: ['web'],
      health: 'ok',
      url: 'https://va-console.web.app',
    ),
    CloudResource(
      id: '//run.googleapis.com/projects/vral-altos/locations/us-central1/services/va-agent-runner',
      project: 'vral-altos',
      type: 'run.service',
      name: 'va-agent-runner',
      health: 'ok',
      labels: {'component': 'agent-mesh'},
    ),
    CloudResource(
      id: '//firestore.googleapis.com/projects/vral-altos/databases/platform',
      project: 'vral-altos',
      type: 'firestore.database',
      name: 'platform',
    ),
    CloudResource(
      id: '//secretmanager.googleapis.com/projects/1/secrets/tucson-credentials',
      project: 'vral-altos',
      type: 'secret',
      name: 'tucson-credentials',
    ),
    CloudResource(
      id: '//run.googleapis.com/projects/cortado-ide/locations/us-central1/services/control-plane',
      project: 'cortado-ide',
      type: 'run.service',
      name: 'control-plane',
      public: true,
      publicRoles: ['roles/run.invoker'],
      health: 'bad',
      detail: 'Image not found',
    ),
  ],
  repos: const [
    RepoView(name: 'Skyhorse', path: 'Vral_Altos/tools/Skyhorse', host: 'github.com', owner: 'Vral-Altos', repo: 'Skyhorse'),
    RepoView(name: 'CortadoBackend', path: 'CortadoBackend', host: 'github.com', owner: 'ObsidianXVI', repo: 'CortadoBackend'),
    RepoView(name: 'Cortado_Server', path: 'Cortado_Server', host: 'github.com', owner: 'Affogato-Project', repo: 'Cortado_Server', dirty: true),
    RepoView(name: 'Hyperion', path: 'Hyperion'),
  ],
);

final hosts = {
  'mac': HostStatus(
    lastSeen: now,
    host: 'Studio.local',
    agents: const ['genie', 'financier'],
    agentInfo: const {'genie': 'Your personal assistant'},
    localServices: const [
      LocalServiceView(label: 'com.vralaltos.worker', running: true),
      LocalServiceView(label: 'com.vralaltos.skyhorse.whatsapp', running: true, connected: true),
      LocalServiceView(label: 'com.vralaltos.skyhorse.telegram', running: false, lastExit: 1),
    ],
  ),
  'cloud': const HostStatus(agents: ['genie']),
};

void main() {
  test('project families join repos and GCP projects by name', () {
    expect(familyKey('CortadoBackend'), 'cortado');
    expect(familyKey('cortado-ide'), 'cortado');
    expect(familyKey('Cortado_Server'), 'cortado');
    expect(familyKey('project-hauberk'), 'hauberk');
    expect(familyKey('Hauberk_Server'), 'hauberk');
    expect(familyKey('MocafeV4'), 'mocafe');
    expect(familyKey('The Hyperion Project'), 'hyperion');
    expect(familyKey('luminary-axis-dashboard'), 'luminary');
  });

  group('the graph', () {
    final g = buildTopology(inventory: inventory(), hosts: hosts, now: now);
    TopoEntity e(String id) => g.entities.firstWhere((x) => x.id == id);
    TopoEntity named(String label) => g.entities.firstWhere((x) => x.label == label);

    test('projects: Vral Altos gathers its repos, cloud and Mac; Cortado gathers across owners', () {
      expect(named('Skyhorse').project, 'va');
      expect(named('va-console').project, 'va');
      expect(e('mac').project, 'va');
      expect(named('control-plane').project, 'cortado');
      expect(named('CortadoBackend').project, 'cortado');
      expect(named('Cortado_Server').project, 'cortado');
      expect(named('Hyperion').project, 'hyperion');
    });

    test('owners: GitHub owners, local-only code, Vral Altos, third parties', () {
      expect(named('Cortado_Server').owner, 'Affogato-Project');
      expect(named('CortadoBackend').owner, 'ObsidianXVI');
      expect(named('Hyperion').ownerName, 'You · local only');
      expect(named('va-agent-runner').owner, 'Vral-Altos');
      expect(e('ext:anthropic').owner, 'third-party');
    });

    test('boundaries and health come from the sources', () {
      expect(named('va-console').boundary, Boundary.public);
      expect(named('control-plane').boundary, Boundary.public);
      expect(named('control-plane').health, Health.bad);
      expect(named('va-agent-runner').boundary, Boundary.cloud);
      expect(named('platform').health, Health.unknown, reason: 'no signal is not invented');
      expect(e('mac').physical, isTrue);
      expect(e('mac').health, Health.ok);
      expect(named('Skyhorse · Telegram').health, Health.bad);
      expect(named('Skyhorse · Whatsapp').health, Health.ok);
      expect(e('agent:genie').boundary, Boundary.counsel);
    });

    test('physical devices and third parties appear only with evidence', () {
      expect(e('phone').physical, isTrue, reason: 'WhatsApp is linked');
      expect(e('ext:notion').label, 'Notion', reason: 'TUCSON credentials exist');
      expect(e('ext:calendar').label, 'Google Calendar');
      expect(g.entities.any((x) => x.id == 'ext:gmail'), isFalse, reason: 'no Skyhorse credentials in this inventory');
      expect(e('ext:github').facts.single.$2, 'Affogato-Project, ObsidianXVI, Vral-Altos');
    });

    test('filters: public surface, the Counsel, code', () {
      Set<String> f(TopoFilter x) => {for (final y in g.entities) if (y.filters.contains(x)) y.label};
      expect(f(TopoFilter.public), {'va-console', 'control-plane'});
      expect(f(TopoFilter.counsel), containsAll(['Genie', 'Financier', 'Anthropic', 'va-agent-runner']));
      expect(f(TopoFilter.repos), containsAll(['Skyhorse', 'CortadoBackend', 'Hyperion', 'GitHub']));
      expect(f(TopoFilter.vaCore), isNot(contains('control-plane')));
    });

    test('links: Mac to the mailbox, hosts to agents, bridges to networks', () {
      bool linked(String a, String b) => g.links.any((l) => l.from == a && l.to == b);
      expect(linked('mac', '//firestore.googleapis.com/projects/vral-altos/databases/platform'), isTrue);
      expect(linked('mac', 'agent:genie'), isTrue);
      expect(linked('//run.googleapis.com/projects/vral-altos/locations/us-central1/services/va-agent-runner', 'agent:genie'), isTrue);
      expect(linked('local:com.vralaltos.skyhorse.whatsapp', 'ext:whatsapp'), isTrue);
    });
  });

  test('without any source the map is empty, not invented', () {
    final g = buildTopology(now: now);
    expect(g.entities, isEmpty);
    final macOnly = buildTopology(hosts: {'mac': HostStatus(lastSeen: now)}, now: now);
    expect([for (final e in macOnly.entities) e.id], ['mac']);
  });

  test('layout: every entity placed inside its fence, districts apart, for each grouping', () {
    final g = buildTopology(inventory: inventory(), hosts: hosts, now: now);
    for (final by in GroupBy.values) {
      final l = layoutTopology(g.entities, by);
      expect(l.positions.keys.toSet(), {for (final e in g.entities) e.id});
      final districts = l.zones.where((z) => z.outer).toList();
      for (var i = 0; i < districts.length; i++) {
        for (var j = i + 1; j < districts.length; j++) {
          expect(districts[i].rect.overlaps(districts[j].rect), isFalse, reason: '${by.name}: ${districts[i].key} / ${districts[j].key}');
        }
      }
      for (final e in g.entities) {
        final fence = l.zones.where((z) => !z.outer && z.rect.contains(l.positions[e.id]!));
        expect(fence, isNotEmpty, reason: '${e.label} is inside a fence');
      }
    }
  });

  Widget host(Widget child) => MaterialApp(
    theme: vaTheme(),
    home: Scaffold(body: child),
  );

  testWidgets('the map: stats, grouping, filters and the readout on hover', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final g = buildTopology(inventory: inventory(), hosts: hosts, now: now);
    await tester.pumpWidget(host(TopologyView(graph: g)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('TOPOLOGY'), findsOneWidget);
    expect(find.textContaining('Collected 3 min ago'), findsOneWidget);
    expect(find.text('${g.entities.length}'), findsWidgets, reason: 'entity count');

    // Filter to the public surface: only those two remain to hover.
    await tester.tap(find.bySemanticsLabel('Show Public surface'));
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.bySemanticsLabel('Group by Owner'));
    await tester.pump(const Duration(seconds: 2));

    // Sweep the pointer over the map until a readout opens.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    var found = false;
    for (var y = 200.0; y < 820 && !found; y += 8) {
      for (var x = 300.0; x < 1100 && !found; x += 8) {
        await mouse.moveTo(Offset(x, y));
        await tester.pump();
        found = find.text('SECURITY').evaluate().isNotEmpty;
      }
    }
    expect(found, isTrue, reason: 'hovering an entity shows its readout');
    expect(find.text('SECURITY'), findsOneWidget);
    expect(find.text('Exposed to the internet'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('no inventory yet: says so, still shows live hosts', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final g = buildTopology(hosts: hosts, now: now);
    await tester.pumpWidget(host(TopologyView(graph: g, inventoryMissing: true)));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('has not been collected yet'), findsOneWidget);
    final empty = buildTopology(now: now);
    await tester.pumpWidget(host(TopologyView(graph: empty, inventoryMissing: true)));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('No topology yet'), findsOneWidget);
  });
}
