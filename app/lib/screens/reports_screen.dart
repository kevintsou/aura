import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import '../widgets/charts.dart';
import 'budgets_screen.dart';
import 'category_picker.dart';
import 'category_report_screen.dart';
import 'transactions_screen.dart';

/// Weekly, monthly or yearly overview: totals with change, a trend of the
/// last periods, where the money went (by category, account or project)
/// and how net worth moved.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, required this.app});

  final AppState app;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

enum _Span { week, month, year }

/// What the trend shows: expenses, income, or income minus expenses.
enum _Measure { expense, income, net }

enum _Group { category, account, project }

class _ReportData {
  _ReportData(AppState app, this.period, this.measure, this.group)
    : totals = totalsFor(app.view, period),
      previous = totalsFor(app.view, period.previous),
      trend = period.isYear
          ? periodTotals(app.view, _kindOf(measure), end: Period.month(period.from.year, 12))
          : periodTotals(app.view, _kindOf(measure), end: period),
      categories = measure == _Measure.net ? const [] : byCategory(app.view, period, _kindOf(measure)!),
      groups = switch ((measure, group)) {
        (_Measure.net, _) || (_, _Group.category) => const [],
        (_, _Group.account) => byAccount(app.view, period, _kindOf(measure)!),
        (_, _Group.project) => byProject(app.view, period, _kindOf(measure)!),
      },
      insights = period.isYear || period.isWeek || period.from.isAfter(app.clock())
          ? const []
          : app.insightsFor(period),
      netWorth = period.isWeek
          ? const []
          : netWorthByMonth(
              app.view,
              {
                for (final e in app.balances.entries)
                  if (!app.hiddenAccountIds.contains(e.key)) e.key: e.value,
              },
              app.rates,
              [for (var i = 11; i >= 0; i--) Period.month(period.to.year, period.to.month - i)],
              today: app.clock(),
            );

  final Period period;
  final _Measure measure;
  final _Group group;
  final Totals totals;
  final Totals previous;
  final List<PeriodTotal> trend;
  final List<CategoryTotal> categories;
  final List<GroupTotal> groups;
  final List<PeriodTotal> netWorth;
  final List<Insight> insights;
}

TxnKind? _kindOf(_Measure m) => switch (m) {
  _Measure.expense => TxnKind.expense,
  _Measure.income => TxnKind.income,
  _Measure.net => null,
};

class _ReportsScreenState extends State<ReportsScreen> {
  Period? _period;
  var _measure = _Measure.expense;
  var _group = _Group.category;
  _ReportData? _data;
  int? _revision;

  AppState get _app => widget.app;

  /// Starts on this month, or on the newest records' month when this
  /// month is empty (e.g. right after importing an older CWMoney export).
  Period _initialPeriod() {
    final now = _app.clock();
    final thisMonth = Period.month(now.year, now.month);
    if (_app.view.count(TxnFilter(from: thisMonth.from, to: thisMonth.to)) > 0) {
      return thisMonth;
    }
    final latest = latestRecordMonth(_app.view);
    return latest == null ? thisMonth : Period.month(latest.year, latest.month);
  }

  _ReportData _load() {
    final period = _period ??= _initialPeriod();
    final d = _data;
    if (d == null || _revision != _app.revision || d.period != period || d.measure != _measure || d.group != _group) {
      _revision = _app.revision;
      _data = _ReportData(_app, period, _measure, _group);
    }
    return _data!;
  }

  void _setPeriod(Period p) => setState(() => _period = p);

  _Span _spanOf(Period p) => p.isYear
      ? _Span.year
      : p.isWeek
      ? _Span.week
      : _Span.month;

  void _setSpan(_Span span) {
    final p = _period!;
    // Keep roughly the same place in time: the period's last day.
    final anchor = p.to.isAfter(_app.clock()) ? _app.clock() : p.to;
    _setPeriod(switch (span) {
      _Span.week => Period.week(anchor),
      _Span.month => Period.month(p.to.year, p.to.month),
      _Span.year => Period.year(p.from.year),
    });
  }

  static String periodLabel(Period p) {
    final f = p.from, t = p.to;
    if (p.isYear) return '${f.year} 年';
    if (p.isWeek) return '${f.month}/${f.day}–${t.month}/${t.day}';
    return '${f.year} 年 ${f.month} 月';
  }

  String _trendTitle(Period p, String what) => switch (_spanOf(p)) {
    _Span.year => '${p.from.year} 年每月$what',
    _Span.month => '近 12 個月$what',
    _Span.week => '近 12 週$what',
  };

  void _openRecords(String title, TxnFilter filter, {Set<String>? ids}) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => RecordsReportScreen(app: _app, title: title, filter: filter, ids: ids),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _app,
    builder: (context, _) {
      final data = _load();
      final p = data.period;
      final what = switch (_measure) {
        _Measure.expense => '支出',
        _Measure.income => '收入',
        _Measure.net => '結餘',
      };
      final kind = _kindOf(_measure);
      final span = _spanOf(p);
      return Scaffold(
        appBar: AppBar(
          title: const Text('報表'),
          actions: [
            TextButton.icon(
              key: const Key('openBudgets'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => BudgetsScreen(app: _app, month: p.isYear || p.isWeek ? null : p),
                ),
              ),
              icon: const Icon(Icons.savings_outlined),
              label: const Text('預算'),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Row(
              children: [
                SegmentedButton<_Span>(
                  key: const Key('spanToggle'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: _Span.week, label: Text('週')),
                    ButtonSegment(value: _Span.month, label: Text('月')),
                    ButtonSegment(value: _Span.year, label: Text('年')),
                  ],
                  selected: {span},
                  onSelectionChanged: (s) => _setSpan(s.single),
                ),
                const Spacer(),
                IconButton(
                  key: const Key('prevPeriod'),
                  tooltip: '上一期',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => _setPeriod(p.previous),
                ),
                Text(periodLabel(p), key: const Key('periodLabel'), style: Theme.of(context).textTheme.titleMedium),
                IconButton(
                  key: const Key('nextPeriod'),
                  tooltip: '下一期',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => _setPeriod(p.next),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _KpiRow(
              data: data,
              periodWord: switch (span) {
                _Span.week => '上週',
                _Span.month => '上月',
                _Span.year => '去年',
              },
            ),
            if (data.insights.isNotEmpty) ...[
              const SizedBox(height: 16),
              _InsightsCard(app: _app, month: p, insights: data.insights, onOpenRecords: _openRecords),
            ],
            const SizedBox(height: 16),
            SegmentedButton<_Measure>(
              key: const Key('kindToggle'),
              segments: const [
                ButtonSegment(value: _Measure.expense, label: Text('支出')),
                ButtonSegment(value: _Measure.income, label: Text('收入')),
                ButtonSegment(value: _Measure.net, label: Text('結餘')),
              ],
              selected: {_measure},
              onSelectionChanged: (s) => setState(() => _measure = s.single),
            ),
            const SizedBox(height: 16),
            _Section(
              title: _trendTitle(p, what),
              subtitle: p.isYear ? '點長條看那個月' : '點長條切換到那一期',
              child: PeriodColumns(
                key: const Key('trendChart'),
                months: data.trend,
                selected: p.isYear ? null : p,
                onSelect: (m) => _setPeriod(m.period),
              ),
            ),
            if (kind != null) ...[
              const SizedBox(height: 16),
              _Section(
                title: '$what來源',
                subtitle:
                    '${periodLabel(p)}共 ${formatMoney(kind == TxnKind.expense ? data.totals.expense : data.totals.income)}',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SegmentedButton<_Group>(
                      key: const Key('groupToggle'),
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: _Group.category, label: Text('分類')),
                        ButtonSegment(value: _Group.account, label: Text('帳戶')),
                        ButtonSegment(value: _Group.project, label: Text('專案')),
                      ],
                      selected: {_group},
                      onSelectionChanged: (s) => setState(() => _group = s.single),
                    ),
                    const SizedBox(height: 8),
                    if (data.categories.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: Text('${periodLabel(p)}沒有$what紀錄')),
                      )
                    else if (_group == _Group.category)
                      _CategoryList(
                        rows: data.categories,
                        onTap: (row) => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => CategoryReportScreen(app: _app, period: p, kind: kind, main: row.category),
                          ),
                        ),
                      )
                    else
                      _GroupList(
                        rows: data.groups,
                        onTap: (g) => _openRecords(
                          '${g.label}・${periodLabel(p)}',
                          TxnFilter(
                            from: p.from,
                            to: p.to,
                            kinds: {kind},
                            accountIds: _group == _Group.account && g.id != null ? {g.id!} : null,
                            projectIds: _group == _Group.project && g.id != null ? {g.id!} : null,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (data.netWorth.isNotEmpty) ...[
              const SizedBox(height: 16),
              _Section(
                title: '淨資產走勢',
                subtitle: '每月底的淨資產，外幣用目前的匯率換算',
                child: PeriodColumns(
                  key: const Key('netWorthChart'),
                  months: data.netWorth,
                  selected: data.netWorth.last.period,
                  onSelect: (_) {},
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}

/// What stands out in the month, each line linking to what it is about,
/// and a way to have the assistant write it up.
class _InsightsCard extends StatelessWidget {
  const _InsightsCard({required this.app, required this.month, required this.insights, required this.onOpenRecords});

  final AppState app;
  final Period month;
  final List<Insight> insights;
  final void Function(String title, TxnFilter filter, {Set<String>? ids}) onOpenRecords;

  static IconData _icon(InsightKind k) => switch (k) {
    InsightKind.total => Icons.summarize_outlined,
    InsightKind.categoryUp => Icons.trending_up,
    InsightKind.categoryDown => Icons.trending_down,
    InsightKind.unusual => Icons.priority_high,
    InsightKind.duplicate => Icons.content_copy_outlined,
    InsightKind.overBudget => Icons.error_outline,
    InsightKind.fastBudget => Icons.speed,
  };

  VoidCallback? _onTap(BuildContext context, Insight i) {
    final label = _ReportsScreenState.periodLabel(month);
    switch (i.kind) {
      case InsightKind.categoryUp || InsightKind.categoryDown when i.categoryId != null:
        final cat = app.view.category(i.categoryId!);
        return () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CategoryReportScreen(app: app, period: month, kind: TxnKind.expense, main: cat),
          ),
        );
      case InsightKind.unusual || InsightKind.duplicate when i.txnIds.isNotEmpty:
        final dates = [for (final id in i.txnIds) ?app.view.txn(id)?.date]..sort();
        if (dates.isEmpty) return null;
        return () => onOpenRecords(
          i.kind == InsightKind.duplicate ? '可能重複・$label' : '特別大的支出・$label',
          TxnFilter(from: dates.first, to: dates.last),
          ids: {...i.txnIds},
        );
      case InsightKind.overBudget || InsightKind.fastBudget:
        return () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => BudgetsScreen(app: app, month: month)),
        );
      default:
        return null;
    }
  }

  String _prompt() {
    final f = month.from;
    return [
      '請幫我寫 ${f.year} 年 ${f.month} 月的月報：整體收支、和之前比起來的變化、值得注意的地方，最後給我幾個具體的建議。'
          'App 先找到了下面這些重點，請用查帳工具核對後再寫：',
      for (final i in insights) '- ${i.text}',
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Section(
      key: const Key('insights'),
      title: '${month.from.month} 月重點',
      subtitle: '和前三個月比較，點一下看細節',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (n, i) in insights.indexed)
            ListTile(
              key: Key('insight-$n'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                _icon(i.kind),
                color: switch (i.kind) {
                  InsightKind.overBudget || InsightKind.duplicate || InsightKind.unusual => theme.colorScheme.error,
                  _ => theme.colorScheme.onSurfaceVariant,
                },
              ),
              title: Text(i.text),
              trailing: _onTap(context, i) == null ? null : const Icon(Icons.chevron_right, size: 18),
              onTap: _onTap(context, i),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('askAiReport'),
              onPressed: () => app.askAssistant(_prompt()),
              icon: const Icon(Icons.auto_awesome_outlined),
              label: const Text('請 AI 寫月報'),
            ),
          ),
        ],
      ),
    );
  }
}

class _KpiRow extends StatelessWidget {
  const _KpiRow({required this.data, required this.periodWord});

  final _ReportData data;
  final String periodWord;

  @override
  Widget build(BuildContext context) {
    final t = data.totals, prev = data.previous;
    return Row(
      children: [
        Expanded(
          child: _StatTile(
            key: const Key('kpiExpense'),
            label: '支出',
            value: t.expense,
            change: percentChange(prev.expense, t.expense),
            upIsGood: false,
            periodWord: periodWord,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatTile(
            key: const Key('kpiIncome'),
            label: '收入',
            value: t.income,
            change: percentChange(prev.income, t.income),
            upIsGood: true,
            periodWord: periodWord,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatTile(key: const Key('kpiNet'), label: '結餘', value: t.net, periodWord: periodWord),
        ),
      ],
    );
  }
}

/// Label, value and (optionally) the change against the previous period,
/// shown as arrow + words + colour, never colour alone.
class _StatTile extends StatelessWidget {
  const _StatTile({
    super.key,
    required this.label,
    required this.value,
    required this.periodWord,
    this.change,
    this.upIsGood = true,
  });

  final String label;
  final Decimal value;
  final String periodWord;
  final double? change;
  final bool upIsGood;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = ChartColors.of(context);
    final c = change;
    final flat = c != null && c.abs() < 0.5;
    final good = c != null && !flat && (c > 0) == upIsGood;
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                formatMoney(value.round(scale: 0)),
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            if (c != null) ...[
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    Icon(
                      flat ? Icons.remove : (c > 0 ? Icons.arrow_upward : Icons.arrow_downward),
                      size: 14,
                      color: flat ? theme.colorScheme.onSurfaceVariant : (good ? colors.good : colors.bad),
                    ),
                    Text(
                      flat ? '與$periodWord持平' : '比$periodWord${c > 0 ? '多' : '少'} ${c.abs().toStringAsFixed(0)}%',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: flat ? theme.colorScheme.onSurfaceVariant : (good ? colors.good : colors.bad),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({super.key, required this.title, required this.child, this.subtitle});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            if (subtitle != null)
              Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// Ranked categories: name and amount as text, share as a single-hue bar.
/// Doubles as the table view: every value is written out.
class _CategoryList extends StatelessWidget {
  const _CategoryList({required this.rows, required this.onTap});

  final List<CategoryTotal> rows;
  final ValueChanged<CategoryTotal> onTap;

  @override
  Widget build(BuildContext context) {
    final max = rows.fold(Decimal.zero, (m, r) => r.total > m ? r.total : m);
    return Column(
      children: [for (final r in rows) CategoryRow(row: r, max: max, onTap: () => onTap(r))],
    );
  }
}

class _GroupList extends StatelessWidget {
  const _GroupList({required this.rows, required this.onTap});

  final List<GroupTotal> rows;
  final ValueChanged<GroupTotal> onTap;

  @override
  Widget build(BuildContext context) {
    final max = rows.fold(Decimal.zero, (m, r) => r.total > m ? r.total : m);
    return Column(
      children: [
        for (final g in rows) ShareRow(label: g.label, total: g.total, share: g.share, max: max, onTap: () => onTap(g)),
      ],
    );
  }
}

class CategoryRow extends StatelessWidget {
  const CategoryRow({super.key, required this.row, required this.max, this.onTap, this.label});

  final CategoryTotal row;
  final Decimal max;
  final VoidCallback? onTap;

  /// Overrides the category name.
  final String? label;

  @override
  Widget build(BuildContext context) =>
      ShareRow(label: label ?? row.category?.name ?? '未分類', total: row.total, share: row.share, max: max, onTap: onTap);
}

/// Name, amount and share as text, with a single-hue bar of the share.
class ShareRow extends StatelessWidget {
  const ShareRow({
    super.key,
    required this.label,
    required this.total,
    required this.share,
    required this.max,
    this.onTap,
  });

  final String label;
  final Decimal total;
  final double share;
  final Decimal max;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(label)),
                Text(formatMoney(total.round(scale: 0)), style: const TextStyle(fontWeight: FontWeight.w600)),
                SizedBox(
                  width: 52,
                  child: Text(
                    '${share.toStringAsFixed(1)}%',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
                if (onTap != null) Icon(Icons.chevron_right, size: 18, color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
            const SizedBox(height: 6),
            ShareBar(fraction: fractionOf(total, max)),
          ],
        ),
      ),
    );
  }
}

/// Records matching a filter, with their total (drill-down from reports).
class RecordsReportScreen extends StatelessWidget {
  const RecordsReportScreen({super.key, required this.app, required this.title, required this.filter, this.ids});

  final AppState app;
  final String title;
  final TxnFilter filter;

  /// Only these records (of those the filter finds).
  final Set<String>? ids;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final l = app.view;
      final txns = [
        for (final t in l.transactions(filter))
          if (ids == null || ids!.contains(t.id)) t,
      ];
      final total = txns.fold(Decimal.zero, (s, t) => s + t.baseAmount);
      final theme = Theme.of(context);
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('${txns.length} 筆', style: theme.textTheme.bodyMedium),
            Text(formatMoney(total), key: const Key('recordsTotal'), style: theme.textTheme.headlineSmall),
            const SizedBox(height: 16),
            for (final t in txns)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  [
                    if (t.categoryId != null) categoryLabel(l, t.categoryId),
                    t.invoice?.sellerName ?? t.note,
                  ].whereType<String>().join('・'),
                ),
                subtitle: Text(formatDate(t.date)),
                trailing: Text(formatMoney(t.baseAmount)),
                onTap: () => openTxnEditor(context, app, t),
              ),
          ],
        ),
      );
    },
  );
}
