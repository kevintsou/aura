import 'package:decimal/decimal.dart';

import 'ledger.dart';
import 'model.dart';
import 'recurring.dart';

/// A charge (or income) that looks like it repeats: same account,
/// category and seller or note, a steady amount, a steady interval.
class RecurringCandidate {
  const RecurringCandidate({
    required this.key,
    required this.latest,
    required this.unit,
    required this.times,
    required this.next,
    required this.fixedAmount,
    required this.label,
  });

  /// Stable id of the pattern, for remembering a dismissal.
  final String key;

  /// The newest matching record; the new item copies it.
  final Txn latest;
  final RepeatUnit unit;

  /// How many matching records were found.
  final int times;

  /// When the next one is expected.
  final DateTime next;

  /// All the amounts were the same (a subscription), rather than close
  /// (a utility bill).
  final bool fixedAmount;

  /// The seller or note that ties the records together, if any.
  final String? label;

  /// A recurring item that starts with the next expected occurrence, so
  /// nothing already recorded is recorded again.
  Recurring toRecurring(String id) => Recurring(
    id: id,
    template: recurringTemplate(latest, id: id, date: next),
    unit: unit,
    next: next,
  );
}

/// Records tie together by kind, account, category and seller or note
/// (CWMoney records often have no note; the steady amount and interval
/// checks then keep everyday spending out).
String _keyOf(Txn t) => '${t.kind.name}|${t.accountId}|${t.categoryId}|${_label(t) ?? ''}';

String? _label(Txn t) {
  final s = (t.invoice?.sellerName ?? t.note)?.trim();
  return s == null || s.isEmpty ? null : s;
}

/// Looks through the last two years for repeating records that are not
/// recurring items yet: at least three weekly or monthly ones, or two a
/// year apart. [dismissed] are keys the user said no to.
List<RecurringCandidate> detectRecurring(
  LedgerReader ledger, {
  required DateTime today,
  Set<String> dismissed = const {},
}) {
  final day = DateTime(today.year, today.month, today.day);
  final groups = <String, List<Txn>>{};
  for (final t in ledger.transactions(
    TxnFilter(
      from: DateTime(day.year, day.month - 26, day.day),
      to: day,
      kinds: const {TxnKind.expense, TxnKind.income},
    ),
  )) {
    if (t.recurringId != null || t.feeOfTxnId != null) continue;
    groups.putIfAbsent(_keyOf(t), () => []).add(t);
  }
  // Patterns an existing item already covers.
  final covered = {for (final r in ledger.recurrings) _keyOf(r.template)};

  final found = <RecurringCandidate>[];
  for (final MapEntry(key: key, value: txns) in groups.entries) {
    if (txns.length < 2 || dismissed.contains(key) || covered.contains(key)) continue;
    txns.sort((a, b) => a.date.compareTo(b.date));
    // Steady amounts: at least four in five within 15% of the median
    // (a bill that varies a little, the odd one-off in the same place).
    final amounts = [for (final t in txns) t.baseAmount]..sort();
    final median = amounts[amounts.length ~/ 2];
    if (median <= Decimal.zero) continue;
    final spread = Decimal.parse('0.15') * median;
    if (amounts.where((a) => (a - median).abs() <= spread).length * 5 < amounts.length * 4) continue;

    final gaps = [for (var i = 1; i < txns.length; i++) txns[i].date.difference(txns[i - 1].date).inDays];
    final unit = _unitOf(gaps, txns);
    if (unit == null || (unit != RepeatUnit.year && txns.length < 3)) continue;
    final last = txns.last;
    var next = _after(last.date, unit);
    // Still going: the next one is not overdue by more than half a period.
    final period = next.difference(last.date).inDays;
    if (day.difference(next).inDays > period ~/ 2) continue;
    while (!next.isAfter(day)) {
      next = _after(next, unit);
    }
    found.add(
      RecurringCandidate(
        key: key,
        latest: last,
        unit: unit,
        times: txns.length,
        next: next,
        fixedAmount: amounts.first == amounts.last,
        label: _label(last),
      ),
    );
  }
  return found..sort((a, b) => b.latest.baseAmount.compareTo(a.latest.baseAmount));
}

/// The interval most gaps agree on (at least two in three), or null.
RepeatUnit? _unitOf(List<int> gaps, List<Txn> txns) {
  bool mostly(bool Function(int) ok) => gaps.where(ok).length * 3 >= gaps.length * 2;
  if (mostly((g) => g >= 26 && g <= 35)) {
    // Monthly: three in four around the same day of the month (±5).
    final days = [for (final t in txns) t.date.day]..sort();
    final mid = days[days.length ~/ 2];
    int apart(int d) => [(d - mid).abs(), 31 - (d - mid).abs()].reduce((a, b) => a < b ? a : b);
    return days.where((d) => apart(d) <= 5).length * 4 >= days.length * 3 ? RepeatUnit.month : null;
  }
  if (mostly((g) => g >= 6 && g <= 8)) return RepeatUnit.week;
  if (mostly((g) => g >= 350 && g <= 380)) return RepeatUnit.year;
  return null;
}

DateTime _after(DateTime d, RepeatUnit unit) => switch (unit) {
  RepeatUnit.day => DateTime(d.year, d.month, d.day + 1),
  RepeatUnit.week => DateTime(d.year, d.month, d.day + 7),
  RepeatUnit.month => _monthLater(d),
  RepeatUnit.year => DateTime(d.year + 1, d.month, d.day),
};

DateTime _monthLater(DateTime d) {
  final last = DateTime(d.year, d.month + 2, 0).day;
  return DateTime(d.year, d.month + 1, d.day > last ? last : d.day);
}
