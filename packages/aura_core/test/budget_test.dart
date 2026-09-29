import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

Decimal d(String s) => Decimal.parse(s);

void main() {
  late InMemoryLedger l;
  final sep = Period.month(2026, 9);

  setUp(() {
    var n = 0;
    Txn spend(DateTime date, String category, String amount, {TxnKind kind = TxnKind.expense}) => Txn(
      id: 't${n++}',
      kind: kind,
      date: date,
      accountId: 'cash',
      categoryId: category,
      amount: d(amount),
      baseAmount: d(amount),
    );
    l = InMemoryLedger(
      accounts: const [Account(id: 'cash', name: '現金', type: AccountType.cash, currency: 'TWD')],
      categories: const [
        Category(id: 'food', kind: TxnKind.expense, name: '生活費'),
        Category(id: 'lunch', kind: TxnKind.expense, name: '午餐', parentId: 'food'),
        Category(id: 'fun', kind: TxnKind.expense, name: '購物娛樂'),
        Category(id: 'job', kind: TxnKind.income, name: '工作收入'),
      ],
      transactions: [
        spend(DateTime(2026, 6, 10), 'lunch', '2000'),
        spend(DateTime(2026, 7, 10), 'lunch', '2600'),
        spend(DateTime(2026, 8, 10), 'lunch', '2450'),
        spend(DateTime(2026, 9, 1), 'lunch', '1200'),
        spend(DateTime(2026, 9, 2), 'food', '300'),
        spend(DateTime(2026, 9, 3), 'fun', '5000'),
        spend(DateTime(2026, 9, 4), 'fun', '-500'), // a refund
        spend(DateTime(2026, 9, 5), 'job', '50000', kind: TxnKind.income),
      ],
      budgets: [
        Budget(id: 'b-fun', amount: d('4000'), categoryId: 'fun'),
        Budget(id: 'b-food', amount: d('6000'), categoryId: 'food'),
        Budget(id: 'b-total', amount: d('10000')),
      ],
    );
  });

  test('spending per budget, total first then in category order', () {
    final s = budgetStatuses(l, sep, today: DateTime(2026, 9, 10, 18));
    expect([for (final b in s) (b.category?.name, b.spent, b.remaining)], [
      (null, d('6000'), d('4000')),
      ('生活費', d('1500'), d('4500')), // subcategory included
      ('購物娛樂', d('4500'), d('-500')), // refund subtracted
    ]);
    expect([for (final b in s) b.over], [false, false, true]);
    expect(s.first.used, 0.6);
  });

  test('pace and daily allowance within this month', () {
    final s = budgetStatuses(l, sep, today: DateTime(2026, 9, 10, 18));
    final total = s.first;
    expect(total.elapsed, closeTo(10 / 30, 1e-9));
    expect(total.daysLeft, 21);
    expect(total.perDay, d('190')); // 4000 / 21 = 190.47…, rounded down
    expect(total.aheadOfPace, isTrue, reason: '60% spent a third of the way in');
    expect(s[1].aheadOfPace, isFalse);
    expect(s[2].perDay, isNull, reason: 'over budget');
    expect(s[2].aheadOfPace, isFalse, reason: 'already over, not just fast');
  });

  test('past and future months have no allowance', () {
    final past = budgetStatuses(l, Period.month(2026, 8), today: DateTime(2026, 9, 10)).first;
    expect((past.spent, past.elapsed, past.daysLeft, past.perDay), (d('2450'), 1.0, 0, null));
    final next = budgetStatuses(l, Period.month(2026, 10), today: DateTime(2026, 9, 10)).first;
    expect((next.spent, next.elapsed, next.daysLeft), (d('0'), 0.0, 0));
  });

  test('the last day counts as a whole day left', () {
    final last = budgetStatuses(l, sep, today: DateTime(2026, 9, 30)).first;
    expect((last.elapsed, last.daysLeft, last.perDay), (1.0, 1, d('4000')));
  });

  test('suggests the recent monthly average, rounded up to a hundred', () {
    // June–August lunches: (2000 + 2600 + 2450) / 3 = 2350.
    expect(suggestedBudget(l, categoryId: 'food', today: DateTime(2026, 9, 10)), d('2400'));
    expect(suggestedBudget(l, today: DateTime(2026, 9, 10)), d('2400'));
    expect(suggestedBudget(l, categoryId: 'fun', today: DateTime(2026, 9, 10)), isNull);
  });
}
