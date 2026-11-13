import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'graph.dart';
import 'layout.dart';

/// The viewport's palette: a dark "holo table" in both themes.
abstract final class Holo {
  static const bg0 = Color(0xFF060A12);
  static const bg1 = Color(0xFF0B1424);
  static const grid = Color(0xFF1B2B45);
  static const text = Color(0xFFD8E6FF);
  static const dim = Color(0xFF7C8BA6);
  static const cyan = Color(0xFF3FE0FF);

  static Color boundary(Boundary? b) => switch (b) {
    Boundary.public => const Color(0xFFFF9F43),
    Boundary.cloud => const Color(0xFF3FA9FF),
    Boundary.devnet => const Color(0xFF2EE6B6),
    Boundary.counsel => const Color(0xFFD27CFF),
    Boundary.local => const Color(0xFF8CF06B),
    Boundary.external => const Color(0xFFB8C2D6),
    null => cyan,
  };

  static Color health(Health h) => switch (h) {
    Health.ok => const Color(0xFF3DF59A),
    Health.warn => const Color(0xFFFFC94D),
    Health.bad => const Color(0xFFFF4D6A),
    Health.idle => const Color(0xFF7C8BA6),
    Health.unknown => const Color(0xFF55627A),
  };

  static Color kind(EntityKind k) => switch (k) {
    EntityKind.host || EntityKind.device => const Color(0xFFC9D3E6),
    EntityKind.vm || EntityKind.service || EntityKind.site => const Color(0xFF3FC8FF),
    EntityKind.database || EntityKind.bucket || EntityKind.registry => const Color(0xFF8C7BFF),
    EntityKind.secret || EntityKind.identity => const Color(0xFFFFB347),
    EntityKind.queue || EntityKind.trigger || EntityKind.job => const Color(0xFF2EE6B6),
    EntityKind.network => const Color(0xFF2E9CE6),
    EntityKind.agent => const Color(0xFFE07CFF),
    EntityKind.repo => const Color(0xFF7FA4D9),
    EntityKind.external => const Color(0xFFE6ECF7),
  };

  static const owners = [
    Color(0xFF3FE0FF),
    Color(0xFFFF7AB6),
    Color(0xFFFFD166),
    Color(0xFF7CFFB2),
    Color(0xFFB89CFF),
    Color(0xFFFF9F43),
    Color(0xFF6BD3FF),
    Color(0xFFFF6B6B),
  ];

  static Color owner(String key) {
    if (key == 'third-party') return const Color(0xFFB8C2D6);
    if (key == 'shared') return const Color(0xFFFF6B6B);
    return owners[key.codeUnits.fold<int>(7, (a, b) => (a * 31 + b) & 0x7fffffff) % owners.length];
  }
}

/// The camera: yaw about the vertical axis, zoom (pixels per world unit),
/// and a pan in screen space.
class IsoCamera {
  IsoCamera({required this.yaw, required this.zoom, required this.pan, required this.center});
  final double yaw, zoom;
  final Offset pan;

  /// The world point at the middle of the viewport.
  final Offset center;

  static const _cos30 = 0.8660254, _sin30 = 0.5, _lift = 1.15;

  ({Offset p, double depth}) project(double x, double y, double z, Size view) {
    final dx = x - center.dx, dy = y - center.dy;
    final c = math.cos(yaw), s = math.sin(yaw);
    final rx = dx * c - dy * s, ry = dx * s + dy * c;
    return (
      p: Offset(view.width / 2 + pan.dx + (rx - ry) * _cos30 * zoom, view.height / 2 + pan.dy + ((rx + ry) * _sin30 - z * _lift) * zoom),
      depth: rx + ry,
    );
  }
}

/// A shape: an n-sided prism (a box when [w]/[d] are set), floating
/// [float] units up.
class _Shape {
  const _Shape({this.sides = 4, this.r = .4, this.w, this.d, required this.h, this.float = 0, this.turn = 0});
  final int sides;
  final double r, h, float, turn;
  final double? w, d;
}

_Shape _shape(EntityKind k) => switch (k) {
  EntityKind.host => const _Shape(w: 1.45, d: 1.0, h: .28),
  EntityKind.device => const _Shape(w: .34, d: .62, h: .07, float: .05),
  EntityKind.vm => const _Shape(w: .8, d: .8, h: .95),
  EntityKind.service => const _Shape(sides: 6, r: .44, h: .78),
  EntityKind.site => const _Shape(w: .78, d: .2, h: .62, float: .08),
  EntityKind.database => const _Shape(sides: 12, r: .4, h: .62),
  EntityKind.bucket => const _Shape(sides: 12, r: .38, h: .32),
  EntityKind.secret => const _Shape(w: .36, d: .36, h: .36),
  EntityKind.queue => const _Shape(w: .7, d: .26, h: .26),
  EntityKind.trigger => const _Shape(sides: 4, r: .26, h: .26, float: .35, turn: math.pi / 4),
  EntityKind.job => const _Shape(sides: 6, r: .28, h: .24),
  EntityKind.registry => const _Shape(w: .66, d: .66, h: .38),
  EntityKind.network => const _Shape(sides: 16, r: .62, h: .06),
  EntityKind.identity => const _Shape(w: .22, d: .22, h: .22),
  EntityKind.agent => const _Shape(sides: 6, r: .32, h: .44, float: .38),
  EntityKind.repo => const _Shape(w: .5, d: .5, h: .3),
  EntityKind.external => const _Shape(sides: 16, r: .5, h: .5, float: .1),
};

/// What the pointer can land on, front-most last.
class HitIndex {
  final hits = <({String id, Path path, double depth, Offset anchor})>[];
  String? at(Offset p) {
    for (final h in hits.reversed) {
      if (h.path.contains(p)) return h.id;
    }
    return null;
  }

  Offset? anchorOf(String id) => hits.where((h) => h.id == id).firstOrNull?.anchor;
}

class TopologyPainter extends CustomPainter {
  TopologyPainter({
    required this.graph,
    required this.from,
    required this.to,
    required this.morph,
    required this.camera,
    required this.pulse,
    required this.hits,
    required this.labels,
    this.hovered,
    this.selected,
    this.query = '',
    this.mono,
    this.district,
  }) : super(repaint: Listenable.merge([pulse, morph]));

  final TopoGraph graph;

  /// The layouts animated between, and how far along ([t], 0–1).
  final TopoLayout from, to;
  final Animation<double> morph;
  double get t => morph.value;
  final String? mono;

  /// Which district an entity is drawn in (links across districts are
  /// only drawn on focus).
  final String Function(TopoEntity e)? district;
  final IsoCamera camera;
  final Animation<double> pulse;
  final HitIndex hits;
  final Map<String, TextPainter> labels;
  final String? hovered, selected;
  final String query;

  static double _ease(double t) => Curves.easeInOutCubic.transform(t.clamp(0, 1));

  Offset? _pos(String id) {
    final b = to.positions[id];
    if (b == null) return null;
    final a = from.positions[id];
    return a == null ? b : Offset.lerp(a, b, _ease(t));
  }

  Rect _zoneRect(ZoneBox z) {
    final old = from.zones.where((x) => x.key == z.key).firstOrNull;
    return old == null ? z.rect : Rect.lerp(old.rect, z.rect, _ease(t))!;
  }

  TextPainter _text(String s, TextStyle style) {
    final key = '${style.fontSize}|${style.color?.toARGB32()}|${style.fontWeight?.value}|$s';
    return labels.putIfAbsent(key, () => TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr)..layout());
  }

  @override
  void paint(Canvas canvas, Size size) {
    hits.hits.clear();
    final phase = pulse.value;
    _grid(canvas, size);
    final byId = {for (final e in graph.entities) e.id: e};
    final focus = selected ?? hovered;
    final neighbours = <String>{
      ?focus,
      if (focus != null)
        for (final l in graph.links)
          if (l.from == focus) l.to else if (l.to == focus) l.from,
    };
    final q = query.trim().toLowerCase();
    bool matches(TopoEntity e) => q.isEmpty || e.label.toLowerCase().contains(q) || e.type.toLowerCase().contains(q);

    // Districts first, then the fences inside them.
    for (final z in to.zones.where((z) => z.outer)) {
      _zone(canvas, size, z, phase);
    }
    for (final z in to.zones.where((z) => !z.outer)) {
      _fence(canvas, size, z, phase);
    }

    // Entities back to front.
    final order = [
      for (final e in graph.entities)
        if (_pos(e.id) case final p?) (e: e, p: p, depth: camera.project(p.dx, p.dy, 0, size).depth),
    ]..sort((a, b) => a.depth.compareTo(b.depth));
    final appear = _ease(t);
    for (final o in order) {
      final isNew = !from.positions.containsKey(o.e.id);
      final dim = (focus != null && !neighbours.contains(o.e.id)) || !matches(o.e);
      _entity(canvas, size, o.e, o.p, phase, scale: isNew ? appear : 1, dim: dim, focus: o.e.id == focus);
    }

    // Links over everything, brightest for the one in focus.
    for (final l in graph.links) {
      final a = _pos(l.from), b = _pos(l.to);
      final ea = byId[l.from], eb = byId[l.to];
      if (a == null || b == null || ea == null || eb == null) continue;
      final lit = focus != null && (l.from == focus || l.to == focus);
      // Code links are many, and links between districts cross the whole
      // map: both show only for the entity in focus.
      if (!lit && (ea.kind == EntityKind.repo || eb.kind == EntityKind.repo)) continue;
      if (!lit && district != null && district!(ea) != district!(eb)) continue;
      _link(canvas, size, a, b, ea, eb, phase, lit: lit, faded: focus != null && !lit);
    }

    // Labels on top.
    for (final o in order) {
      final e = o.e;
      final landmark = e.kind == EntityKind.host || e.kind == EntityKind.device;
      final show = e.id == focus ||
          (focus != null && neighbours.contains(e.id)) ||
          (q.isNotEmpty && matches(e)) ||
          (landmark && camera.zoom > 14) ||
          ((e.kind == EntityKind.external || e.kind == EntityKind.agent) && camera.zoom > 40) ||
          camera.zoom > 54;
      if (!show) continue;
      final s = _shape(e.kind);
      final top = camera.project(o.p.dx, o.p.dy, s.float + s.h + .55, size).p;
      final focused = e.id == focus;
      final tp = _text(e.label, TextStyle(
        fontFamily: mono,
        fontSize: focused ? 12.5 : 10.5,
        fontWeight: focused ? FontWeight.w700 : FontWeight.w500,
        color: focused ? Colors.white : Holo.text.withValues(alpha: (focus != null && !neighbours.contains(e.id)) ? .25 : .82),
        letterSpacing: .4,
      ));
      final at = top - Offset(tp.width / 2, tp.height);
      if (focused) {
        canvas.drawRRect(
          RRect.fromRectAndRadius((at - const Offset(6, 3)) & Size(tp.width + 12, tp.height + 6), const Radius.circular(4)),
          Paint()..color = Holo.bg0.withValues(alpha: .8),
        );
      }
      tp.paint(canvas, at);
    }
  }

  void _grid(Canvas canvas, Size size) {
    final b = to.bounds.inflate(10);
    if (b.isEmpty) return;
    final paint = Paint()
      ..color = Holo.grid.withValues(alpha: .55)
      ..strokeWidth = .7;
    const step = 2.0;
    for (var x = (b.left / step).floor() * step; x <= b.right; x += step) {
      canvas.drawLine(camera.project(x, b.top, 0, size).p, camera.project(x, b.bottom, 0, size).p, paint);
    }
    for (var y = (b.top / step).floor() * step; y <= b.bottom; y += step) {
      canvas.drawLine(camera.project(b.left, y, 0, size).p, camera.project(b.right, y, 0, size).p, paint);
    }
  }

  Path _poly(List<Offset> pts) => Path()..addPolygon(pts, true);

  List<Offset> _rectAt(Rect r, double z, Size size) => [
    camera.project(r.left, r.top, z, size).p,
    camera.project(r.right, r.top, z, size).p,
    camera.project(r.right, r.bottom, z, size).p,
    camera.project(r.left, r.bottom, z, size).p,
  ];

  /// The screen-topmost corner of a rect (where its label goes).
  Offset _topCorner(Rect r, double z, Size size) =>
      (_rectAt(r, z, size)..sort((a, b) => a.dy.compareTo(b.dy))).first;

  void _zone(Canvas canvas, Size size, ZoneBox z, double phase) {
    final r = _zoneRect(z);
    final color = Holo.boundary(z.boundary);
    final base = _rectAt(r, 0, size);
    // A slab: dark top with a faint tint, and a glowing rim.
    canvas.drawPath(_poly(base), Paint()..color = Color.lerp(Holo.bg1, color, .06)!.withValues(alpha: .92));
    canvas.drawPath(
      _poly(base),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = color.withValues(alpha: .38)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
    );
    canvas.drawPath(_poly(base), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8
      ..color = color.withValues(alpha: .55));
    // Corner brackets.
    for (final c in base) {
      canvas.drawCircle(c, 2.2, Paint()..color = color.withValues(alpha: .8));
    }
    final at = _topCorner(r, 0, size);
    final title = _text(z.label.toUpperCase(), TextStyle(
      fontFamily: mono,
      fontSize: 13,
      fontWeight: FontWeight.w700,
      letterSpacing: 2.2,
      color: color.withValues(alpha: .95),
    ));
    final sub = _text(
      [
        '${z.count} entities',
        if (z.public > 0) '${z.public} public',
        if (z.bad > 0) '${z.bad} down',
        if (z.warn > 0) '${z.warn} degraded',
      ].join('  ·  '),
      TextStyle(fontFamily: mono, fontSize: 10, color: Holo.dim, letterSpacing: .6),
    );
    title.paint(canvas, at + Offset(-title.width / 2, -title.height - sub.height - 10));
    if (camera.zoom >= 12) sub.paint(canvas, at + Offset(-sub.width / 2, -sub.height - 7));
    if (z.bad > 0) {
      final glow = .4 + .6 * (0.5 + 0.5 * math.sin(phase * math.pi * 2 * 2));
      canvas.drawCircle(at + Offset(title.width / 2 + 10, -sub.height - title.height / 2 - 10), 3.5,
          Paint()..color = Holo.health(Health.bad).withValues(alpha: glow));
    }
  }

  void _fence(Canvas canvas, Size size, ZoneBox z, double phase) {
    final r = _zoneRect(z).deflate(.05);
    final color = Holo.boundary(z.boundary);
    const wall = .42;
    final base = _rectAt(r, .02, size);
    final top = _rectAt(r, wall, size);
    canvas.drawPath(_poly(base), Paint()..color = color.withValues(alpha: .07));
    // Translucent walls with a bright top rail: a force-field fence.
    for (var i = 0; i < 4; i++) {
      final j = (i + 1) % 4;
      final quad = _poly([base[i], base[j], top[j], top[i]]);
      canvas.drawPath(
        quad,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(0, base[i].dy),
            Offset(0, top[i].dy),
            [color.withValues(alpha: .14), color.withValues(alpha: .02)],
          ),
      );
    }
    final rail = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withValues(alpha: .65);
    canvas.drawPath(_poly(top), rail);
    // A light runs along the rail.
    final run = (phase + z.key.hashCode % 100 / 100) % 1;
    final edge = (run * 4).floor(), f = run * 4 - edge;
    final p = Offset.lerp(top[edge], top[(edge + 1) % 4], f)!;
    canvas.drawCircle(p, 2.4, Paint()
      ..color = color
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    // Dashed ground line.
    final dash = Paint()
      ..strokeWidth = .8
      ..color = color.withValues(alpha: .4);
    for (var i = 0; i < 4; i++) {
      final a = base[i], b = base[(i + 1) % 4];
      final n = ((b - a).distance / 7).floor();
      for (var k = 0; k < n; k += 2) {
        canvas.drawLine(Offset.lerp(a, b, k / n)!, Offset.lerp(a, b, (k + 1) / n)!, dash);
      }
    }
    if (camera.zoom < 16) return;
    final corners = _rectAt(r, wall, size)..sort((a, b) => a.dy.compareTo(b.dy));
    // Along the far edge, left of the district's title corner.
    final far = corners[0].dx < corners[1].dx ? corners[0] : corners[1];
    final at = Offset.lerp(corners[0], corners[1], .5)! * .5 + far * .5;
    final tp = _text(
      '${z.label.toUpperCase()}${z.bad > 0 ? '  ▲${z.bad}' : ''}',
      TextStyle(fontFamily: mono, fontSize: 9.5, fontWeight: FontWeight.w700, letterSpacing: 1.6, color: color.withValues(alpha: .9)),
    );
    tp.paint(canvas, at + Offset(-tp.width / 2, -tp.height - 4));
  }

  void _entity(Canvas canvas, Size size, TopoEntity e, Offset c, double phase,
      {required double scale, required bool dim, required bool focus}) {
    if (scale <= 0.01) return;
    final s = _shape(e.kind);
    final color = Holo.kind(e.kind);
    final alpha = dim ? .22 : 1.0;
    final ring = <Offset>[];
    if (s.w != null) {
      final w = s.w! / 2 * scale, d = s.d! / 2 * scale;
      ring.addAll([Offset(-w, -d), Offset(w, -d), Offset(w, d), Offset(-w, d)]);
    } else {
      for (var i = 0; i < s.sides; i++) {
        final a = s.turn + i * 2 * math.pi / s.sides;
        ring.add(Offset(math.cos(a), math.sin(a)) * s.r * scale);
      }
    }
    final z0 = s.float * scale, z1 = z0 + s.h * scale;
    final bottom = [for (final o in ring) camera.project(c.dx + o.dx, c.dy + o.dy, z0, size)];
    final top = [for (final o in ring) camera.project(c.dx + o.dx, c.dy + o.dy, z1, size)];

    // Owner footprint: a ring on the ground in the owner's colour.
    final foot = [
      for (var i = 0; i < 20; i++)
        camera.project(c.dx + math.cos(i * math.pi / 10) * footprint(e.kind) * .5 * scale,
            c.dy + math.sin(i * math.pi / 10) * footprint(e.kind) * .5 * scale, 0, size).p,
    ];
    canvas.drawPath(_poly(foot), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = focus ? 1.6 : .9
      ..color = Holo.owner(e.owner).withValues(alpha: .55 * alpha));
    if (e.public) {
      final pr = .5 + .5 * math.sin(phase * math.pi * 2);
      canvas.drawPath(_poly(foot), Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..color = Holo.boundary(Boundary.public).withValues(alpha: (.25 + .35 * pr) * alpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    }
    if (s.float > 0) {
      // A light beam down to the ground for floating shapes.
      final g = camera.project(c.dx, c.dy, 0, size).p;
      canvas.drawLine(g, camera.project(c.dx, c.dy, z0, size).p,
          Paint()..color = color.withValues(alpha: .25 * alpha)..strokeWidth = 1);
    }

    // Sides, back to front; light comes from the upper left.
    final sides = <({Path path, double depth, double shade})>[];
    for (var i = 0; i < ring.length; i++) {
      final j = (i + 1) % ring.length;
      final mid = (ring[i] + ring[j]) / 2;
      final normal = Offset(mid.dx, mid.dy);
      final ang = math.atan2(normal.dy, normal.dx) + camera.yaw;
      sides.add((
        path: _poly([bottom[i].p, bottom[j].p, top[j].p, top[i].p]),
        depth: (bottom[i].depth + bottom[j].depth) / 2,
        shade: .35 + .35 * (0.5 + 0.5 * math.cos(ang - math.pi * .25)),
      ));
    }
    sides.sort((a, b) => a.depth.compareTo(b.depth));
    final virtualAlpha = e.physical ? 1.0 : .62;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = focus ? 1.4 : .8
      ..color = (focus ? Colors.white : color).withValues(alpha: (e.physical ? .5 : .9) * alpha);
    final hull = Path();
    for (final f in sides) {
      final fill = Color.lerp(Holo.bg0, color, f.shade)!;
      canvas.drawPath(f.path, Paint()..color = fill.withValues(alpha: virtualAlpha * alpha));
      canvas.drawPath(f.path, outline);
      hull.addPath(f.path, Offset.zero);
    }
    final topPath = _poly([for (final p in top) p.p]);
    canvas.drawPath(
      topPath,
      Paint()
        ..shader = ui.Gradient.linear(
          top.first.p,
          top[top.length ~/ 2].p,
          [
            Color.lerp(color, Colors.white, e.physical ? .45 : .25)!.withValues(alpha: (e.physical ? 1 : .8) * alpha),
            color.withValues(alpha: (e.physical ? .95 : .6) * alpha),
          ],
        ),
    );
    canvas.drawPath(topPath, outline);
    hull.addPath(topPath, Offset.zero);
    if (focus) {
      canvas.drawPath(hull, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Holo.cyan.withValues(alpha: .7)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
    }
    if (e.physical) {
      // A screen-like inset on hosts and devices.
      final inset = [for (final p in top) Offset.lerp(p.p, _centroid(top.map((x) => x.p).toList()), .28)!];
      canvas.drawPath(_poly(inset), Paint()..color = Holo.bg0.withValues(alpha: .55 * alpha));
      canvas.drawPath(_poly(inset), Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .8
        ..color = Holo.cyan.withValues(alpha: .6 * alpha));
    }

    // Health beacon above the shape.
    if (e.health != Health.unknown) {
      final hc = Holo.health(e.health);
      final b = camera.project(c.dx, c.dy, z1 + .22, size).p;
      final beat = e.health == Health.bad ? .5 + .5 * math.sin(phase * math.pi * 2 * 3) : 1.0;
      final r = (focus ? 4.2 : 3.2) * (camera.zoom / 34).clamp(.7, 1.4);
      canvas.drawCircle(b, r * 2.2, Paint()
        ..color = hc.withValues(alpha: .28 * beat * alpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
      canvas.drawPath(
        _poly([b + Offset(0, -r), b + Offset(r * .8, 0), b + Offset(0, r), b + Offset(-r * .8, 0)]),
        Paint()..color = hc.withValues(alpha: (.55 + .45 * beat) * alpha),
      );
    }

    // Hit area: the shape and a little around it.
    final anchor = camera.project(c.dx, c.dy, z1, size).p;
    hits.hits.add((id: e.id, path: hull..addPath(_poly(foot), Offset.zero), depth: bottom.first.depth, anchor: anchor));
  }

  Offset _centroid(List<Offset> pts) => pts.reduce((a, b) => a + b) / pts.length.toDouble();

  void _link(Canvas canvas, Size size, Offset a, Offset b, TopoEntity ea, TopoEntity eb, double phase,
      {required bool lit, required bool faded}) {
    final sa = _shape(ea.kind), sb = _shape(eb.kind);
    final p0 = camera.project(a.dx, a.dy, sa.float + sa.h, size).p;
    final p2 = camera.project(b.dx, b.dy, sb.float + sb.h, size).p;
    final lift = ((a - b).distance * .22 + .6).clamp(.6, 6.0);
    final mid = camera.project((a.dx + b.dx) / 2, (a.dy + b.dy) / 2, math.max(sa.float + sa.h, sb.float + sb.h) + lift, size).p;
    final path = Path()
      ..moveTo(p0.dx, p0.dy)
      ..quadraticBezierTo(mid.dx, mid.dy, p2.dx, p2.dy);
    final color = lit ? Holo.cyan : Holo.cyan.withValues(alpha: faded ? .06 : .22);
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = lit ? 1.6 : .9
      ..color = color);
    if (lit) {
      canvas.drawPath(path, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = Holo.cyan.withValues(alpha: .18)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    }
    if (faded) return;
    // Packets travelling from source to target.
    for (final k in lit ? const [0.0, .33, .66] : const [0.0]) {
      final u = (phase + k + (ea.id.hashCode % 97) / 97) % 1;
      final q = _quad(p0, mid, p2, u);
      canvas.drawCircle(q, lit ? 2.6 : 1.6, Paint()
        ..color = (lit ? Colors.white : Holo.cyan).withValues(alpha: lit ? .95 : .55)
        ..maskFilter = lit ? const MaskFilter.blur(BlurStyle.normal, 1.5) : null);
    }
  }

  Offset _quad(Offset a, Offset c, Offset b, double u) => a * ((1 - u) * (1 - u)) + c * (2 * (1 - u) * u) + b * (u * u);

  @override
  bool shouldRepaint(TopologyPainter old) => true;
}
