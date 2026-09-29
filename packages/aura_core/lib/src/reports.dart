import 'package:decimal/decimal.dart';

import 'ledger.dart';
import 'model.dart';

/// Report figures. All amounts are in the base currency (CWMoney's 小計),
/// income and expenses only: transfers move money, they do not spend it.

/// A calendar range, both ends inclusive.
class Period {
  const Period(this.from, this.to);

  factory Period.month(int year, int month) =>
      Period(DateTime(year, month), DateTime(year, month + 1, 0));

  factory Period.year(int year) => Period(DateTime(year), DateTime(year, 12, 31));

  final DateTime from;
  final DateTime to;

  bool get isYear => from.month == 1 && to.month == 12 && from.day == 1 && to.day == 31;

  /// The period of the same length just before this one.
  Period get previous => isYear
      ? Period.year(from.year - 1)
      : Period.month(from.month == 1 ? from.year - 1 : from.year, from.month == 1 ? 12 : from.month - 1);

  Period get next => isYear
      ? Period.year(from.year + 1)
      : Period.month(from.month == 12 ? from.year + 1 : from.year, from.month == 12 ? 1 : from.month + 1);

  bool contains(DateTime d) => !d.isBefore(from) && !d.isAfter(to);

  @override
  bool operator ==(Object other) =>
      other is Period && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

class Totals {
  const Totals({required this.income, required this.expense, required this.count});

  final Decimal income;
  final Decimal expense;

  /// Income and expense records counted.
  final int count;

  Decimal get net => income - expense;
}

Totals totalsFor(LedgerReader ledger, Period p) {
  var income = Decimal.zero, expense = Decimal.zero;
  var n = 0;
  for (final t in ledger.transactions(
    TxnFilter(from: p.from, to: p.to, kinds: const {TxnKind.income, TxnKind.expense}),
  )) {
    n++;
    t.kind == TxnKind.income ? income += t.baseAmount : expense += t.baseAmount;
  }
  return Totals(income: income, expense: expense, count: n);
}

class CategoryTotal {
  const CategoryTotal({
    required this.category,
    required this.total,
    required this.count,
    required this.share,
  });

  /// Null for records without a category.
  final Category? category;
  final Decimal total;
  final int count;

  /// Percentage of the whole (0–100); 0 when the whole is not positive.
  final double share;
}

/// Totals of [kind] per main category, largest first. With [parentId],
/// per subcategory of that main category instead; records filed directly
/// on the main category come back under the main category itself.
List<CategoryTotal> byCategory(
  LedgerReader ledger,
  Period p,
  TxnKind kind, {
  String? parentId,
}) {
  final sums = <String?, (Decimal, int)>{};
  for (final t in ledger.transactions(
    TxnFilter(
      from: p.from,
      to: p.to,
      kinds: {kind},
      categoryIds: parentId == null ? null : {parentId},
    ),
  )) {
    final leaf = t.categoryId == null ? null : ledger.category(t.categoryId!);
    final key = parentId == null ? (leaf?.parentId ?? leaf?.id) : leaf?.id;
    final (sum, n) = sums[key] ?? (Decimal.zero, 0);
    sums[key] = (sum + t.baseAmount, n + 1);
  }
  final whole = sums.values.fold(Decimal.zero, (a, e) => a + e.$1);
  return [
    for (final MapEntry(key: id, value: (sum, n)) in sums.entries)
      CategoryTotal(
        category: id == null ? null : ledger.category(id),
        total: sum,
        count: n,
        share: whole > Decimal.zero ? (sum / whole).toDouble() * 100 : 0,
      ),
  ]..sort((a, b) => b.total.compareTo(a.total));
}

class MonthTotal {
  const MonthTotal(this.year, this.month, this.total);
  final int year;
  final int month;
  final Decimal total;

  Period get period => Period.month(year, month);
}

/// [count] consecutive months of [kind] totals ending with [end]'s month,
/// oldest first; months without records are zero. With [categoryId],
/// only that category (and its subcategories).
List<MonthTotal> monthlyTotals(
  LedgerReader ledger,
  TxnKind kind, {
  required DateTime end,
  int count = 12,
  String? categoryId,
}) {
  final months = [
    for (var i = count - 1; i >= 0; i--) DateTime(end.year, end.month - i),
  ];
  final sums = {for (final m in months) (m.year, m.month): Decimal.zero};
  for (final t in ledger.transactions(
    TxnFilter(
      from: months.first,
      to: DateTime(end.year, end.month + 1, 0),
      kinds: {kind},
      categoryIds: categoryId == null ? null : {categoryId},
    ),
  )) {
    final key = (t.date.year, t.date.month);
    sums[key] = sums[key]! + t.baseAmount;
  }
  return [
    for (final m in months) MonthTotal(m.year, m.month, sums[(m.year, m.month)]!),
  ];
}

/// The month of the newest record, or null for an empty ledger.
DateTime? latestRecordMonth(LedgerReader ledger) {
  final newest = ledger.transactions(const TxnFilter(), 0, 1).firstOrNull;
  return newest == null ? null : DateTime(newest.date.year, newest.date.month);
}

/// Relative change from [before] to [now] in percent; null when there is
/// no meaningful base (a zero or negative previous value).
double? percentChange(Decimal before, Decimal now) =>
    before > Decimal.zero ? ((now - before) / before).toDouble() * 100 : null;
