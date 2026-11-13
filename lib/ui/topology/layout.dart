import 'dart:math' as math;
import 'dart:ui';

import 'graph.dart';

/// A fenced area on the ground plane: a district (outer) or a fence inside
/// one (inner).
class ZoneBox {
  ZoneBox({
    required this.key,
    required this.label,
    required this.rect,
    required this.outer,
    this.boundary,
    this.count = 0,
    this.bad = 0,
    this.warn = 0,
    this.public = 0,
  });
  final String key;
  final String label;
  final Rect rect;
  final bool outer;

  /// Set when the area is a security boundary (its fence colour).
  final Boundary? boundary;
  final int count, bad, warn, public;
}

/// Where everything sits, in world units on the ground plane.
class TopoLayout {
  TopoLayout(this.positions, this.zones, this.bounds);
  final Map<String, Offset> positions;
  final List<ZoneBox> zones;
  final Rect bounds;

  static final empty = TopoLayout(const {}, const [], Rect.zero);
}

/// The district small code-only projects share.
const sideKey = '~side';

/// How much ground an entity needs (diameter, world units).
double footprint(EntityKind k) => switch (k) {
  EntityKind.host => 1.8,
  EntityKind.external => 1.3,
  EntityKind.network => 1.4,
  EntityKind.vm => 1.1,
  EntityKind.service || EntityKind.site || EntityKind.database || EntityKind.registry => 1.0,
  EntityKind.bucket || EntityKind.agent || EntityKind.queue || EntityKind.device => 0.9,
  EntityKind.repo => 0.8,
  EntityKind.secret || EntityKind.trigger || EntityKind.job => 0.7,
  EntityKind.identity => 0.5,
};

int _kindRank(EntityKind k) => switch (k) {
  EntityKind.host => 0,
  EntityKind.device => 1,
  EntityKind.external => 2,
  EntityKind.site => 3,
  EntityKind.service => 4,
  EntityKind.vm => 5,
  EntityKind.agent => 6,
  EntityKind.database => 7,
  EntityKind.bucket => 8,
  EntityKind.queue => 9,
  EntityKind.trigger => 10,
  EntityKind.job => 11,
  EntityKind.registry => 12,
  EntityKind.network => 13,
  EntityKind.secret => 14,
  EntityKind.identity => 15,
  EntityKind.repo => 16,
};

String outerKey(TopoEntity e, GroupBy g) => switch (g) {
  GroupBy.project => e.project,
  GroupBy.boundary => e.boundary.name,
  GroupBy.owner => e.owner,
};

String outerLabel(TopoEntity e, GroupBy g) => switch (g) {
  GroupBy.project => e.projectName,
  GroupBy.boundary => e.boundary.label,
  GroupBy.owner => e.ownerName,
};

/// Districts, then fences inside them, then entities on a grid in each
/// fence. Districts and fences are packed in rows (largest first) so the
/// estate reads as one city.
TopoLayout layoutTopology(List<TopoEntity> entities, GroupBy by) {
  if (entities.isEmpty) return TopoLayout.empty;
  // Small code-only projects (a repo or two, nothing deployed) share one
  // district so the real estate is not lost among them.
  final famSize = <String, int>{};
  final famDeployed = <String>{};
  for (final e in entities) {
    famSize[e.project] = (famSize[e.project] ?? 0) + 1;
    if (e.kind != EntityKind.repo) famDeployed.add(e.project);
  }
  bool side(TopoEntity e) =>
      by == GroupBy.project && e.project != 'va' && e.project != 'external' && !famDeployed.contains(e.project) && famSize[e.project]! <= 2;
  String oKey(TopoEntity e) => side(e) ? sideKey : outerKey(e, by);
  String oLabel(TopoEntity e) => side(e) ? 'Side projects & archives' : outerLabel(e, by);

  // Inner grouping: the boundary within a project or owner; the project
  // within a boundary (and within the side-projects district).
  String innerKey(TopoEntity e) => by == GroupBy.boundary || side(e) ? 'p:${e.project}' : e.boundary.name;
  String innerLabel(TopoEntity e) => by == GroupBy.boundary || side(e) ? e.projectName : e.boundary.label;

  final outer = <String, Map<String, List<TopoEntity>>>{};
  final outerNames = <String, String>{};
  final innerNames = <String, String>{};
  for (final e in entities) {
    final o = oKey(e);
    outerNames[o] = oLabel(e);
    innerNames[innerKey(e)] = innerLabel(e);
    ((outer[o] ??= {})[innerKey(e)] ??= []).add(e);
  }

  int outerRank(String k) => switch (by) {
    GroupBy.project => k == 'va' ? -1 : (k == 'external' ? 1 << 20 : (k == sideKey ? 1 << 19 : 0)),
    GroupBy.boundary => Boundary.values.indexWhere((b) => b.name == k),
    GroupBy.owner => switch (k) {
      vaOwner => -3,
      'you' => -2,
      personalOwner => -1,
      'shared' => 1 << 18,
      'local' => 1 << 19,
      'third-party' => 1 << 20,
      _ => 0,
    },
  };
  int innerRank(String k) => k.startsWith('p:')
      ? (k == 'p:va' ? -1 : 0)
      : Boundary.values.indexWhere((b) => b.name == k);

  const pad = 0.7, header = 1.1, gap = 0.8, zoneGap = 2.6;
  final positions = <String, Offset>{};
  final zones = <ZoneBox>[];

  // Size each fence; lay its entities out relative to its corner.
  final fenceSizes = <String, Map<String, Size>>{};
  final local = <String, Offset>{};
  for (final MapEntry(key: o, value: inners) in outer.entries) {
    for (final MapEntry(key: i, value: list) in inners.entries) {
      list.sort((a, b) {
        final r = _kindRank(a.kind).compareTo(_kindRank(b.kind));
        return r != 0 ? r : a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
      final cell = list.map((e) => footprint(e.kind)).reduce(math.max) + 0.35;
      final cols = math.max(1, math.sqrt(list.length * 1.4).ceil());
      final rows = (list.length / cols).ceil();
      for (final (n, e) in list.indexed) {
        local[e.id] = Offset(pad + (n % cols + .5) * cell, header + pad * .5 + (n ~/ cols + .5) * cell);
      }
      (fenceSizes[o] ??= {})[i] = Size(cols * cell + pad * 2, rows * cell + header + pad * 1.5);
    }
  }

  // Shelf-pack [sizes] into rows about [width] wide; returns each corner.
  Map<String, Offset> pack(Map<String, Size> sizes, double space, int Function(String) rank) {
    final keys = sizes.keys.toList()
      ..sort((a, b) {
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : (sizes[b]!.width * sizes[b]!.height).compareTo(sizes[a]!.width * sizes[a]!.height);
      });
    final area = sizes.values.fold<double>(0, (s, z) => s + (z.width + space) * (z.height + space));
    final widest = sizes.values.map((s) => s.width).reduce(math.max);
    final width = math.max(widest, math.sqrt(area) * 1.15);
    final out = <String, Offset>{};
    var x = 0.0, y = 0.0, rowH = 0.0;
    for (final k in keys) {
      final s = sizes[k]!;
      if (x > 0 && x + s.width > width) {
        x = 0;
        y += rowH + space;
        rowH = 0;
      }
      out[k] = Offset(x, y);
      x += s.width + space;
      rowH = math.max(rowH, s.height);
    }
    return out;
  }

  // Districts: their fences packed inside.
  final districtSizes = <String, Size>{};
  final fenceCorners = <String, Map<String, Offset>>{};
  for (final o in outer.keys) {
    final corners = pack(fenceSizes[o]!, gap, innerRank);
    fenceCorners[o] = corners;
    var w = 0.0, h = 0.0;
    for (final MapEntry(key: i, value: c) in corners.entries) {
      w = math.max(w, c.dx + fenceSizes[o]![i]!.width);
      h = math.max(h, c.dy + fenceSizes[o]![i]!.height);
    }
    districtSizes[o] = Size(w + pad * 2, h + header * 1.6 + pad);
  }
  final districtCorners = pack(districtSizes, zoneGap, outerRank);

  var bounds = Rect.zero;
  for (final o in outer.keys) {
    final dc = districtCorners[o]!;
    final dRect = dc & districtSizes[o]!;
    bounds = bounds == Rect.zero ? dRect : bounds.expandToInclude(dRect);
    final all = outer[o]!.values.expand((l) => l).toList();
    zones.add(ZoneBox(
      key: o,
      label: outerNames[o]!,
      rect: dRect,
      outer: true,
      boundary: by == GroupBy.boundary ? Boundary.values.byName(o) : (o == sideKey ? Boundary.local : null),
      count: all.length,
      bad: all.where((e) => e.health == Health.bad).length,
      warn: all.where((e) => e.health == Health.warn).length,
      public: all.where((e) => e.public).length,
    ));
    for (final MapEntry(key: i, value: list) in outer[o]!.entries) {
      final fc = dc + Offset(pad, header * 1.6) + fenceCorners[o]![i]!;
      zones.add(ZoneBox(
        key: '$o/$i',
        label: innerNames[i]!,
        rect: fc & fenceSizes[o]![i]!,
        outer: false,
        boundary: i.startsWith('p:') ? null : Boundary.values.byName(i),
        count: list.length,
        bad: list.where((e) => e.health == Health.bad).length,
        warn: list.where((e) => e.health == Health.warn).length,
        public: list.where((e) => e.public).length,
      ));
      for (final e in list) {
        positions[e.id] = fc + local[e.id]!;
      }
    }
  }
  return TopoLayout(positions, zones, bounds);
}
