import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../format.dart';
import '../widgets/charts.dart';
import 'category_picker.dart';
import 'category_report_screen.dart';
import 'dialogs.dart';
import 'reports_screen.dart';
import 'transactions_screen.dart';

String _monthLabel(Period p) => '${p.from.year} 年 ${p.from.month} 月';

String budgetName(BudgetStatus s) => switch (s.category) {
  null => '每月總預算',
  final c => c.name,
};

Period _thisMonth(AppState app) {
  final now = app.clock();
  return Period.month(now.year, now.month);
}

/// Every budget for one month, with progress; add, change or remove them.
class BudgetsScreen extends StatefulWidget {
  const BudgetsScreen({super.key, required this.app, this.month});

  final AppState app;

  /// Defaults to this month.
  final Period? month;

  @override
  State<BudgetsScreen> createState() => _BudgetsScreenState();
}

class _BudgetsScreenState extends State<BudgetsScreen> {
  late Period _month = widget.month ?? _thisMonth(widget.app);

  AppState get _app => widget.app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _app,
    builder: (context, _) {
      final statuses = budgetStatuses(_app.view, _month, today: _app.clock());
      final hasTotal = statuses.any((s) => s.category == null);
      return Scaffold(
        appBar: AppBar(title: const Text('預算')),
        floatingActionButton: FloatingActionButton.extended(
          heroTag: null,
          key: const Key('addBudget'),
          onPressed: () => showBudgetEditor(context, _app),
          icon: const Icon(Icons.add),
          label: const Text('新增預算'),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
          children: [
            Row(
              children: [
                IconButton(
                  key: const Key('prevBudgetMonth'),
                  tooltip: '上個月',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => setState(() => _month = _month.previous),
                ),
                Expanded(
                  child: Text(
                    _monthLabel(_month),
                    key: const Key('budgetMonth'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  key: const Key('nextBudgetMonth'),
                  tooltip: '下個月',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => setState(() => _month = _month.next),
                ),
              ],
            ),
            if (statuses.isEmpty)
              const _Intro()
            else ...[
              for (final s in statuses) ...[
                BudgetCard(
                  status: s,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => BudgetDetailScreen(app: _app, budgetId: s.budget.id, month: _month),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              if (!hasTotal)
                TextButton.icon(
                  onPressed: () => showBudgetEditor(context, _app, total: true),
                  icon: const Icon(Icons.add),
                  label: const Text('設定每月總預算'),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '直線是今天：長條超過直線，代表花得比日子過得快。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
    child: Column(
      children: [
        const Icon(Icons.savings_outlined, size: 48),
        const SizedBox(height: 16),
        const Text('還沒有預算', style: TextStyle(fontSize: 20)),
        const SizedBox(height: 8),
        Text(
          '設定每個月總共想花多少，或替某個分類設上限。'
          '這裡會顯示還剩多少、每天還可以花多少，超支時提醒你。',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    ),
  );
}

/// One budget: name, spent of the amount, the meter and what it means.
class BudgetCard extends StatelessWidget {
  const BudgetCard({super.key, required this.status, this.onTap, this.compact = false});

  final BudgetStatus status;
  final VoidCallback? onTap;

  /// For summaries elsewhere: no card chrome.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = status;
    final body = Padding(
      padding: compact ? EdgeInsets.zero : const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(budgetName(s), style: theme.textTheme.titleSmall)),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: formatMoney(s.spent.round(scale: 0)),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    TextSpan(
                      text: ' / ${formatMoney(s.amount)}',
                      style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          BudgetMeter(used: s.used, elapsed: s.daysLeft > 0 ? s.elapsed : null, over: s.over),
          const SizedBox(height: 6),
          BudgetStatusLine(status: s),
        ],
      ),
    );
    if (compact) return InkWell(onTap: onTap, child: body);
    return Card.outlined(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: body),
    );
  }
}

/// What the numbers mean, in words, with an icon where it matters.
class BudgetStatusLine extends StatelessWidget {
  const BudgetStatusLine({super.key, required this.status});

  final BudgetStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = ChartColors.of(context);
    final s = status;
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final (IconData? icon, String text, Color? color) = switch (s) {
      _ when s.over => (Icons.error_outline, '超支 ${formatMoney((-s.remaining).round(scale: 0))}', colors.bad),
      _ when s.daysLeft > 0 => (
        s.aheadOfPace ? Icons.trending_up : null,
        '還剩 ${formatMoney(s.remaining.round(scale: 0))}・每天可花 ${formatMoney(s.perDay!)}'
            '${s.aheadOfPace ? '・花得比進度快' : ''}',
        null,
      ),
      _ when s.elapsed == 0 => (null, '還沒開始', null),
      _ => (Icons.check_circle_outline, '沒有超支，剩下 ${formatMoney(s.remaining.round(scale: 0))}', colors.good),
    };
    return Row(
      key: const Key('budgetStatus'),
      children: [
        if (icon != null) ...[
          Icon(icon, size: 16, color: color ?? theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
        ],
        Expanded(child: Text(text, style: muted?.copyWith(color: color))),
        Text('${(s.used * 100).round()}%', style: muted),
      ],
    );
  }
}

/// One budget over time: this month's standing, the last 12 months
/// against the budget line, and where this month's money went.
class BudgetDetailScreen extends StatelessWidget {
  const BudgetDetailScreen({super.key, required this.app, required this.budgetId, required this.month});

  final AppState app;
  final String budgetId;
  final Period month;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final l = app.view;
      final status = budgetStatuses(l, month, today: app.clock()).where((s) => s.budget.id == budgetId).firstOrNull;
      if (status == null) return const Scaffold(body: SizedBox.shrink()); // just deleted
      final categoryId = status.budget.categoryId;
      final months = monthlyTotals(l, TxnKind.expense, end: month.to, categoryId: categoryId);
      final overMonths = months.where((m) => m.total > status.amount).length;
      final theme = Theme.of(context);
      return Scaffold(
        appBar: AppBar(
          title: Text(budgetName(status)),
          actions: [
            IconButton(
              key: const Key('editBudget'),
              tooltip: '修改',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => showBudgetEditor(context, app, existing: status.budget),
            ),
            IconButton(
              key: const Key('deleteBudget'),
              tooltip: '刪除',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (!await confirm(
                  context,
                  title: '刪除「${budgetName(status)}」？',
                  message: '只會刪除預算，紀錄不受影響。',
                  action: '刪除',
                )) {
                  return;
                }
                app.deleteBudget(budgetId);
                if (context.mounted) Navigator.pop(context);
              },
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(_monthLabel(month), style: theme.textTheme.bodyMedium),
            const SizedBox(height: 8),
            BudgetCard(status: status),
            const SizedBox(height: 16),
            Card.outlined(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('近 12 個月', style: theme.textTheme.titleSmall),
                    Text(
                      overMonths == 0 ? '每個月都在預算內' : '有 $overMonths 個月超過目前的預算',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                    MonthColumns(
                      key: const Key('budgetTrend'),
                      months: months,
                      selected: (month.from.year, month.from.month),
                      reference: status.amount,
                      onSelect: (m) => Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                          builder: (_) => BudgetDetailScreen(app: app, budgetId: budgetId, month: m.period),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (categoryId == null) ...[
              Text('這個月花在哪裡', style: theme.textTheme.titleSmall),
              ..._byCategory(context, l, status),
            ] else ...[
              Text('這個月的紀錄', style: theme.textTheme.titleSmall),
              for (final t in l.transactions(
                TxnFilter(from: month.from, to: month.to, kinds: const {TxnKind.expense}, categoryIds: {categoryId}),
              ))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    [
                      if (t.categoryId != categoryId) l.category(t.categoryId!)?.name,
                      t.invoice?.sellerName ?? t.note,
                    ].whereType<String>().join('・'),
                  ),
                  subtitle: Text(formatDate(t.date)),
                  trailing: Text(formatMoney(t.baseAmount)),
                  onTap: () => openTxnEditor(context, app, t),
                ),
            ],
          ],
        ),
      );
    },
  );

  List<Widget> _byCategory(BuildContext context, LedgerReader l, BudgetStatus status) {
    final rows = byCategory(l, month, TxnKind.expense);
    final max = rows.fold(Decimal.zero, (m, r) => r.total > m ? r.total : m);
    return [
      for (final r in rows)
        CategoryRow(
          row: r,
          max: max,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => CategoryReportScreen(app: app, period: month, kind: TxnKind.expense, main: r.category),
            ),
          ),
        ),
    ];
  }
}

/// Adds a budget ([total] for the whole-month one) or changes [existing].
Future<void> showBudgetEditor(BuildContext context, AppState app, {Budget? existing, bool total = false}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _BudgetEditor(app: app, existing: existing, total: total),
    );

class _BudgetEditor extends StatefulWidget {
  const _BudgetEditor({required this.app, this.existing, this.total = false});

  final AppState app;
  final Budget? existing;
  final bool total;

  @override
  State<_BudgetEditor> createState() => _BudgetEditorState();
}

class _BudgetEditorState extends State<_BudgetEditor> {
  late final _amount = TextEditingController(text: widget.existing?.amount.toString() ?? '');

  /// Null for the whole-month total.
  late String? _categoryId = widget.existing != null ? widget.existing!.categoryId : (widget.total ? null : _firstFree());
  String? _error;

  AppState get _app => widget.app;
  bool get _isNew => widget.existing == null;

  Set<String?> get _taken => {
    for (final b in _app.ledger.budgets)
      if (b.id != widget.existing?.id) b.categoryId,
  };

  /// The total if it is free, else the first main expense category that is.
  String? _firstFree() {
    if (!_taken.contains(null)) return null;
    return _app.ledger.categories
        .where((c) => c.kind == TxnKind.expense && c.parentId == null && !_taken.contains(c.id))
        .firstOrNull
        ?.id;
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _pickScope() async {
    final taken = _taken;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('scopeTotal'),
              leading: const Icon(Icons.account_balance_wallet_outlined),
              title: const Text('每月總預算'),
              subtitle: Text(taken.contains(null) ? '已經設定了' : '所有支出加起來'),
              enabled: !taken.contains(null),
              onTap: () => Navigator.pop(context, ''),
            ),
            ListTile(
              key: const Key('scopeCategory'),
              leading: const Icon(Icons.category_outlined),
              title: const Text('某個分類'),
              subtitle: const Text('主分類包含它的子分類'),
              onTap: () => Navigator.pop(context, 'pick'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == '') {
      setState(() => _categoryId = null);
      return;
    }
    final id = await pickCategory(
      context,
      ledger: _app.ledger,
      kind: TxnKind.expense,
      selectedId: _categoryId,
      mainsSelectable: true,
      disabledIds: {...taken.whereType<String>()},
    );
    if (mounted && id != null) setState(() => _categoryId = id);
  }

  void _save() {
    final amount = Decimal.tryParse(_amount.text.trim().replaceAll(',', ''));
    if (amount == null || amount <= Decimal.zero) {
      setState(() => _error = '請輸入大於 0 的金額');
      return;
    }
    final error = _app.setBudget(
      Budget(id: widget.existing?.id ?? newId('b'), amount: amount, categoryId: _categoryId),
    );
    if (error != null) {
      setState(() => _error = error);
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = _app.view;
    final suggestion = suggestedBudget(l, categoryId: _categoryId, today: _app.clock());
    final scopeLabel = _categoryId == null ? '每月總預算（所有支出）' : categoryLabel(l, _categoryId);
    return AlertDialog(
      title: Text(_isNew ? '新增預算' : '修改預算'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              key: const Key('budgetScope'),
              contentPadding: EdgeInsets.zero,
              title: const Text('範圍'),
              subtitle: Text(scopeLabel),
              trailing: _isNew ? const Icon(Icons.chevron_right) : null,
              onTap: _isNew ? _pickScope : null,
            ),
            TextField(
              key: const Key('budgetAmount'),
              controller: _amount,
              autofocus: !_isNew,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              decoration: InputDecoration(
                labelText: '每月金額',
                prefixText: 'NT\$ ',
                helperText: suggestion == null ? null : '過去 3 個月平均約 ${formatMoney(suggestion)}',
                errorText: _error,
              ),
              onSubmitted: (_) => _save(),
            ),
            if (suggestion != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const Key('useSuggestion'),
                  onPressed: () => setState(() => _amount.text = suggestion.toString()),
                  child: const Text('用平均值'),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(key: const Key('saveBudget'), onPressed: _save, child: const Text('儲存')),
      ],
    );
  }
}

/// This month's budget at a glance, for the top of other screens. Null
/// when there are no budgets.
Widget? budgetSummary(BuildContext context, AppState app) {
  final statuses = budgetStatuses(app.view, _thisMonth(app), today: app.clock());
  if (statuses.isEmpty) return null;
  void open() => Navigator.push(context, MaterialPageRoute(builder: (_) => BudgetsScreen(app: app)));
  final total = statuses.where((s) => s.category == null).firstOrNull;
  if (total != null) {
    return Padding(
      key: const Key('budgetSummary'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: BudgetCard(status: total, onTap: open, compact: true),
    );
  }
  final over = statuses.where((s) => s.over).length;
  return ListTile(
    key: const Key('budgetSummary'),
    leading: Icon(over > 0 ? Icons.error_outline : Icons.savings_outlined),
    title: Text('本月 ${statuses.length} 個分類預算'),
    subtitle: Text(over > 0 ? '$over 個已經超支' : '都還在預算內'),
    trailing: const Icon(Icons.chevron_right),
    onTap: open,
  );
}
