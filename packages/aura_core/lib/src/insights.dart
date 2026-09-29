import 'package:decimal/decimal.dart';

import 'budget.dart';
import 'ledger.dart';
import 'model.dart';
import 'reports.dart';

enum InsightKind { total, categoryUp, categoryDown, unusual, duplicate, overBudget, fastBudget }

/// One thing worth knowing about a month, in words, with what it is
/// about so the screen can link to it.
class Insight {
  const Insight(this.kind, this.text, {this.categoryId, this.txnIds = const [], this.amount});

  final InsightKind kind;
  final String text;
  final String? categoryId;
  final List<String> txnIds;
  final Decimal? amount;
}

String _money(Decimal d) {
  final s = d.abs().round(scale: 0).toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '${d < Decimal.zero ? '-' : ''}NT\$$s';
}

Decimal _avg(Iterable<Decimal> xs) =>
    xs.isEmpty ? Decimal.zero : (xs.fold(Decimal.zero, (a, b) => a + b) / Decimal.fromInt(xs.length)).toDecimal(scaleOnInfinitePrecision: 2);

/// Records that look like the same charge twice: same account, amount
/// and seller or note, not made by a recurring item. With an invoice
/// number on both, the numbers must match (the same invoice entered
/// twice, up to two days apart); otherwise they must be on the same day.
/// Pairs whose [duplicateKey] is in [dismissed] were ruled out by the user.
List<List<Txn>> possibleDuplicates(LedgerReader ledger, Period p, {Set<String> dismissed = const {}}) {
  final txns = ledger.transactions(
    TxnFilter(from: DateTime(p.from.year, p.from.month, p.from.day - 2), to: p.to, kinds: const {TxnKind.expense}),
  );
  final found = <List<Txn>>[];
  final used = <String>{};
  for (final (i, a) in txns.indexed) {
    if (a.recurringId != null || used.contains(a.id) || a.baseAmount < Decimal.fromInt(50)) continue;
    final label = _label(a);
    if (label == null) continue;
    for (final b in txns.skip(i + 1)) {
      final apart = _day(a.date).difference(_day(b.date)).inDays;
      if (apart > 2) break; // newest first
      if (b.recurringId != null || used.contains(b.id)) continue;
      if (b.accountId != a.accountId || b.baseAmount != a.baseAmount || _label(b) != label) continue;
      if (!p.contains(_day(a.date)) && !p.contains(_day(b.date))) continue;
      final (na, nb) = (a.invoice?.number, b.invoice?.number);
      final same = na != null && nb != null ? na == nb : apart == 0;
      if (same && !dismissed.contains(duplicateKey([a, b]))) {
        found.add([a, b]);
        used.addAll([a.id, b.id]);
        break;
      }
    }
  }
  return found;
}

String _twice(List<Txn> pair) {
  final (a, b) = (pair.last.date, pair.first.date);
  return _day(a) == _day(b) ? '${a.month}/${a.day} 記了兩次' : '在 ${a.month}/${a.day} 和 ${b.month}/${b.day} 各記了一次';
}

/// Identifies a pair of records, whichever order they come in.
String duplicateKey(List<Txn> pair) => ([for (final t in pair) t.id]..sort()).join('|');

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

String? _label(Txn t) {
  final s = (t.invoice?.sellerName ?? t.note)?.trim();
  return s == null || s.isEmpty ? null : s;
}

/// The month's highlights, most telling first: spending against last
/// month and the recent average, the categories that moved most,
/// unusually large expenses, possible double charges and budgets in
/// trouble. Figures are for the ledger as given (hidden accounts
/// excluded when a filtered view is passed).
List<Insight> monthlyInsights(
  LedgerReader ledger,
  Period month, {
  required DateTime today,
  Set<String> dismissedDuplicates = const {},
}) {
  final out = <Insight>[];
  final now = totalsFor(ledger, month).expense;
  final prevMonths = periodTotals(ledger, TxnKind.expense, end: month.previous, count: 3);
  final avg = _avg(prevMonths.map((m) => m.total).where((t) => t > Decimal.zero));
  final last = prevMonths.last.total;
  if (now > Decimal.zero || last > Decimal.zero) {
    final vsLast = last > Decimal.zero ? ((now - last) / last).toDouble() * 100 : null;
    final vsAvg = avg > Decimal.zero ? ((now - avg) / avg).toDouble() * 100 : null;
    out.add(
      Insight(
        InsightKind.total,
        [
          '支出 ${_money(now)}',
          if (vsLast != null) '比上月${vsLast >= 0 ? '多' : '少'} ${vsLast.abs().round()}%',
          if (vsAvg != null) '比前三個月平均${vsAvg >= 0 ? '多' : '少'} ${vsAvg.abs().round()}%',
        ].join('，'),
        amount: now,
      ),
    );
  }

  // Categories that moved most against their three-month average.
  final before = <String?, Decimal>{};
  for (final m in prevMonths) {
    for (final c in byCategory(ledger, m.period, TxnKind.expense)) {
      before[c.category?.id] = (before[c.category?.id] ?? Decimal.zero) + c.total;
    }
  }
  final three = Decimal.fromInt(3);
  final changes = <(Category, Decimal, Decimal)>[];
  final seen = <String?>{};
  for (final c in byCategory(ledger, month, TxnKind.expense)) {
    seen.add(c.category?.id);
    if (c.category == null) continue;
    changes.add((c.category!, c.total, _third(before[c.category!.id] ?? Decimal.zero)));
  }
  for (final MapEntry(key: id, value: sum) in before.entries) {
    if (id == null || seen.contains(id)) continue;
    final cat = ledger.category(id);
    if (cat != null) changes.add((cat, Decimal.zero, _third(sum)));
  }
  final big = [
    for (final (cat, nowC, avgC) in changes)
      if ((nowC - avgC).abs() >= Decimal.fromInt(500) &&
          (avgC == Decimal.zero || ((nowC - avgC).abs() / avgC).toDouble() >= 0.2))
        (cat, nowC, avgC),
  ]..sort((a, b) => (b.$2 - b.$3).abs().compareTo((a.$2 - a.$3).abs()));
  for (final (cat, nowC, avgC) in big.take(3)) {
    final up = nowC > avgC;
    out.add(
      Insight(
        up ? InsightKind.categoryUp : InsightKind.categoryDown,
        '${cat.name} ${_money(nowC)}，${up ? '比平常多' : '比平常少'} ${_money((nowC - avgC).abs())}'
        '（前三個月平均 ${_money(avgC)}）',
        categoryId: cat.id,
        amount: nowC - avgC,
      ),
    );
  }

  // Unusually large: three times the category's usual, the most in a
  // year, and at least 1,000.
  final history = ledger.transactions(
    TxnFilter(from: DateTime(month.from.year - 1, month.from.month), to: month.from.subtract(const Duration(days: 1)), kinds: const {TxnKind.expense}),
  );
  final usual = <String, List<Decimal>>{};
  for (final t in history) {
    if (t.categoryId != null) usual.putIfAbsent(t.categoryId!, () => []).add(t.baseAmount);
  }
  final unusual = <Txn>[];
  for (final t in ledger.transactions(TxnFilter(from: month.from, to: month.to, kinds: const {TxnKind.expense}))) {
    final past = usual[t.categoryId];
    if (past == null || past.length < 5 || t.baseAmount < Decimal.fromInt(1000)) continue;
    final sorted = [...past]..sort();
    final median = sorted[sorted.length ~/ 2];
    // And more than anything in the category the year before.
    if (median > Decimal.zero && t.baseAmount >= median * three && t.baseAmount > sorted.last) unusual.add(t);
  }
  unusual.sort((a, b) => b.baseAmount.compareTo(a.baseAmount));
  for (final t in unusual.take(2)) {
    final cat = t.categoryId == null ? null : ledger.category(t.categoryId!);
    out.add(
      Insight(
        InsightKind.unusual,
        '${t.date.month}/${t.date.day} ${[?cat?.name, ?_label(t)].join('・')} ${_money(t.baseAmount)}，比這類支出平常大很多',
        txnIds: [t.id],
        categoryId: t.categoryId,
        amount: t.baseAmount,
      ),
    );
  }

  for (final pair in possibleDuplicates(ledger, month, dismissed: dismissedDuplicates)) {
    final a = pair.first;
    out.add(
      Insight(
        InsightKind.duplicate,
        '${_label(a)} ${_money(a.baseAmount)} ${_twice(pair)}，是不是重複記帳或重複扣款？',
        txnIds: [for (final t in pair) t.id],
        amount: a.baseAmount,
      ),
    );
  }

  for (final s in budgetStatuses(ledger, month, today: today)) {
    final name = s.category?.name ?? '每月總預算';
    if (s.over) {
      out.add(
        Insight(InsightKind.overBudget, '$name超支 ${_money(-s.remaining)}', categoryId: s.category?.id, amount: -s.remaining),
      );
    } else if (s.aheadOfPace) {
      out.add(
        Insight(
          InsightKind.fastBudget,
          '$name已經用了 ${(s.used * 100).round()}%，這個月才過 ${(s.elapsed * 100).round()}%',
          categoryId: s.category?.id,
        ),
      );
    }
  }
  return out;
}

Decimal _third(Decimal d) => (d / Decimal.fromInt(3)).toDecimal(scaleOnInfinitePrecision: 2);
