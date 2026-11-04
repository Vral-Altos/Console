import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import 'theme.dart';

// ---------------------------------------------------------------- formatting

String ago(DateTime? t, {DateTime? now}) {
  if (t == null) return 'never';
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${math.max(1, d.inMinutes)} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays < 2) return 'yesterday';
  return '${d.inDays} days ago';
}

String bytes(int? b) {
  if (b == null) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v >= 100 || i == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)} ${units[i]}';
}

String usd(double? v) {
  if (v == null) return '—';
  if (v == 0) return r'$0';
  if (v < 0.01) return r'<$0.01';
  if (v < 100) return '\$${v.toStringAsFixed(2)}';
  return '\$${v.toStringAsFixed(0)}';
}

String money(double? v, String? currency) {
  if (v == null) return '—';
  final c = currency ?? '';
  final symbol = switch (c) { 'SGD' => r'S$', 'USD' => r'$', 'EUR' => '€', 'GBP' => '£', _ => '$c ' };
  return '$symbol${v.toStringAsFixed(2)}';
}

String compact(num? v) {
  if (v == null) return '—';
  if (v < 1000) return '$v';
  if (v < 1e6) return '${(v / 1000).toStringAsFixed(v < 1e4 ? 1 : 0)}k';
  return '${(v / 1e6).toStringAsFixed(1)}M';
}

String pct(double? f) => f == null ? '—' : '${(f * 100).round()}%';

String duration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  if (d.inHours < 48) return '${d.inHours}h ${d.inMinutes % 60}m';
  return '${d.inDays}d ${d.inHours % 24}h';
}

String clockTime(BuildContext context, DateTime t) =>
    TimeOfDay.fromDateTime(t.toLocal()).format(context);

/// Shorter model names: `claude-opus-5-5` → `Opus 5.5`.
String modelName(String? id) {
  if (id == null) return '';
  final m = RegExp(r'claude-([a-z]+)-(\d+)-(\d+)').firstMatch(id);
  if (m == null) return id;
  final family = m.group(1)!;
  return '${family[0].toUpperCase()}${family.substring(1)} ${m.group(2)}.${m.group(3)}';
}

String agentLabel(String name) {
  if (name.startsWith('director-')) return 'Director · ${name.substring(9)}';
  if (name == 'rhog') return 'RHOG';
  return name.isEmpty ? name : '${name[0].toUpperCase()}${name.substring(1)}';
}

// ------------------------------------------------------------------- pieces

/// A titled panel: the Console's basic container.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    this.title,
    this.subtitle,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.icon,
  });

  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null) ...[
              Row(children: [
                if (icon != null) ...[Icon(icon, size: 18, color: t.muted), const SizedBox(width: 8)],
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title!, style: text.titleSmall),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(subtitle!, style: text.bodySmall?.copyWith(color: t.muted)),
                      ),
                  ]),
                ),
                ?trailing,
              ]),
              const SizedBox(height: 14),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

/// A small coloured dot; [pulse] makes it breathe (something is live).
class StatusDot extends StatefulWidget {
  const StatusDot({super.key, required this.color, this.pulse = false, this.size = 8});
  final Color color;
  final bool pulse;
  final double size;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void initState() {
    super.initState();
    if (widget.pulse) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(StatusDot old) {
    super.didUpdateWidget(old);
    if (widget.pulse && !_c.isAnimating) _c.repeat(reverse: true);
    if (!widget.pulse && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, _) => Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: widget.color,
        shape: BoxShape.circle,
        boxShadow: widget.pulse
            ? [BoxShadow(color: widget.color.withValues(alpha: .45 * (1 - _c.value)), blurRadius: 0, spreadRadius: 4 * _c.value)]
            : null,
      ),
    ),
  );
}

/// A rounded label with a dot, e.g. "Serving" in green.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color, this.pulse = false, this.dense = false});
  final String label;
  final Color color;
  final bool pulse;
  final bool dense;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10, vertical: dense ? 3 : 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      StatusDot(color: color, pulse: pulse, size: dense ? 6 : 7),
      SizedBox(width: dense ? 5 : 6),
      Flexible(
        child: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                  letterSpacing: .1,
                )),
      ),
    ]),
  );
}

/// A coloured circle with an agent's initial(s).
class AgentAvatar extends StatelessWidget {
  const AgentAvatar({super.key, required this.agent, this.size = 28});
  final String agent;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final color = agentColor(context, agent);
    final label = agent.startsWith('director-')
        ? 'D'
        : agent == 'rhog'
            ? 'R'
            : (agent.isEmpty ? '?' : agent[0].toUpperCase());
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color, Color.lerp(color, t.panel, .25)!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(size * .32),
      ),
      child: Text(
        label,
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: size * .44, height: 1),
      ),
    );
  }
}

Color agentColor(BuildContext context, String agent) {
  final s = Tokens.of(context).series;
  const fixed = {'genie': 0, 'financier': 1, 'roman': 2, 'sierra': 3, 'rhog': 4};
  final i = fixed[agent] ?? agent.codeUnits.fold<int>(0, (a, b) => a + b) % s.length;
  return s[i % s.length];
}

/// A quiet message where data would be.
class EmptyNote extends StatelessWidget {
  const EmptyNote(this.text, {super.key, this.icon = Icons.inbox_outlined});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: t.faint),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: t.muted))),
      ]),
    );
  }
}

/// Shows a stream's loading and error states, or its data.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({super.key, required this.value, required this.data, this.compact = false});
  final AsyncValue<T> value;
  final Widget Function(T) data;
  final bool compact;

  @override
  Widget build(BuildContext context) => value.when(
    skipLoadingOnReload: true,
    loading: () => Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 4 : 12),
      child: const LinearProgressIndicator(minHeight: 2),
    ),
    error: (e, _) => EmptyNote('Could not load: $e', icon: Icons.error_outline),
    data: data,
  );
}

/// Where agents run right now: the Mac while its worker is fresh, else the
/// cloud.
class PlacementChip extends ConsumerWidget {
  const PlacementChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Tokens.of(context);
    final mac = ref.watch(macStatusProvider);
    ref.watch(clockProvider);
    return mac.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => StatusPill(label: 'Status unavailable', color: t.bad),
      data: (m) {
        final on = macIsOn(m, DateTime.now());
        return Tooltip(
          message: on
              ? 'Agents run on the Mac (${m?.host ?? 'worker'}).'
              : 'The Mac worker is away; agents run in the cloud.',
          child: Semantics(
            container: true,
            label: on ? 'Agents run on the Mac' : 'Agents run in the cloud',
            excludeSemantics: true,
            child: StatusPill(label: on ? 'Mac' : 'Cloud', color: on ? t.ok : t.info),
          ),
        );
      },
    );
  }
}

/// Lays children out in as many equal columns as fit at [minWidth] each.
class ResponsiveGrid extends StatelessWidget {
  const ResponsiveGrid({super.key, required this.children, this.minWidth = 240, this.gap = 14, this.maxColumns = 6});
  final List<Widget> children;
  final double minWidth;
  final double gap;
  final int maxColumns;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
    final cols = math.max(1, math.min(maxColumns, ((c.maxWidth + gap) / (minWidth + gap)).floor()));
    final w = (c.maxWidth - gap * (cols - 1)) / cols;
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [for (final child in children) SizedBox(width: w, child: child)],
    );
  });
}

/// A label/value row for detail lists.
class KeyValue extends StatelessWidget {
  const KeyValue(this.label, this.value, {super.key, this.mono = false});
  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 110, child: Text(label, style: text.bodySmall?.copyWith(color: t.muted))),
        Expanded(
          child: SelectableText(
            value,
            style: text.bodySmall?.copyWith(fontFamily: mono ? t.mono : null),
          ),
        ),
      ]),
    );
  }
}

/// A thin horizontal meter (0–1), coloured by how full it is.
class Meter extends StatelessWidget {
  const Meter({super.key, required this.value, this.height = 6, this.color, this.warnAt = .75, this.badAt = .9});
  final double? value;
  final double height;
  final Color? color;
  final double warnAt;
  final double badAt;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final v = (value ?? 0).clamp(0.0, 1.0);
    final c = color ?? (v >= badAt ? t.bad : v >= warnAt ? t.warn : Theme.of(context).colorScheme.primary);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: Stack(children: [
          Positioned.fill(child: ColoredBox(color: t.sunken)),
          FractionallySizedBox(
            widthFactor: value == null ? 0 : math.max(v, .015),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeOutCubic,
              color: c,
            ),
          ),
        ]),
      ),
    );
  }
}

/// Shows a snack bar with an error from an action.
void showError(BuildContext context, Object e) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$e')));
}

/// Runs [action], reporting a failure in a snack bar.
Future<void> guarded(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
