import 'dart:io';

import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

Decimal d(String s) => Decimal.parse(s);

void main() {
  final today = DateTime(2026, 9, 29);
  late InMemoryLedger ledger;
  late String savings;

  setUp(() {
    ledger = importCwmoneyCsv(
      File('test/fixtures/sample_cwmoney.csv').readAsBytesSync(),
    ).ledger;
    savings = ledger.accounts.firstWhere((a) => a.name == '活存-測試').id;
  });

  // 活存-測試 in the fixture: +50000 (9/25), −3000 −15 (9/24),
  // −100000 (9/23), +32370 (9/22), −5000 one-sided (9/21) = −25645.
  AccountBalance savingsBalance({DateTime? on, BalanceAnchor? anchor}) =>
      balanceOf(
        ledger.account(savings)!,
        ledger.accountFlows().where((f) => f.accountId == savings),
        today: on ?? today,
        anchor: anchor,
      );

  test('without an anchor the opening balance is assumed to be zero', () {
    final b = computeBalances(ledger, today: today)[savings]!;
    expect(b.isSet, isFalse);
    expect(b.opening, d('0'));
    expect(b.current, d('-25645'));
    expect(b.firstDate, DateTime(2026, 9, 21));
    expect(b.flowCount, 6);
  });

  test("today's real balance gives the opening balance", () {
    final b = savingsBalance(
      anchor: BalanceAnchor(amount: d('200000'), date: today),
    );
    expect(b.current, d('200000'));
    expect(b.opening, d('225645'));
  });

  test('a balance on an earlier day carries forward', () {
    final b = savingsBalance(
      anchor: BalanceAnchor(amount: d('100000'), date: DateTime(2026, 9, 23)),
    );
    expect(b.current, d('146985')); // + (−3015) on 9/24, +50000 on 9/25
    expect(b.opening, d('172630'));
  });

  test('an opening balance anchors to the day before the first record', () {
    final anchor = savingsBalance().openingAnchor(d('1000'), today: today);
    expect(anchor.date, DateTime(2026, 9, 20));
    final b = savingsBalance(anchor: anchor);
    expect(b.opening, d('1000'));
    expect(b.current, d('-24645'));
  });

  test('records after today are not in the current balance yet', () {
    final b = savingsBalance(on: DateTime(2026, 9, 24));
    expect(b.current, d('-75645'));
  });

  test('transfers move money between accounts in their own currencies', () {
    final all = computeBalances(ledger, today: today);
    Decimal of(String name) =>
        all[ledger.accounts.firstWhere((a) => a.name == name).id]!.current;
    expect(of('現金'), d('2880')); // +3000 transfer, −120 lunch
    expect(of('美金-測試'), d('-1000')); // USD, not TWD
    expect(of('日幣-測試'), d('-10000')); // JPY
    expect(of('定存-測試'), d('100000'));
  });

  test('a stored anchor is used and can be cleared', () {
    ledger.setBalanceAnchor(
      savings,
      BalanceAnchor(amount: d('200000'), date: today),
    );
    expect(computeBalances(ledger, today: today)[savings]!.current, d('200000'));
    ledger.setBalanceAnchor(savings, null);
    expect(computeBalances(ledger, today: today)[savings]!.isSet, isFalse);
  });

  test('an account without records keeps its anchor as its balance', () {
    final empty = InMemoryLedger(
      accounts: [
        Account(
          id: 'a',
          name: '新帳戶',
          type: AccountType.cash,
          currency: 'TWD',
          anchor: BalanceAnchor(amount: d('500'), date: DateTime(2026, 9, 1)),
        ),
      ],
    );
    final b = computeBalances(empty, today: today)['a']!;
    expect(b.current, d('500'));
    expect(b.opening, d('500'));
    expect(b.openingAnchor(d('700'), today: today).date, today);
  });
}
