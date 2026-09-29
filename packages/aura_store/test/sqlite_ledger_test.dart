import 'dart:io';

import 'package:aura_core/aura_core.dart';
import 'package:aura_store/aura_store.dart';
import 'package:decimal/decimal.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

final _imported = importCwmoneyCsv(
  File('../aura_core/test/fixtures/sample_cwmoney.csv').readAsBytesSync(),
).ledger;

/// Every field of a transaction, for exact comparisons.
Map<String, Object?> _fields(Txn t) => {
  'id': t.id,
  'kind': t.kind,
  'date': t.date,
  'accountId': t.accountId,
  'toAccountId': t.toAccountId,
  'amount': t.amount,
  'toAmount': t.toAmount,
  'baseAmount': t.baseAmount,
  'fxRateDisplay': t.fxRateDisplay,
  'categoryId': t.categoryId,
  'projectId': t.projectId,
  'note': t.note,
  'place': t.place,
  'createdAt': t.createdAt,
  'feeOfTxnId': t.feeOfTxnId,
  'needsReview': t.needsReview,
  'legacyRows': t.legacyRows,
  'invoice': t.invoice == null
      ? null
      : {
          'number': t.invoice!.number,
          'taxId': t.invoice!.sellerTaxId,
          'seller': t.invoice!.sellerName,
          'address': t.invoice!.sellerAddress,
          'carrier': t.invoice!.carrier,
          'items': [
            for (final i in t.invoice!.items) [i.name, i.quantity, i.amount],
          ],
        },
};

void main() {
  late SqliteLedger db;

  setUp(() {
    db = SqliteLedger.inMemory()..replaceAll(_imported);
  });
  tearDown(() => db.close());

  test('creates the latest schema', () {
    expect(db.schemaVersion, migrations.length);
  });

  test('round-trips every field of every transaction exactly', () {
    expect(
      db.transactions().map(_fields).toList(),
      _imported.transactions().map(_fields).toList(),
    );
    expect(db.accounts.map((a) => (a.id, a.name, a.type, a.currency)),
        _imported.accounts.map((a) => (a.id, a.name, a.type, a.currency)));
    expect(db.categories.map((c) => (c.id, c.kind, c.name, c.parentId)),
        _imported.categories.map((c) => (c.id, c.kind, c.name, c.parentId)));
    expect(db.projects.map((p) => p.name), _imported.projects.map((p) => p.name));
  });

  test('keeps decimals exact', () {
    final t = db.transactions(const TxnFilter(keyword: '虧損')).single;
    expect(t.amount, Decimal.parse('-1874.5'));
    final fuel = db.transactions(const TxnFilter(keyword: '汽油')).single;
    expect(fuel.invoice!.items.single.quantity, Decimal.parse('56.68'));
  });

  group('filters match the in-memory ledger', () {
    String cat(String name, {bool main = false}) => _imported.categories
        .firstWhere((c) => c.name == name && (c.parentId == null) == main)
        .id;
    String acct(String name) =>
        _imported.accounts.firstWhere((a) => a.name == name).id;

    final cases = <String, TxnFilter Function()>{
      'everything': () => const TxnFilter(),
      'date range': () =>
          TxnFilter(from: DateTime(2026, 9, 20), to: DateTime(2026, 9, 24)),
      'kinds': () => const TxnFilter(kinds: {TxnKind.income, TxnKind.transfer}),
      'main category includes subcategories': () =>
          TxnFilter(categoryIds: {cat('生活費', main: true)}),
      'subcategory': () => TxnFilter(categoryIds: {cat('加油')}),
      'account on either side of a transfer': () =>
          TxnFilter(accountIds: {acct('現金')}),
      'project': () => TxnFilter(projectIds: {_imported.projects.single.id}),
      'keyword in note': () => const TxnFilter(keyword: '薪水'),
      'keyword in seller': () => const TxnFilter(keyword: '測試加油站'),
      'keyword in items': () => const TxnFilter(keyword: '茶葉蛋'),
      'keyword not in items when hidden': () =>
          const TxnFilter(keyword: '茶葉蛋', searchInvoiceItems: false),
      'keyword is not a LIKE pattern': () => const TxnFilter(keyword: '%'),
      'combined': () => TxnFilter(
        kinds: {TxnKind.expense},
        accountIds: {acct('信用卡-測試')},
        from: DateTime(2026, 9, 28),
      ),
    };
    for (final MapEntry(key: name, value: filter) in cases.entries) {
      test(name, () {
        expect(
          db.transactions(filter()).map((t) => t.id).toList(),
          _imported.transactions(filter()).map((t) => t.id).toList(),
        );
        expect(db.count(filter()), _imported.count(filter()));
        expect(
          db.transactions(filter(), 2, 3).map((t) => t.id).toList(),
          _imported.transactions(filter(), 2, 3).map((t) => t.id).toList(),
        );
      });
    }
  });

  test('replaceAll replaces instead of appending', () {
    db.replaceAll(_imported);
    expect(db.transactions(), hasLength(_imported.transactions().length));
    db.replaceAll(InMemoryLedger());
    expect(db.transactions(), isEmpty);
    expect(db.accounts, isEmpty);
  });

  test('a failed replaceAll leaves the old data untouched', () {
    final broken = InMemoryLedger(
      transactions: [
        Txn(
          id: 'x',
          kind: TxnKind.expense,
          date: DateTime(2026),
          accountId: 'no-such-account',
          amount: Decimal.one,
          baseAmount: Decimal.one,
        ),
      ],
    );
    expect(() => db.replaceAll(broken), throwsA(isA<SqliteException>()));
    expect(db.transactions(), hasLength(_imported.transactions().length));
    expect(db.accounts, hasLength(_imported.accounts.length));
  });

  test('stores meta values', () {
    db.setMeta('import.file', 'a.csv');
    db.setMeta('import.file', 'b.csv');
    expect(db.meta('import.file'), 'b.csv');
    db.setMeta('import.file', null);
    expect(db.meta('import.file'), isNull);
  });

  group('on disk', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('aura_store'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('data survives closing and reopening', () {
      final path = '${dir.path}/aura.db';
      SqliteLedger.open(path)
        ..replaceAll(_imported)
        ..setMeta('k', 'v')
        ..close();
      final reopened = SqliteLedger.open(path);
      addTearDown(reopened.close);
      expect(reopened.meta('k'), 'v');
      expect(
        reopened.transactions().map(_fields).toList(),
        _imported.transactions().map(_fields).toList(),
      );
    });

    test('refuses a database from a newer app version', () {
      final path = '${dir.path}/future.db';
      final raw = sqlite3.open(path)..userVersion = migrations.length + 1;
      raw.close();
      expect(() => SqliteLedger.open(path), throwsStateError);
    });
  });
}
