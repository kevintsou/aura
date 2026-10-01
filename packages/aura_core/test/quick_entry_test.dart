import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

void main() {
  late InMemoryLedger l;
  var n = 0;
  Txn t(int day, String note, String amount, {String cat = 'lunch', String acct = 'cash', TxnKind kind = TxnKind.expense}) => Txn(
    id: 't${n++}',
    kind: kind,
    date: DateTime(2026, 9, day),
    accountId: acct,
    categoryId: cat,
    amount: Decimal.parse(amount),
    baseAmount: Decimal.parse(amount),
    note: note,
  );

  setUp(() {
    l = InMemoryLedger(
      accounts: const [
        Account(id: 'cash', name: '現金', type: AccountType.cash, currency: 'TWD'),
        Account(id: 'card', name: '信用卡', type: AccountType.credit, currency: 'TWD'),
      ],
      categories: const [
        Category(id: 'food', kind: TxnKind.expense, name: '餐飲'),
        Category(id: 'lunch', kind: TxnKind.expense, name: '午餐', parentId: 'food'),
        Category(id: 'dinner', kind: TxnKind.expense, name: '晚餐', parentId: 'food'),
        Category(id: 'pay', kind: TxnKind.income, name: '薪水'),
      ],
      transactions: [
        t(1, '便當', '100'),
        t(2, '便當', '110', acct: 'card'),
        t(3, '便當 ', '120'),
        t(4, '便當加蛋', '130'),
        t(5, '咖啡', '60', cat: 'dinner'),
        t(6, '便當', '125', cat: 'dinner'),
        t(7, '九月薪水', '50000', cat: 'pay', kind: TxnKind.income),
        t(8, '多行\n備註', '1'),
      ],
    );
  });

  test('the usual category and account, and the latest amount', () {
    final u = usualFor(l, ' 便當')!;
    expect((u.note, u.kind, u.categoryId, u.accountId, u.amount, u.times), ('便當', TxnKind.expense, 'lunch', 'cash', Decimal.parse('125'), 4));
    expect(usualFor(l, '九月薪水')!.kind, TxnKind.income);
    expect(usualFor(l, '沒用過'), isNull);
    expect(usualFor(l, ''), isNull);
    expect(usualFor(l, '便當', kind: TxnKind.income), isNull);
  });

  test('completes notes used before, prefix matches and the most used first', () {
    expect(recentNotes(l, '便'), ['便當', '便當加蛋']);
    expect(recentNotes(l, '當'), ['便當', '便當加蛋']);
    expect(recentNotes(l, '便當'), ['便當加蛋'], reason: 'not what is already typed');
    expect(recentNotes(l, '薪'), ['九月薪水']);
    expect(recentNotes(l, '薪', kind: TxnKind.expense), isEmpty);
    expect(recentNotes(l, '備註'), isEmpty, reason: 'multi-line notes are not suggestions');
    expect(recentNotes(l, ''), isEmpty);
  });

  test('a copy keeps what is repeated and drops what belongs to the original', () {
    final original = Txn(
      id: 'o',
      kind: TxnKind.expense,
      date: DateTime(2026, 8, 1),
      accountId: 'cash',
      categoryId: 'lunch',
      amount: Decimal.fromInt(80),
      baseAmount: Decimal.fromInt(80),
      note: '早餐',
      place: '店',
      location: const GeoPoint(25, 121),
      invoice: const Invoice(number: 'AB12345678'),
      legacyRows: const [
        ['x'],
      ],
      recurringId: 'r',
      createdAt: DateTime(2026, 8, 1, 8),
    );
    final c = copyOfTxn(original, id: 'c', date: DateTime(2026, 9, 29, 13), createdAt: DateTime(2026, 9, 29, 13));
    expect((c.id, c.date, c.amount, c.categoryId, c.note), ('c', DateTime(2026, 9, 29), Decimal.fromInt(80), 'lunch', '早餐'));
    expect([c.place, c.location, c.invoice, c.recurringId], everyElement(isNull));
    expect(c.legacyRows, isEmpty);
  });
}
