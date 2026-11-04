import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';

/// Where agents run right now: the Mac while its worker is fresh, else the
/// cloud.
class PlacementChip extends ConsumerWidget {
  const PlacementChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mac = ref.watch(macStatusProvider);
    return mac.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => const Chip(avatar: Icon(Icons.error_outline, size: 16), label: Text('Status unavailable')),
      data: (m) {
        final on = macIsOn(m, DateTime.now());
        return Tooltip(
          message: on
              ? 'Agents run on the Mac (${m?.host ?? 'worker'}).'
              : 'The Mac worker is away; agents run in the cloud.',
          child: Chip(
            avatar: Icon(on ? Icons.laptop_mac : Icons.cloud_outlined, size: 16),
            label: Text(on ? 'Mac' : 'Cloud'),
          ),
        );
      },
    );
  }
}

String ago(DateTime? t, {DateTime? now}) {
  if (t == null) return 'never';
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 48) return '${d.inHours} h ago';
  return '${d.inDays} days ago';
}

/// A titled card section.
class Section extends StatelessWidget {
  const Section({super.key, required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
            ?trailing,
          ]),
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );
}

/// Shows a stream's loading and error states, or its data.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({super.key, required this.value, required this.data});
  final AsyncValue<T> value;
  final Widget Function(T) data;

  @override
  Widget build(BuildContext context) => value.when(
    loading: () => const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
    error: (e, _) => Text('Could not load: $e', style: TextStyle(color: Theme.of(context).colorScheme.error)),
    data: data,
  );
}
