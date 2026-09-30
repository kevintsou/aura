import 'ledger.dart';
import 'model.dart';

enum RepeatUnit { day, week, month, year }

/// A record that repeats (rent, salary, subscriptions, instalments).
/// Occurrences are recorded as ordinary transactions once their day has
/// come; see [recordDueRecurring].
///
/// Dates are counted from the start, not from the previous occurrence,
/// so "the 31st of every month" falls on the last day of shorter months
/// and returns to the 31st afterwards.
class Recurring {
  const Recurring({
    required this.id,
    required this.template,
    required this.unit,
    this.every = 1,
    this.until,
    this.times,
    this.next,
  });

  final String id;

  /// What each occurrence records; its date is the first occurrence.
  final Txn template;
  final RepeatUnit unit;

  /// Every how many [unit]s.
  final int every;

  /// Last day an occurrence may fall on (inclusive).
  final DateTime? until;

  /// How many occurrences in total (e.g. 12 instalments).
  final int? times;

  /// The next occurrence not yet recorded; null once finished.
  final DateTime? next;

  DateTime get start => template.date;

  /// The [k]-th occurrence (0 is the start), or null past the end.
  DateTime? occurrence(int k) {
    if (k < 0 || (times != null && k >= times!)) return null;
    final s = start, n = k * every;
    final date = switch (unit) {
      RepeatUnit.day => DateTime(s.year, s.month, s.day + n),
      RepeatUnit.week => DateTime(s.year, s.month, s.day + 7 * n),
      RepeatUnit.month => _clamped(s.year, s.month + n, s.day),
      RepeatUnit.year => _clamped(s.year + n, s.month, s.day),
    };
    return until != null && date.isAfter(until!) ? null : date;
  }

  /// Occurrences on or after [from], in order.
  Iterable<DateTime> occurrencesFrom(DateTime from) sync* {
    for (var k = 0;; k++) {
      final d = occurrence(k);
      if (d == null) return;
      if (!d.isBefore(from)) yield d;
    }
  }

  /// The first occurrence on or after [from], or null if none is left.
  DateTime? firstFrom(DateTime from) => occurrencesFrom(from).firstOrNull;

  /// The record for the occurrence on [date]. Its id is derived from the
  /// date, so recording the same occurrence twice is impossible.
  Txn occurrenceTxn(DateTime date) => template.copyWith(
    id: occurrenceId(id, date),
    date: date,
    createdAt: date,
    recurringId: id,
  );

  Recurring withNext(DateTime? next) => Recurring(
    id: id,
    template: template,
    unit: unit,
    every: every,
    until: until,
    times: times,
    next: next,
  );
}

/// What a recurring item repeats: the parts of [t] that fit every
/// occurrence. Not its invoice, place, position, creation time or source
/// rows, which belong to that one record.
Txn recurringTemplate(Txn t, {required String id, DateTime? date}) => Txn(
  id: id,
  kind: t.kind,
  date: date ?? t.date,
  accountId: t.accountId,
  toAccountId: t.toAccountId,
  amount: t.amount,
  toAmount: t.toAmount,
  baseAmount: t.baseAmount,
  fxRateDisplay: t.fxRateDisplay,
  categoryId: t.categoryId,
  projectId: t.projectId,
  note: t.note,
);

String occurrenceId(String recurringId, DateTime date) =>
    '$recurringId@${date.year}-${_two(date.month)}-${_two(date.day)}';

String _two(int n) => n.toString().padLeft(2, '0');

/// Day [day] of the month, or its last day when the month is shorter.
DateTime _clamped(int year, int month, int day) {
  final last = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, day > last ? last : day);
}

/// Outcome of [recordDueRecurring].
class RecurringRun {
  RecurringRun(this.recorded, this.problems);

  /// Records added.
  final List<Txn> recorded;

  /// Recurring items that could not be recorded, with the reason (e.g.
  /// the account was archived and then deleted).
  final Map<String, String> problems;
}

/// Records every occurrence due by [today] (catching up on days the app
/// was not opened) and moves each item's [Recurring.next] past today.
/// Safe to run any number of times: occurrences have fixed ids.
RecurringRun recordDueRecurring(LedgerStore ledger, {required DateTime today}) {
  final day = DateTime(today.year, today.month, today.day);
  final recorded = <Txn>[];
  final problems = <String, String>{};
  for (final r in ledger.recurrings) {
    final next = r.next;
    if (next == null || next.isAfter(day)) continue;
    try {
      for (final date in r.occurrencesFrom(next).takeWhile((d) => !d.isAfter(day))) {
        final txn = r.occurrenceTxn(date);
        if (ledger.txn(txn.id) != null) continue;
        ledger.addTxn(txn);
        recorded.add(txn);
      }
      ledger.setRecurring(r.withNext(r.firstFrom(DateTime(day.year, day.month, day.day + 1))));
    } on ArgumentError catch (e) {
      problems[r.id] = '${e.message}';
    }
  }
  return RecurringRun(recorded, problems);
}

/// "每月 5 日", "每 2 週的週三", "每年 3 月 1 日", with the end if any.
String describeRepeat(Recurring r) {
  final s = r.start;
  const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
  final every = r.every;
  final rule = switch (r.unit) {
    RepeatUnit.day => every == 1 ? '每天' : '每 $every 天',
    RepeatUnit.week => '${every == 1 ? '每週' : '每 $every 週的週'}${weekdays[s.weekday - 1]}',
    RepeatUnit.month => '${every == 1 ? '每月' : '每 $every 個月的'} ${s.day} 日',
    RepeatUnit.year => '${every == 1 ? '每年' : '每 $every 年的'} ${s.month} 月 ${s.day} 日',
  };
  final end = switch ((r.until, r.times)) {
    (final DateTime u, _) => '，到 ${u.year}/${_two(u.month)}/${_two(u.day)}',
    (_, final int n) => '，共 $n 次',
    _ => '',
  };
  return '$rule$end';
}
