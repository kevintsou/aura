import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

Decimal d(String s) => Decimal.parse(s);

void main() {
  final sep = Period.month(2026, 9);
  var n = 0;
  Txn spend(
    DateTime date,
    String category,
    String amount, {
    String account = 'cash',
    String? note,
    Invoice? invoice,
    String? recurringId,
  }) => Txn(
    id: 't${n++}',
    kind: TxnKind.expense,
    date: date,
    accountId: account,
    categoryId: category,
    amount: d(amount),
    baseAmount: d(amount),
    note: note,
    invoice: invoice,
    recurringId: recurringId,
  );

  InMemoryLedger ledger(List<Txn> txns, {List<Budget> budgets = const []}) => InMemoryLedger(
    accounts: const [
      Account(id: 'cash', name: '現金', type: AccountType.cash, currency: 'TWD'),
      Account(id: 'card', name: '信用卡', type: AccountType.credit, currency: 'TWD'),
    ],
    categories: const [
      Category(id: 'food', kind: TxnKind.expense, name: '生活費'),
      Category(id: 'lunch', kind: TxnKind.expense, name: '午餐', parentId: 'food'),
      Category(id: 'fun', kind: TxnKind.expense, name: '購物娛樂'),
      Category(id: 'car', kind: TxnKind.expense, name: '交通'),
    ],
    transactions: txns,
    budgets: budgets,
  );

  // June to August: food 3,000 a month, fun 1,000, car 2,000.
  List<Txn> usual() => [
    for (final m in [6, 7, 8]) ...[
      spend(DateTime(2026, m, 5), 'lunch', '1000'),
      spend(DateTime(2026, m, 15), 'lunch', '1000'),
      spend(DateTime(2026, m, 25), 'food', '1000'),
      spend(DateTime(2026, m, 12), 'fun', '1000'),
      spend(DateTime(2026, m, 20), 'car', '2000'),
    ],
  ];

  test('the month against last month and the three before', () {
    final l = ledger([...usual(), spend(DateTime(2026, 9, 3), 'lunch', '3000'), spend(DateTime(2026, 9, 4), 'car', '4500')]);
    final ins = monthlyInsights(l, sep, today: DateTime(2026, 9, 29));
    expect(ins.first.kind, InsightKind.total);
    expect(ins.first.text, '支出 NT\$7,500，比上月多 25%，比前三個月平均多 25%');
    expect(ins.first.amount, d('7500'));
  });

  test('categories that moved most, biggest first, small moves left out', () {
    final l = ledger([
      ...usual(),
      spend(DateTime(2026, 9, 3), 'lunch', '3200'), // +200: too small
      spend(DateTime(2026, 9, 4), 'car', '4500'), // +2,500
      // fun: nothing this month, -1,000
    ]);
    final ins = monthlyInsights(l, sep, today: DateTime(2026, 9, 29));
    final moves = [for (final i in ins) if (i.kind == InsightKind.categoryUp || i.kind == InsightKind.categoryDown) i];
    expect([for (final i in moves) (i.kind, i.categoryId, i.amount)], [
      (InsightKind.categoryUp, 'car', d('2500')),
      (InsightKind.categoryDown, 'fun', d('-1000')),
    ]);
    expect(moves.first.text, '交通 NT\$4,500，比平常多 NT\$2,500（前三個月平均 NT\$2,000）');
    expect(moves.last.text, '購物娛樂 NT\$0，比平常少 NT\$1,000（前三個月平均 NT\$1,000）');
  });

  test('an expense far above what its category usually costs', () {
    final l = ledger([
      ...usual(),
      spend(DateTime(2026, 9, 10), 'lunch', '1000'),
      spend(DateTime(2026, 9, 12), 'lunch', '3500', note: '聚餐'),
      spend(DateTime(2026, 9, 14), 'car', '5000'), // too few past records
    ]);
    final unusual = [for (final i in monthlyInsights(l, sep, today: DateTime(2026, 9, 29))) if (i.kind == InsightKind.unusual) i];
    expect(unusual, hasLength(1));
    expect(unusual.single.text, '9/12 午餐・聚餐 NT\$3,500，比這類支出平常大很多');
    expect(l.txn(unusual.single.txnIds.single)!.note, '聚餐');
  });

  group('possible duplicates', () {
    test('same place, amount and account on the same day', () {
      final l = ledger([
        spend(DateTime(2026, 9, 10), 'lunch', '180', note: '便當'),
        spend(DateTime(2026, 9, 10), 'lunch', '180', note: '便當'),
        spend(DateTime(2026, 9, 11), 'lunch', '180', note: '便當'), // next day: a new lunch
        spend(DateTime(2026, 9, 10), 'lunch', '180', note: '便當', account: 'card'), // other account
        spend(DateTime(2026, 9, 12), 'lunch', '40', note: '茶'), // too small to matter
        spend(DateTime(2026, 9, 12), 'lunch', '40', note: '茶'),
      ]);
      final dups = possibleDuplicates(l, sep);
      expect([for (final p in dups) [for (final t in p) (t.date, t.accountId)]], [
        [(DateTime(2026, 9, 10), 'cash'), (DateTime(2026, 9, 10), 'cash')],
      ]);
      final ins = monthlyInsights(l, sep, today: DateTime(2026, 9, 29)).where((i) => i.kind == InsightKind.duplicate);
      expect(ins.single.text, '便當 NT\$180 9/10 記了兩次，是不是重複記帳或重複扣款？');
    });

    test('the same invoice number entered twice, days apart', () {
      const inv = Invoice(number: 'AB12345678', sellerTaxId: '12345678', sellerName: '好市多');
      const other = Invoice(number: 'AB12345679', sellerTaxId: '12345678', sellerName: '好市多');
      final l = ledger([
        spend(DateTime(2026, 9, 1), 'food', '2300', invoice: inv),
        spend(DateTime(2026, 9, 2), 'food', '2300', invoice: inv),
        // Two different invoices on the same day are two purchases.
        spend(DateTime(2026, 9, 20), 'food', '99', invoice: inv),
        spend(DateTime(2026, 9, 20), 'food', '99', invoice: other),
      ]);
      final dups = possibleDuplicates(l, sep);
      expect(dups, hasLength(1));
      expect([for (final t in dups.single) t.baseAmount], [d('2300'), d('2300')]);
      final ins = monthlyInsights(l, sep, today: DateTime(2026, 9, 29)).where((i) => i.kind == InsightKind.duplicate);
      expect(ins.single.text, '好市多 NT\$2,300 在 9/1 和 9/2 各記了一次，是不是重複記帳或重複扣款？');
    });

    test('recurring records and records without a note are left alone', () {
      final l = ledger([
        spend(DateTime(2026, 9, 5), 'fun', '390', note: '串流', recurringId: 'r1'),
        spend(DateTime(2026, 9, 5), 'fun', '390', note: '串流'),
        spend(DateTime(2026, 9, 6), 'lunch', '120'),
        spend(DateTime(2026, 9, 6), 'lunch', '120'),
      ]);
      expect(possibleDuplicates(l, sep), isEmpty);
    });

    test('a pair before the month belongs to that month', () {
      final l = ledger([
        spend(DateTime(2026, 8, 31), 'lunch', '500', note: '聚餐'),
        spend(DateTime(2026, 8, 31), 'lunch', '500', note: '聚餐'),
      ]);
      expect(possibleDuplicates(l, sep), isEmpty);
      expect(possibleDuplicates(l, Period.month(2026, 8)), hasLength(1));
    });

    test('a pair the user ruled out stays quiet', () {
      final l = ledger([
        spend(DateTime(2026, 9, 10), 'lunch', '180', note: '便當'),
        spend(DateTime(2026, 9, 10), 'lunch', '180', note: '便當'),
      ]);
      final pair = possibleDuplicates(l, sep).single;
      expect(duplicateKey(pair), duplicateKey(pair.reversed.toList()));
      expect(possibleDuplicates(l, sep, dismissed: {duplicateKey(pair)}), isEmpty);
      expect(
        monthlyInsights(l, sep, today: DateTime(2026, 9, 29), dismissedDuplicates: {duplicateKey(pair)})
            .where((i) => i.kind == InsightKind.duplicate),
        isEmpty,
      );
    });
  });

  test('budgets over or spending too fast', () {
    final l = ledger(
      [
        ...usual(),
        spend(DateTime(2026, 9, 3), 'fun', '1500'),
        spend(DateTime(2026, 9, 4), 'lunch', '2500'),
      ],
      budgets: [
        Budget(id: 'b-fun', amount: d('1200'), categoryId: 'fun'),
        Budget(id: 'b-food', amount: d('3000'), categoryId: 'food'),
        Budget(id: 'b-car', amount: d('2000'), categoryId: 'car'),
      ],
    );
    final ins = monthlyInsights(l, sep, today: DateTime(2026, 9, 10));
    final budget = [for (final i in ins) if (i.kind == InsightKind.overBudget || i.kind == InsightKind.fastBudget) i];
    expect([for (final i in budget) (i.kind, i.text)], [
      (InsightKind.fastBudget, '生活費已經用了 83%，這個月才過 33%'),
      (InsightKind.overBudget, '購物娛樂超支 NT\$300'),
    ]);
  });

  test('a month with nothing says nothing', () {
    expect(monthlyInsights(ledger(const []), sep, today: DateTime(2026, 9, 29)), isEmpty);
  });
}
