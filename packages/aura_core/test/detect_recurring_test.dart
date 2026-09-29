import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

Decimal d(String s) => Decimal.parse(s);

void main() {
  final today = DateTime(2026, 9, 29);
  var n = 0;
  Txn txn(
    DateTime date,
    String amount, {
    String? note,
    String category = 'bills',
    String account = 'card',
    TxnKind kind = TxnKind.expense,
  }) => Txn(
    id: 't${n++}',
    kind: kind,
    date: date,
    accountId: account,
    categoryId: category,
    amount: d(amount),
    baseAmount: d(amount),
    note: note,
  );

  InMemoryLedger ledger(List<Txn> txns, {List<Recurring> recurrings = const []}) => InMemoryLedger(
    accounts: const [
      Account(id: 'card', name: '信用卡', type: AccountType.credit, currency: 'TWD'),
      Account(id: 'bank', name: '活存', type: AccountType.bank, currency: 'TWD'),
    ],
    categories: const [
      Category(id: 'bills', kind: TxnKind.expense, name: '帳單'),
      Category(id: 'food', kind: TxnKind.expense, name: '餐飲'),
      Category(id: 'job', kind: TxnKind.income, name: '薪資'),
    ],
    transactions: txns,
    recurrings: recurrings,
  );

  test('finds a monthly subscription, a bill that varies, a salary and a yearly fee', () {
    final l = ledger([
      for (var m = 3; m <= 9; m++) txn(DateTime(2026, m, 5), '390', note: '串流影音'),
      for (var m = 4; m <= 9; m++) txn(DateTime(2026, m, 20 + m % 3), '${900 + m * 10}', note: '電費', account: 'bank'),
      for (var m = 5; m <= 9; m++)
        txn(DateTime(2026, m, 25), '52000', category: 'job', account: 'bank', kind: TxnKind.income),
      txn(DateTime(2025, 3, 10), '1200', note: '網域續約'),
      txn(DateTime(2026, 3, 10), '1200', note: '網域續約'),
      // Noise: lunches of different amounts and irregular one-offs.
      for (var i = 0; i < 20; i++) txn(DateTime(2026, 9, 1 + i), '${100 + i * 7}', category: 'food', note: '午餐'),
      txn(DateTime(2026, 6, 1), '5000', note: '冷氣'),
    ]);
    final found = detectRecurring(l, today: today);
    expect(
      [for (final c in found) (c.label, c.unit, c.times, c.next, c.fixedAmount)],
      [
        (null, RepeatUnit.month, 5, DateTime(2026, 10, 25), true), // salary: no note, same amount
        ('網域續約', RepeatUnit.year, 2, DateTime(2027, 3, 10), true),
        ('電費', RepeatUnit.month, 6, DateTime(2026, 10, 20), false),
        ('串流影音', RepeatUnit.month, 7, DateTime(2026, 10, 5), true),
      ],
    );
  });

  test('turning one into a recurring item starts from the next one', () {
    final l = ledger([for (var m = 5; m <= 9; m++) txn(DateTime(2026, m, 5), '390', note: '串流影音')]);
    final c = detectRecurring(l, today: today).single;
    final r = c.toRecurring('r1');
    expect(
      (r.start, r.next, r.unit, r.template.note, r.template.amount),
      (DateTime(2026, 10, 5), DateTime(2026, 10, 5), RepeatUnit.month, '串流影音', d('390')),
    );
    l.setRecurring(r);
    expect(detectRecurring(l, today: today), isEmpty, reason: 'covered now');
    expect(recordDueRecurring(l, today: today).recorded, isEmpty, reason: 'nothing recorded twice');
  });

  test('stopped charges and dismissed ones are left out', () {
    final stopped = ledger([for (var m = 1; m <= 5; m++) txn(DateTime(2026, m, 5), '390', note: '健身房')]);
    expect(detectRecurring(stopped, today: today), isEmpty);
    final l = ledger([for (var m = 5; m <= 9; m++) txn(DateTime(2026, m, 5), '390', note: '串流影音')]);
    final key = detectRecurring(l, today: today).single.key;
    expect(detectRecurring(l, today: today, dismissed: {key}), isEmpty);
  });
}
