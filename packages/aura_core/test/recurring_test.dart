import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

Txn _template(DateTime start, {String account = 'cash', String? category = 'rent', int amount = 12000}) => Txn(
  id: 'tpl',
  kind: TxnKind.expense,
  date: start,
  accountId: account,
  categoryId: category,
  amount: Decimal.fromInt(amount),
  baseAmount: Decimal.fromInt(amount),
  note: '房租',
);

Recurring _r(
  DateTime start,
  RepeatUnit unit, {
  int every = 1,
  DateTime? until,
  int? times,
  DateTime? next,
  String account = 'cash',
}) => Recurring(
  id: 'r1',
  template: _template(start, account: account),
  unit: unit,
  every: every,
  until: until,
  times: times,
  next: next ?? start,
);

List<DateTime> _first(Recurring r, int n) => r.occurrencesFrom(DateTime(1900)).take(n).toList();

InMemoryLedger _ledger({List<Recurring> recurrings = const []}) => InMemoryLedger(
  accounts: const [Account(id: 'cash', name: '現金', type: AccountType.cash, currency: 'TWD')],
  categories: const [Category(id: 'rent', kind: TxnKind.expense, name: '房租')],
  recurrings: recurrings,
);

void main() {
  group('occurrences', () {
    test('the 31st falls on the last day of shorter months and comes back', () {
      expect(_first(_r(DateTime(2026, 1, 31), RepeatUnit.month), 4), [
        DateTime(2026, 1, 31),
        DateTime(2026, 2, 28),
        DateTime(2026, 3, 31),
        DateTime(2026, 4, 30),
      ]);
      expect(_first(_r(DateTime(2024, 2, 29), RepeatUnit.year), 2), [DateTime(2024, 2, 29), DateTime(2025, 2, 28)]);
    });

    test('days, weeks and intervals', () {
      expect(_first(_r(DateTime(2026, 9, 29), RepeatUnit.day), 3).last, DateTime(2026, 10, 1));
      expect(_first(_r(DateTime(2026, 9, 30), RepeatUnit.week, every: 2), 3), [
        DateTime(2026, 9, 30),
        DateTime(2026, 10, 14),
        DateTime(2026, 10, 28),
      ]);
      expect(_first(_r(DateTime(2026, 11, 15), RepeatUnit.month, every: 3), 3).last, DateTime(2027, 5, 15));
    });

    test('end after a number of times or on a date', () {
      expect(_first(_r(DateTime(2026, 1, 5), RepeatUnit.month, times: 3), 10), hasLength(3));
      expect(_first(_r(DateTime(2026, 1, 5), RepeatUnit.month, until: DateTime(2026, 4, 5)), 10).last, DateTime(2026, 4, 5));
      final r = _r(DateTime(2026, 1, 5), RepeatUnit.month, times: 3);
      expect(r.firstFrom(DateTime(2026, 2, 6)), DateTime(2026, 3, 5));
      expect(r.firstFrom(DateTime(2026, 3, 6)), isNull);
    });

    test('are described in words', () {
      expect(describeRepeat(_r(DateTime(2026, 9, 5), RepeatUnit.month)), '每月 5 日');
      expect(describeRepeat(_r(DateTime(2026, 9, 30), RepeatUnit.week)), '每週三');
      expect(describeRepeat(_r(DateTime(2026, 9, 30), RepeatUnit.week, every: 2)), '每 2 週的週三');
      expect(describeRepeat(_r(DateTime(2026, 3, 1), RepeatUnit.year, times: 5)), '每年 3 月 1 日，共 5 次');
      expect(
        describeRepeat(_r(DateTime(2026, 9, 5), RepeatUnit.month, every: 2, until: DateTime(2027, 6, 30))),
        '每 2 個月的 5 日，到 2027/06/30',
      );
      expect(describeRepeat(_r(DateTime(2026, 9, 5), RepeatUnit.day)), '每天');
    });
  });

  group('recording', () {
    test('catches up on missed occurrences, once', () {
      final l = _ledger(recurrings: [_r(DateTime(2026, 7, 5), RepeatUnit.month)]);
      final run = recordDueRecurring(l, today: DateTime(2026, 9, 29, 8));
      expect([for (final t in run.recorded) t.date], [DateTime(2026, 7, 5), DateTime(2026, 8, 5), DateTime(2026, 9, 5)]);
      expect(l.count(), 3);
      final t = l.transactions().first;
      expect((t.id, t.recurringId, t.note, t.baseAmount), ('r1@2026-09-05', 'r1', '房租', Decimal.fromInt(12000)));
      expect(l.recurrings.single.next, DateTime(2026, 10, 5));

      expect(recordDueRecurring(l, today: DateTime(2026, 9, 30)).recorded, isEmpty);
      expect(recordDueRecurring(l, today: DateTime(2026, 10, 5)).recorded.single.date, DateTime(2026, 10, 5));
    });

    test('a deleted occurrence is not recorded again', () {
      final l = _ledger(recurrings: [_r(DateTime(2026, 9, 5), RepeatUnit.month)]);
      recordDueRecurring(l, today: DateTime(2026, 9, 29));
      l.deleteTxn('r1@2026-09-05');
      expect(recordDueRecurring(l, today: DateTime(2026, 9, 29)).recorded, isEmpty);
      expect(l.count(), 0);
    });

    test('an interrupted run does not duplicate what it already recorded', () {
      // As if the app stopped after recording but before moving next on.
      final r = _r(DateTime(2026, 9, 5), RepeatUnit.month);
      final l = _ledger(recurrings: [r])..addTxn(r.occurrenceTxn(DateTime(2026, 9, 5)));
      expect(recordDueRecurring(l, today: DateTime(2026, 9, 29)).recorded, isEmpty);
      expect(l.count(), 1);
      expect(l.recurrings.single.next, DateTime(2026, 10, 5));
    });

    test('future starts wait; finished items stop', () {
      final l = _ledger(
        recurrings: [
          _r(DateTime(2026, 10, 1), RepeatUnit.month),
          Recurring(
            id: 'r2',
            template: _template(DateTime(2026, 8, 1)),
            unit: RepeatUnit.month,
            times: 2,
            next: DateTime(2026, 8, 1),
          ),
        ],
      );
      final run = recordDueRecurring(l, today: DateTime(2026, 9, 29));
      expect([for (final t in run.recorded) t.id], ['r2@2026-08-01', 'r2@2026-09-01']);
      expect([for (final r in l.recurrings) r.next], [DateTime(2026, 10, 1), null]);
    });

    test('reports items it cannot record and carries on with the rest', () {
      final l = _ledger(
        recurrings: [
          _r(DateTime(2026, 9, 1), RepeatUnit.month, account: 'gone'),
          Recurring(id: 'r2', template: _template(DateTime(2026, 9, 2)), unit: RepeatUnit.month, next: DateTime(2026, 9, 2)),
        ],
      );
      final run = recordDueRecurring(l, today: DateTime(2026, 9, 29));
      expect(run.problems.keys, ['r1']);
      expect(run.recorded.single.id, 'r2@2026-09-02');
    });
  });
}
