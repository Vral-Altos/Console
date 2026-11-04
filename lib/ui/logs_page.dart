import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/providers.dart';
import '../data/telemetry.dart';
import 'charts.dart';
import 'theme.dart';
import 'widgets.dart';

/// Every service's logs and metrics, and the operator's own trail, like
/// Cloud Logging and Cloud Monitoring: a Logs Explorer, Monitoring charts and
/// an Activity timeline. Data: `logs` (14 days) and `metrics` (30 days).
class LogsPage extends ConsumerStatefulWidget {
  const LogsPage({super.key});

  @override
  ConsumerState<LogsPage> createState() => _LogsPageState();
}

/// The services that report, in display order; others appear as they are seen.
const knownSources = [
  'mac-worker',
  'cloud-runner',
  'consult-mcp',
  'financier-mcp',
  'autobench',
  'console',
];

String sourceLabel(String s) => switch (s) {
  'mac-worker' => 'Mac worker',
  'cloud-runner' => 'Cloud runner',
  'consult-mcp' => 'Consult (MCP)',
  'financier-mcp' => 'Financier MCP',
  'autobench' => 'Autobench',
  'console' => 'Console',
  _ when s.startsWith('devstation-') => 'Devstation ${s.substring(11)}',
  _ => s,
};

class _LogsPageState extends ConsumerState<LogsPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  TimeRange _range = TimeRange.h1;
  DateTime _now = DateTime.now();

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _refresh() => setState(() => _now = DateTime.now());

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final from = _now.subtract(_range.span);
    final header = Padding(
      padding: EdgeInsets.fromLTRB(narrow ? 14 : 28, narrow ? 14 : 22, narrow ? 14 : 28, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 10,
          children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('Logs & monitoring', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -.4)),
              const SizedBox(height: 4),
              Text('Every service’s logs and metrics, and what you did in the Console.',
                  style: text.bodyMedium?.copyWith(color: t.muted)),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              _RangeMenu(value: _range, onChanged: (r) => setState(() {
                _range = r;
                _now = DateTime.now();
              })),
              const SizedBox(width: 6),
              IconButton(tooltip: 'Refresh', onPressed: _refresh, icon: const Icon(Icons.refresh)),
            ]),
          ],
        ),
        const SizedBox(height: 8),
        TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          dividerColor: t.border,
          tabs: const [
            Tab(icon: Icon(Icons.receipt_long_outlined, size: 18), text: 'Logs Explorer', iconMargin: EdgeInsets.zero),
            Tab(icon: Icon(Icons.monitor_heart_outlined, size: 18), text: 'Monitoring', iconMargin: EdgeInsets.zero),
            Tab(icon: Icon(Icons.history, size: 18), text: 'Activity', iconMargin: EdgeInsets.zero),
          ],
        ),
      ]),
    );
    return Column(children: [
      header,
      Expanded(
        child: TabBarView(controller: _tabs, children: [
          LogsExplorer(from: from, to: _now, range: _range),
          MonitoringView(from: from, to: _now, range: _range),
          ActivityView(from: from),
        ]),
      ),
    ]);
  }
}

class _RangeMenu extends StatelessWidget {
  const _RangeMenu({required this.value, required this.onChanged});
  final TimeRange value;
  final ValueChanged<TimeRange> onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<TimeRange>(
    tooltip: 'Time range',
    initialValue: value,
    onSelected: onChanged,
    itemBuilder: (_) => [for (final r in TimeRange.values) PopupMenuItem(value: r, child: Text('Last ${r.label}'))],
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Tokens.of(context).border),
        borderRadius: BorderRadius.circular(10),
        color: Tokens.of(context).panel,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.schedule, size: 16),
        const SizedBox(width: 8),
        Text('Last ${value.label}', style: Theme.of(context).textTheme.labelLarge),
        const Icon(Icons.expand_more, size: 18),
      ]),
    ),
  );
}

String bucketLabel(Duration d) => d.inHours >= 1 ? '${d.inHours} h' : '${d.inMinutes} min';

Color severityColor(BuildContext context, LogSeverity s) {
  final t = Tokens.of(context);
  return switch (s) {
    LogSeverity.error => t.bad,
    LogSeverity.warning => t.warn,
    LogSeverity.info => t.info,
    LogSeverity.debug => t.faint,
  };
}

IconData severityIcon(LogSeverity s) => switch (s) {
  LogSeverity.error => Icons.error,
  LogSeverity.warning => Icons.warning_amber_rounded,
  LogSeverity.info => Icons.info_outline,
  LogSeverity.debug => Icons.bug_report_outlined,
};

/// The UTC hour [from] falls in: the metrics query key.
DateTime hourOf(DateTime from) {
  final u = from.toUtc();
  return DateTime.utc(u.year, u.month, u.day, u.hour);
}

// --------------------------------------------------------------- explorer

class LogsExplorer extends ConsumerStatefulWidget {
  const LogsExplorer({super.key, required this.from, required this.to, required this.range});
  final DateTime from;
  final DateTime to;
  final TimeRange range;

  @override
  ConsumerState<LogsExplorer> createState() => _LogsExplorerState();
}

class _LogsExplorerState extends ConsumerState<LogsExplorer> with AutomaticKeepAliveClientMixin {
  String? _source;
  final Set<LogSeverity> _severities = {LogSeverity.info, LogSeverity.warning, LogSeverity.error};
  final _search = TextEditingController();
  String _query = '';
  int _limit = 200;
  bool _paused = false;
  List<LogEntry>? _frozen;
  final Set<String> _open = {};

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final pad = narrow ? 14.0 : 28.0;
    final all = _severities.length == 3;
    final q = LogQuery(
      from: widget.from,
      source: _source,
      severities: all ? const [] : [for (final s in _severities) s.name],
      limit: _limit,
    );
    final value = ref.watch(logsProvider(q));
    final hours = ref.watch(metricsProvider(hourOf(widget.from))).value ?? const <MetricHour>[];
    final sources = {...knownSources, for (final h in hours) h.source}.toList();
    final live = value.value;
    if (!_paused && live != null) _frozen = live;
    final entries = (_paused ? _frozen : live) ?? const <LogEntry>[];
    final shown = _query.isEmpty
        ? entries
        : entries.where((e) {
            final hay = '${e.message} ${e.component} ${e.source} ${e.host ?? ''} ${jsonEncode(_jsonable(e.fields))}'.toLowerCase();
            return hay.contains(_query);
          }).toList();

    final histogram = Panel(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: TimeChart(
        from: widget.from,
        bucket: widget.range.bucket,
        stacked: true,
        height: 90,
        series: [
          for (final (name, color, label) in [
            ('log_info', t.info, 'Info'),
            ('log_warning', t.warn, 'Warning'),
            ('log_error', t.bad, 'Error'),
          ])
            if (_severities.any((s) => 'log_${s.name}' == name))
              (
                name: label,
                color: color,
                values: bucketed(hours, name, from: widget.from, to: DateTime.now(), bucket: widget.range.bucket, source: _source),
              ),
        ],
      ),
    );

    final toolbar = Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      SizedBox(
        width: narrow ? double.infinity : 280,
        child: TextField(
          controller: _search,
          onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
          decoration: InputDecoration(
            hintText: 'Search messages and fields',
            prefixIcon: Icon(Icons.search, size: 18, color: t.muted),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
      ),
      PopupMenuButton<String?>(
        tooltip: 'Source',
        onSelected: (s) => setState(() => _source = s == '' ? null : s),
        itemBuilder: (_) => [
          const PopupMenuItem(value: '', child: Text('All sources')),
          for (final s in sources) PopupMenuItem(value: s, child: Text(sourceLabel(s))),
        ],
        child: Chip(
          avatar: const Icon(Icons.dns_outlined, size: 16),
          label: Text(_source == null ? 'All sources' : sourceLabel(_source!)),
          deleteIcon: _source == null ? null : const Icon(Icons.close, size: 14),
          onDeleted: _source == null ? null : () => setState(() => _source = null),
        ),
      ),
      for (final s in [LogSeverity.info, LogSeverity.warning, LogSeverity.error])
        FilterChip(
          avatar: Icon(severityIcon(s), size: 16, color: severityColor(context, s)),
          label: Text(s.name[0].toUpperCase() + s.name.substring(1)),
          selected: _severities.contains(s),
          showCheckmark: false,
          onSelected: (on) => setState(() {
            if (on) {
              _severities.add(s);
            } else if (_severities.length > 1) {
              _severities.remove(s);
            }
          }),
        ),
      FilledButton.tonalIcon(
        onPressed: () => setState(() => _paused = !_paused),
        icon: Icon(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 18),
        label: Text(_paused ? 'Resume live' : 'Live'),
      ),
    ]);

    return CustomScrollView(slivers: [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(pad, 16, pad, 8),
        sliver: SliverList.list(children: [
          toolbar,
          const SizedBox(height: 12),
          histogram,
          const SizedBox(height: 12),
          Row(children: [
            if (!_paused && value.hasValue) ...[StatusDot(color: t.ok, pulse: true), const SizedBox(width: 8)],
            Expanded(
              child: Text(
                value.isLoading && !value.hasValue
                    ? 'Loading…'
                    : '${shown.length} entr${shown.length == 1 ? 'y' : 'ies'}'
                        '${_query.isEmpty ? '' : ' matching “$_query”'} · newest first'
                        '${entries.length >= _limit ? ' · showing the latest $_limit' : ''}'
                        '${_paused ? ' · paused' : ''}',
                style: text.labelSmall,
              ),
            ),
          ]),
          if (value.hasError) EmptyNote('Could not load logs: ${value.error}', icon: Icons.error_outline),
          const SizedBox(height: 6),
        ]),
      ),
      if (value.hasValue && shown.isEmpty)
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: pad),
          sliver: const SliverToBoxAdapter(
            child: Panel(child: EmptyNote('No log entries in this range and filter.', icon: Icons.receipt_long_outlined)),
          ),
        ),
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: pad),
        sliver: SliverList.builder(
          itemCount: shown.length,
          itemBuilder: (context, i) => LogRow(
            entry: shown[i],
            first: i == 0,
            last: i == shown.length - 1,
            open: _open.contains(shown[i].id),
            onToggle: () => setState(() => _open.contains(shown[i].id) ? _open.remove(shown[i].id) : _open.add(shown[i].id)),
            onSource: (s) => setState(() => _source = s),
          ),
        ),
      ),
      SliverPadding(
        padding: EdgeInsets.fromLTRB(pad, 10, pad, 40),
        sliver: SliverToBoxAdapter(
          child: entries.length >= _limit
              ? Center(
                  child: OutlinedButton(
                    onPressed: () => setState(() => _limit += 200),
                    child: const Text('Load older entries'),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
    ]);
  }
}

Map<String, Object?> _jsonable(Map<String, Object?> m) =>
    {for (final e in m.entries) e.key: e.value is DateTime ? (e.value as DateTime).toIso8601String() : e.value};

String _stamp(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${months[l.month - 1]} ${two(l.day)} ${two(l.hour)}:${two(l.minute)}:${two(l.second)}.${l.millisecond.toString().padLeft(3, '0')}';
}

/// One entry: a dense row that expands to its fields, like Logs Explorer.
class LogRow extends ConsumerWidget {
  const LogRow({
    super.key,
    required this.entry,
    required this.open,
    required this.onToggle,
    this.onSource,
    this.first = false,
    this.last = false,
  });
  final LogEntry entry;
  final bool open;
  final VoidCallback onToggle;
  final ValueChanged<String>? onSource;
  final bool first;
  final bool last;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final e = entry;
    final color = severityColor(context, e.severity);
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final threadId = e.fields['threadId'] as String?;
    final radius = BorderRadius.vertical(
      top: first ? const Radius.circular(12) : Radius.zero,
      bottom: last ? const Radius.circular(12) : Radius.zero,
    );
    final mono = text.bodySmall?.copyWith(fontFamily: t.mono, fontSize: 12);
    final sourceTag = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: t.sunken, borderRadius: BorderRadius.circular(5)),
      child: Text(sourceLabel(e.source), style: text.labelSmall),
    );
    return Material(
      color: open ? t.sunken.withValues(alpha: .6) : t.panel,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: t.border, width: .6),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(open ? Icons.expand_more : Icons.chevron_right, size: 16, color: t.faint),
              const SizedBox(width: 4),
              Padding(padding: const EdgeInsets.only(top: 1), child: Icon(severityIcon(e.severity), size: 15, color: color)),
              const SizedBox(width: 8),
              if (!narrow) ...[
                SizedBox(width: 160, child: Text(_stamp(e.at), style: mono?.copyWith(color: t.muted))),
                SizedBox(width: 120, child: Align(alignment: Alignment.centerLeft, child: sourceTag)),
                SizedBox(width: 90, child: Text(e.component, style: mono?.copyWith(color: t.muted), overflow: TextOverflow.ellipsis)),
              ],
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (narrow)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        Text(_stamp(e.at), style: mono?.copyWith(color: t.muted, fontSize: 11)),
                        sourceTag,
                        Text(e.component, style: text.labelSmall),
                      ]),
                    ),
                  Text(
                    e.message,
                    maxLines: open ? null : 1,
                    overflow: open ? null : TextOverflow.ellipsis,
                    style: mono?.copyWith(color: e.severity == LogSeverity.error ? t.bad : null),
                  ),
                ]),
              ),
            ]),
            if (open)
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 10, 4, 4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  KeyValue('Time', e.at.toLocal().toIso8601String(), mono: true),
                  KeyValue('Severity', e.severity.name.toUpperCase()),
                  KeyValue('Source', e.source),
                  if (e.host != null) KeyValue('Host', e.host!, mono: true),
                  KeyValue('Component', e.component),
                  for (final f in e.fields.entries)
                    KeyValue(f.key, f.value is DateTime ? (f.value as DateTime).toLocal().toIso8601String() : '${f.value}', mono: true),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, children: [
                    OutlinedButton.icon(
                      onPressed: () => Clipboard.setData(ClipboardData(
                        text: const JsonEncoder.withIndent('  ').convert({
                          'at': e.at.toIso8601String(),
                          'severity': e.severity.name,
                          'source': e.source,
                          'host': e.host,
                          'component': e.component,
                          'message': e.message,
                          'fields': _jsonable(e.fields),
                        }),
                      )),
                      icon: const Icon(Icons.data_object, size: 16),
                      label: const Text('Copy JSON'),
                    ),
                    if (onSource != null)
                      OutlinedButton.icon(
                        onPressed: () => onSource!(e.source),
                        icon: const Icon(Icons.filter_alt_outlined, size: 16),
                        label: Text('Only ${sourceLabel(e.source)}'),
                      ),
                    if (threadId != null)
                      FilledButton.tonalIcon(
                        onPressed: () => openChat(ref, threadId: threadId),
                        icon: const Icon(Icons.forum_outlined, size: 16),
                        label: const Text('Open conversation'),
                      ),
                  ]),
                ]),
              ),
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- monitoring

class MonitoringView extends ConsumerStatefulWidget {
  const MonitoringView({super.key, required this.from, required this.to, required this.range});
  final DateTime from;
  final DateTime to;
  final TimeRange range;

  @override
  ConsumerState<MonitoringView> createState() => _MonitoringViewState();
}

class _MonitoringViewState extends ConsumerState<MonitoringView> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = Tokens.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final pad = narrow ? 14.0 : 28.0;
    final value = ref.watch(metricsProvider(hourOf(widget.from)));
    final hours = value.value ?? const <MetricHour>[];
    final from = widget.from;
    final to = DateTime.now(); // the stream keeps adding minutes
    final bucket = widget.range.bucket;
    List<double?> b(String name, {String? source, bool gauge = false}) =>
        bucketed(hours, name, from: from, to: to, bucket: bucket, source: source, gauge: gauge);
    double sum(String name, {String? source}) => total(hours, name, from: from, to: to, source: source);
    final sources = {for (final h in hours) h.source}.toList()
      ..sort((a, c) {
        final ia = knownSources.indexOf(a), ic = knownSources.indexOf(c);
        return (ia < 0 ? 99 : ia).compareTo(ic < 0 ? 99 : ic);
      });
    Color colorFor(String s) => t.series[sources.indexOf(s) % t.series.length];
    final hostSources = sources.where((s) => hours.any((h) => h.source == s && h.minutes.values.any((m) => m.containsKey('cpu')))).toList();

    final turns = sum('turns');
    final failed = sum('turns_failed');
    final turnMs = sum('turn_ms');
    final latency = b('turn_ms');
    final perTurn = b('turns');
    final avgLatency = [
      for (var i = 0; i < latency.length; i++)
        latency[i] == null || (perTurn[i] ?? 0) == 0 ? null : latency[i]! / perTurn[i]! / 1000,
    ];

    Widget chart(String title, String subtitle, List<Series> series, {bool stacked = false, double? max, String Function(double)? fmt}) =>
        Panel(
          title: title,
          subtitle: subtitle,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: series.isEmpty || series.every((s) => s.values.every((v) => v == null))
              ? const Padding(padding: EdgeInsets.symmetric(vertical: 40), child: Center(child: EmptyNote('No data in this range.', icon: Icons.show_chart)))
              : TimeChart(series: series, from: from, bucket: bucket, stacked: stacked, max: max, format: fmt),
        );

    String pctFmt(double v) => '${(v * 100).round()}%';

    return ListView(padding: EdgeInsets.fromLTRB(pad, 16, pad, 40), children: [
      if (value.hasError) EmptyNote('Could not load metrics: ${value.error}', icon: Icons.error_outline),
      if (!value.hasValue && !value.hasError) const LinearProgressIndicator(minHeight: 2),
      ResponsiveGrid(minWidth: 150, maxColumns: 6, gap: 10, children: [
        _Kpi('Chat turns', compact(turns.round())),
        _Kpi('Failed', '${failed.round()}', bad: failed > 0),
        _Kpi('Avg. turn', turns == 0 ? '—' : duration(Duration(milliseconds: turnMs ~/ turns))),
        _Kpi('Claude cost', usd(sum('cost_usd'))),
        _Kpi('Errors logged', '${sum('log_error').round()}', bad: sum('log_error') > 0),
        _Kpi('Runner wake-ups', '${sum('http_requests', source: 'cloud-runner').round()}'),
      ]),
      const SizedBox(height: 14),
      ResponsiveGrid(minWidth: 420, maxColumns: 3, children: [
        chart('Chat turns', 'Done, failed and stopped, per ${bucketLabel(bucket)}', [
          (name: 'Done', color: t.series[0], values: b('turns')),
          (name: 'Failed', color: t.bad, values: b('turns_failed')),
          (name: 'Stopped', color: t.warn, values: b('turns_cancelled')),
        ], stacked: true),
        chart('Turn latency', 'Average seconds per turn', [
          (name: 'Avg. turn (s)', color: t.series[1], values: avgLatency),
        ]),
        chart('Log volume', 'Entries by severity, all services', [
          (name: 'Info', color: t.info, values: b('log_info')),
          (name: 'Warning', color: t.warn, values: b('log_warning')),
          (name: 'Error', color: t.bad, values: b('log_error')),
        ], stacked: true),
        chart('Errors by source', 'Error entries per service', [
          for (final s in sources)
            if (sum('log_error', source: s) > 0) (name: sourceLabel(s), color: colorFor(s), values: b('log_error', source: s)),
        ]),
        chart('CPU by host', 'Busy fraction of all cores', [
          for (final s in hostSources) (name: sourceLabel(s), color: colorFor(s), values: b('cpu', source: s, gauge: true)),
        ], max: 1, fmt: pctFmt),
        chart('Memory by host', 'Used fraction', [
          for (final s in hostSources) (name: sourceLabel(s), color: colorFor(s), values: b('mem', source: s, gauge: true)),
        ], max: 1, fmt: pctFmt),
        chart('Claude cost', 'API-equivalent USD', [
          (name: 'Cost', color: t.series[2], values: b('cost_usd')),
        ], stacked: true, fmt: (v) => usd(v)),
        chart('Output tokens', 'Tokens written by agents', [
          (name: 'Tokens', color: t.series[1], values: b('tokens_out')),
        ], stacked: true, fmt: (v) => compact(v.round())),
        chart('Cloud runner', 'Wake-ups (Eventarc, sweep, billing)', [
          (name: 'Requests', color: t.series[0], values: b('http_requests', source: 'cloud-runner')),
        ], stacked: true),
        chart('Factory', 'Builds and failures', [
          (name: 'Builds', color: t.ok, values: b('factory_builds')),
          (name: 'Failed', color: t.bad, values: b('factory_failed')),
        ], stacked: true),
        chart('Tools', 'Consults, Financier tool calls, Autobench syncs', [
          (name: 'Consults', color: t.series[0], values: b('consults')),
          (name: 'Financier', color: t.series[1], values: b('tool_calls')),
          (name: 'Autobench syncs', color: t.series[2], values: b('syncs')),
        ], stacked: true),
        chart('Sessions', 'Compactions, hand-offs, usage limits', [
          (name: 'Compactions', color: t.series[1], values: b('compactions')),
          (name: 'Hand-offs', color: t.series[3], values: b('handoffs')),
          (name: 'Usage limited', color: t.warn, values: b('usage_limited')),
        ], stacked: true),
      ]),
    ]);
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value, {this.bad = false});
  final String label;
  final String value;
  final bool bad;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: text.labelSmall),
          const SizedBox(height: 4),
          Text(value, style: text.titleLarge?.copyWith(fontFamily: t.mono, color: bad ? t.bad : null)),
        ]),
      ),
    );
  }
}

// --------------------------------------------------------------- activity

enum _Who { all, operator, system }

/// What happened, in order: the operator's actions in the Console and the
/// system's own events (workers starting and stopping, Factory builds,
/// billing reports).
class ActivityView extends ConsumerStatefulWidget {
  const ActivityView({super.key, required this.from});
  final DateTime from;

  @override
  ConsumerState<ActivityView> createState() => _ActivityViewState();
}

class _ActivityViewState extends ConsumerState<ActivityView> with AutomaticKeepAliveClientMixin {
  _Who _who = _Who.all;
  final Set<String> _open = {};

  @override
  bool get wantKeepAlive => true;

  static const _system = ['lifecycle', 'factory', 'billing'];

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final pad = narrow ? 14.0 : 28.0;
    final components = switch (_who) {
      _Who.all => ['audit', ..._system],
      _Who.operator => ['audit'],
      _Who.system => _system,
    };
    final value = ref.watch(logsProvider(LogQuery(from: widget.from, components: components, limit: 300)));
    final list = value.value ?? const <LogEntry>[];
    final items = <Widget>[];
    DateTime? day;
    for (final e in list) {
      final l = e.at.toLocal();
      final d = DateTime(l.year, l.month, l.day);
      if (d != day) {
        day = d;
        items.add(Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
          child: Text(
            '${['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][l.weekday - 1]} ${l.day}/${l.month}',
            style: text.labelMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ));
      }
      final (IconData icon, Color color) = switch (e.component) {
        'audit' => (Icons.person_outline, Theme.of(context).colorScheme.primary),
        'factory' => (Icons.precision_manufacturing_outlined, t.series[1]),
        'billing' => (Icons.payments_outlined, t.series[2]),
        _ => (Icons.power_settings_new, t.muted),
      };
      final open = _open.contains(e.id);
      items.add(InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => open ? _open.remove(e.id) : _open.add(e.id)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(9)),
              child: Icon(icon, size: 16, color: e.severity == LogSeverity.error ? t.bad : color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e.message, style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500, color: e.severity == LogSeverity.error ? t.bad : null)),
                Text(
                  '${clockTime(context, e.at)} · ${e.component == 'audit' ? 'You, in the Console' : sourceLabel(e.source)}',
                  style: text.labelSmall,
                ),
                if (open && e.fields.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Column(children: [for (final f in e.fields.entries) KeyValue(f.key, '${f.value}', mono: true)]),
                  ),
              ]),
            ),
            if (e.fields['threadId'] is String && e.component == 'audit')
              IconButton(
                tooltip: 'Open conversation',
                onPressed: () => openChat(ref, threadId: e.fields['threadId'] as String),
                icon: Icon(Icons.forum_outlined, size: 18, color: t.muted),
              ),
          ]),
        ),
      ));
    }
    return ListView(padding: EdgeInsets.fromLTRB(pad, 16, pad, 40), children: [
      Align(
        alignment: Alignment.centerLeft,
        child: SegmentedButton<_Who>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: _Who.all, label: Text('All')),
            ButtonSegment(value: _Who.operator, icon: Icon(Icons.person_outline, size: 16), label: Text('You')),
            ButtonSegment(value: _Who.system, icon: Icon(Icons.memory, size: 16), label: Text('System')),
          ],
          selected: {_who},
          onSelectionChanged: (s) => setState(() => _who = s.first),
        ),
      ),
      const SizedBox(height: 8),
      if (value.hasError) EmptyNote('Could not load activity: ${value.error}', icon: Icons.error_outline),
      if (!value.hasValue && !value.hasError) const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator(minHeight: 2)),
      if (value.hasValue && list.isEmpty) const Panel(child: EmptyNote('Nothing happened in this range.', icon: Icons.history)),
      if (items.isNotEmpty) Panel(padding: const EdgeInsets.fromLTRB(14, 0, 14, 10), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: items)),
    ]);
  }
}
