import 'package:decimal/decimal.dart';

import 'ledger.dart';
import 'model.dart';
import 'reports.dart';

/// How a budget stands in one month. Spending is the month's expense
/// records in the base currency (transfer fees included, refunds
/// entered as negative expenses subtract).
class BudgetStatus {
  BudgetStatus._({
    required this.budget,
    required this.category,
    required this.month,
    required this.spent,
    required this.elapsed,
    required this.daysLeft,
  });

  final Budget budget;

  /// Null for the whole-month total.
  final Category? category;
  final Period month;
  final Decimal spent;

  /// Share of the month gone by the end of today: 1 for past months, 0
  /// for future ones.
  final double elapsed;

  /// Days left in the month, today included; 0 unless it is this month.
  final int daysLeft;

  Decimal get amount => budget.amount;
  Decimal get remaining => amount - spent;
  bool get over => spent > amount;

  /// Share of the budget spent (above 1 when over).
  double get used => (spent / amount).toDouble();

  /// What can still be spent each day, today included, to stay within
  /// the budget. Null outside this month or when nothing is left.
  Decimal? get perDay => daysLeft > 0 && remaining > Decimal.zero
      ? (remaining / Decimal.fromInt(daysLeft)).toDecimal(scaleOnInfinitePrecision: 0).floor()
      : null;

  /// Spending runs more than 10 points ahead of the calendar, so the
  /// budget will run out before the month does at this pace.
  bool get aheadOfPace => !over && daysLeft > 0 && used > elapsed + 0.1;
}

/// Every budget's standing in [month], the total first.
List<BudgetStatus> budgetStatuses(LedgerReader ledger, Period month, {required DateTime today}) {
  final day = DateTime(today.year, today.month, today.day);
  final days = month.to.difference(month.from).inDays + 1;
  final double elapsed;
  final int daysLeft;
  if (day.isAfter(month.to)) {
    (elapsed, daysLeft) = (1, 0);
  } else if (day.isBefore(month.from)) {
    (elapsed, daysLeft) = (0, 0);
  } else {
    final gone = day.difference(month.from).inDays + 1;
    (elapsed, daysLeft) = (gone / days, days - gone + 1);
  }
  final order = {for (final (i, c) in ledger.categories.indexed) c.id: i};
  final budgets = [...ledger.budgets]
    ..sort((a, b) {
      if (a.categoryId == null || b.categoryId == null) {
        return (a.categoryId == null ? 0 : 1) - (b.categoryId == null ? 0 : 1);
      }
      return (order[a.categoryId] ?? 0) - (order[b.categoryId] ?? 0);
    });
  return [
    for (final b in budgets)
      BudgetStatus._(
        budget: b,
        category: b.categoryId == null ? null : ledger.category(b.categoryId!),
        month: month,
        spent: spentIn(ledger, month, categoryId: b.categoryId),
        elapsed: elapsed,
        daysLeft: daysLeft,
      ),
  ];
}

/// Expenses in [period], of one category (with its subcategories) or of
/// all when [categoryId] is null.
Decimal spentIn(LedgerReader ledger, Period period, {String? categoryId}) => ledger
    .transactions(
      TxnFilter(
        from: period.from,
        to: period.to,
        kinds: const {TxnKind.expense},
        categoryIds: categoryId == null ? null : {categoryId},
      ),
    )
    .fold(Decimal.zero, (sum, t) => sum + t.baseAmount);

/// Average monthly spending over the [months] full months before
/// [today]'s month, rounded up to a hundred: a starting point for a new
/// budget. Null when there was no spending.
Decimal? suggestedBudget(LedgerReader ledger, {String? categoryId, required DateTime today, int months = 3}) {
  final totals = monthlyTotals(
    ledger,
    TxnKind.expense,
    end: DateTime(today.year, today.month - 1),
    count: months,
    categoryId: categoryId,
  );
  final sum = totals.fold(Decimal.zero, (s, m) => s + m.total);
  if (sum <= Decimal.zero) return null;
  final hundreds = (sum / Decimal.fromInt(months * 100)).toDecimal(scaleOnInfinitePrecision: 2).ceil();
  return hundreds * Decimal.fromInt(100);
}
