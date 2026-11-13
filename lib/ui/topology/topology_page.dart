import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../theme.dart';
import '../widgets.dart';
import 'graph.dart';
import 'iso_painter.dart';
import 'layout.dart';

/// Everything Vral Altos and the operator's other projects are made of, on
/// one isometric map: districts by project (or boundary, or owner), the
/// security fences inside them, health and exposure, and how things talk.
class TopologyPage extends ConsumerWidget {
  const TopologyPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inventory = ref.watch(topologyProvider);
    final hosts = ref.watch(allStatusProvider).value ?? const {};
    final devstations = ref.watch(devstationsProvider).value ?? const <Devstation>[];
    ref.watch(clockProvider);
    if (inventory.isLoading && !inventory.hasValue) {
      return const ColoredBox(color: Holo.bg0, child: Center(child: CircularProgressIndicator(color: Holo.cyan)));
    }
    final graph = buildTopology(inventory: inventory.value, hosts: hosts, devstations: devstations, now: DateTime.now());
    // The Console keeps every page built; the map only animates when shown.
    return TickerMode(
      enabled: ref.watch(pageProvider) == ConsolePage.topology,
      child: TopologyView(graph: graph, inventoryMissing: inventory.value == null),
    );
  }
}

class TopologyView extends StatefulWidget {
  const TopologyView({super.key, required this.graph, this.inventoryMissing = false});
  final TopoGraph graph;
  final bool inventoryMissing;

  @override
  State<TopologyView> createState() => _TopologyViewState();
}

class _TopologyViewState extends State<TopologyView> with TickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
  late final AnimationController _morph = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..value = 1;
  late final AnimationController _cam = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  GroupBy _by = GroupBy.project;
  TopoFilter _filter = TopoFilter.all;
  String _query = '';
  final _search = TextEditingController();

  TopoLayout _from = TopoLayout.empty, _to = TopoLayout.empty;
  String _layoutKey = '';

  double _yaw = 0, _zoom = 30;
  Offset _pan = Offset.zero;
  Offset _center = Offset.zero;
  // Camera animation endpoints.
  ({double yaw, double zoom, Offset pan, Offset center})? _camFrom, _camTo;
  bool _fitted = false;

  final _hits = HitIndex();
  final _labels = <String, TextPainter>{};
  String? _hovered, _selected;
  Offset? _pointer;
  double _scaleStartZoom = 30, _scaleStartYaw = 0;
  Size _view = Size.zero;

  @override
  void initState() {
    super.initState();
    _cam.addListener(() {
      final a = _camFrom, b = _camTo;
      if (a == null || b == null) return;
      final u = Curves.easeInOutCubic.transform(_cam.value);
      setState(() {
        _yaw = a.yaw + (b.yaw - a.yaw) * u;
        _zoom = a.zoom + (b.zoom - a.zoom) * u;
        _pan = Offset.lerp(a.pan, b.pan, u)!;
        _center = Offset.lerp(a.center, b.center, u)!;
      });
    });
  }

  @override
  void dispose() {
    _pulse.dispose();
    _morph.dispose();
    _cam.dispose();
    _search.dispose();
    for (final t in _labels.values) {
      t.dispose();
    }
    super.dispose();
  }

  List<TopoEntity> get _visible => [for (final e in widget.graph.entities) if (e.filters.contains(_filter)) e];

  /// Lays out again when the grouping, the filter or the set of entities
  /// changes, morphing from where things were.
  void _relayout() {
    final vis = _visible;
    final key = '${_by.name}|${_filter.name}|${vis.map((e) => e.id).join(',')}';
    if (key == _layoutKey) return;
    final current = _to;
    final next = layoutTopology(vis, _by);
    // Morph from wherever things are now (mid-animation included).
    _from = _morph.isAnimating ? _snapshot(current) : current;
    _to = next;
    _layoutKey = key;
    if (_from.positions.isEmpty) {
      _morph.value = 1;
    } else {
      _morph.forward(from: 0);
    }
    if (!_fitted && _view != Size.zero) {
      _fitted = true;
      _fit(animate: false);
    } else if (_fitted) {
      // After this frame: the camera animation rebuilds as it runs.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fit();
      });
    }
  }

  TopoLayout _snapshot(TopoLayout l) => l; // the painter lerps; restarting from the target is smooth enough.

  /// Frames the whole map.
  void _fit({bool animate = true}) {
    final b = _to.bounds;
    if (b.isEmpty || _view == Size.zero) return;
    // The HUD takes the top ~130 px; keep the map below it.
    const top = 140.0, bottom = 24.0;
    final diag = (b.width + b.height) * .87; // iso width of the plot
    final zoom = ((_view.width - 80) / diag).clamp(6.0, 60.0).toDouble();
    final heightZoom = ((_view.height - top - bottom) / ((b.width + b.height) * .5 + 4)).clamp(6.0, 60.0).toDouble();
    _moveCamera(yaw: _yaw, zoom: math.min(zoom, heightZoom), pan: Offset(0, (top - bottom) / 2), center: b.center, animate: animate);
  }

  void _moveCamera({required double yaw, required double zoom, required Offset pan, required Offset center, bool animate = true}) {
    if (!animate) {
      // Called while building (the first fit) or from a handler that
      // rebuilds anyway.
      _cam.stop();
      _yaw = yaw;
      _zoom = zoom;
      _pan = pan;
      _center = center;
      return;
    }
    _camFrom = (yaw: _yaw, zoom: _zoom, pan: _pan, center: _center);
    _camTo = (yaw: yaw, zoom: zoom, pan: pan, center: center);
    _cam.forward(from: 0);
  }

  void _rotate(double by) => _moveCamera(yaw: _yaw + by, zoom: _zoom, pan: _pan, center: _center);
  void _zoomBy(double f, [Offset? at]) {
    final z = (_zoom * f).clamp(6.0, 120.0);
    // Keep the point under the cursor still.
    final focal = at == null ? Offset.zero : at - Offset(_view.width / 2, _view.height / 2) - _pan;
    setState(() {
      _pan += focal - focal * (z / _zoom);
      _zoom = z;
    });
  }

  /// Selects and flies to the first entity matching the search.
  void _findFirst(String q) {
    final s = q.trim().toLowerCase();
    if (s.isEmpty) return;
    final hits = _visible.where((e) => e.label.toLowerCase().contains(s) || e.type.toLowerCase().contains(s)).toList()
      ..sort((a, b) => (a.label.toLowerCase().startsWith(s) ? 0 : 1).compareTo(b.label.toLowerCase().startsWith(s) ? 0 : 1));
    if (hits.isEmpty) return;
    setState(() {
      _selected = hits.first.id;
      _pointer = null;
    });
    _focusOn(hits.first.id);
  }

  /// Centres and zooms onto one entity.
  void _focusOn(String id) {
    final p = _to.positions[id];
    if (p == null) return;
    _moveCamera(yaw: _yaw, zoom: math.max(_zoom, 56), pan: Offset.zero, center: p);
  }

  @override
  void didUpdateWidget(TopologyView old) {
    super.didUpdateWidget(old);
    if (_selected != null && !widget.graph.entities.any((e) => e.id == _selected)) _selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final mono = Tokens.of(context).mono;
    final graph = widget.graph;
    final byId = {for (final e in graph.entities) e.id: e};
    final focusId = _selected ?? _hovered;
    final focus = focusId == null ? null : byId[focusId];
    final text = Theme.of(context).textTheme;
    final narrow = MediaQuery.sizeOf(context).width < 700;

    return ColoredBox(
      color: Holo.bg0,
      child: LayoutBuilder(builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        if (size != _view) {
          final first = _view == Size.zero;
          _view = size;
          if (first) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? setState(() {}) : null);
        }
        _relayout();
        final camera = IsoCamera(yaw: _yaw, zoom: _zoom, pan: _pan, center: _center);
        final anchor = focusId == null ? null : _hits.anchorOf(focusId);
        return Stack(children: [
          // Backdrop: a deep radial glow.
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(center: Alignment(0, -.2), radius: 1.1, colors: [Holo.bg1, Holo.bg0]),
              ),
            ),
          ),
          Positioned.fill(
            child: Listener(
              onPointerSignal: (s) {
                if (s is PointerScrollEvent) _zoomBy(s.scrollDelta.dy > 0 ? .9 : 1.1, s.localPosition);
              },
              child: MouseRegion(
                cursor: _hovered != null ? SystemMouseCursors.click : SystemMouseCursors.grab,
                onHover: (e) {
                  final id = _hits.at(e.localPosition);
                  if (id != _hovered || _pointer != e.localPosition) {
                    setState(() {
                      _hovered = id;
                      _pointer = e.localPosition;
                    });
                  }
                },
                onExit: (_) => setState(() => _hovered = null),
                child: GestureDetector(
                  onTapUp: (d) {
                    final id = _hits.at(d.localPosition);
                    setState(() {
                      _selected = id == _selected ? null : id;
                      _pointer = d.localPosition;
                    });
                  },
                  onDoubleTapDown: (d) {
                    final id = _hits.at(d.localPosition);
                    if (id != null) _focusOn(id);
                  },
                  onScaleStart: (_) {
                    _scaleStartZoom = _zoom;
                    _scaleStartYaw = _yaw;
                    _cam.stop();
                  },
                  onScaleUpdate: (d) => setState(() {
                    _pan += d.focalPointDelta;
                    if (d.pointerCount > 1) {
                      _zoom = (_scaleStartZoom * d.scale).clamp(6.0, 120.0);
                      _yaw = _scaleStartYaw - d.rotation;
                    }
                  }),
                  child: ClipRect(
                    child: CustomPaint(
                    size: size,
                    painter: TopologyPainter(
                      graph: graph,
                      from: _from,
                      to: _to,
                      morph: _morph,
                      camera: camera,
                      pulse: _pulse,
                      hits: _hits,
                      labels: _labels,
                      hovered: _hovered,
                      selected: _selected,
                      query: _query,
                      mono: mono,
                      district: (e) => outerKey(e, _by),
                    ),
                  ),
                  ),
                ),
              ),
            ),
          ),
          // Scanline sweep for atmosphere.
          Positioned.fill(child: IgnorePointer(child: _Scan(animation: _pulse))),
          Positioned(
            left: 16,
            right: 16,
            top: 12,
            child: _Hud(
              graph: graph,
              mono: mono,
              inventoryMissing: widget.inventoryMissing,
              by: _by,
              filter: _filter,
              search: _search,
              narrow: narrow,
              onBy: (b) => setState(() => _by = b),
              onFilter: (f) => setState(() {
                _filter = f;
                _selected = null;
              }),
              onQuery: (q) => setState(() => _query = q),
              onSubmit: _findFirst,
            ),
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: _Controls(
              onRotateLeft: () => _rotate(-math.pi / 4),
              onRotateRight: () => _rotate(math.pi / 4),
              onZoomIn: () => _zoomBy(1.25),
              onZoomOut: () => _zoomBy(.8),
              onFit: () => setState(() {
                _selected = null;
                _fit();
              }),
            ),
          ),
          if (!narrow) Positioned(left: 16, bottom: 16, child: _Legend(mono: mono, by: _by)),
          if (focus != null && (anchor != null || _pointer != null))
            _Overlay(
              entity: focus,
              at: _selected != null ? (anchor ?? _pointer!) : (_pointer ?? anchor!),
              view: size,
              mono: mono,
              pinned: _selected != null,
              links: [
                for (final l in graph.links)
                  if (l.from == focus.id && byId[l.to] != null)
                    '${l.label} → ${byId[l.to]!.label}'
                  else if (l.to == focus.id && byId[l.from] != null)
                    '${byId[l.from]!.label} ${l.label} →',
              ],
              onClose: () => setState(() => _selected = null),
              onFocus: () => _focusOn(focus.id),
            ),
          if (graph.entities.isEmpty)
            Center(
              child: Text(
                'No topology yet. The Mac worker maps the estate every 15 minutes\n(or run `va_agent topology`).',
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: Holo.dim, fontFamily: mono),
              ),
            ),
        ]);
      }),
    );
  }
}

class _Scan extends StatelessWidget {
  const _Scan({required this.animation});
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    builder: (context, _) {
      final y = (animation.value * 1.6 - .3);
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: [(y - .06).clamp(0, 1), y.clamp(0, 1), (y + .002).clamp(0, 1)],
            colors: [Colors.transparent, Holo.cyan.withValues(alpha: .035), Colors.transparent],
          ),
        ),
      );
    },
  );
}

/// The heads-up display: what is on the map, how it is grouped, filters.
class _Hud extends StatelessWidget {
  const _Hud({
    required this.graph,
    required this.mono,
    required this.inventoryMissing,
    required this.by,
    required this.filter,
    required this.search,
    required this.narrow,
    required this.onBy,
    required this.onFilter,
    required this.onQuery,
    required this.onSubmit,
  });
  final TopoGraph graph;
  final String? mono;
  final bool inventoryMissing, narrow;
  final GroupBy by;
  final TopoFilter filter;
  final TextEditingController search;
  final ValueChanged<GroupBy> onBy;
  final ValueChanged<TopoFilter> onFilter;
  final ValueChanged<String> onQuery;
  final ValueChanged<String> onSubmit;

  @override
  Widget build(BuildContext context) {
    final es = graph.entities;
    final projects = es.map((e) => e.project).where((p) => p != 'external').toSet().length;
    final bad = es.where((e) => e.health == Health.bad).length;
    final warn = es.where((e) => e.health == Health.warn).length;
    final public = es.where((e) => e.public).length;
    final physical = es.where((e) => e.physical).length;
    final at = graph.collectedAt;
    TextStyle s(double size, {Color color = Holo.text, FontWeight w = FontWeight.w500, double spacing = .6}) =>
        TextStyle(fontFamily: mono, fontSize: size, color: color, fontWeight: w, letterSpacing: spacing);
    Widget stat(String label, String value, Color color) => Padding(
      padding: const EdgeInsets.only(right: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(value, style: s(18, color: color, w: FontWeight.w700, spacing: 0)),
        Text(label.toUpperCase(), style: s(9, color: Holo.dim, spacing: 1.4)),
      ]),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 24,
        runSpacing: 10,
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 8, height: 8, decoration: const BoxDecoration(color: Holo.cyan, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Holo.cyan, blurRadius: 8)])),
              const SizedBox(width: 10),
              Text('TOPOLOGY', style: s(15, w: FontWeight.w800, spacing: 4)),
            ]),
            const SizedBox(height: 2),
            Text(
              inventoryMissing
                  ? 'Live hosts only · the cloud and code inventory has not been collected yet'
                  : 'Collected ${at == null ? '—' : ago(at)}${graph.errors.isEmpty ? '' : ' · ${graph.errors.length} source(s) failed'}',
              style: s(10, color: inventoryMissing || graph.errors.isNotEmpty ? Holo.health(Health.warn) : Holo.dim),
            ),
          ]),
          Row(mainAxisSize: MainAxisSize.min, children: [
            stat('Projects', '$projects', Holo.text),
            stat('Entities', '${es.length}', Holo.text),
            stat('Physical', '$physical', Holo.text),
            stat('Public', '$public', Holo.boundary(Boundary.public)),
            stat('Down', '$bad', bad > 0 ? Holo.health(Health.bad) : Holo.dim),
            stat('Degraded', '$warn', warn > 0 ? Holo.health(Health.warn) : Holo.dim),
          ]),
        ],
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        _Segmented(
          mono: mono,
          label: 'GROUP BY',
          options: [for (final g in GroupBy.values) (g.label, g == by, () => onBy(g))],
        ),
        for (final f in TopoFilter.values)
          _Chip(
            mono: mono,
            label: f.label,
            selected: f == filter,
            count: es.where((e) => e.filters.contains(f)).length,
            onTap: () => onFilter(f),
          ),
        SizedBox(
          width: narrow ? 180 : 220,
          height: 32,
          child: TextField(
            controller: search,
            onChanged: onQuery,
            onSubmitted: onSubmit,
            style: s(12),
            cursorColor: Holo.cyan,
            decoration: InputDecoration(
              hintText: 'Find an entity (Enter flies to it)',
              hintStyle: s(12, color: Holo.dim),
              prefixIcon: const Icon(Icons.search, size: 16, color: Holo.dim),
              filled: true,
              fillColor: Holo.bg1.withValues(alpha: .85),
              contentPadding: EdgeInsets.zero,
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: Holo.cyan.withValues(alpha: .25))),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Holo.cyan)),
            ),
          ),
        ),
      ]),
    ]);
  }
}

class _Segmented extends StatelessWidget {
  const _Segmented({required this.mono, required this.label, required this.options});
  final String? mono;
  final String label;
  final List<(String, bool, VoidCallback)> options;

  @override
  Widget build(BuildContext context) => Container(
    height: 32,
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: Holo.bg1.withValues(alpha: .85),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: Holo.cyan.withValues(alpha: .25)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(label, style: TextStyle(fontFamily: mono, fontSize: 9, color: Holo.dim, letterSpacing: 1.4)),
      ),
      for (final (l, on, tap) in options)
        Semantics(
          button: true,
          selected: on,
          label: 'Group by $l',
          excludeSemantics: true,
          child: GestureDetector(
            onTap: tap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? Holo.cyan.withValues(alpha: .18) : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(l, style: TextStyle(fontFamily: mono, fontSize: 11.5, color: on ? Holo.cyan : Holo.text, fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
            ),
          ),
        ),
    ]),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.mono, required this.label, required this.selected, required this.count, required this.onTap});
  final String? mono;
  final String label;
  final bool selected;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: 'Show $label',
    excludeSemantics: true,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: count == 0 ? null : onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected ? Holo.cyan.withValues(alpha: .16) : Holo.bg1.withValues(alpha: .85),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: selected ? Holo.cyan : Holo.cyan.withValues(alpha: .2)),
            boxShadow: selected ? [BoxShadow(color: Holo.cyan.withValues(alpha: .25), blurRadius: 10)] : null,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: TextStyle(fontFamily: mono, fontSize: 11.5, color: count == 0 ? Holo.dim : (selected ? Holo.cyan : Holo.text), fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
            const SizedBox(width: 6),
            Text('$count', style: TextStyle(fontFamily: mono, fontSize: 10, color: Holo.dim)),
          ]),
        ),
      ),
    ),
  );
}

class _Controls extends StatelessWidget {
  const _Controls({required this.onRotateLeft, required this.onRotateRight, required this.onZoomIn, required this.onZoomOut, required this.onFit});
  final VoidCallback onRotateLeft, onRotateRight, onZoomIn, onZoomOut, onFit;

  @override
  Widget build(BuildContext context) {
    Widget b(IconData i, String tip, VoidCallback f) => Tooltip(
      message: tip,
      child: IconButton(
        onPressed: f,
        icon: Icon(i, size: 18),
        color: Holo.text,
        style: IconButton.styleFrom(
          backgroundColor: Holo.bg1.withValues(alpha: .9),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6), side: BorderSide(color: Holo.cyan.withValues(alpha: .25))),
        ),
      ),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyQ): onRotateLeft,
        const SingleActivator(LogicalKeyboardKey.keyE): onRotateRight,
      },
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        b(Icons.rotate_left_rounded, 'Rotate left (Q)', onRotateLeft),
        const SizedBox(width: 6),
        b(Icons.rotate_right_rounded, 'Rotate right (E)', onRotateRight),
        const SizedBox(width: 6),
        b(Icons.remove_rounded, 'Zoom out', onZoomOut),
        const SizedBox(width: 6),
        b(Icons.add_rounded, 'Zoom in', onZoomIn),
        const SizedBox(width: 6),
        b(Icons.center_focus_strong_outlined, 'Fit everything', onFit),
      ]),
    );
  }
}

class _Legend extends StatefulWidget {
  const _Legend({required this.mono, required this.by});
  final String? mono;
  final GroupBy by;

  @override
  State<_Legend> createState() => _LegendState();
}

/// Folded to a tab until hovered (or tapped), so it never hides the map.
class _LegendState extends State<_Legend> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _open = true),
    onExit: (_) => setState(() => _open = false),
    child: GestureDetector(
      onTap: () => setState(() => _open = !_open),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.bottomLeft,
        child: _open
            ? _body(context)
            : Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Holo.bg1.withValues(alpha: .82),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Holo.cyan.withValues(alpha: .2)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  for (final b in Boundary.values)
                    Container(width: 7, height: 7, margin: const EdgeInsets.only(right: 4), color: Holo.boundary(b)),
                  const SizedBox(width: 6),
                  Text('LEGEND', style: TextStyle(fontFamily: widget.mono, fontSize: 10, color: Holo.dim, letterSpacing: 1.4)),
                ]),
              ),
      ),
    ),
  );

  Widget _body(BuildContext context) {
    final mono = widget.mono;
    TextStyle s(Color c) => TextStyle(fontFamily: mono, fontSize: 10, color: c, letterSpacing: .5);
    Widget row(Color c, String l, {bool diamond = false}) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Transform.rotate(
          angle: diamond ? math.pi / 4 : 0,
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: diamond ? c : c.withValues(alpha: .25), border: Border.all(color: c), borderRadius: BorderRadius.circular(diamond ? 1 : 2)),
          ),
        ),
        const SizedBox(width: 8),
        Text(l, style: s(Holo.text.withValues(alpha: .85))),
      ]),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 14, 6),
      decoration: BoxDecoration(
        color: Holo.bg1.withValues(alpha: .82),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Holo.cyan.withValues(alpha: .2)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('FENCES', style: s(Holo.dim)),
          const SizedBox(height: 6),
          for (final b in Boundary.values) row(Holo.boundary(b), b.label),
        ]),
        const SizedBox(width: 20),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('HEALTH', style: s(Holo.dim)),
          const SizedBox(height: 6),
          row(Holo.health(Health.ok), 'Healthy', diamond: true),
          row(Holo.health(Health.warn), 'Degraded', diamond: true),
          row(Holo.health(Health.bad), 'Down', diamond: true),
          row(Holo.health(Health.idle), 'Stopped / idle', diamond: true),
          const SizedBox(height: 6),
          Text('Solid = physical · glass = virtual', style: s(Holo.dim)),
          Text('Ground ring = owner · amber halo = public', style: s(Holo.dim)),
        ]),
      ]),
    );
  }
}

/// The sci-fi readout for the entity under the pointer (or pinned).
class _Overlay extends StatefulWidget {
  const _Overlay({
    required this.entity,
    required this.at,
    required this.view,
    required this.mono,
    required this.pinned,
    required this.links,
    required this.onClose,
    required this.onFocus,
  });
  final TopoEntity entity;
  final Offset at;
  final Size view;
  final String? mono;
  final bool pinned;
  final List<String> links;
  final VoidCallback onClose, onFocus;

  @override
  State<_Overlay> createState() => _OverlayState();
}

class _OverlayState extends State<_Overlay> with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))..forward();

  @override
  void didUpdateWidget(_Overlay old) {
    super.didUpdateWidget(old);
    if (old.entity.id != widget.entity.id) _in.forward(from: .3);
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entity;
    const w = 300.0;
    final hc = Holo.health(e.health);
    final bc = Holo.boundary(e.boundary);
    var left = widget.at.dx + 22;
    if (left + w > widget.view.width - 12) left = widget.at.dx - w - 22;
    left = left.clamp(12.0, math.max(12.0, widget.view.width - w - 12));
    // Roughly how tall the card is, so it stays on screen.
    final height = 250.0 +
        20 * math.min(e.facts.length, 9) +
        15 * math.min(widget.links.length, 6) +
        (e.url != null ? 26 : 0) +
        (widget.pinned ? 0 : 22);
    final top = (widget.at.dy - 40).clamp(110.0, math.max(110.0, widget.view.height - height - 12)).toDouble();
    TextStyle s(double size, {Color color = Holo.text, FontWeight w = FontWeight.w500, double spacing = .3}) =>
        TextStyle(fontFamily: widget.mono, fontSize: size, color: color, fontWeight: w, letterSpacing: spacing, height: 1.35);
    Widget tag(String t, Color c) => Container(
      margin: const EdgeInsets.only(right: 6, bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: c.withValues(alpha: .12), border: Border.all(color: c.withValues(alpha: .6)), borderRadius: BorderRadius.circular(3)),
      child: Text(t.toUpperCase(), style: s(9, color: c, w: FontWeight.w700, spacing: 1.2)),
    );

    final card = Container(
      width: w,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Holo.bg0.withValues(alpha: .9),
        border: Border.all(color: Holo.cyan.withValues(alpha: .45)),
        boxShadow: [BoxShadow(color: Holo.cyan.withValues(alpha: .18), blurRadius: 24)],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: Text(e.label, style: s(14, w: FontWeight.w700, spacing: .2), maxLines: 2, overflow: TextOverflow.ellipsis)),
          if (widget.pinned) ...[
            InkWell(onTap: widget.onFocus, child: const Padding(padding: EdgeInsets.all(2), child: Icon(Icons.center_focus_weak, size: 16, color: Holo.dim))),
            InkWell(onTap: widget.onClose, child: const Padding(padding: EdgeInsets.all(2), child: Icon(Icons.close, size: 16, color: Holo.dim))),
          ],
        ]),
        Text(e.type, style: s(10.5, color: Holo.dim)),
        const SizedBox(height: 10),
        Wrap(children: [
          tag(e.boundary.label, bc),
          tag(e.physical ? 'Physical' : 'Virtual', Holo.text),
          if (e.public) tag('Public', Holo.boundary(Boundary.public)),
        ]),
        _Rule(color: Holo.cyan.withValues(alpha: .25)),
        _Kv('HEALTH', Row(children: [
          _Beacon(color: hc, pulse: e.health == Health.bad),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              switch (e.health) {
                Health.ok => 'Healthy',
                Health.warn => 'Degraded',
                Health.bad => 'Down',
                Health.idle => 'Stopped',
                Health.unknown => 'No signal',
              } + (e.healthDetail == null ? '' : ' · ${e.healthDetail}'),
              style: s(11, color: e.health == Health.unknown ? Holo.dim : hc),
            ),
          ),
        ]), mono: widget.mono),
        _Kv('SECURITY', Text(
          e.public
              ? 'Exposed to the internet'
              : switch (e.boundary) {
                  Boundary.cloud => 'Internal · IAM-guarded',
                  Boundary.devnet => 'Private network',
                  Boundary.counsel => 'Agent sandbox',
                  Boundary.local => 'On your premises',
                  Boundary.external => 'Third party',
                  Boundary.public => 'Public',
                },
          style: s(11, color: e.public ? Holo.boundary(Boundary.public) : Holo.text),
        ), mono: widget.mono),
        _Kv('PROJECT', Text(e.projectName, style: s(11)), mono: widget.mono),
        _Kv('OWNER', Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Holo.owner(e.owner), width: 1.5))),
          const SizedBox(width: 6),
          Expanded(child: Text(e.ownerName, style: s(11))),
        ]), mono: widget.mono),
        if (e.facts.isNotEmpty) ...[
          _Rule(color: Holo.cyan.withValues(alpha: .25)),
          for (final (k, v) in e.facts.take(9)) _Kv(k.toUpperCase(), Text(v, style: s(11), maxLines: 2, overflow: TextOverflow.ellipsis), mono: widget.mono),
        ],
        if (widget.links.isNotEmpty) ...[
          _Rule(color: Holo.cyan.withValues(alpha: .25)),
          for (final l in widget.links.take(5)) Text('⟶ $l', style: s(10.5, color: Holo.cyan.withValues(alpha: .85)), overflow: TextOverflow.ellipsis),
          if (widget.links.length > 5) Text('+${widget.links.length - 5} more', style: s(10, color: Holo.dim)),
        ],
        if (e.url != null) ...[
          const SizedBox(height: 8),
          InkWell(
            onTap: () => unawaited(launchUrl(Uri.parse(e.url!), webOnlyWindowName: '_blank')),
            child: Text('OPEN ↗', style: s(10.5, color: Holo.cyan, w: FontWeight.w700, spacing: 1.5)),
          ),
        ],
        if (!widget.pinned) ...[
          const SizedBox(height: 8),
          Text('Click to pin · double-click to zoom in', style: s(9.5, color: Holo.dim)),
        ],
      ]),
    );

    return Positioned(
      left: left,
      top: top,
      child: FadeTransition(
        opacity: _in,
        child: ScaleTransition(
          scale: Tween(begin: .96, end: 1.0).animate(CurvedAnimation(parent: _in, curve: Curves.easeOutCubic)),
          alignment: Alignment.topLeft,
          child: IgnorePointer(
            ignoring: !widget.pinned,
            child: CustomPaint(foregroundPainter: _Brackets(), child: card),
          ),
        ),
      ),
    );
  }
}

class _Kv extends StatelessWidget {
  const _Kv(this.k, this.v, {required this.mono});
  final String k;
  final Widget v;
  final String? mono;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 92,
        child: Text(k, style: TextStyle(fontFamily: mono, fontSize: 9, color: Holo.dim, letterSpacing: 1.2, height: 1.6), overflow: TextOverflow.ellipsis),
      ),
      Expanded(child: v),
    ]),
  );
}

class _Rule extends StatelessWidget {
  const _Rule({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 8), color: color);
}

class _Beacon extends StatefulWidget {
  const _Beacon({required this.color, required this.pulse});
  final Color color;
  final bool pulse;

  @override
  State<_Beacon> createState() => _BeaconState();
}

class _BeaconState extends State<_Beacon> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, _) => Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: widget.color,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: widget.color.withValues(alpha: widget.pulse ? .3 + .5 * _c.value : .5), blurRadius: 8)],
      ),
    ),
  );
}

/// Sci-fi corner brackets around the readout.
class _Brackets extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Holo.cyan
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    const l = 12.0;
    for (final (x, y, dx, dy) in [(0.0, 0.0, 1.0, 1.0), (size.width, 0.0, -1.0, 1.0), (0.0, size.height, 1.0, -1.0), (size.width, size.height, -1.0, -1.0)]) {
      canvas.drawPath(Path()..moveTo(x + dx * l, y)..lineTo(x, y)..lineTo(x, y + dy * l), p);
    }
  }

  @override
  bool shouldRepaint(_Brackets old) => false;
}
