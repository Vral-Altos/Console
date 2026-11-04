import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// A small line of recent values (nulls are gaps), scaled to [max] (or the
/// data's own maximum).
class Sparkline extends StatelessWidget {
  const Sparkline({super.key, required this.values, this.color, this.height = 36, this.max});
  final List<double?> values;
  final Color? color;
  final double height;
  final double? max;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    width: double.infinity,
    child: CustomPaint(
      painter: _SparkPainter(
        values,
        color ?? Theme.of(context).colorScheme.primary,
        max,
      ),
    ),
  );
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.color, this.max);
  final List<double?> values;
  final Color color;
  final double? max;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = values.whereType<double>();
    if (values.length < 2 || pts.isEmpty) return;
    final top = max ?? math.max(pts.reduce(math.max), 1e-9);
    final dx = size.width / (values.length - 1);
    final line = Path();
    final fill = Path();
    var open = false;
    Offset? last;
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v == null) {
        if (open && last != null) {
          fill
            ..lineTo(last.dx, size.height)
            ..close();
        }
        open = false;
        continue;
      }
      final p = Offset(i * dx, size.height - (v / top).clamp(0, 1) * (size.height - 2) - 1);
      if (!open) {
        line.moveTo(p.dx, p.dy);
        fill
          ..moveTo(p.dx, size.height)
          ..lineTo(p.dx, p.dy);
        open = true;
      } else {
        line.lineTo(p.dx, p.dy);
        fill.lineTo(p.dx, p.dy);
      }
      last = p;
    }
    if (open && last != null) {
      fill
        ..lineTo(last.dx, size.height)
        ..close();
    }
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: .22), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    if (last != null) canvas.drawCircle(last, 2.6, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.values != values || old.color != color || old.max != max;
}

/// A ring showing a fraction, with a label in the middle.
class RingGauge extends StatelessWidget {
  const RingGauge({super.key, required this.value, required this.label, this.caption, this.size = 74});
  final double? value;
  final String label;
  final String? caption;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final v = (value ?? 0).clamp(0.0, 1.0);
    final color = value == null
        ? t.faint
        : v >= .9
            ? t.bad
            : v >= .75
                ? t.warn
                : Theme.of(context).colorScheme.primary;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: size,
        height: size,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: v),
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOutCubic,
          builder: (context, a, _) => CustomPaint(
            painter: _RingPainter(a, color, t.sunken),
            child: Center(
              child: Text(
                value == null ? '—' : '${(v * 100).round()}%',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(fontFamily: t.mono, fontSize: size * .19),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 6),
      Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
      if (caption != null)
        Text(caption!, style: Theme.of(context).textTheme.labelSmall, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
    ]);
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.v, this.color, this.track);
  final double v;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * .1;
    final rect = Rect.fromLTWH(stroke / 2, stroke / 2, size.width - stroke, size.height - stroke);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, math.pi * 2, false, base..color = track);
    if (v > 0) canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * v, false, base..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.v != v || old.color != color;
}

/// One bar of a [BarChart].
typedef Bar = ({String label, double value, String detail});

/// Vertical bars with a hover / tap read-out. The last bar is emphasised
/// (usually "today").
class BarChart extends StatefulWidget {
  const BarChart({super.key, required this.bars, this.height = 150, this.color, this.format});
  final List<Bar> bars;
  final double height;
  final Color? color;
  final String Function(double v)? format;

  @override
  State<BarChart> createState() => _BarChartState();
}

class _BarChartState extends State<BarChart> {
  int? _hover;

  int? _indexAt(Offset p, double width) {
    if (widget.bars.isEmpty) return null;
    final i = (p.dx / width * widget.bars.length).floor();
    return i.clamp(0, widget.bars.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    final text = Theme.of(context).textTheme;
    final shown = _hover ?? (widget.bars.isEmpty ? null : widget.bars.length - 1);
    final fmt = widget.format ?? (v) => v.toStringAsFixed(0);
    final top = widget.bars.isEmpty ? 1.0 : math.max(widget.bars.map((b) => b.value).reduce(math.max), 1e-9);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        height: 44,
        child: shown == null
            ? const SizedBox.shrink()
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(fmt(widget.bars[shown].value), maxLines: 1, style: text.titleMedium?.copyWith(fontFamily: t.mono)),
                Text(widget.bars[shown].detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.labelSmall),
              ]),
      ),
      const SizedBox(height: 8),
      LayoutBuilder(builder: (context, c) {
        return MouseRegion(
          onHover: (e) => setState(() => _hover = _indexAt(e.localPosition, c.maxWidth)),
          onExit: (_) => setState(() => _hover = null),
          child: GestureDetector(
            onTapDown: (e) => setState(() => _hover = _indexAt(e.localPosition, c.maxWidth)),
            onHorizontalDragUpdate: (e) => setState(() => _hover = _indexAt(e.localPosition, c.maxWidth)),
            child: SizedBox(
              height: widget.height,
              width: c.maxWidth,
              child: CustomPaint(
                painter: _BarPainter(
                  values: [for (final b in widget.bars) b.value / top],
                  color: color,
                  muted: color.withValues(alpha: .35),
                  grid: t.border,
                  selected: shown,
                ),
              ),
            ),
          ),
        );
      }),
      const SizedBox(height: 6),
      if (widget.bars.isNotEmpty)
        Row(children: [
          Text(widget.bars.first.label, style: text.labelSmall),
          const Spacer(),
          if (widget.bars.length > 2) Text(widget.bars[widget.bars.length ~/ 2].label, style: text.labelSmall),
          const Spacer(),
          Text(widget.bars.last.label, style: text.labelSmall),
        ]),
    ]);
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({required this.values, required this.color, required this.muted, required this.grid, this.selected});
  final List<double> values;
  final Color color;
  final Color muted;
  final Color grid;
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final g = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final f in [0.0, .5, 1.0]) {
      final y = size.height - f * (size.height - 1) - .5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), g);
    }
    if (values.isEmpty) return;
    final slot = size.width / values.length;
    final w = math.max(2.0, math.min(28.0, slot * .62));
    for (var i = 0; i < values.length; i++) {
      final h = math.max(values[i] > 0 ? 2.0 : 0.0, values[i] * (size.height - 4));
      final x = i * slot + (slot - w) / 2;
      final r = RRect.fromRectAndCorners(
        Rect.fromLTWH(x, size.height - h, w, h),
        topLeft: const Radius.circular(4),
        topRight: const Radius.circular(4),
      );
      canvas.drawRRect(r, Paint()..color = i == selected ? color : muted);
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.values != values || old.selected != selected || old.color != color;
}

/// Month-to-date spend: a line over the days of the month, with dashed
/// guides at [marks] (e.g. the S$15 target and the budget).
class SpendChart extends StatelessWidget {
  const SpendChart({
    super.key,
    required this.points,
    required this.daysInMonth,
    required this.marks,
    this.height = 160,
  });

  /// (day of month, cumulative cost).
  final List<(int, double)> points;
  final int daysInMonth;
  final List<({double value, String label})> marks;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SpendPainter(
          points,
          daysInMonth,
          marks,
          Theme.of(context).colorScheme.primary,
          t.border,
          t.muted,
          Theme.of(context).textTheme.labelSmall!,
        ),
      ),
    );
  }
}

class _SpendPainter extends CustomPainter {
  _SpendPainter(this.points, this.days, this.marks, this.color, this.grid, this.muted, this.label);
  final List<(int, double)> points;
  final int days;
  final List<({double value, String label})> marks;
  final Color color;
  final Color grid;
  final Color muted;
  final TextStyle label;

  @override
  void paint(Canvas canvas, Size size) {
    final spent = points.isEmpty ? 0.0 : points.map((p) => p.$2).reduce(math.max);
    final first = marks.isEmpty ? 0.0 : marks.map((m) => m.value).reduce(math.min);
    final top = math.max(math.max(spent, first), 1e-9) * 1.15;
    double y(double v) => size.height - (v / top) * (size.height - 8) - 4;
    double x(int day) => (day - 1) / math.max(1, days - 1) * size.width;
    canvas.drawLine(Offset(0, size.height - .5), Offset(size.width, size.height - .5), Paint()..color = grid);
    for (final m in marks.where((m) => m.value <= top)) {
      final yy = y(m.value);
      final dash = Paint()
        ..color = muted.withValues(alpha: .6)
        ..strokeWidth = 1;
      for (var xx = 0.0; xx < size.width; xx += 8) {
        canvas.drawLine(Offset(xx, yy), Offset(math.min(xx + 4, size.width), yy), dash);
      }
      final tp = TextPainter(text: TextSpan(text: m.label, style: label.copyWith(color: muted)), textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, Offset(size.width - tp.width, yy - tp.height - 2));
    }
    if (points.isEmpty) return;
    final path = Path()..moveTo(x(points.first.$1), y(points.first.$2));
    for (final p in points.skip(1)) {
      path.lineTo(x(p.$1), y(p.$2));
    }
    final fill = Path.from(path)
      ..lineTo(x(points.last.$1), size.height)
      ..lineTo(x(points.first.$1), size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: .2), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    for (final p in points) {
      canvas.drawCircle(Offset(x(p.$1), y(p.$2)), 2.5, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_SpendPainter old) => old.points != points || old.marks != marks || old.color != color;
}

/// One line or stack of a [TimeChart].
typedef Series = ({String name, Color color, List<double?> values});

/// Values over time in equal buckets from [from]: lines, or stacked bars
/// ([stacked]); hover or tap reads out a bucket.
class TimeChart extends StatefulWidget {
  const TimeChart({
    super.key,
    required this.series,
    required this.from,
    required this.bucket,
    this.stacked = false,
    this.height = 150,
    this.format,
    this.max,
  });

  final List<Series> series;
  final DateTime from;
  final Duration bucket;
  final bool stacked;
  final double height;
  final String Function(double v)? format;

  /// A fixed top of the scale (e.g. 1 for fractions).
  final double? max;

  @override
  State<TimeChart> createState() => _TimeChartState();
}

class _TimeChartState extends State<TimeChart> {
  int? _hover;

  int get _n => widget.series.isEmpty ? 0 : widget.series.first.values.length;

  String _time(BuildContext context, DateTime t) {
    final l = t.toLocal();
    final hm = TimeOfDay.fromDateTime(l).format(context);
    return widget.bucket >= const Duration(hours: 4) || DateTime.now().difference(t) > const Duration(hours: 24)
        ? '${l.day}/${l.month} $hm'
        : hm;
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final fmt = widget.format ?? (v) => v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2);
    double top = widget.max ?? 0;
    if (widget.max == null) {
      for (var i = 0; i < _n; i++) {
        if (widget.stacked) {
          top = math.max(top, widget.series.fold<double>(0, (a, s) => a + (s.values[i] ?? 0)));
        } else {
          for (final s in widget.series) {
            top = math.max(top, s.values[i] ?? 0);
          }
        }
      }
    }
    if (top <= 0) top = 1;
    final shown = _hover;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: 34,
        child: Wrap(spacing: 12, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (shown != null)
            Text(_time(context, widget.from.add(widget.bucket * shown)), style: text.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
          for (final s in widget.series)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: s.color, borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 5),
              Text(
                shown == null ? s.name : '${s.name} ${s.values[shown] == null ? '—' : fmt(s.values[shown]!)}',
                style: text.labelSmall,
              ),
            ]),
        ]),
      ),
      LayoutBuilder(builder: (context, c) {
        int? at(Offset p) => _n == 0 ? null : (p.dx / c.maxWidth * _n).floor().clamp(0, _n - 1);
        return MouseRegion(
          onHover: (e) => setState(() => _hover = at(e.localPosition)),
          onExit: (_) => setState(() => _hover = null),
          child: GestureDetector(
            onTapDown: (e) => setState(() => _hover = at(e.localPosition)),
            onHorizontalDragUpdate: (e) => setState(() => _hover = at(e.localPosition)),
            child: SizedBox(
              height: widget.height,
              width: c.maxWidth,
              child: CustomPaint(
                painter: _TimePainter(widget.series, widget.stacked, top, t.border, shown, Theme.of(context).colorScheme.onSurface),
              ),
            ),
          ),
        );
      }),
      const SizedBox(height: 4),
      Row(children: [
        Text(_time(context, widget.from), style: text.labelSmall),
        const Spacer(),
        Text('max ${fmt(top)}', style: text.labelSmall),
        const Spacer(),
        Text('now', style: text.labelSmall),
      ]),
    ]);
  }
}

class _TimePainter extends CustomPainter {
  _TimePainter(this.series, this.stacked, this.top, this.grid, this.selected, this.ink);
  final List<Series> series;
  final bool stacked;
  final double top;
  final Color grid;
  final int? selected;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final g = Paint()..color = grid;
    for (final f in [0.0, .5, 1.0]) {
      final y = size.height - f * (size.height - 1) - .5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), g);
    }
    if (series.isEmpty) return;
    final n = series.first.values.length;
    if (n == 0) return;
    final slot = size.width / n;
    double y(double v) => size.height - (v / top).clamp(0, 1) * (size.height - 2) - 1;
    if (stacked) {
      final w = math.max(1.0, slot * .72);
      for (var i = 0; i < n; i++) {
        var base = 0.0;
        for (final s in series) {
          final v = s.values[i] ?? 0;
          if (v <= 0) continue;
          final r = Rect.fromLTRB(i * slot + (slot - w) / 2, y(base + v), i * slot + (slot + w) / 2, y(base));
          canvas.drawRect(r, Paint()..color = s.color.withValues(alpha: selected == null || selected == i ? 1 : .55));
          base += v;
        }
      }
    } else {
      for (final s in series) {
        final path = Path();
        var open = false;
        for (var i = 0; i < n; i++) {
          final v = s.values[i];
          final x = i * slot + slot / 2;
          if (v == null) {
            open = false;
            continue;
          }
          if (!open) {
            path.moveTo(x, y(v));
            open = true;
          } else {
            path.lineTo(x, y(v));
          }
          if (n <= 60) canvas.drawCircle(Offset(x, y(v)), 1.8, Paint()..color = s.color);
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = s.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.7
            ..strokeJoin = StrokeJoin.round,
        );
      }
    }
    if (selected != null) {
      final x = selected! * slot + slot / 2;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), Paint()..color = ink.withValues(alpha: .25));
    }
  }

  @override
  bool shouldRepaint(_TimePainter old) => true;
}
