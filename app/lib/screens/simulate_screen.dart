import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import '../widgets/charts.dart';
import 'category_picker.dart';
import 'dialogs.dart';

/// "What if I ate out 3 times less a month?": try cuts to categories and
/// see what they save a month and a year, measured on recent months.
class SimulateScreen extends StatefulWidget {
  const SimulateScreen({super.key, required this.app});

  final AppState app;

  @override
  State<SimulateScreen> createState() => _SimulateScreenState();
}

class _Change {
  _Change(this.categoryId);
  String categoryId;
  var byTimes = false;
  var percent = 10.0;
  var times = 1;

  WhatIf get whatIf => byTimes ? WhatIf.times(categoryId, times) : WhatIf.percent(categoryId, percent);
}

class _SimulateScreenState extends State<SimulateScreen> {
  var _months = 3;
  final _changes = <_Change>[];

  AppState get _app => widget.app;
  LedgerReader get _l => _app.view;

  @override
  void initState() {
    super.initState();
    // Start with where most of the money goes.
    final months = recentMonths(_app.clock(), _months);
    final top = byCategory(_l, Period(months.first.from, months.last.to), TxnKind.expense)
        .where((c) => c.category != null)
        .firstOrNull;
    if (top != null) _changes.add(_Change(top.category!.id));
  }

  /// Spending in the 12 full months before this one.
  bool get _hasOlderSpending {
    final year = recentMonths(_app.clock(), 12);
    return _l.count(TxnFilter(from: year.first.from, to: year.last.to, kinds: const {TxnKind.expense})) > 0;
  }

  SpendingHabit _habit(String id) => spendingHabit(_l, id, today: _app.clock(), months: _months);

  Future<void> _pick(_Change? change) async {
    final id = await pickCategory(
      context,
      ledger: _l,
      kind: TxnKind.expense,
      selectedId: change?.categoryId,
      mainsSelectable: true,
    );
    if (id == null) return;
    setState(() {
      if (change == null) {
        _changes.add(_Change(id));
      } else {
        change.categoryId = id;
        change.times = change.times.clamp(0, _maxTimes(id));
      }
    });
  }

  int _maxTimes(String id) => _habit(id).timesPerMonth.ceil().clamp(1, 60);

  /// Each cut category's new monthly amount, rounded up to 100, as budgets.
  Future<void> _applyAsBudgets(SimulationResult r) async {
    final plan = <(String, Decimal)>[];
    for (final (i, c) in _changes.indexed) {
      if (r.savings[i] <= Decimal.zero) continue;
      final after = _habit(c.categoryId).monthly - r.savings[i];
      final rounded = Decimal.fromInt(((after.toDouble() / 100).ceil() * 100).clamp(100, 1 << 31));
      plan.add((c.categoryId, rounded));
    }
    if (plan.isEmpty) return;
    final ok = await confirm(
      context,
      title: '設成每月預算？',
      message: [for (final (id, amount) in plan) '${categoryLabel(_l, id)}：${formatMoney(amount)}'].join('\n'),
      action: '設定',
    );
    if (!ok || !mounted) return;
    for (final (id, amount) in plan) {
      final existing = _app.ledger.budgets.where((b) => b.categoryId == id).firstOrNull;
      _app.setBudget(Budget(id: existing?.id ?? newId('b'), amount: amount, categoryId: id));
    }
    showMessage(context, '已設定 ${plan.length} 個預算');
  }

  void _askAi(SimulationResult r) {
    final lines = [
      for (final (i, c) in _changes.indexed)
        '- ${categoryLabel(_l, c.categoryId)}：${c.byTimes ? '每月少 ${c.times} 次' : '少 ${c.percent.round()}%'}，'
            '每月省 ${formatMoney(r.savings[i])}',
    ];
    _app.askAssistant(
      [
        '我想調整開銷，下面是用最近 $_months 個月平均試算的結果。請查帳看看這個計畫實不實際，'
            '哪些比較容易做到、哪些可能太難，還有沒有其他值得省的地方：',
        ...lines,
        '合計每月省 ${formatMoney(r.monthlySaving)}，一年 ${formatMoney(r.yearlySaving)}。',
      ].join('\n'),
    );
    Navigator.popUntil(context, (route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = simulate(_l, [for (final c in _changes) c.whatIf], today: _app.clock(), months: _months);
    final months = recentMonths(_app.clock(), _months);
    final from = months.first.from, to = months.last.from;
    return Scaffold(
      appBar: AppBar(title: const Text('省錢試算')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            '用 ${from.year}/${from.month}–${to.year}/${to.month} 這 $_months 個月的平均來算',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            key: const Key('simMonths'),
            segments: const [
              ButtonSegment(value: 3, label: Text('3 個月')),
              ButtonSegment(value: 6, label: Text('6 個月')),
              ButtonSegment(value: 12, label: Text('12 個月')),
            ],
            selected: {_months},
            onSelectionChanged: (s) => setState(() => _months = s.single),
          ),
          const SizedBox(height: 16),
          if (result.spending == Decimal.zero)
            Card.outlined(
              key: const Key('simNoHistory'),
              margin: const EdgeInsets.only(bottom: 16),
              child: ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('這段期間沒有支出紀錄'),
                subtitle: Text(
                  '試算用的是完整月份的平均（不含這個月）。'
                  '${_months < 12 && _hasOlderSpending ? '可以改用 12 個月，或' : ''}記滿一個月後再來試試。',
                ),
              ),
            ),
          for (final (i, c) in _changes.indexed) ...[
            _ChangeCard(
              key: Key('change-$i'),
              ledger: _l,
              change: c,
              habit: _habit(c.categoryId),
              saving: result.savings[i],
              onPick: () => _pick(c),
              onRemove: () => setState(() => _changes.removeAt(i)),
              onChanged: () => setState(() {}),
            ),
            const SizedBox(height: 8),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('addChange'),
              onPressed: () => _pick(null),
              icon: const Icon(Icons.add),
              label: const Text('再加一個分類'),
            ),
          ),
          const SizedBox(height: 8),
          _ResultCard(result: result),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                key: const Key('applyAsBudgets'),
                onPressed: result.monthlySaving > Decimal.zero ? () => _applyAsBudgets(result) : null,
                icon: const Icon(Icons.savings_outlined),
                label: const Text('設成每月預算'),
              ),
              OutlinedButton.icon(
                key: const Key('askAiPlan'),
                onPressed: _changes.isEmpty ? null : () => _askAi(result),
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('請 AI 評估這個計畫'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChangeCard extends StatelessWidget {
  const _ChangeCard({
    super.key,
    required this.ledger,
    required this.change,
    required this.habit,
    required this.saving,
    required this.onPick,
    required this.onRemove,
    required this.onChanged,
  });

  final LedgerReader ledger;
  final _Change change;
  final SpendingHabit habit;
  final Decimal saving;
  final VoidCallback onPick, onRemove, onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = change;
    final maxTimes = habit.timesPerMonth.ceil().clamp(1, 60);
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              key: const Key('changeCategory'),
              contentPadding: EdgeInsets.zero,
              title: Text(categoryLabel(ledger, c.categoryId)),
              subtitle: Text(
                habit.monthly == Decimal.zero
                    ? '這段期間沒有紀錄'
                    : '平均每月 ${formatMoney(habit.monthly.round(scale: 0))}・'
                          '約 ${habit.timesPerMonth.toStringAsFixed(habit.timesPerMonth < 10 ? 1 : 0)} 次・'
                          '每次約 ${formatMoney(habit.perTime.round(scale: 0))}',
              ),
              onTap: onPick,
              trailing: IconButton(tooltip: '移除', icon: const Icon(Icons.close), onPressed: onRemove),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: SegmentedButton<bool>(
                key: const Key('changeMode'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('少幾成')),
                  ButtonSegment(value: true, label: Text('每月少幾次')),
                ],
                selected: {c.byTimes},
                onSelectionChanged: (s) {
                  c.byTimes = s.single;
                  c.times = c.times.clamp(0, maxTimes);
                  onChanged();
                },
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: c.byTimes
                      ? Slider(
                          key: const Key('changeAmount'),
                          value: c.times.clamp(0, maxTimes).toDouble(),
                          max: maxTimes.toDouble(),
                          divisions: maxTimes,
                          label: '少 ${c.times} 次',
                          onChanged: (v) {
                            c.times = v.round();
                            onChanged();
                          },
                        )
                      : Slider(
                          key: const Key('changeAmount'),
                          value: c.percent,
                          max: 100,
                          divisions: 20,
                          label: '少 ${c.percent.round()}%',
                          onChanged: (v) {
                            c.percent = v;
                            onChanged();
                          },
                        ),
                ),
                SizedBox(
                  width: 72,
                  child: Text(
                    c.byTimes ? '少 ${c.times} 次' : '少 ${c.percent.round()}%',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                '每月省 ${formatMoney(saving)}',
                key: const Key('changeSaving'),
                style: theme.textTheme.titleSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final SimulationResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = result;
    String rate(double? x) => x == null ? '—' : '${(x * 100).round()}%';
    Widget row(String label, String before, String after) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(before, style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.arrow_forward, size: 16)),
          Text(after, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
    return Card.outlined(
      key: const Key('simResult'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('每月省', style: theme.textTheme.labelLarge),
            Text(
              formatMoney(r.monthlySaving),
              key: const Key('monthlySaving'),
              style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            Text('一年省 ${formatMoney(r.yearlySaving)}', key: const Key('yearlySaving')),
            const SizedBox(height: 12),
            row('每月支出', formatMoney(r.spending.round(scale: 0)), formatMoney(r.spendingAfter.round(scale: 0))),
            if (r.income > Decimal.zero) ...[
              row('每月結餘', formatMoney(r.leftBefore.round(scale: 0)), formatMoney(r.leftAfter.round(scale: 0))),
              row('儲蓄率', rate(r.savingsRateBefore), rate(r.savingsRateAfter)),
            ],
            if (r.spending > Decimal.zero) ...[
              const SizedBox(height: 12),
              Text('支出：現在', style: theme.textTheme.bodySmall),
              const ShareBar(fraction: 1),
              const SizedBox(height: 6),
              Text('支出：照計畫', style: theme.textTheme.bodySmall),
              ShareBar(fraction: fractionOf(r.spendingAfter, r.spending)),
            ],
          ],
        ),
      ),
    );
  }
}
