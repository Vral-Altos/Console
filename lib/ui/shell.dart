import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/providers.dart';
import 'billing_page.dart';
import 'chat/chat_page.dart';
import 'logs_page.dart';
import 'overview_page.dart';
import 'projects_page.dart';
import 'system_page.dart';
import 'theme.dart';
import 'topology/topology_page.dart';
import 'widgets.dart';

typedef _Dest = ({ConsolePage page, IconData icon, IconData selected, String label});

const _destinations = <_Dest>[
  (page: ConsolePage.overview, icon: Icons.space_dashboard_outlined, selected: Icons.space_dashboard, label: 'Overview'),
  (page: ConsolePage.chat, icon: Icons.forum_outlined, selected: Icons.forum, label: 'Chat'),
  (page: ConsolePage.projects, icon: Icons.folder_outlined, selected: Icons.folder, label: 'Projects'),
  (page: ConsolePage.topology, icon: Icons.hub_outlined, selected: Icons.hub, label: 'Topology'),
  (page: ConsolePage.billing, icon: Icons.payments_outlined, selected: Icons.payments, label: 'Billing'),
  (page: ConsolePage.logs, icon: Icons.receipt_long_outlined, selected: Icons.receipt_long, label: 'Logs'),
  (page: ConsolePage.system, icon: Icons.tune_outlined, selected: Icons.tune, label: 'System'),
];

/// The Console's frame: a sidebar on wide screens, a bottom bar on phones.
/// Ctrl/⌘+K starts a new chat; Ctrl/⌘+1…7 switch pages.
class Shell extends ConsumerWidget {
  const Shell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(pageProvider);
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 900;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final active = ref.watch(activeMessagesProvider).value ?? const <ChatMessage>[];
    final approvals = (ref.watch(approvalsProvider).value ?? const <Approval>[]).where((a) => a.status == 'pending').length;
    final badges = {
      ConsolePage.chat: active.isEmpty ? null : '${active.length}',
      ConsolePage.system: approvals == 0 ? null : '$approvals',
    };

    void go(ConsolePage p) => ref.read(pageProvider.notifier).go(p);
    final body = IndexedStack(
      index: page.index,
      children: const [OverviewPage(), ChatPage(), ProjectsPage(), TopologyPage(), BillingPage(), LogsPage(), SystemPage()],
    );

    return CallbackShortcuts(
      bindings: {
        for (final (i, d) in _destinations.indexed) ...{
          SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i), control: true): () => go(d.page),
          SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i), meta: true): () => go(d.page),
        },
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () => openChat(ref),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () => openChat(ref),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: SafeArea(
            bottom: false,
            child: wide
                ? Row(children: [
                    _Sidebar(page: page, badges: badges, onGo: go),
                    Expanded(child: body),
                  ])
                : body,
          ),
          bottomNavigationBar: wide || keyboard
              ? null
              : DecoratedBox(
                  decoration: BoxDecoration(border: Border(top: BorderSide(color: Tokens.of(context).border))),
                  child: NavigationBar(
                    selectedIndex: page.index,
                    onDestinationSelected: (i) => go(ConsolePage.values[i]),
                    labelBehavior: size.width < 520
                        ? NavigationDestinationLabelBehavior.onlyShowSelected
                        : NavigationDestinationLabelBehavior.alwaysShow,
                    destinations: [
                      for (final d in _destinations)
                        NavigationDestination(
                          icon: Badge(isLabelVisible: badges[d.page] != null, label: Text(badges[d.page] ?? ''), child: Icon(d.icon)),
                          selectedIcon: Badge(isLabelVisible: badges[d.page] != null, label: Text(badges[d.page] ?? ''), child: Icon(d.selected)),
                          label: d.label,
                        ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.page, required this.badges, required this.onGo});
  final ConsolePage page;
  final Map<ConsolePage, String?> badges;
  final void Function(ConsolePage) onGo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final user = ref.watch(authStateProvider).value;
    final mode = ref.watch(themeModeProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 76,
      decoration: BoxDecoration(color: t.canvas, border: Border(right: BorderSide(color: t.border))),
      child: Column(children: [
        const SizedBox(height: 14),
        Tooltip(
          message: 'Vral Altos Console',
          child: Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [scheme.primary, t.series[3]], begin: Alignment.topLeft, end: Alignment.bottomRight),
              borderRadius: BorderRadius.circular(11),
            ),
            child: const Text('VA', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14, letterSpacing: .5)),
          ),
        ),
        const SizedBox(height: 22),
        for (final d in _destinations)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Semantics(
              button: true,
              selected: d.page == page,
              label: '${d.label} Tab',
              excludeSemantics: true,
              child: InkWell(
                onTap: () => onGo(d.page),
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 64,
                  child: Column(children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      width: 48,
                      height: 32,
                      decoration: BoxDecoration(
                        color: d.page == page ? scheme.primary.withValues(alpha: .14) : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Badge(
                        isLabelVisible: badges[d.page] != null,
                        label: Text(badges[d.page] ?? ''),
                        offset: const Offset(-4, 2),
                        child: Center(
                          child: Icon(d.page == page ? d.selected : d.icon, size: 21, color: d.page == page ? scheme.primary : t.muted),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      d.label,
                      style: text.labelSmall?.copyWith(
                        color: d.page == page ? scheme.onSurface : t.muted,
                        fontWeight: d.page == page ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        const Spacer(),
        const PlacementChip(),
        const SizedBox(height: 10),
        IconButton(
          tooltip: dark ? 'Light theme' : 'Dark theme',
          onPressed: () => ref.read(themeModeProvider.notifier).set(dark ? ThemeMode.light : ThemeMode.dark),
          icon: Icon(mode == ThemeMode.system ? Icons.brightness_auto_outlined : dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined, color: t.muted),
        ),
        PopupMenuButton<String>(
          tooltip: user?.email ?? 'Account',
          onSelected: (v) {
            if (v == 'out') ref.read(firebaseAuthProvider)?.signOut();
          },
          itemBuilder: (_) => [
            PopupMenuItem(enabled: false, child: Text(user?.email ?? '')),
            const PopupMenuItem(value: 'out', child: ListTile(leading: Icon(Icons.logout), title: Text('Sign out'), dense: true)),
          ],
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: CircleAvatar(
              radius: 16,
              backgroundColor: t.sunken,
              foregroundImage: user?.photoURL == null ? null : NetworkImage(user!.photoURL!),
              child: Text((user?.email ?? '?')[0].toUpperCase(), style: text.labelLarge),
            ),
          ),
        ),
        const SizedBox(height: 12),
      ]),
    );
  }
}
