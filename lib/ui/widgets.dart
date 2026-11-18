import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_mesh/ui_mesh.dart';

import '../data/providers.dart';

export 'package:ui_mesh/ui_mesh.dart';

// ---------------------------------------------------------------- formatting

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

/// A coloured circle with an agent's initial(s).
class AgentAvatar extends StatelessWidget {
  const AgentAvatar({super.key, required this.agent, this.size = 28});
  final String agent;
  final double size;

  @override
  Widget build(BuildContext context) {
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
          colors: [color, Color.lerp(color, VaColors.panel, .25)!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(size * .32),
      ),
      child: Text(
        label,
        style: TextStyle(color: VaColors.canvas, fontWeight: FontWeight.w700, fontSize: size * .44, height: 1),
      ),
    );
  }
}

Color agentColor(BuildContext context, String agent) =>
    VaColors.forName(agent, fixed: const {'genie': 0, 'financier': 1, 'roman': 2, 'sierra': 3, 'rhog': 4});

/// Where agents run right now: the Mac while its worker is fresh, else the
/// cloud.
class PlacementChip extends ConsumerWidget {
  const PlacementChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mac = ref.watch(macStatusProvider);
    ref.watch(clockProvider);
    return mac.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => VaStatusPill(label: 'Status unavailable', color: VaColors.danger),
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
            child: VaStatusPill(label: on ? 'Mac' : 'Cloud', color: on ? VaColors.success : VaColors.info),
          ),
        );
      },
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
