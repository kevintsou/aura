// Run with a daylight-saving time zone, e.g. TZ=America/New_York, to
// check dates are counted in calendar days, not 24-hour steps.
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

void main() {
  test('calendar days across daylight-saving changes', () {
    // US: 2026-03-08 has 23 hours, 2026-11-01 has 25.
    expect(daysBetween(DateTime(2026, 3, 7), DateTime(2026, 3, 9)), 2);
    expect(daysBetween(DateTime(2026, 10, 31), DateTime(2026, 11, 2)), 2);
    expect(daysBetween(DateTime(2026, 3, 9), DateTime(2026, 3, 7)), -2);
  });

  test('a month with a daylight-saving change still has all its days', () {
    const cash = Account(id: 'cash', name: '現金', type: AccountType.cash, currency: 'TWD');
    final l = InMemoryLedger(
      accounts: const [cash],
      categories: const [Category(id: 'food', kind: TxnKind.expense, name: '餐飲')],
      budgets: [Budget(id: 'b', amount: Decimal.fromInt(3100))],
    );
    final s = budgetStatuses(l, Period.month(2026, 3), today: DateTime(2026, 3, 31, 12)).single;
    expect((s.daysLeft, s.elapsed), (1, 1.0));
    final first = budgetStatuses(l, Period.month(2026, 3), today: DateTime(2026, 3, 1)).single;
    expect(first.daysLeft, 31);
  });

  test('a daily recurring item does not skip the day after a change', () {
    const cash = Account(id: 'cash', name: '現金', type: AccountType.cash, currency: 'TWD');
    final l = InMemoryLedger(accounts: const [cash]);
    l.setRecurring(
      Recurring(
        id: 'r',
        template: Txn(
          id: 'r',
          kind: TxnKind.expense,
          date: DateTime(2026, 3, 6),
          accountId: 'cash',
          amount: Decimal.one,
          baseAmount: Decimal.one,
        ),
        unit: RepeatUnit.day,
        next: DateTime(2026, 3, 6),
      ),
    );
    for (var d = 6; d <= 10; d++) {
      recordDueRecurring(l, today: DateTime(2026, 3, d, 20));
    }
    expect([for (final t in l.transactions()) t.date.day]..sort(), [6, 7, 8, 9, 10]);
    expect(l.recurrings.single.next, DateTime(2026, 3, 11));
  });

  test('the opening balance is the day before the first record', () {
    const cash = Account(id: 'cash', name: '現金', type: AccountType.cash, currency: 'TWD');
    final b = balanceOf(cash, [AccountFlow('cash', DateTime(2026, 3, 9), Decimal.one)], today: DateTime(2026, 3, 20));
    expect(b.openingAnchor(Decimal.ten, today: DateTime(2026, 3, 20)).date, DateTime(2026, 3, 8));
  });
}
