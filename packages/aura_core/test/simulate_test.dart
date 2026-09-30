import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

Decimal d(String s) => Decimal.parse(s);

void main() {
  late InMemoryLedger l;
  final today = DateTime(2026, 9, 15);

  setUp(() {
    var n = 0;
    Txn t(DateTime date, String category, int amount, {TxnKind kind = TxnKind.expense}) => Txn(
      id: 't${n++}',
      kind: kind,
      date: date,
      accountId: 'cash',
      categoryId: category,
      amount: Decimal.fromInt(amount),
      baseAmount: Decimal.fromInt(amount),
    );
    l = InMemoryLedger(
      accounts: const [Account(id: 'cash', name: '現金', type: AccountType.cash, currency: 'TWD')],
      categories: const [
        Category(id: 'food', kind: TxnKind.expense, name: '餐飲'),
        Category(id: 'out', kind: TxnKind.expense, name: '外食', parentId: 'food'),
        Category(id: 'fun', kind: TxnKind.expense, name: '娛樂'),
        Category(id: 'pay', kind: TxnKind.income, name: '薪水'),
      ],
      transactions: [
        // June to August: eating out 10 times a month at 300, groceries
        // 3,000, fun 1,500, pay 40,000.
        for (final m in [6, 7, 8]) ...[
          for (var i = 1; i <= 10; i++) t(DateTime(2026, m, i), 'out', 300),
          t(DateTime(2026, m, 20), 'food', 3000),
          t(DateTime(2026, m, 21), 'fun', 1500),
          t(DateTime(2026, m, 5), 'pay', 40000, kind: TxnKind.income),
        ],
        // This month does not count: it is not over.
        t(DateTime(2026, 9, 1), 'fun', 99999),
        // Before the window.
        t(DateTime(2026, 5, 1), 'fun', 99999),
      ],
    );
  });

  test('habits over the last full months', () {
    final out = spendingHabit(l, 'out', today: today);
    expect((out.monthly, out.timesPerMonth, out.perTime), (d('3000'), 10.0, d('300')));
    final food = spendingHabit(l, 'food', today: today);
    expect((food.monthly, food.timesPerMonth), (d('6000'), 11.0), reason: 'subcategories included');
    expect(recentMonths(today, 3).map((p) => p.from.month), [6, 7, 8]);
    expect(recentMonths(DateTime(2026, 2, 3), 3).map((p) => (p.from.year, p.from.month)), [(2025, 11), (2025, 12), (2026, 1)]);
  });

  test('eating out 3 times less and 20% less fun', () {
    final r = simulate(l, const [WhatIf.times('out', 3), WhatIf.percent('fun', 20)], today: today);
    expect(r.savings, [d('900'), d('300')]);
    expect((r.monthlySaving, r.yearlySaving), (d('1200'), d('14400')));
    expect((r.income, r.spending, r.spendingAfter), (d('40000'), d('7500'), d('6300')));
    expect((r.leftBefore, r.leftAfter), (d('32500'), d('33700')));
    expect(r.savingsRateBefore, closeTo(0.8125, 1e-9));
    expect(r.savingsRateAfter, closeTo(0.8425, 1e-9));
  });

  test('never saves more than the category costs, even when changes overlap', () {
    final r = simulate(
      l,
      const [WhatIf.times('out', 50), WhatIf.percent('food', 100), WhatIf.percent('out', 10)],
      today: today,
    );
    expect(r.savings, [d('3000'), d('3000'), d('0')]);
    expect(r.spendingAfter, d('1500'));
  });

  test('no history, no savings', () {
    final r = simulate(l, const [WhatIf.percent('fun', 50)], today: DateTime(2020, 1, 1));
    expect((r.monthlySaving, r.income, r.savingsRateBefore), (Decimal.zero, Decimal.zero, null));
  });
}
