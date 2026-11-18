import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/providers.dart';
import 'charts.dart';
import 'overview_page.dart' show StatTile;
import 'projects_page.dart' show PageScroll, PageTitle;
import 'widgets.dart';

/// The month's target spend (S$), as on the Overview.
const spendTarget = 15.0;

/// What every GCP project on the billing account costs: this invoice month
/// against the last, each day by project, and by service and SKU. From the
/// Cloud Billing export (`billing/breakdown`); until the export is switched
/// on the page says how, and shows the budget's month-to-date total.
class BillingPage extends ConsumerStatefulWidget {
  const BillingPage({super.key});

  @override
  ConsumerState<BillingPage> createState() => _BillingPageState();
}

class _BillingPageState extends ConsumerState<BillingPage> {
  /// The project the service and SKU panels are narrowed to.
  String? _project;

  @override
  Widget build(BuildContext context) {
    ref.watch(clockProvider);
    return PageScroll(children: [
      const PageTitle(
        title: 'Billing',
        subtitle: 'What every GCP project on the billing account costs, from the Cloud Billing export. '
            'Google updates it a few times a day; amounts are net of credits.',
      ),
      VaAsyncView(
        value: ref.watch(billingBreakdownProvider),
        data: (b) => b == null || b.status != 'ok'
            ? _Setup(breakdown: b)
            : BillingBreakdownView(
                breakdown: b,
                project: _project,
                onProject: (p) => setState(() => _project = p == _project ? null : p),
              ),
      ),
    ]);
  }
}

/// The export is not on yet (or has not landed): how to switch it on, and
/// the budget's figure meanwhile.
class _Setup extends ConsumerWidget {
  const _Setup({required this.breakdown});
  final BillingBreakdown? breakdown;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final budget = ref.watch(billingProvider).value;
    final waiting = breakdown?.status == 'empty';
    final dataset = breakdown?.dataset ?? 'vral-altos.va_billing';
    Widget step(int n, String s) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: VaColors.sunken, shape: BoxShape.circle, border: Border.all(color: VaColors.border)),
          child: Text('$n', style: text.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 10),
        Expanded(child: Padding(padding: const EdgeInsets.only(top: 2), child: Text(s, style: text.bodyMedium))),
      ]),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      VaPanel(
        title: waiting ? 'Waiting for the first export' : 'Switch on the billing export',
        subtitle: waiting
            ? 'The export is on. Google’s first load backfills from the start of last month and can take up to five days.'
            : 'Breakdowns come from Cloud Billing’s BigQuery export. Google only allows switching it on in the Cloud Console; the dataset and access are ready.',
        icon: waiting ? Icons.hourglass_top : Icons.toggle_on_outlined,
        child: waiting
            ? VaEmptyNote('Last checked ${ago(breakdown?.at)} in $dataset (${breakdown?.table ?? 'no table'}).', icon: Icons.schedule)
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                step(1, 'Cloud Console → Billing → Billing export → BigQuery export.'),
                step(2, 'Standard usage cost → Edit settings: project vral-altos, dataset va_billing → Save.'),
                step(3, 'Google backfills from the start of last month (up to five days). This page fills in after the next budget report.'),
                if (breakdown?.at != null)
                  Text('Last checked ${ago(breakdown!.at)}: no export table in $dataset yet.', style: text.labelSmall),
              ]),
      ),
      const SizedBox(height: 14),
      VaResponsiveGrid(minWidth: 220, maxColumns: 3, children: [
        StatTile(
          label: 'GCP spend this month',
          icon: Icons.cloud_outlined,
          value: budget == null ? '—' : money(budget.costAmount, budget.currencyCode),
          sub: budget == null
              ? 'Waiting for the budget’s first report'
              : 'From the budget (total only) · ${ago(budget.updatedAt)}',
          child: budget == null ? null : VaMeter(value: budget.costAmount / spendTarget, warnAt: .66, badAt: 1),
        ),
      ]),
    ]);
  }
}

/// The breakdown itself: totals, the daily chart, projects, services, SKUs.
class BillingBreakdownView extends StatelessWidget {
  const BillingBreakdownView({super.key, required this.breakdown, this.project, required this.onProject, this.now});
  final BillingBreakdown breakdown;
  final String? project;
  final void Function(String) onProject;

  /// For tests; the clock otherwise.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final b = breakdown;
    final cur = b.currency;
    final at = now ?? DateTime.now();

    // How far through the invoice month we are (Cloud Billing's months run
    // on US Pacific time; UTC−8 as the agent mesh counts them).
    final p = at.toUtc().subtract(const Duration(hours: 8));
    final daysInMonth = DateTime.utc(p.year, p.month + 1, 0).day;
    final elapsed = (p.day - 1 + p.hour / 24 + p.minute / 1440) / daysInMonth;
    final projected = elapsed < .03 ? null : b.total / elapsed;

    // Colours: the five costliest projects, the rest together.
    final ranked = [for (final x in b.projects) if (x.net > 0 || x.previous > 0) x];
    final top = ranked.take(5).map((x) => x.id).toList();
    Color colorOf(String id) => top.contains(id) ? VaColors.series[top.indexOf(id) % VaColors.series.length] : VaColors.faint;
    final names = {for (final x in b.projects) x.id: x.name, '~account': 'Billing account'};
    String nameOf(String id) => names[id] ?? (id.isEmpty ? 'Billing account' : id);

    final selected = project;
    final services = [
      for (final s in b.services)
        if (selected == null) (s.name, s.net, s.previous) else if ((s.projects[selected] ?? 0).abs() > 0) (s.name, s.projects[selected]!, null),
    ]..sort((x, y) => y.$2.compareTo(x.$2));
    final skus = [for (final k in b.skus) if (selected == null || k.project == selected) k];
    final change = b.previousTotal <= 0 ? null : b.total / b.previousTotal;

    final daily = _DailyChart(breakdown: b, top: top, colorOf: colorOf, nameOf: nameOf, now: at);
    final byProject = VaPanel(
      title: 'By project',
      subtitle: selected == null ? 'This month and last. Select one to narrow services and SKUs.' : 'Showing ${nameOf(selected)} below. Select again for all.',
      icon: Icons.folder_outlined,
      child: ranked.isEmpty
          ? const VaEmptyNote('Nothing billed this month or last.')
          : Column(children: [
              for (final x in ranked)
                _ProjectRow(
                  project: x,
                  currency: cur,
                  color: colorOf(x.id),
                  max: ranked.map((y) => math.max(y.net, y.previous)).reduce(math.max),
                  selected: selected == x.id,
                  onTap: () => onProject(x.id),
                ),
            ]),
    );
    final byService = VaPanel(
      title: 'By service',
      subtitle: selected == null ? 'This month (last month)' : nameOf(selected),
      icon: Icons.category_outlined,
      child: services.isEmpty
          ? const VaEmptyNote('Nothing billed.')
          : Column(children: [
              for (final s in services.take(12))
                _AmountRow(
                  label: s.$1,
                  amount: money(s.$2, cur),
                  aside: s.$3 == null ? null : money(s.$3, cur),
                  fraction: services.first.$2 <= 0 ? 0 : (s.$2 / services.first.$2).clamp(0, 1).toDouble(),
                  color: Theme.of(context).colorScheme.primary,
                ),
            ]),
    );

    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 900;
      Widget pair(Widget a, Widget b2) => wide
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 3, child: a),
              const SizedBox(width: 14),
              Expanded(flex: 2, child: b2),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [a, const SizedBox(height: 14), b2]);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        VaResponsiveGrid(minWidth: 160, maxColumns: 4, children: [
          StatTile(
            label: 'This month',
            icon: Icons.payments_outlined,
            value: money(b.total, cur),
            sub: '${_monthName(b.month)} so far · ${money(b.cost, cur)} before ${money(-b.credits, cur)} credits',
          ),
          StatTile(
            label: 'At this pace',
            icon: Icons.trending_up,
            accent: projected != null && projected > spendTarget ? VaColors.warning : null,
            value: projected == null ? '—' : money(projected, cur),
            sub: projected == null ? 'Too early in the month to tell' : 'Projected for ${_monthName(b.month)} · target S\$${spendTarget.toStringAsFixed(0)}',
            child: projected == null ? null : VaMeter(value: projected / spendTarget, warnAt: .66, badAt: 1),
          ),
          StatTile(
            label: 'Last month',
            icon: Icons.history,
            value: money(b.previousTotal, cur),
            sub: change == null ? _monthName(b.previousMonth) : '${_monthName(b.previousMonth)} · this month so far is ${pct(change)} of it',
          ),
          StatTile(
            label: 'Costliest project',
            icon: Icons.local_fire_department_outlined,
            value: ranked.isEmpty ? '—' : money(ranked.first.net, cur),
            sub: ranked.isEmpty ? 'Nothing billed yet' : '${ranked.first.name} · ${b.total <= 0 ? '—' : pct(ranked.first.net / b.total)} of the month',
          ),
        ]),
        const SizedBox(height: 14),
        daily,
        const SizedBox(height: 14),
        pair(byProject, byService),
        const SizedBox(height: 14),
        VaPanel(
          title: 'Top SKUs',
          subtitle: selected == null ? 'The month’s largest line items' : 'The month’s largest line items in ${nameOf(selected)}',
          icon: Icons.receipt_long_outlined,
          child: skus.isEmpty
              ? const VaEmptyNote('No line items.')
              : Column(children: [
                  for (final k in skus.take(12))
                    _AmountRow(
                      label: k.sku.isEmpty ? k.service : k.sku,
                      detail: '${k.service} · ${nameOf(k.project)}',
                      amount: money(k.net, cur),
                      fraction: skus.first.net <= 0 ? 0 : (k.net / skus.first.net).clamp(0, 1).toDouble(),
                      color: colorOf(k.project),
                    ),
                ]),
        ),
        const SizedBox(height: 10),
        Text(
          'Exported by Google ${ago(b.exportedAt)} · read ${ago(b.at)} · ${b.dataset ?? 'vral-altos.va_billing'}${b.table == null ? '' : '.${b.table}'}',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ]);
    });
  }
}

String _monthName(String? m) {
  if (m == null || m.length < 7) return '—';
  const names = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final i = int.tryParse(m.substring(5, 7));
  return i == null || i < 1 || i > 12 ? m : '${names[i - 1]} ${m.substring(0, 4)}';
}

/// Each day's net cost for the last 30 operator days, stacked by project.
class _DailyChart extends StatelessWidget {
  const _DailyChart({required this.breakdown, required this.top, required this.colorOf, required this.nameOf, required this.now});
  final BillingBreakdown breakdown;
  final List<String> top;
  final Color Function(String) colorOf;
  final String Function(String) nameOf;
  final DateTime now;

  static const days = 30;

  @override
  Widget build(BuildContext context) {
    // Operator days (Singapore, UTC+8), oldest first.
    final today = now.toUtc().add(const Duration(hours: 8));
    final first = DateTime.utc(today.year, today.month, today.day).subtract(const Duration(days: days - 1));
    final keys = [for (var i = 0; i < days; i++) first.add(Duration(days: i)).toIso8601String().substring(0, 10)];
    double v(String day, bool Function(String) which) =>
        (breakdown.days[day] ?? const {}).entries.where((e) => which(e.key)).fold(0.0, (s, e) => s + e.value);
    final series = <Series>[
      for (final id in top) (name: nameOf(id), color: colorOf(id), values: [for (final d in keys) math.max(0, v(d, (k) => k == id))]),
      if (breakdown.days.values.any((m) => m.keys.any((k) => !top.contains(k))))
        (name: 'Other', color: VaColors.faint, values: [for (final d in keys) math.max(0, v(d, (k) => !top.contains(k)))]),
    ];
    final any = series.any((s) => s.values.any((x) => (x ?? 0) > 0));
    return VaPanel(
      title: 'Daily cost',
      subtitle: 'The last $days days by project (your days, Singapore time). Hover a day for its split.',
      icon: Icons.bar_chart,
      child: !any
          ? const VaEmptyNote('No billed days in the last month.')
          : TimeChart(
              series: series,
              // Singapore midnight of the first day.
              from: first.subtract(const Duration(hours: 8)),
              bucket: const Duration(days: 1),
              stacked: true,
              height: 170,
              format: (x) => money(x, breakdown.currency),
            ),
    );
  }
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.project,
    required this.currency,
    required this.color,
    required this.max,
    required this.selected,
    required this.onTap,
  });
  final BillingProject project;
  final String? currency;
  final Color color;
  final double max;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final x = project;
    double f(double v) => max <= 0 ? 0 : (v / max).clamp(0, 1).toDouble();
    return Semantics(
      button: true,
      selected: selected,
      label: 'Project ${x.name}: ${money(x.net, currency)} this month, ${money(x.previous, currency)} last month',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? scheme.primary.withValues(alpha: .08) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? scheme.primary.withValues(alpha: .4) : Colors.transparent),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  x.name,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                ),
              ),
              if (x.id.isNotEmpty && x.id != x.name) ...[
                Flexible(child: Text(x.id, overflow: TextOverflow.ellipsis, style: text.labelSmall?.copyWith(color: VaColors.faint))),
                const SizedBox(width: 10),
              ],
              Text(money(x.net, currency), style: text.bodyMedium?.copyWith(fontFamily: VaType.mono, fontWeight: FontWeight.w600)),
              SizedBox(
                width: 84,
                child: Text(
                  money(x.previous, currency),
                  textAlign: TextAlign.right,
                  style: text.labelSmall?.copyWith(fontFamily: VaType.mono, color: VaColors.muted),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Stack(children: [
              Container(height: 4, decoration: BoxDecoration(color: VaColors.sunken, borderRadius: BorderRadius.circular(2))),
              FractionallySizedBox(
                widthFactor: f(x.previous),
                child: Container(height: 4, decoration: BoxDecoration(color: VaColors.border, borderRadius: BorderRadius.circular(2))),
              ),
              FractionallySizedBox(
                widthFactor: f(x.net),
                child: Container(height: 4, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
              ),
            ]),
            if (x.credits < 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${money(x.cost, currency)} before ${money(-x.credits, currency)} credits', style: text.labelSmall),
              ),
          ]),
        ),
      ),
    );
  }
}

class _AmountRow extends StatelessWidget {
  const _AmountRow({required this.label, required this.amount, required this.fraction, required this.color, this.aside, this.detail});
  final String label;
  final String? detail;
  final String amount;
  final String? aside;
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: text.bodyMedium, overflow: TextOverflow.ellipsis, maxLines: 2),
              if (detail != null) Text(detail!, style: text.labelSmall?.copyWith(color: VaColors.muted), overflow: TextOverflow.ellipsis),
            ]),
          ),
          const SizedBox(width: 10),
          Text(amount, style: text.bodyMedium?.copyWith(fontFamily: VaType.mono, fontWeight: FontWeight.w600)),
          if (aside != null)
            SizedBox(
              width: 76,
              child: Text(aside!, textAlign: TextAlign.right, style: text.labelSmall?.copyWith(fontFamily: VaType.mono, color: VaColors.muted)),
            ),
        ]),
        const SizedBox(height: 5),
        Stack(children: [
          Container(height: 3, decoration: BoxDecoration(color: VaColors.sunken, borderRadius: BorderRadius.circular(2))),
          FractionallySizedBox(
            widthFactor: fraction,
            child: Container(height: 3, decoration: BoxDecoration(color: color.withValues(alpha: .8), borderRadius: BorderRadius.circular(2))),
          ),
        ]),
      ]),
    );
  }
}
