import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import '../widgets/amount_list_tile.dart';
import 'reports_screen.dart';
import 'transactions_screen.dart';

/// One main category in a period: its subcategories and its records.
class CategoryReportScreen extends StatelessWidget {
  const CategoryReportScreen({
    super.key,
    required this.app,
    required this.period,
    required this.kind,
    required this.main,
  });

  final AppState app;
  final Period period;
  final TxnKind kind;

  /// Null for records without a category.
  final Category? main;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final l = app.view;
      final subs = main == null ? const <CategoryTotal>[] : byCategory(l, period, kind, parentId: main!.id);
      final txns = [
        for (final t in l.transactions(
          TxnFilter(from: period.from, to: period.to, kinds: {kind}, categoryIds: main == null ? null : {main!.id}),
        ))
          if (main != null || t.categoryId == null) t,
      ];
      final total = txns.fold(Decimal.zero, (s, t) => s + t.baseAmount);
      final max = subs.fold(Decimal.zero, (m, r) => r.total > m ? r.total : m);
      final label = period.isYear ? '${period.from.year} 年' : '${period.from.year} 年 ${period.from.month} 月';
      final theme = Theme.of(context);
      return Scaffold(
        appBar: AppBar(title: Text(main?.name ?? '未分類')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('$label・${txns.length} 筆', style: theme.textTheme.bodyMedium),
            Text(
              formatMoney(total),
              key: const Key('categoryTotal'),
              style: theme.textTheme.headlineSmall?.copyWith(color: moneyColor(context, total)),
            ),
            if (subs.length > 1 || (subs.length == 1 && subs.single.category?.id != main?.id)) ...[
              const SizedBox(height: 16),
              Text('子分類', style: theme.textTheme.titleSmall),
              for (final r in subs) CategoryRow(row: r, max: max, label: r.category?.id == main?.id ? '（未細分）' : null),
            ],
            const SizedBox(height: 16),
            Text('紀錄', style: theme.textTheme.titleSmall),
            for (final t in txns)
              AmountListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  [
                    if (t.categoryId != null && t.categoryId != main?.id) l.category(t.categoryId!)?.name,
                    t.invoice?.sellerName ?? t.note,
                  ].whereType<String>().join('・'),
                ),
                subtitle: Text(formatDate(t.date)),
                trailing: Text(formatMoney(t.baseAmount), style: moneyStyle(context, t.baseAmount)),
                onTap: () => openTxnEditor(context, app, t),
              ),
          ],
        ),
      );
    },
  );
}
