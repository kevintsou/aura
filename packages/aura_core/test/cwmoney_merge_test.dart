import 'dart:io';

import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

final _bytes = File('test/fixtures/sample_cwmoney.csv').readAsBytesSync();

/// The fixture's records, split on CRLF: the header, then records 1–14.
final _records = () {
  final lines = <List<int>>[[]];
  for (var i = 0; i < _bytes.length; i++) {
    if (_bytes[i] == 0x0D && i + 1 < _bytes.length && _bytes[i + 1] == 0x0A) {
      lines.add([]);
      i++;
    } else {
      lines.last.add(_bytes[i]);
    }
  }
  return lines.where((l) => l.isNotEmpty).toList();
}();

/// A CWMoney export holding only the fixture records numbered [ids]
/// (1: breakfast 9/28 … 14: lunch 9/18; 4+5 a transfer, 6 its fee).
List<int> _csv(Iterable<int> ids) => [
  for (final i in [0, ...ids]) ...[..._records[i], 0x0D, 0x0A],
];

InMemoryLedger _import(Iterable<int> ids) => importCwmoneyCsv(_csv(ids)).ledger;

final _all = [for (var i = 1; i <= 14; i++) i];

InMemoryLedger _merge(LedgerReader current, CwmMergePlan plan, {bool skip = true}) =>
    plan.applyTo(current, skipPossibleDuplicates: skip);

Txn _only(LedgerReader l, bool Function(Txn) test) => l.transactions().where(test).single;

void main() {
  test('the fixture splits into a header and 14 records', () {
    expect(_records, hasLength(15));
    expect(_import(_all).count(), importCwmoneyCsv(_bytes).ledger.count());
  });

  test('merging the same file again adds nothing', () {
    final current = _import(_all);
    final plan = planCwmoneyMerge(current, _import(_all));
    expect(plan.isEmpty, isTrue);
    expect(plan.alreadyPresent, current.count());
    expect(plan.newAccounts, isEmpty);
    expect(plan.newCategories, isEmpty);
    expect(_merge(current, plan).count(), current.count());
  });

  test('a newer export adds only the records not seen before', () {
    // First the older half (9/18–9/23), then an export covering it all.
    final current = _import([7, 8, 9, 10, 11, 12, 13, 14]);
    expect(current.count(), 6);
    final plan = planCwmoneyMerge(current, _import(_all));
    expect(plan.alreadyPresent, 6);
    expect(plan.newTxns, hasLength(5)); // breakfast, fuel, salary, transfer, fee
    expect((plan.from, plan.to), (DateTime(2026, 9, 24), DateTime(2026, 9, 28)));
    expect(plan.latestExisting, DateTime(2026, 9, 23));
    expect(
      [for (final a in plan.newAccounts) a.name],
      unorderedEquals(['信用卡-測試']),
      reason: '活存-測試 and 現金 already exist and are reused',
    );
    // 早餐 goes under the existing 生活費; the other main categories are new.
    final food = current.categories.firstWhere((c) => c.name == '生活費');
    expect(
      [for (final c in plan.newCategories) (c.name, c.parentId == food.id)],
      unorderedEquals([
        ('早餐', true),
        ('行車交通', false),
        ('加油', false),
        ('工作收入', false),
        ('薪資收入', false),
        ('醫療其他', false),
        ('手續費', false),
      ]),
    );
    expect([for (final p in plan.newProjects) p.name], ['測試專案']);

    final merged = _merge(current, plan);
    final full = _import(_all);
    expect(merged.count(), full.count());
    expect(totalsFor(merged, Period.month(2026, 9)).expense, totalsFor(full, Period.month(2026, 9)).expense);
    expect(merged.accounts.map((a) => a.name).toSet(), hasLength(merged.accounts.length));
    // Every record points at something that exists.
    final check = InMemoryLedger(
      accounts: merged.accounts,
      categories: merged.categories,
      projects: merged.projects,
    );
    for (final t in merged.transactions()) {
      expect(() => checkTxn(check, t), returnsNormally);
    }
    // The fee is linked to the transfer added with it.
    final fee = _only(merged, (t) => t.note == null && t.baseAmount == Decimal.fromInt(15));
    final transfer = _only(merged, (t) => t.kind == TxnKind.transfer && t.baseAmount == Decimal.fromInt(3000));
    expect(fee.feeOfTxnId, transfer.id);
  });

  test('records are recognised after being edited in Aura', () {
    final current = _import([12, 13, 14]);
    final lunch = _only(current, (t) => t.note == '便當');
    current.updateTxn(
      Txn(
        id: lunch.id,
        kind: lunch.kind,
        date: lunch.date,
        accountId: lunch.accountId,
        categoryId: lunch.categoryId,
        amount: Decimal.fromInt(125),
        baseAmount: Decimal.fromInt(125),
        note: '便當加飲料',
        legacyRows: lunch.legacyRows,
      ),
    );
    final plan = planCwmoneyMerge(current, _import(_all));
    expect(plan.alreadyPresent, 3);
    final merged = _merge(current, plan);
    expect(merged.transactions().where((t) => t.date == DateTime(2026, 9, 18)), hasLength(1));
    expect(_only(merged, (t) => t.id == lunch.id).note, '便當加飲料', reason: 'the edit is kept');
  });

  test('completes a transfer that was imported with one side', () {
    // Only the outgoing row of the 9/24 transfer, plus its fee.
    final current = _import([5, 6]);
    final oneSided = _only(current, (t) => t.kind == TxnKind.transfer);
    expect(oneSided.needsReview, isTrue);
    expect(oneSided.toAccountId, isNull);

    final plan = planCwmoneyMerge(current, _import([4, 5, 6]));
    expect(plan.completedTransfers, hasLength(1));
    expect(plan.newTxns, isEmpty);
    expect(plan.alreadyPresent, 1); // the fee
    final merged = _merge(current, plan);
    final done = _only(merged, (t) => t.kind == TxnKind.transfer);
    expect(done.id, oneSided.id);
    expect(done.needsReview, isFalse);
    expect(merged.account(done.toAccountId!)!.name, '現金');
    expect(plan.newAccounts.single.name, '現金');
    expect(_only(merged, (t) => t.kind == TxnKind.expense).feeOfTxnId, oneSided.id);
  });

  test('leaves a one-sided transfer alone once the user has fixed it', () {
    final current = _import([5]);
    final oneSided = _only(current, (t) => t.kind == TxnKind.transfer);
    current
      ..addAccount(const Account(id: 'x', name: '零用金', type: AccountType.cash, currency: 'TWD'))
      ..updateTxn(
        Txn(
          id: oneSided.id,
          kind: TxnKind.transfer,
          date: oneSided.date,
          accountId: oneSided.accountId,
          toAccountId: 'x',
          amount: oneSided.amount,
          baseAmount: oneSided.baseAmount,
          legacyRows: oneSided.legacyRows,
        ),
      );
    final plan = planCwmoneyMerge(current, _import([4, 5]));
    expect(plan.isEmpty, isTrue);
    expect(plan.alreadyPresent, 1);
  });

  test('flags records that look like ones entered by hand', () {
    final current = InMemoryLedger(categories: defaultCategories(), accounts: [defaultCashAccount()]);
    final cash = current.accounts.single;
    final lunch = current.categories.firstWhere((c) => c.name == '午餐');
    current
      ..addTxn(
        Txn(
          id: 'manual',
          kind: TxnKind.expense,
          date: DateTime(2026, 9, 18),
          accountId: cash.id,
          categoryId: lunch.id,
          amount: Decimal.fromInt(120),
          baseAmount: Decimal.fromInt(120),
          note: '午餐',
        ),
      )
      ..setBalanceAnchor(cash.id, BalanceAnchor(amount: Decimal.fromInt(500), date: DateTime(2026, 9, 1)));

    final plan = planCwmoneyMerge(current, _import(_all));
    expect(plan.newTxns, hasLength(11));
    final flagged = plan.newTxns.where((t) => plan.possibleDuplicates.contains(t.id)).single;
    expect(flagged.note, '便當');
    expect(flagged.categoryId, lunch.id, reason: 'matched to the default category by name');

    expect(_merge(current, plan).count(), 11);
    expect(_merge(current, plan, skip: false).count(), 12);
    expect(_merge(current, plan).account(cash.id)!.anchor!.amount, Decimal.fromInt(500));
  });
}
