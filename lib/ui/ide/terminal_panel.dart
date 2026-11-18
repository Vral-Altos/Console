import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';
import 'package:ui_mesh/ui_mesh.dart';

import '../../data/ide_connection.dart';

/// One shell on the Devstation and its screen here.
class TermTab {
  TermTab(this.id, this.terminal, this.title);
  final int id;
  final Terminal terminal;
  String title;
  bool exited = false;
  bool hadOutput = false;
}

/// The page's terminals: opened, reattached after a reconnect, closed.
/// Shells keep running on the Devstation when the page goes away.
class IdeTerminals extends ChangeNotifier {
  IdeTerminals(this.conn) {
    _sub = conn.terminalEvents.listen(_event);
  }

  final IdeConnection conn;
  final tabs = <TermTab>[];
  int active = 0;
  late final StreamSubscription<IdeTermEvent> _sub;

  /// The phone key bar's Ctrl: applies to the next key typed.
  bool ctrlArmed = false;

  TermTab? get current => active >= 0 && active < tabs.length ? tabs[active] : null;

  TermTab _make(int id, String title) {
    final terminal = Terminal(maxLines: 5000);
    final tab = TermTab(id, terminal, title);
    terminal.onOutput = (data) {
      if (ctrlArmed && data.length == 1) {
        final c = data.toUpperCase().codeUnitAt(0);
        if (c >= 64 && c < 96) data = String.fromCharCode(c - 64);
        ctrlArmed = false;
        notifyListeners();
      }
      conn.input(id, data);
    };
    terminal.onResize = (w, h, pw, ph) => conn.resize(id, w, h);
    terminal.onTitleChange = (t) {
      tab.title = t;
      notifyListeners();
    };
    return tab;
  }

  Future<void> add({String? cwd}) async {
    final id = await conn.openTerminal(cwd: cwd);
    tabs.add(_make(id, cwd == null ? 'shell' : cwd.substring(cwd.lastIndexOf('/') + 1)));
    active = tabs.length - 1;
    notifyListeners();
  }

  /// Shows shells the Devstation already has (opened earlier from any device).
  Future<void> adopt(Iterable<int> ids) async {
    for (final id in ids) {
      if (tabs.any((t) => t.id == id)) continue;
      final tab = _make(id, 'shell $id');
      tabs.add(tab);
      try {
        await conn.attachTerminal(id);
      } catch (_) {
        tabs.remove(tab);
      }
    }
    if (active >= tabs.length) active = tabs.length - 1;
    notifyListeners();
  }

  void _event(IdeTermEvent e) {
    final i = tabs.indexWhere((t) => t.id == e.terminal);
    if (i < 0) return;
    final tab = tabs[i];
    if (e.isExit) {
      tab.exited = true;
      tab.terminal.write('\r\n\x1b[2m[shell ended${e.exitCode == -1 ? '' : ' (${e.exitCode})'}]\x1b[0m\r\n');
      notifyListeners();
      return;
    }
    // A reattach replays recent output: start the screen again from it.
    if (e.replay && tab.hadOutput) tab.terminal.write('\x1bc');
    tab.hadOutput = true;
    tab.terminal.write(e.data!);
  }

  Future<void> close(TermTab tab) async {
    tabs.remove(tab);
    if (active >= tabs.length) active = tabs.length - 1;
    notifyListeners();
    if (!tab.exited) {
      try {
        await conn.closeTerminal(tab.id);
      } catch (_) {}
    }
  }

  void select(int i) {
    active = i;
    notifyListeners();
  }

  void send(String data) {
    final t = current;
    if (t != null && !t.exited) conn.input(t.id, data);
  }

  void toggleCtrl() {
    ctrlArmed = !ctrlArmed;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

/// Terminal tabs, the active terminal, and (on touch screens) a row of the
/// keys a phone keyboard lacks.
class TerminalPanel extends StatelessWidget {
  const TerminalPanel({super.key, required this.terminals, this.keyBar = false, this.onHide});

  final IdeTerminals terminals;
  final bool keyBar;
  final VoidCallback? onHide;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: terminals,
      builder: (context, _) {
        final current = terminals.current;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 34,
              decoration: BoxDecoration(
                color: VaColors.panel,
                border: Border(bottom: BorderSide(color: VaColors.border)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final (i, tab) in terminals.tabs.indexed)
                          _Tab(
                            label: tab.title.isEmpty ? 'shell' : tab.title,
                            selected: i == terminals.active,
                            faded: tab.exited,
                            onTap: () => terminals.select(i),
                            onClose: () => terminals.close(tab),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('new-terminal'),
                    tooltip: 'New terminal',
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => guardedTerminal(context, terminals.add),
                    icon: const Icon(Icons.add),
                  ),
                  if (onHide != null)
                    IconButton(
                      tooltip: 'Hide terminals',
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      onPressed: onHide,
                      icon: const Icon(Icons.keyboard_arrow_down),
                    ),
                ],
              ),
            ),
            Expanded(
              child: current == null
                  ? Center(
                      child: TextButton.icon(
                        onPressed: () => guardedTerminal(context, terminals.add),
                        icon: const Icon(Icons.terminal, size: 18),
                        label: const Text('Open a terminal'),
                      ),
                    )
                  : Container(
                      color: TerminalThemes.defaultTheme.background,
                      child: TerminalView(
                        current.terminal,
                        key: ValueKey('term-${current.id}'),
                        autofocus: true,
                        padding: const EdgeInsets.all(6),
                        textStyle: TerminalStyle(fontSize: 13, fontFamily: VaType.mono),
                        keyboardType: TextInputType.text,
                      ),
                    ),
            ),
            if (keyBar && current != null) _KeyBar(terminals: terminals),
          ],
        );
      },
    );
  }
}

Future<void> guardedTerminal(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Terminal: $e')));
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.onClose,
    this.faded = false,
  });
  final String label;
  final bool selected;
  final bool faded;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.only(left: 10, right: 2),
        decoration: BoxDecoration(
          color: selected ? VaColors.canvas : null,
          border: Border(bottom: BorderSide(color: selected ? scheme.primary : Colors.transparent, width: 2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal, size: 14, color: VaColors.muted),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: faded ? VaColors.faint : null),
              ),
            ),
            IconButton(
              tooltip: 'Close',
              iconSize: 14,
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}

class _KeyBar extends StatelessWidget {
  const _KeyBar({required this.terminals});
  final IdeTerminals terminals;

  @override
  Widget build(BuildContext context) {
    Widget key(String label, String? send, {bool on = false, VoidCallback? tap}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      child: Material(
        color: on ? Theme.of(context).colorScheme.primary.withValues(alpha: .25) : VaColors.sunken,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: tap ?? () => terminals.send(send!),
          child: Container(
            constraints: const BoxConstraints(minWidth: 38),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            child: Text(label, style: TextStyle(fontFamily: VaType.mono, fontSize: 13)),
          ),
        ),
      ),
    );
    return Container(
      key: const ValueKey('terminal-keys'),
      height: 44,
      color: VaColors.panel,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        children: [
          key('esc', '\x1b'),
          key('tab', '\t'),
          key('ctrl', null, on: terminals.ctrlArmed, tap: terminals.toggleCtrl),
          key('↑', '\x1b[A'),
          key('↓', '\x1b[B'),
          key('←', '\x1b[D'),
          key('→', '\x1b[C'),
          key('^C', '\x03'),
          key('|', '|'),
          key('~', '~'),
          key('/', '/'),
          key('-', '-'),
        ],
      ),
    );
  }
}
