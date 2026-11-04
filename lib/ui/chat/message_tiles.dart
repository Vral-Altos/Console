import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../theme.dart';
import '../widgets.dart';
import 'attachment_views.dart';
import 'markdown_view.dart';

const _column = 760.0;

/// Centres a conversation's content in a readable column.
class ChatColumn extends StatelessWidget {
  const ChatColumn({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _column),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: child),
    ),
  );
}

/// Hover state for showing a message's actions on desktop (always shown on
/// touch screens).
class _Hoverable extends StatefulWidget {
  const _Hoverable({required this.builder});
  final Widget Function(BuildContext context, bool hover) builder;

  @override
  State<_Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<_Hoverable> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).platform;
    final touch = p == TargetPlatform.iOS || p == TargetPlatform.android;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: widget.builder(context, _hover || touch),
    );
  }
}

class _ActionIcon extends StatefulWidget {
  const _ActionIcon({required this.icon, required this.tooltip, required this.onPressed, this.doneIcon});
  final IconData icon;
  final IconData? doneIcon;
  final String tooltip;
  final FutureOr<void> Function() onPressed;

  @override
  State<_ActionIcon> createState() => _ActionIconState();
}

class _ActionIconState extends State<_ActionIcon> {
  bool _done = false;
  Timer? _t;

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: widget.tooltip,
    visualDensity: VisualDensity.compact,
    iconSize: 16,
    color: Tokens.of(context).muted,
    onPressed: () async {
      await widget.onPressed();
      if (widget.doneIcon == null || !mounted) return;
      setState(() => _done = true);
      _t?.cancel();
      _t = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _done = false);
      });
    },
    icon: Icon(_done ? widget.doneIcon : widget.icon),
  );
}

/// The operator's message: a bubble on the right.
class OperatorBubble extends StatelessWidget {
  const OperatorBubble({super.key, required this.message, this.onEdit});
  final ChatMessage message;
  final void Function(ChatMessage message)? onEdit;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return _Hoverable(
      builder: (context, hover) {
        return Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (message.attachments.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(left: 56, bottom: message.text.isEmpty ? 0 : 6),
                  child: MessageAttachments(attachments: message.attachments),
                ),
              if (message.text.isNotEmpty)
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    const SizedBox(width: 56),
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                        decoration: BoxDecoration(color: t.userBubble, borderRadius: BorderRadius.circular(18)),
                        child: Text.rich(mentionSpan(context, message.text, message.mentions, text.bodyLarge)),
                      ),
                    ),
                  ],
                ),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 120),
                opacity: hover ? 1 : 0,
                alwaysIncludeSemantics: true,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (message.createdAt != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text(clockTime(context, message.createdAt!), style: text.labelSmall?.copyWith(color: t.faint)),
                      ),
                    _ActionIcon(
                      icon: Icons.content_copy,
                      doneIcon: Icons.check,
                      tooltip: 'Copy',
                      onPressed: () => Clipboard.setData(ClipboardData(text: message.text)),
                    ),
                    if (onEdit != null)
                      _ActionIcon(icon: Icons.edit_outlined, tooltip: 'Edit and resend', onPressed: () => onEdit!(message)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AgentHeader extends StatelessWidget {
  const _AgentHeader({required this.agent, this.trailing});
  final String agent;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        AgentAvatar(agent: agent, size: 24),
        const SizedBox(width: 10),
        Text(agentLabel(agent), style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
        if (trailing != null) ...[const SizedBox(width: 10), Flexible(child: trailing!)],
      ],
    ),
  );
}

/// An agent's reply: Markdown, with copy / retry and what the turn took.
class AgentReply extends StatelessWidget {
  const AgentReply({super.key, required this.message, required this.agent, this.onRetry});
  final ChatMessage message;
  final String agent;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final m = message;
    final meta = [
      if (m.placement != null)
        m.placement == 'mac'
            ? 'Mac'
            : m.placement == 'cloud'
            ? 'Cloud'
            : 'Devstation',
      ?m.accountId,
      if (m.model != null) modelName(m.model),
      if ((m.outputTokens ?? 0) > 0) '${compact(m.outputTokens)} tokens',
      if (m.costUsd != null && m.costUsd! > 0) usd(m.costUsd),
      if ((m.durationMs ?? 0) > 0) duration(Duration(milliseconds: m.durationMs!)),
    ].join(' · ');
    return _Hoverable(
      builder: (context, hover) {
        return Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _AgentHeader(
                agent: agent,
                trailing: m.stopped ? StatusPill(label: 'Stopped', color: t.warn, dense: true) : null,
              ),
              if (m.tools.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ToolsUsed(tools: m.tools),
                ),
              MarkdownView(data: m.text),
              const SizedBox(height: 4),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      [if (m.createdAt != null) clockTime(context, m.createdAt!), if (meta.isNotEmpty) meta].join(' · '),
                      style: text.labelSmall?.copyWith(color: t.faint),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (m.costUsd != null)
                    Tooltip(
                      message: 'Cost is the API-equivalent Claude Code reports; a subscription is not billed per turn.',
                      child: Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(Icons.info_outline, size: 13, color: t.faint),
                      ),
                    ),
                  const SizedBox(width: 6),
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 120),
                    opacity: hover ? 1 : .0,
                    alwaysIncludeSemantics: true,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ActionIcon(
                          icon: Icons.content_copy,
                          doneIcon: Icons.check,
                          tooltip: 'Copy',
                          onPressed: () => Clipboard.setData(ClipboardData(text: m.text)),
                        ),
                        if (onRetry != null) _ActionIcon(icon: Icons.refresh, tooltip: 'Ask again', onPressed: onRetry!),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The tools a turn used, e.g. `Read ×3 · consult (va-mesh)`.
class ToolsUsed extends StatelessWidget {
  const ToolsUsed({super.key, required this.tools});
  final List<String> tools;

  static String label(String name) {
    final m = RegExp(r'^mcp__(.+?)__(.+)$').firstMatch(name);
    return m == null ? name : '${m.group(2)} (${m.group(1)})';
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final counts = <String, int>{};
    for (final x in tools) {
      counts[label(x)] = (counts[label(x)] ?? 0) + 1;
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final e in counts.entries)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: t.sunken,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: t.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.handyman_outlined, size: 12, color: t.muted),
                const SizedBox(width: 5),
                Text(e.value > 1 ? '${e.key} ×${e.value}' : e.key, style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
      ],
    );
  }
}

/// Seconds since [since], ticking.
class Elapsed extends StatefulWidget {
  const Elapsed({super.key, required this.since, this.style});
  final DateTime? since;
  final TextStyle? style;

  @override
  State<Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<Elapsed> {
  late final Timer _t = Timer.periodic(const Duration(seconds: 1), (_) {
    if (mounted) setState(() {});
  });

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.since;
    if (s == null) return const SizedBox.shrink();
    final d = DateTime.now().difference(s);
    return Text(duration(d.isNegative ? Duration.zero : d), style: widget.style);
  }
}

/// The agent's reply while it is queued or being written: where it will
/// run, what it is doing, and the text so far.
class PendingReply extends ConsumerWidget {
  const PendingReply({super.key, required this.message, required this.agent, required this.onStop});
  final ChatMessage message;
  final String agent;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final m = message;
    final running = m.status == MessageStatus.running;
    ref.watch(clockProvider);
    final hosts = ref.watch(allStatusProvider).value ?? const {};
    final now = DateTime.now();
    final String waiting;
    if (agent.startsWith('director-')) {
      final id = agent.substring(9);
      waiting = isFresh(hosts['devstation-$id'], now)
          ? 'Waiting for Devstation $id'
          : 'Devstation $id is not running; this waits until it starts';
    } else {
      waiting = isFresh(hosts['mac'], now) ? 'Waiting for the Mac' : 'Waking the cloud runner';
    }
    final status = m.cancelRequested
        ? 'Stopping…'
        : running
        ? (m.activity ?? ((m.partial ?? '').isEmpty ? 'Thinking' : 'Writing'))
        : waiting;
    final host = running
        ? (m.claimedBy == 'mac'
              ? 'Mac'
              : m.claimedBy == 'cloud'
              ? 'Cloud'
              : 'Devstation')
        : null;
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AgentHeader(agent: agent),
          Row(
            children: [
              SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: t.info)),
              const SizedBox(width: 10),
              Flexible(
                child: _Shimmer(
                  child: Text(
                    '$status…'.replaceAll('……', '…'),
                    style: text.bodyMedium?.copyWith(color: t.muted, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Elapsed(
                since: running ? m.claimedAt ?? m.createdAt : m.createdAt,
                style: text.labelSmall?.copyWith(fontFamily: t.mono),
              ),
              if (host != null) Text(' · $host', style: text.labelSmall),
              const SizedBox(width: 6),
              TextButton(
                onPressed: m.cancelRequested ? null : onStop,
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: t.muted),
                child: Text(running ? 'Stop' : 'Cancel'),
              ),
            ],
          ),
          if (m.tools.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ToolsUsed(tools: m.tools),
            ),
          if ((m.partial ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: StreamingMarkdown(text: m.partial!),
            ),
        ],
      ),
    );
  }
}

/// A gentle opacity pulse for "in progress" text.
class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.child});
  final Widget child;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(opacity: Tween(begin: .55, end: 1.0).animate(_c), child: widget.child);
}

/// A turn that failed: the reason, and Retry.
class FailedNote extends StatelessWidget {
  const FailedNote({super.key, required this.message, required this.onRetry});
  final ChatMessage message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(
          color: t.bad.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: t.bad.withValues(alpha: .3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(Icons.error_outline, size: 18, color: t.bad),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'This turn failed',
                    style: text.labelLarge?.copyWith(color: t.bad, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(message.error ?? 'Unknown error.', style: text.bodySmall),
                ],
              ),
            ),
            if (onRetry != null)
              TextButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh, size: 16), label: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

/// A one-line note in the middle of the conversation.
class SystemNote extends StatelessWidget {
  const SystemNote({super.key, required this.text, this.icon = Icons.info_outline});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          Expanded(child: Divider(color: t.border)),
          const SizedBox(width: 12),
          Icon(icon, size: 14, color: t.faint),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text, style: Theme.of(context).textTheme.labelSmall, textAlign: TextAlign.center),
          ),
          const SizedBox(width: 12),
          Expanded(child: Divider(color: t.border)),
        ],
      ),
    );
  }
}

String dayLabel(DateTime t, DateTime now) {
  final a = DateTime(t.year, t.month, t.day);
  final b = DateTime(now.year, now.month, now.day);
  final d = b.difference(a).inDays;
  if (d == 0) return 'Today';
  if (d == 1) return 'Yesterday';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return d < 7 ? days[t.weekday - 1] : '${t.day} ${months[t.month - 1]}${t.year == now.year ? '' : ' ${t.year}'}';
}
