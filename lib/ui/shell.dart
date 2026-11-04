import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import 'chat_page.dart';
import 'factory_page.dart';
import 'maintenance_page.dart';
import 'widgets.dart';

/// The Console's three pages: Chat, Factory, Maintenance.
class Shell extends ConsumerStatefulWidget {
  const Shell({super.key});

  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> {
  int _page = 0;

  static const _destinations = [
    (Icons.forum_outlined, Icons.forum, 'Chat'),
    (Icons.precision_manufacturing_outlined, Icons.precision_manufacturing, 'Factory'),
    (Icons.tune_outlined, Icons.tune, 'Maintenance'),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final page = switch (_page) {
      0 => const ChatPage(),
      1 => const FactoryPage(),
      _ => const MaintenancePage(),
    };
    final user = ref.watch(authStateProvider).value;
    return Scaffold(
      appBar: AppBar(
        title: Text(_destinations[_page].$3),
        actions: [
          const PlacementChip(),
          IconButton(
            tooltip: 'Sign out ${user?.email ?? ''}',
            onPressed: () => ref.read(firebaseAuthProvider)?.signOut(),
            icon: const Icon(Icons.logout),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: wide
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: _page,
                  onDestinationSelected: (i) => setState(() => _page = i),
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (final (icon, selected, label) in _destinations)
                      NavigationRailDestination(
                        icon: Icon(icon),
                        selectedIcon: Icon(selected),
                        label: Text(label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: page),
              ],
            )
          : page,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _page,
              onDestinationSelected: (i) => setState(() => _page = i),
              destinations: [
                for (final (icon, selected, label) in _destinations)
                  NavigationDestination(icon: Icon(icon), selectedIcon: Icon(selected), label: label),
              ],
            ),
    );
  }
}
