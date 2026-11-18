import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/ide_connection.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../theme.dart';
import '../widgets.dart';
import 'code_editor.dart';
import 'ide_workspace.dart';
import 'terminal_panel.dart';

/// Opens the IDE for [d] full screen.
void openIde(BuildContext context, Devstation d) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => IdePage(devstationId: d.id, project: d.project),
  ),
);

/// A small IDE on a Devstation (docs/agent_topology.md §6.4): the file tree,
/// tabbed editors and terminals, through the IDE gateway. On a phone one of
/// the three fills the screen at a time.
class IdePage extends ConsumerStatefulWidget {
  const IdePage({super.key, required this.devstationId, this.project});
  final String devstationId;
  final String? project;

  @override
  ConsumerState<IdePage> createState() => _IdePageState();
}

enum _Pane { files, editor, terminal }

class _IdePageState extends ConsumerState<IdePage> {
  late final IdeConnection conn;
  late final IdeWorkspace ws;
  late final IdeTerminals terms;
  var _pane = _Pane.editor;
  var _showTerminal = true;
  double _treeWidth = 260;
  double _termHeight = 260;
  Timer? _waitForStart;
  var _firstReady = true;

  @override
  void initState() {
    super.initState();
    conn = IdeConnection(
      devstationId: widget.devstationId,
      connect: ref.read(ideSocketFactoryProvider),
      token: ref.read(ideTokenProvider),
    );
    ws = IdeWorkspace(conn);
    terms = IdeTerminals(conn);
    conn.addListener(_phaseChanged);
    conn.start();
  }

  Future<void> _phaseChanged() async {
    if (!mounted) return;
    setState(() {});
    if (conn.phase == IdePhase.ready) {
      _waitForStart?.cancel();
      if (_firstReady) {
        _firstReady = false;
        await ws.setRoot(conn.workspace);
        await terms.adopt(conn.existingTerminals);
        if (!mounted) return;
        if (terms.tabs.isEmpty && MediaQuery.sizeOf(context).width >= 900) {
          await guardedTerminal(context, terms.add);
        }
      } else {
        unawaited(ws.refreshAll());
      }
    } else if (conn.phase == IdePhase.failed && conn.errorCode == 'not-running') {
      // Started from here or elsewhere: keep trying while it boots.
      _waitForStart ??= Timer.periodic(const Duration(seconds: 10), (_) {
        final d = _devstation();
        if (conn.phase == IdePhase.failed && d?.desired == 'running') conn.retry();
      });
    }
  }

  Devstation? _devstation() {
    final list = ref.read(devstationsProvider).value ?? const <Devstation>[];
    for (final d in list) {
      if (d.id == widget.devstationId) return d;
    }
    return null;
  }

  @override
  void dispose() {
    _waitForStart?.cancel();
    conn.removeListener(_phaseChanged);
    terms.dispose();
    ws.dispose();
    conn.dispose();
    super.dispose();
  }

  bool get _wide => MediaQuery.sizeOf(context).width >= 900;

  Future<void> _open(String path) async {
    try {
      await ws.open(path);
      if (!_wide) setState(() => _pane = _Pane.editor);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _save([OpenFile? file]) async {
    final f = file ?? ws.current;
    if (f == null || f.readOnly) return;
    try {
      await ws.save(f);
    } on SaveConflict {
      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('${f.name} changed on the Devstation'),
          content: const Text('Someone (perhaps the director) changed this file since you opened it.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(c, 'reload'), child: const Text('Discard mine, reload')),
            FilledButton(onPressed: () => Navigator.pop(c, 'overwrite'), child: const Text('Overwrite')),
          ],
        ),
      );
      if (!mounted) return;
      if (choice == 'overwrite') {
        await guarded(context, () => ws.save(f, force: true));
      } else if (choice == 'reload') {
        await guarded(context, () => ws.revert(f));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _closeFile(OpenFile f) async {
    if (f.dirty) {
      final choice = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Save ${f.name}?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(c, 'discard'), child: const Text("Don't save")),
            FilledButton(onPressed: () => Navigator.pop(c, 'save'), child: const Text('Save')),
          ],
        ),
      );
      if (choice == null) return;
      if (choice == 'save') {
        await _save(f);
        if (f.dirty) return;
      }
    }
    ws.close(f);
  }

  Future<void> _quickOpen() async {
    final path = await showDialog<String>(
      context: context,
      builder: (_) => _QuickOpen(conn: conn, root: ws.root ?? conn.workspace),
    );
    if (path != null) await _open(path);
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    ref.watch(devstationsProvider); // keeps the state below fresh
    final d = _devstation();
    final body = switch (conn.phase) {
      IdePhase.failed => _Failed(conn: conn, devstation: d, id: widget.devstationId),
      IdePhase.connecting when _firstReady => const Center(child: CircularProgressIndicator()),
      _ => ListenableBuilder(listenable: ws, builder: (context, _) => _wide ? _desktop(t) : _phone(t)),
    };
    return PopScope(
      canPop: !ws.anyDirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Unsaved changes'),
            content: const Text('Leave the IDE and lose them?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Stay')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Leave')),
            ],
          ),
        );
        if ((leave ?? false) && context.mounted) {
          for (final f in ws.files) {
            f.reload(f.controller.text, f.mtime); // marks clean
          }
          Navigator.of(context).pop();
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyP, meta: true): _quickOpen,
          const SingleActivator(LogicalKeyboardKey.keyP, control: true): _quickOpen,
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        },
        child: Scaffold(
          backgroundColor: t.canvas,
          appBar: AppBar(
            titleSpacing: 0,
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    '${widget.project ?? widget.devstationId} · IDE',
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                const SizedBox(width: 10),
                _ConnPill(conn: conn),
              ],
            ),
            actions: [
              if (conn.phase == IdePhase.ready || conn.phase == IdePhase.reconnecting) ...[
                IconButton(tooltip: 'Go to file (⌘P)', onPressed: _quickOpen, icon: const Icon(Icons.search)),
                if (_wide)
                  IconButton(
                    tooltip: _showTerminal ? 'Hide terminals' : 'Show terminals',
                    onPressed: () => setState(() => _showTerminal = !_showTerminal),
                    icon: const Icon(Icons.terminal),
                  ),
              ],
              const SizedBox(width: 6),
            ],
            bottom: _wide || conn.phase != IdePhase.ready && conn.phase != IdePhase.reconnecting
                ? null
                : PreferredSize(
                    preferredSize: const Size.fromHeight(44),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                      child: SegmentedButton<_Pane>(
                        key: const ValueKey('ide-panes'),
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                            value: _Pane.files,
                            icon: Icon(Icons.folder_outlined, size: 18),
                            label: Text('Files'),
                          ),
                          ButtonSegment(
                            value: _Pane.editor,
                            icon: Icon(Icons.edit_note, size: 18),
                            label: Text('Editor'),
                          ),
                          ButtonSegment(
                            value: _Pane.terminal,
                            icon: Icon(Icons.terminal, size: 18),
                            label: Text('Terminal'),
                          ),
                        ],
                        selected: {_pane},
                        onSelectionChanged: (s) {
                          setState(() => _pane = s.first);
                          if (s.first == _Pane.terminal && terms.tabs.isEmpty) guardedTerminal(context, terms.add);
                        },
                      ),
                    ),
                  ),
          ),
          body: body,
        ),
      ),
    );
  }

  Widget _desktop(Tokens t) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(
        width: _treeWidth,
        child: _FileTree(ws: ws, onOpen: _open, onTerminalHere: _terminalHere),
      ),
      _Splitter(axis: Axis.horizontal, onDrag: (d) => setState(() => _treeWidth = (_treeWidth + d).clamp(160, 600))),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _Editors(ws: ws, onSave: _save, onClose: _closeFile),
            ),
            if (_showTerminal) ...[
              _Splitter(
                axis: Axis.vertical,
                onDrag: (d) => setState(() => _termHeight = (_termHeight - d).clamp(100, 900)),
              ),
              SizedBox(
                height: _termHeight,
                child: TerminalPanel(terminals: terms, onHide: () => setState(() => _showTerminal = false)),
              ),
            ],
          ],
        ),
      ),
    ],
  );

  Widget _phone(Tokens t) => IndexedStack(
    index: _pane.index,
    children: [
      _FileTree(ws: ws, onOpen: _open, onTerminalHere: _terminalHere),
      _Editors(ws: ws, onSave: _save, onClose: _closeFile, compact: true),
      TerminalPanel(terminals: terms, keyBar: true),
    ],
  );

  Future<void> _terminalHere(String dir) async {
    setState(() {
      _showTerminal = true;
      if (!_wide) _pane = _Pane.terminal;
    });
    await guardedTerminal(context, () => terms.add(cwd: dir));
  }
}

class _ConnPill extends StatelessWidget {
  const _ConnPill({required this.conn});
  final IdeConnection conn;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final (label, color, pulse) = switch (conn.phase) {
      IdePhase.connecting => ('Connecting', t.info, true),
      IdePhase.ready => ('Connected', t.ok, false),
      IdePhase.reconnecting => ('Reconnecting', t.warn, true),
      IdePhase.failed => ('Not connected', t.bad, false),
    };
    return StatusPill(label: label, color: color, pulse: pulse, dense: true);
  }
}

/// Why the IDE is not connected, and (for a stopped Devstation) a Start button.
class _Failed extends ConsumerWidget {
  const _Failed({required this.conn, required this.devstation, required this.id});
  final IdeConnection conn;
  final Devstation? devstation;
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final d = devstation;
    final stopped = conn.errorCode == 'not-running';
    final starting = d?.desired == 'running' && stopped;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(stopped ? Icons.power_settings_new : Icons.link_off, size: 36, color: t.muted),
              const SizedBox(height: 12),
              Text(
                starting ? 'Starting $id…' : (stopped ? '$id is stopped' : 'Could not connect'),
                style: text.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                starting
                    ? 'The IDE connects by itself once the Devstation is up (about a minute).'
                    : stopped
                    ? 'It stops itself after 20 idle minutes. Start it to open the IDE; it costs only while running.'
                    : conn.error ?? '',
                style: text.bodySmall?.copyWith(color: t.muted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              if (starting)
                const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
              else if (stopped && d != null)
                FilledButton.icon(
                  key: const ValueKey('ide-start'),
                  onPressed: () => guarded(
                    context,
                    () => ref.read(repositoryProvider)!.requestFactory(action: 'start', devstationId: id),
                  ),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Start Devstation'),
                )
              else
                OutlinedButton.icon(
                  onPressed: conn.retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Splitter extends StatelessWidget {
  const _Splitter({required this.axis, required this.onDrag});
  final Axis axis;
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final h = axis == Axis.horizontal;
    return MouseRegion(
      cursor: h ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: h ? (e) => onDrag(e.delta.dx) : null,
        onVerticalDragUpdate: h ? null : (e) => onDrag(e.delta.dy),
        child: Container(
          width: h ? 5 : null,
          height: h ? null : 5,
          alignment: Alignment.center,
          child: Container(width: h ? 1 : null, height: h ? null : 1, color: t.border),
        ),
      ),
    );
  }
}

class _FileTree extends StatelessWidget {
  const _FileTree({required this.ws, required this.onOpen, required this.onTerminalHere});
  final IdeWorkspace ws;
  final ValueChanged<String> onOpen;
  final ValueChanged<String> onTerminalHere;

  Future<String?> _ask(BuildContext context, String title, {String initial = '', String action = 'OK'}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          key: const ValueKey('ide-name'),
          controller: c,
          autofocus: true,
          autocorrect: false,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(action)),
        ],
      ),
    );
  }

  Future<void> _menu(BuildContext context, Offset at, String path, IdeEntry? e) async {
    final dir = e == null || e.dir ? path : dirName(path);
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        const PopupMenuItem(value: 'file', child: Text('New file')),
        const PopupMenuItem(value: 'folder', child: Text('New folder')),
        if (e != null) const PopupMenuItem(value: 'rename', child: Text('Rename / move')),
        if (e != null) const PopupMenuItem(value: 'delete', child: Text('Delete')),
        const PopupMenuItem(value: 'terminal', child: Text('Terminal here')),
        const PopupMenuItem(value: 'copy', child: Text('Copy path')),
      ],
    );
    if (!context.mounted || choice == null) return;
    switch (choice) {
      case 'file' || 'folder':
        final name = await _ask(
          context,
          choice == 'file' ? 'New file in ${baseName(dir)}' : 'New folder in ${baseName(dir)}',
          action: 'Create',
        );
        if (name != null && name.isNotEmpty && context.mounted) {
          await guarded(context, () => ws.create(dir, name, folder: choice == 'folder'));
        }
      case 'rename':
        final to = await _ask(context, 'Rename or move', initial: path, action: 'Rename');
        if (to != null && to.isNotEmpty && to != path && context.mounted) {
          await guarded(context, () => ws.rename(path, to));
        }
      case 'delete':
        final yes = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Delete ${baseName(path)}?'),
            content: const Text('It is moved to ~/.ide-trash on the Devstation, so it can be recovered.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
            ],
          ),
        );
        if ((yes ?? false) && context.mounted) await guarded(context, () => ws.delete(path));
      case 'terminal':
        onTerminalHere(dir);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: path));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final rows = ws.rows();
    final root = ws.root;
    return Container(
      color: t.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 34,
            padding: const EdgeInsets.only(left: 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    root == null ? '' : baseName(root).toUpperCase(),
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: t.muted, letterSpacing: .6),
                  ),
                ),
                IconButton(
                  tooltip: 'New…',
                  iconSize: 17,
                  visualDensity: VisualDensity.compact,
                  onPressed: root == null
                      ? null
                      : () {
                          final box = context.findRenderObject() as RenderBox;
                          _menu(context, box.localToGlobal(Offset(box.size.width - 40, 34)), root, null);
                        },
                  icon: const Icon(Icons.add),
                ),
                IconButton(
                  tooltip: ws.showHidden ? 'Hide .git and tool folders' : 'Show everything',
                  iconSize: 17,
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    ws.showHidden = !ws.showHidden;
                    ws.refreshAll();
                  },
                  icon: Icon(ws.showHidden ? Icons.visibility : Icons.visibility_off_outlined),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  iconSize: 17,
                  visualDensity: VisualDensity.compact,
                  onPressed: ws.refreshAll,
                  icon: const Icon(Icons.refresh),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Open folder',
                  iconSize: 17,
                  icon: const Icon(Icons.more_vert),
                  onSelected: ws.setRoot,
                  itemBuilder: (_) => [
                    PopupMenuItem(value: ws.conn.workspace, child: const Text('Workspace')),
                    PopupMenuItem(value: ws.conn.home, child: const Text('Home')),
                  ],
                ),
              ],
            ),
          ),
          if (root != null && ws.failed[root] != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(ws.failed[root]!, style: TextStyle(color: t.bad, fontSize: 12)),
            ),
          Expanded(
            child: ListView.builder(
              key: const ValueKey('file-tree'),
              itemCount: rows.length,
              itemExtent: 28,
              itemBuilder: (context, i) {
                final r = rows[i];
                final e = r.entry;
                final open = ws.expanded.contains(r.path);
                final current = ws.current?.path == r.path;
                return GestureDetector(
                  onSecondaryTapDown: (d) => _menu(context, d.globalPosition, r.path, e),
                  onLongPressStart: (d) => _menu(context, d.globalPosition, r.path, e),
                  child: InkWell(
                    onTap: () => e.dir ? ws.toggle(r.path) : onOpen(r.path),
                    child: Container(
                      color: current ? Theme.of(context).colorScheme.primary.withValues(alpha: .12) : null,
                      padding: EdgeInsets.only(left: 8.0 + r.depth * 14),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 16,
                            child: e.dir
                                ? (ws.loading.contains(r.path)
                                      ? const SizedBox(
                                          width: 10,
                                          height: 10,
                                          child: CircularProgressIndicator(strokeWidth: 1.5),
                                        )
                                      : Icon(open ? Icons.expand_more : Icons.chevron_right, size: 16, color: t.muted))
                                : null,
                          ),
                          const SizedBox(width: 2),
                          Icon(
                            e.dir ? (open ? Icons.folder_open : Icons.folder) : Icons.description_outlined,
                            size: 15,
                            color: e.dir ? t.info : t.muted,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              e.name,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: e.name.startsWith('.') ? t.muted : null),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Editors extends StatelessWidget {
  const _Editors({required this.ws, required this.onSave, required this.onClose, this.compact = false});
  final IdeWorkspace ws;
  final Future<void> Function([OpenFile?]) onSave;
  final Future<void> Function(OpenFile) onClose;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final f = ws.current;
    if (f == null) {
      return Center(
        child: Text(
          compact ? 'Open a file from Files.' : 'Open a file from the tree, or ⌘P to find one.',
          style: TextStyle(color: t.muted),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 34,
          decoration: BoxDecoration(
            color: t.panel,
            border: Border(bottom: BorderSide(color: t.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final (i, file) in ws.files.indexed)
                      InkWell(
                        key: ValueKey('tab-${file.path}'),
                        onTap: () => ws.select(i),
                        child: Container(
                          padding: const EdgeInsets.only(left: 12, right: 2),
                          decoration: BoxDecoration(
                            color: i == ws.active ? t.canvas : null,
                            border: Border(
                              bottom: BorderSide(color: i == ws.active ? scheme.primary : Colors.transparent, width: 2),
                            ),
                          ),
                          child: Row(
                            children: [
                              Text(file.name, style: const TextStyle(fontSize: 12.5)),
                              if (file.dirty)
                                Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: Icon(Icons.circle, size: 8, color: t.warn, semanticLabel: 'unsaved'),
                                ),
                              IconButton(
                                tooltip: 'Close',
                                iconSize: 14,
                                visualDensity: VisualDensity.compact,
                                onPressed: () => onClose(file),
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (f.saving)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else if (!f.readOnly)
                TextButton(
                  key: const ValueKey('ide-save'),
                  onPressed: f.dirty ? () => onSave(f) : null,
                  child: const Text('Save'),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
          child: Text(
            f.path,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: t.faint, fontFamily: t.mono),
          ),
        ),
        Expanded(
          child: f.note != null
              ? Center(
                  child: Text(f.note!, style: TextStyle(color: t.muted)),
                )
              : CodeEditor(key: ValueKey(f), controller: f.controller, onSave: () => onSave(f)),
        ),
      ],
    );
  }
}

class _QuickOpen extends StatefulWidget {
  const _QuickOpen({required this.conn, required this.root});
  final IdeConnection conn;
  final String root;

  @override
  State<_QuickOpen> createState() => _QuickOpenState();
}

class _QuickOpenState extends State<_QuickOpen> {
  List<String> _found = const [];
  Timer? _debounce;
  var _seq = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _search(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), () async {
      final seq = ++_seq;
      try {
        final found = await widget.conn.find(widget.root, q);
        if (mounted && seq == _seq) {
          setState(() {
            _found = found;
            _error = null;
          });
        }
      } catch (e) {
        if (mounted && seq == _seq) setState(() => _error = '$e');
      }
    });
  }

  String _rel(String p) => p.startsWith('${widget.root}/') ? p.substring(widget.root.length + 1) : p;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.fromLTRB(16, 60, 16, 16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                key: const ValueKey('quick-open'),
                autofocus: true,
                autocorrect: false,
                decoration: const InputDecoration(
                  hintText: 'Go to file…',
                  prefixIcon: Icon(Icons.search),
                  isDense: true,
                ),
                onChanged: _search,
                onSubmitted: (_) {
                  if (_found.isNotEmpty) Navigator.pop(context, _found.first);
                },
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(_error!, style: TextStyle(color: t.bad)),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in _found.take(60))
                    ListTile(
                      dense: true,
                      title: Text(baseName(p)),
                      subtitle: Text(
                        _rel(p),
                        style: TextStyle(fontFamily: t.mono, fontSize: 11, color: t.muted),
                      ),
                      onTap: () => Navigator.pop(context, p),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
