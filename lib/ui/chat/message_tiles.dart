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
import 'chat_naming.dart';

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
    icon: AnimatedSwitcher(
      duration: const Duration(milliseconds: 160),
      transitionBuilder: (c, a) => ScaleTransition(scale: a, child: FadeTransition(opacity: a, child: c)),
      child: Icon(_done ? widget.doneIcon : widget.icon, key: ValueKey(_done)),
    ),
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
          padding: const EdgeInsets.only(top: 22, bottom: 2),
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
                      icon: Icons.content_copy_rounded,
                      doneIcon: Icons.check_rounded,
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
  const _AgentHeader({required this.agent, this.trailing, this.busy = false});
  final String agent;
  final Widget? trailing;
  final bool busy;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        _Breathing(active: busy, child: AgentAvatar(agent: agent, size: 24)),
        const SizedBox(width: 10),
        Text(agentLabel(agent), style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
        if (trailing != null) ...[const SizedBox(width: 10), Flexible(child: trailing!)],
      ],
    ),
  );
}

/// An agent's reply: Markdown, with copy / retry and what the turn took.
/// Laid out like [PendingReply] (header, tools, text, a footer row), so the
/// streamed reply turns into the finished one without moving.
class AgentReply extends StatelessWidget {
  const AgentReply({super.key, required this.message, required this.agent, this.onRetry, this.latest = false});
  final ChatMessage message;
  final String agent;
  final VoidCallback? onRetry;

  /// The conversation's newest reply keeps its actions visible.
  final bool latest;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final m = message;
    final meta = [
      if (m.createdAt != null) clockTime(context, m.createdAt!),
      if (m.placement != null)
        m.placement == 'mac'
            ? 'Mac'
            : m.placement == 'cloud'
            ? 'Cloud'
            : 'Devstation',
      ?m.accountId,
      if ((m.durationMs ?? 0) > 0) duration(Duration(milliseconds: m.durationMs!)),
    ].join(' · ');
    // What the turn used, always shown: model, tokens, cost, the account's
    // quota after it.
    final usage = [
      if (m.model != null) modelName(m.model),
      if ((m.contextTokens ?? 0) > 0) '${compact(m.contextTokens)} context',
      if ((m.outputTokens ?? 0) > 0) '${compact(m.outputTokens)} out',
      if (m.costUsd != null) usd(m.costUsd),
      if (m.quota?.fiveHour != null) quotaLabel('5h', m.quota!.fiveHour!),
      if (m.quota?.sevenDay != null) quotaLabel('7d', m.quota!.sevenDay!),
    ].join(' · ');
    return _Hoverable(
      builder: (context, hover) {
        return Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _AgentHeader(
                agent: agent,
                trailing: m.stopped ? StatusPill(label: 'Stopped', color: t.warn, dense: true) : null,
              ),
              if (m.tools.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: ToolActivity(tools: m.tools, took: (m.durationMs ?? 0) > 0 ? Duration(milliseconds: m.durationMs!) : null),
                ),
              MarkdownView(data: m.text),
              const SizedBox(height: 6),
              SizedBox(
                height: 32,
                child: Row(
                  children: [
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 140),
                      opacity: hover || latest ? 1 : 0,
                      alwaysIncludeSemantics: true,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _ActionIcon(
                            icon: Icons.content_copy_rounded,
                            doneIcon: Icons.check_rounded,
                            tooltip: 'Copy',
                            onPressed: () => Clipboard.setData(ClipboardData(text: m.text)),
                          ),
                          if (onRetry != null) _ActionIcon(icon: Icons.refresh_rounded, tooltip: 'Ask again', onPressed: onRetry!),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (usage.isNotEmpty)
                          Flexible(
                            child: Text(
                              usage,
                              key: const Key('reply-usage'),
                              style: text.labelSmall?.copyWith(color: t.muted, fontFeatures: const [FontFeature.tabularFigures()]),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        if (m.costUsd != null)
                          Tooltip(
                            message: 'Cost is the API-equivalent Claude Code reports; a subscription is not billed per turn. '
                                'Quota is the account\'s 5-hour and 7-day usage after this reply.',
                            child: Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Icon(Icons.info_outline, size: 13, color: t.faint),
                            ),
                          ),
                        if (meta.isNotEmpty)
                          Flexible(
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 140),
                              opacity: hover ? 1 : 0,
                              alwaysIncludeSemantics: true,
                              child: Text('  $meta', style: text.labelSmall?.copyWith(color: t.faint), overflow: TextOverflow.ellipsis),
                            ),
                          ),
                      ]),
                    ),
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

/// The tools a turn used, e.g. `Read ×3 · consult (va-mesh)`.
class ToolsUsed extends StatelessWidget {
  const ToolsUsed({super.key, required this.tools});
  final List<String> tools;

  static String label(String name) {
    final m = RegExp(r'^mcp__(.+?)__(.+)$').firstMatch(name);
    return m == null ? name : '${m.group(2)} (${m.group(1)})';
  }

  static IconData icon(String name) {
    if (name.startsWith('mcp__')) return Icons.extension_outlined;
    return switch (name) {
      'Read' => Icons.description_outlined,
      'Write' || 'Edit' || 'MultiEdit' || 'NotebookEdit' => Icons.edit_note_rounded,
      'Bash' => Icons.terminal_rounded,
      'Grep' || 'Glob' => Icons.search_rounded,
      'WebSearch' => Icons.travel_explore_rounded,
      'WebFetch' => Icons.language_rounded,
      'Task' || 'Agent' => Icons.account_tree_outlined,
      'TodoWrite' => Icons.checklist_rounded,
      _ => Icons.handyman_outlined,
    };
  }

  /// Each tool once, in first-use order, with how often it ran.
  static List<(String name, int count)> counted(List<String> tools) {
    final counts = <String, int>{};
    for (final x in tools) {
      counts[x] = (counts[x] ?? 0) + 1;
    }
    return [for (final e in counts.entries) (e.key, e.value)];
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final rows = counted(tools);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, (name, n)) in rows.indexed)
          Semantics(
            container: true,
            child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                width: 22,
                child: Column(children: [
                  Expanded(child: Center(child: Container(width: 1, color: i == 0 ? Colors.transparent : t.border))),
                  Icon(icon(name), size: 14, color: t.muted),
                  Expanded(child: Center(child: Container(width: 1, color: i == rows.length - 1 ? Colors.transparent : t.border))),
                ]),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(n > 1 ? '${label(name)} ×$n' : label(name), style: text.bodySmall?.copyWith(color: t.muted)),
              ),
            ]),
          ),
          ),
      ],
    );
  }
}

/// What a turn did, folded to one line ("Used 4 tools · 12s"); opens to
/// the list of tools.
class ToolActivity extends StatefulWidget {
  const ToolActivity({super.key, required this.tools, this.took, this.running = false});
  final List<String> tools;
  final Duration? took;
  final bool running;

  @override
  State<ToolActivity> createState() => _ToolActivityState();
}

class _ToolActivityState extends State<ToolActivity> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final n = widget.tools.length;
    final distinct = ToolsUsed.counted(widget.tools);
    final what = distinct.length == 1 ? ToolsUsed.label(distinct.single.$1) : '$n tools';
    final summary = [
      '${widget.running ? 'Using' : 'Used'} $what${distinct.length == 1 && n > 1 ? ' ×$n' : ''}',
      if (widget.took != null) duration(widget.took!),
    ].join(' · ');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(
        container: true,
        button: true,
        expanded: _open,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(ToolsUsed.icon(widget.tools.last), size: 15, color: t.muted),
              const SizedBox(width: 8),
              Flexible(child: Text(summary, style: text.bodySmall?.copyWith(color: t.muted, fontWeight: FontWeight.w500))),
              const SizedBox(width: 2),
              AnimatedRotation(
                turns: _open ? .25 : 0,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                child: Icon(Icons.chevron_right_rounded, size: 18, color: t.faint),
              ),
            ]),
          ),
        ),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topLeft,
        child: _open
            ? Padding(padding: const EdgeInsets.only(top: 4, left: 2), child: ToolsUsed(tools: widget.tools))
            : const SizedBox(width: double.infinity),
      ),
    ]);
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

/// The agent's reply while it is queued or being written: the text so far,
/// the tools it has used, and underneath what it is doing now.
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
        ? 'Stopping'
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
    final hasText = (m.partial ?? '').isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AgentHeader(agent: agent, busy: true),
          if (m.tools.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: ToolActivity(tools: m.tools, running: true),
            ),
          if (hasText) StreamingMarkdown(text: m.partial!),
          SizedBox(height: hasText ? 6 : 0),
          SizedBox(
            height: 32,
            child: Row(
              children: [
                Flexible(
                  child: ShimmerText(
                    '${status.replaceAll(RegExp(r'…+$'), '')}…',
                    style: text.bodyMedium?.copyWith(color: t.muted, fontWeight: FontWeight.w500),
                  ),
                ),
                const SizedBox(width: 10),
                Elapsed(
                  since: running ? m.claimedAt ?? m.createdAt : m.createdAt,
                  style: text.labelSmall?.copyWith(fontFamily: t.mono, color: t.faint),
                ),
                if (host != null) Text(' · $host', style: text.labelSmall?.copyWith(color: t.faint)),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: m.cancelRequested ? null : onStop,
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: t.muted, textStyle: text.labelMedium),
                  child: Text(running ? 'Stop' : 'Cancel'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "In progress" text: a soft highlight sweeps across it.
class ShimmerText extends StatefulWidget {
  const ShimmerText(this.text, {super.key, this.style});
  final String text;
  final TextStyle? style;

  @override
  State<ShimmerText> createState() => _ShimmerTextState();
}

class _ShimmerTextState extends State<ShimmerText> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.style?.color ?? Tokens.of(context).muted;
    final bright = Theme.of(context).colorScheme.onSurface;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final x = -1.0 + 3.0 * Curves.easeInOut.transform(_c.value);
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (r) => LinearGradient(
            begin: Alignment(x - 1, 0),
            end: Alignment(x + 1, 0),
            colors: [base, bright, base],
            stops: const [.3, .5, .7],
          ).createShader(r),
          child: child,
        );
      },
      child: Text(widget.text, style: widget.style, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

/// A slow pulse on the agent's avatar while it works.
class _Breathing extends StatefulWidget {
  const _Breathing({required this.child, required this.active});
  final Widget child;
  final bool active;

  @override
  State<_Breathing> createState() => _BreathingState();
}

class _BreathingState extends State<_Breathing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_Breathing old) {
    super.didUpdateWidget(old);
    if (widget.active && !_c.isAnimating) _c.repeat(reverse: true);
    if (!widget.active && _c.isAnimating) _c.animateTo(0, duration: const Duration(milliseconds: 200));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, child) {
      final v = Curves.easeInOut.transform(_c.value);
      return Transform.scale(scale: 1 - .08 * v, child: Opacity(opacity: 1 - .35 * v, child: child));
    },
    child: widget.child,
  );
}

/// New content fades and rises into place; content already there when the
/// conversation opened does not move.
class Appear extends StatefulWidget {
  const Appear({super.key, required this.child, required this.animate});
  final Widget child;
  final bool animate;

  @override
  State<Appear> createState() => _AppearState();
}

class _AppearState extends State<Appear> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
  late final Animation<double> _a = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    widget.animate ? _c.forward() : _c.value = 1;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _a,
    child: SlideTransition(position: Tween(begin: const Offset(0, .04), end: Offset.zero).animate(_a), child: widget.child),
  );
}

/// Placeholder lines while a conversation loads.
class ConversationSkeleton extends StatefulWidget {
  const ConversationSkeleton({super.key});

  @override
  State<ConversationSkeleton> createState() => _ConversationSkeletonState();
}

class _ConversationSkeletonState extends State<ConversationSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    Widget bar(double w, {double h = 12, double r = 6}) => FractionallySizedBox(
      widthFactor: w,
      alignment: Alignment.centerLeft,
      child: Container(height: h, decoration: BoxDecoration(color: t.sunken, borderRadius: BorderRadius.circular(r))),
    );
    return Semantics(
      label: 'Loading the conversation',
      child: FadeTransition(
        opacity: Tween(begin: .5, end: 1.0).animate(_c),
        child: Padding(
          padding: const EdgeInsets.only(top: 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Align(alignment: Alignment.centerRight, child: SizedBox(width: 260, child: bar(1, h: 40, r: 18))),
            const SizedBox(height: 28),
            Row(children: [
              Container(width: 24, height: 24, decoration: BoxDecoration(color: t.sunken, borderRadius: BorderRadius.circular(8))),
              const SizedBox(width: 10),
              SizedBox(width: 70, child: bar(1)),
            ]),
            const SizedBox(height: 14),
            bar(.95),
            const SizedBox(height: 10),
            bar(.88),
            const SizedBox(height: 10),
            bar(.6),
          ]),
        ),
      ),
    );
  }
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
