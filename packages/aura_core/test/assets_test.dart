import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

Decimal d(String s) => Decimal.parse(s);

void main() {
  final ledger = InMemoryLedger(
    accounts: [
      Account(
        id: 'cash',
        name: '現金',
        type: AccountType.cash,
        currency: 'TWD',
        anchor: BalanceAnchor(amount: d('5000'), date: DateTime(2026, 9, 30)),
      ),
      Account(
        id: 'card',
        name: '信用卡',
        type: AccountType.credit,
        currency: 'TWD',
        anchor: BalanceAnchor(amount: d('-12000'), date: DateTime(2026, 9, 30)),
      ),
      Account(
        id: 'usd',
        name: '美金',
        type: AccountType.bank,
        currency: 'USD',
        anchor: BalanceAnchor(amount: d('1000'), date: DateTime(2026, 9, 30)),
      ),
      Account(
        id: 'jpy',
        name: '日幣',
        type: AccountType.cash,
        currency: 'JPY',
        anchor: BalanceAnchor(amount: d('20000'), date: DateTime(2026, 9, 30)),
      ),
      const Account(id: 'odd', name: '不明', type: AccountType.other, currency: unknownCurrency),
    ],
    transactions: [
      // Older USD rate, then a newer one: the newest wins.
      Txn(
        id: 'u1',
        kind: TxnKind.expense,
        date: DateTime(2026, 8, 1),
        accountId: 'usd',
        amount: d('10'),
        baseAmount: d('310'),
      ),
      Txn(
        id: 'u2',
        kind: TxnKind.transfer,
        date: DateTime(2026, 9, 22),
        accountId: 'usd',
        toAccountId: 'cash',
        amount: d('100'),
        toAmount: d('3237'),
        baseAmount: d('3237'),
      ),
      // JPY only ever received: the rate comes from what arrived.
      Txn(
        id: 'j1',
        kind: TxnKind.transfer,
        date: DateTime(2026, 9, 1),
        accountId: 'cash',
        toAccountId: 'jpy',
        amount: d('2100'),
        toAmount: d('10000'),
        baseAmount: d('2100'),
      ),
      Txn(
        id: 'o1',
        kind: TxnKind.expense,
        date: DateTime(2026, 9, 1),
        accountId: 'odd',
        amount: d('5'),
        baseAmount: d('5'),
      ),
    ],
  );

  test('rates come from the newest record in each currency, or the user', () {
    final rates = knownRates(ledger);
    expect((rates['USD']!.rate, rates['USD']!.asOf), (d('32.37'), DateTime(2026, 9, 22)));
    expect(rates['JPY']!.rate, d('0.21'));
    expect(rates.containsKey(unknownCurrency), isFalse);
    final manual = knownRates(ledger, manual: {'USD': '30'});
    expect((manual['USD']!.rate, manual['USD']!.manual), (d('30'), true));
  });

  test('net worth converts foreign balances and separates debts', () {
    final balances = computeBalances(ledger, today: DateTime(2026, 9, 30)).values;
    final s = summarizeAssets(balances, knownRates(ledger));
    // 5000 cash + 32370 USD + 4200 JPY; 12000 card debt.
    expect(s.assets, d('41570'));
    expect(s.liabilities, d('12000'));
    expect(s.net, d('29570'));
    expect(s.byType[AccountType.credit], d('-12000'));
    expect(s.byType[AccountType.cash], d('9200'));
    expect(s.unconverted.single.name, '不明');
  });
}
