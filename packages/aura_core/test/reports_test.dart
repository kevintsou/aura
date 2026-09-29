import 'dart:io';

import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

Decimal d(String s) => Decimal.parse(s);

void main() {
  final ledger = importCwmoneyCsv(File('test/fixtures/sample_cwmoney.csv').readAsBytesSync()).ledger;
  final sep = Period.month(2026, 9);

  group('Period', () {
    test('months and years, with neighbours', () {
      expect(sep.from, DateTime(2026, 9));
      expect(sep.to, DateTime(2026, 9, 30));
      expect(Period.month(2026, 1).previous, Period.month(2025, 12));
      expect(Period.month(2026, 12).next, Period.month(2027, 1));
      expect(Period.month(2024, 2).to, DateTime(2024, 2, 29));
      expect(Period.year(2026).previous, Period.year(2025));
      expect(Period.year(2026).isYear, isTrue);
      expect(sep.isYear, isFalse);
    });
  });

  test('totals count income and expenses, not transfers', () {
    final t = totalsFor(ledger, sep);
    // Expenses: 65 + 1800 + 15 (transfer fee) + 2010 + 120.
    expect(t.expense, d('4010'));
    // Income: 50000 − 1874.5 (a recorded investment loss).
    expect(t.income, d('48125.5'));
    expect(t.net, d('44115.5'));
    expect(t.count, 7);
    expect(totalsFor(ledger, Period.month(2026, 8)).count, 0);
  });

  test('expenses by main category, largest first, with shares', () {
    final rows = byCategory(ledger, sep, TxnKind.expense);
    expect(
      [for (final r in rows) (r.category!.name, r.total, r.count)],
      [('購物娛樂', d('2010'), 1), ('行車交通', d('1800'), 1), ('生活費', d('185'), 2), ('醫療其他', d('15'), 1)],
    );
    expect(rows.first.share, closeTo(50.12, 0.01));
    expect(rows.fold(0.0, (a, r) => a + r.share), closeTo(100, 1e-9));
  });

  test('drills into the subcategories of one main category', () {
    final food = ledger.categories.firstWhere((c) => c.name == '生活費' && c.parentId == null);
    final rows = byCategory(ledger, sep, TxnKind.expense, parentId: food.id);
    expect([for (final r in rows) (r.category!.name, r.total)], [('午餐', d('120')), ('早餐', d('65'))]);
  });

  test('records filed on a main category itself stay visible in the drill-down', () {
    final l = InMemoryLedger(
      accounts: const [Account(id: 'a', name: '現金', type: AccountType.cash, currency: 'TWD')],
      categories: const [
        Category(id: 'm', kind: TxnKind.expense, name: '生活費'),
        Category(id: 's', kind: TxnKind.expense, name: '午餐', parentId: 'm'),
      ],
      transactions: [
        for (final (id, cat, amt) in [('1', 'm', 30), ('2', 's', 100), ('3', null, 5)])
          Txn(
            id: id,
            kind: TxnKind.expense,
            date: DateTime(2026, 9, 1),
            accountId: 'a',
            categoryId: cat,
            amount: Decimal.fromInt(amt),
            baseAmount: Decimal.fromInt(amt),
          ),
      ],
    );
    expect(
      [for (final r in byCategory(l, sep, TxnKind.expense)) (r.category?.name, r.total)],
      [('生活費', d('130')), (null, d('5'))],
    );
    expect(
      [for (final r in byCategory(l, sep, TxnKind.expense, parentId: 'm')) (r.category?.name, r.total)],
      [('午餐', d('100')), ('生活費', d('30'))],
    );
  });

  test('monthly totals fill empty months with zero, oldest first', () {
    final months = monthlyTotals(ledger, TxnKind.expense, end: DateTime(2026, 10), count: 3);
    expect(
      [for (final m in months) (m.year, m.month, m.total)],
      [(2026, 8, d('0')), (2026, 9, d('4010')), (2026, 10, d('0'))],
    );
    final across = monthlyTotals(ledger, TxnKind.income, end: DateTime(2027, 1), count: 12);
    expect((across.first.year, across.first.month), (2026, 2));
    expect(across.map((m) => m.total).reduce((a, b) => a + b), d('48125.5'));
  });

  test('latest record month and percent change', () {
    expect(latestRecordMonth(ledger), DateTime(2026, 9));
    expect(latestRecordMonth(InMemoryLedger()), isNull);
    expect(percentChange(d('100'), d('150')), 50);
    expect(percentChange(d('0'), d('150')), isNull);
  });

  group('weeks and other groupings', () {
    test('weeks run Monday to Sunday', () {
      final w = Period.week(DateTime(2026, 9, 24)); // a Thursday
      expect((w.from, w.to, w.isWeek, w.isYear), (DateTime(2026, 9, 21), DateTime(2026, 9, 27), true, false));
      expect(w.previous, Period.week(DateTime(2026, 9, 14)));
      expect(w.next.from, DateTime(2026, 9, 28));
      expect(Period.week(DateTime(2026, 12, 30)).next.from, DateTime(2027, 1, 4));
      expect(sep.isWeek, isFalse);
    });

    test('period totals for weeks, and the net', () {
      final weeks = periodTotals(ledger, TxnKind.expense, end: Period.week(DateTime(2026, 9, 28)), count: 3);
      expect(
        [for (final w in weeks) (w.period.from, w.total)],
        [
          (DateTime(2026, 9, 14), d('2130')), // lunch 120 + Sunday 9/20's 2010
          (DateTime(2026, 9, 21), d('1815')),
          (DateTime(2026, 9, 28), d('65')),
        ],
      );
      final net = periodTotals(ledger, null, end: sep, count: 2);
      expect([for (final m in net) m.total], [d('0'), d('44115.5')]);
    });

    test('by account and by project', () {
      expect(
        [for (final g in byAccount(ledger, sep, TxnKind.expense)) (g.label, g.total)],
        [('日幣-測試', d('2010')), ('信用卡-測試', d('1865')), ('現金', d('120')), ('活存-測試', d('15'))],
      );
      expect(
        [for (final g in byProject(ledger, sep, TxnKind.income)) (g.label, g.total, g.id == null)],
        [('測試專案', d('50000'), false), ('沒有專案', d('-1874.5'), true)],
      );
    });

    test('net worth at each month end works back from today', () {
      final l = InMemoryLedger(
        accounts: [
          Account(
            id: 'cash',
            name: '現金',
            type: AccountType.cash,
            currency: 'TWD',
            anchor: BalanceAnchor(amount: d('1000'), date: DateTime(2026, 9, 29)),
          ),
        ],
        transactions: [
          Txn(
            id: 'a',
            kind: TxnKind.income,
            date: DateTime(2026, 8, 10),
            accountId: 'cash',
            amount: d('500'),
            baseAmount: d('500'),
          ),
          Txn(
            id: 'b',
            kind: TxnKind.expense,
            date: DateTime(2026, 9, 10),
            accountId: 'cash',
            amount: d('200'),
            baseAmount: d('200'),
          ),
          Txn(
            id: 'c',
            kind: TxnKind.expense,
            date: DateTime(2026, 10, 10),
            accountId: 'cash',
            amount: d('50'),
            baseAmount: d('50'),
          ),
        ],
      );
      final today = DateTime(2026, 9, 29);
      final balances = computeBalances(l, today: today);
      final months = [Period.month(2026, 7), Period.month(2026, 8), Period.month(2026, 9)];
      expect(
        [for (final m in netWorthByMonth(l, balances, const {}, months, today: today)) m.total],
        [
          d('700'), // before the 500 came in
          d('1200'),
          d('1000'), // today; the October record is in the future
        ],
      );
    });
  });
}
