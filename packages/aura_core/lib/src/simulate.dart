import 'package:decimal/decimal.dart';

import 'ledger.dart';
import 'model.dart';
import 'reports.dart';

/// How much a category usually costs a month, over recent full months.
class SpendingHabit {
  const SpendingHabit({required this.categoryId, required this.monthly, required this.timesPerMonth});

  final String categoryId;

  /// Average spending a month (subcategories included).
  final Decimal monthly;

  /// Average number of records a month.
  final double timesPerMonth;

  /// Average cost of one record.
  Decimal get perTime => timesPerMonth == 0
      ? Decimal.zero
      : (monthly / Decimal.parse(timesPerMonth.toStringAsFixed(4))).toDecimal(scaleOnInfinitePrecision: 2);
}

/// The [months] full months before [today]'s month, oldest first.
List<Period> recentMonths(DateTime today, int months) => [
  for (var i = months; i >= 1; i--) Period.month(today.year, today.month - i),
];

Period _span(List<Period> months) => Period(months.first.from, months.last.to);

SpendingHabit spendingHabit(LedgerReader ledger, String categoryId, {required DateTime today, int months = 3}) {
  final span = _span(recentMonths(today, months));
  final txns = ledger.transactions(
    TxnFilter(from: span.from, to: span.to, kinds: const {TxnKind.expense}, categoryIds: {categoryId}),
  );
  final total = txns.fold(Decimal.zero, (s, t) => s + t.baseAmount);
  return SpendingHabit(
    categoryId: categoryId,
    monthly: (total / Decimal.fromInt(months)).toDecimal(scaleOnInfinitePrecision: 2),
    timesPerMonth: txns.length / months,
  );
}

/// One change to try: spend [percent]% less on a category, or skip it
/// [times] times a month (at its average cost per time).
class WhatIf {
  const WhatIf.percent(this.categoryId, double this.percent) : times = null;
  const WhatIf.times(this.categoryId, int this.times) : percent = null;

  final String categoryId;
  final double? percent;
  final int? times;
}

class SimulationResult {
  const SimulationResult({
    required this.savings,
    required this.income,
    required this.spending,
    required this.months,
  });

  /// Monthly saving of each change, in order.
  final List<Decimal> savings;

  /// Average monthly income and spending before any change.
  final Decimal income;
  final Decimal spending;
  final int months;

  Decimal get monthlySaving => savings.fold(Decimal.zero, (s, x) => s + x);
  Decimal get yearlySaving => monthlySaving * Decimal.fromInt(12);
  Decimal get spendingAfter => spending - monthlySaving;
  Decimal get leftBefore => income - spending;
  Decimal get leftAfter => income - spendingAfter;

  /// Share of income kept, or null without income.
  double? get savingsRateBefore => income > Decimal.zero ? (leftBefore / income).toDouble() : null;
  double? get savingsRateAfter => income > Decimal.zero ? (leftAfter / income).toDouble() : null;
}

/// What [changes] would save a month, measured on the average of the
/// [months] full months before [today]. Two changes to the same category
/// (or to a category and its subcategory) never save more than it costs.
SimulationResult simulate(LedgerReader ledger, List<WhatIf> changes, {required DateTime today, int months = 3}) {
  final span = _span(recentMonths(today, months));
  final t = totalsFor(ledger, span);
  final n = Decimal.fromInt(months);
  Decimal avg(Decimal x) => (x / n).toDecimal(scaleOnInfinitePrecision: 2);

  final left = <String, Decimal>{};
  final savings = <Decimal>[];
  for (final c in changes) {
    final habit = spendingHabit(ledger, c.categoryId, today: today, months: months);
    var saving = switch (c) {
      WhatIf(percent: final p?) => habit.monthly * Decimal.parse((p.clamp(0, 100) / 100).toStringAsFixed(4)),
      WhatIf(times: final k?) => habit.perTime * Decimal.fromInt(k < 0 ? 0 : k),
      _ => Decimal.zero,
    };
    // What is still there to cut in this category and the ones around it.
    final family = _family(ledger, c.categoryId);
    final room = family.fold<Decimal?>(null, (m, id) {
      final r = left[id] ?? spendingHabit(ledger, id, today: today, months: months).monthly;
      return m == null || r < m ? r : m;
    })!;
    if (saving > room) saving = room;
    if (saving < Decimal.zero) saving = Decimal.zero;
    for (final id in family) {
      left[id] = (left[id] ?? spendingHabit(ledger, id, today: today, months: months).monthly) - saving;
    }
    savings.add(saving.round(scale: 0));
  }
  return SimulationResult(savings: savings, income: avg(t.income), spending: avg(t.expense), months: months);
}

/// The category and its parent (cutting a subcategory also cuts the
/// parent's total).
List<String> _family(LedgerReader ledger, String categoryId) {
  final parent = ledger.category(categoryId)?.parentId;
  return [categoryId, ?parent];
}
