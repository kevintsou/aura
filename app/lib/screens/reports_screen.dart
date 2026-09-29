import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import '../widgets/charts.dart';
import 'category_report_screen.dart';

/// Monthly or yearly overview: totals with change, a 12-month trend and
/// where the money went, by category.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, required this.app});

  final AppState app;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportData {
  _ReportData(LedgerReader l, this.period, this.kind)
    : totals = totalsFor(l, period),
      previous = totalsFor(l, period.previous),
      months = monthlyTotals(l, kind, end: period.to),
      categories = byCategory(l, period, kind);

  final Period period;
  final TxnKind kind;
  final Totals totals;
  final Totals previous;
  final List<MonthTotal> months;
  final List<CategoryTotal> categories;
}

class _ReportsScreenState extends State<ReportsScreen> {
  Period? _period;
  var _kind = TxnKind.expense;
  _ReportData? _data;
  int? _revision;

  AppState get _app => widget.app;

  /// Starts on this month, or on the newest records' month when this
  /// month is empty (e.g. right after importing an older CWMoney export).
  Period _initialPeriod() {
    final now = _app.clock();
    final thisMonth = Period.month(now.year, now.month);
    if (_app.ledger.count(TxnFilter(from: thisMonth.from, to: thisMonth.to)) > 0) {
      return thisMonth;
    }
    final latest = latestRecordMonth(_app.ledger);
    return latest == null ? thisMonth : Period.month(latest.year, latest.month);
  }

  _ReportData _load() {
    final period = _period ??= _initialPeriod();
    final d = _data;
    if (d == null || _revision != _app.revision || d.period != period || d.kind != _kind) {
      _revision = _app.revision;
      _data = _ReportData(_app.ledger, period, _kind);
    }
    return _data!;
  }

  void _setPeriod(Period p) => setState(() => _period = p);

  String _periodLabel(Period p) =>
      p.isYear ? '${p.from.year} 年' : '${p.from.year} 年 ${p.from.month} 月';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _app,
    builder: (context, _) {
      final data = _load();
      final p = data.period;
      final kindLabel = _kind == TxnKind.expense ? '支出' : '收入';
      return Scaffold(
        appBar: AppBar(title: const Text('報表')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Row(
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('月')),
                    ButtonSegment(value: true, label: Text('年')),
                  ],
                  selected: {p.isYear},
                  onSelectionChanged: (s) => _setPeriod(
                    s.single ? Period.year(p.from.year) : Period.month(p.from.year, p.isYear ? p.to.month : p.from.month),
                  ),
                ),
                const Spacer(),
                IconButton(
                  key: const Key('prevPeriod'),
                  tooltip: '上一期',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => _setPeriod(p.previous),
                ),
                Text(_periodLabel(p), key: const Key('periodLabel'), style: Theme.of(context).textTheme.titleMedium),
                IconButton(
                  key: const Key('nextPeriod'),
                  tooltip: '下一期',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => _setPeriod(p.next),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _KpiRow(data: data, periodWord: p.isYear ? '去年' : '上月'),
            const SizedBox(height: 16),
            SegmentedButton<TxnKind>(
              key: const Key('kindToggle'),
              segments: const [
                ButtonSegment(value: TxnKind.expense, label: Text('支出')),
                ButtonSegment(value: TxnKind.income, label: Text('收入')),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.single),
            ),
            const SizedBox(height: 16),
            _Section(
              title: p.isYear ? '${p.from.year} 年每月$kindLabel' : '近 12 個月$kindLabel',
              subtitle: p.isYear ? '點長條看那個月' : '點長條切換月份',
              child: MonthColumns(
                key: const Key('trendChart'),
                months: data.months,
                selected: p.isYear ? null : (p.from.year, p.from.month),
                onSelect: (m) => _setPeriod(m.period),
              ),
            ),
            const SizedBox(height: 16),
            _Section(
              title: '$kindLabel分類',
              subtitle: data.categories.isEmpty
                  ? null
                  : '${_periodLabel(p)}共 ${formatMoney(_kind == TxnKind.expense ? data.totals.expense : data.totals.income)}',
              child: data.categories.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: Text('${_periodLabel(p)}沒有$kindLabel紀錄')),
                    )
                  : _CategoryList(
                      rows: data.categories,
                      onTap: (row) => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => CategoryReportScreen(
                            app: _app,
                            period: p,
                            kind: _kind,
                            main: row.category,
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      );
    },
  );
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
          child: _StatTile(
            key: const Key('kpiNet'),
            label: '結餘',
            value: t.net,
            periodWord: periodWord,
          ),
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
  const _Section({required this.title, required this.child, this.subtitle});

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
    return Column(children: [for (final r in rows) CategoryRow(row: r, max: max, onTap: () => onTap(r))]);
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
                Expanded(child: Text(label ?? row.category?.name ?? '未分類')),
                Text(formatMoney(row.total.round(scale: 0)), style: const TextStyle(fontWeight: FontWeight.w600)),
                SizedBox(
                  width: 52,
                  child: Text(
                    '${row.share.toStringAsFixed(1)}%',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
                if (onTap != null) Icon(Icons.chevron_right, size: 18, color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
            const SizedBox(height: 6),
            ShareBar(fraction: fractionOf(row.total, max)),
          ],
        ),
      ),
    );
  }
}
