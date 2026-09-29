import 'dart:io';

import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

final _bytes = File('test/fixtures/sample_cwmoney.csv').readAsBytesSync();

List<String> _lines(List<int> bytes) =>
    decodeBig5Hkscs(bytes).split('\r\n').where((l) => l.isNotEmpty).toList();

List<List<String>> _rows(List<int> bytes) => [
  for (final l in _lines(bytes).skip(1)) l.substring(1, l.length - 1).split('","'),
];

Decimal d(String s) => Decimal.parse(s);

void main() {
  test('Big5-HKSCS encoding reverses decoding, CWMoney style', () {
    final text = decodeBig5Hkscs(_bytes);
    expect(encodeBig5Hkscs(text), _bytes);
    // 十 has two codes; CWMoney writes the common one, and ／ as 0xA1FE.
    expect(encodeBig5Hkscs('十／'), [0xA4, 0x51, 0xA1, 0xFE]);
    var replaced = 0;
    expect(encodeBig5Hkscs('a😀b', unmappable: (_) => replaced++), 'a?b'.codeUnits);
    expect(replaced, 1);
  });

  test('imported records go back out as they came in', () {
    final ledger = importCwmoneyCsv(_bytes).ledger;
    final r = exportCwmoneyCsv(ledger, includeCarrier: true);
    expect((r.records, r.rows, r.unchanged, r.replacedCharacters), (11, 14, 11, 0));
    final ours = _lines(r.bytes), theirs = _lines(_bytes);
    expect(ours.first, theirs.first, reason: 'header');
    expect(ours.toSet(), theirs.toSet(), reason: 'the same rows, byte for byte');
    expect(r.bytes.sublist(r.bytes.length - 2), [13, 10], reason: 'every record ends with CRLF');
    // Newest first, and a transfer's receiving row comes first.
    final rows = _rows(r.bytes);
    expect(rows.map((r) => r[0]).toList(), [...rows.map((r) => r[0])]..sort((a, b) => b.compareTo(a)));
    final transfer = rows.indexWhere((r) => r[0] == '2026/09/24' && r[13] == '1');
    expect((rows[transfer][1], rows[transfer + 1][1]), ('收入', '支出'));
  });

  test('masks the e-invoice carrier number unless asked not to', () {
    final ledger = importCwmoneyCsv(_bytes).ledger;
    final masked = decodeBig5Hkscs(exportCwmoneyCsv(ledger).bytes);
    expect(masked, isNot(contains('/TEST123')));
    expect(masked, contains('[手機條碼,******]'));
    expect(decodeBig5Hkscs(exportCwmoneyCsv(ledger, includeCarrier: true).bytes), contains('[手機條碼,/TEST123]'));
  });

  test('an edited record changes only what was edited', () {
    final ledger = importCwmoneyCsv(_bytes).ledger;
    final lunch = ledger.transactions().firstWhere((t) => t.note == '便當');
    ledger.updateTxn(
      Txn(
        id: lunch.id,
        kind: lunch.kind,
        date: lunch.date,
        accountId: lunch.accountId,
        categoryId: lunch.categoryId,
        amount: d('135'),
        baseAmount: d('135'),
        note: '便當加湯',
        place: lunch.place,
        createdAt: lunch.createdAt,
        legacyRows: lunch.legacyRows,
      ),
    );
    final r = exportCwmoneyCsv(ledger, includeCarrier: true);
    expect(r.unchanged, 10);
    final original = lunch.legacyRows.single;
    final row = _rows(r.bytes).firstWhere((r) => r[0] == '2026/09/18');
    expect(row, [...original.take(6), '135', original[7], '135', ...original.sublist(9, 14), '便當加湯']);
  });

  test('records made in Aura become rows CWMoney can read back', () {
    final l = InMemoryLedger(
      accounts: const [
        Account(id: 'cash', name: '現金', type: AccountType.cash, currency: 'TWD'),
        Account(id: 'usd', name: '美金-測試', type: AccountType.bank, currency: 'USD'),
      ],
      categories: const [
        Category(id: 'food', kind: TxnKind.expense, name: '生活費'),
        Category(id: 'lunch', kind: TxnKind.expense, name: '午餐', parentId: 'food'),
        Category(id: 'fee', kind: TxnKind.expense, name: '手續費'),
        Category(id: 'job', kind: TxnKind.income, name: '工作收入'),
      ],
      projects: const [Project(id: 'trip', name: '東京旅行')],
    );
    Txn txn(String id, TxnKind kind, String amount, {String? category, String account = 'cash', String? note}) => Txn(
      id: id,
      kind: kind,
      date: DateTime(2026, 10, 3),
      accountId: account,
      categoryId: category,
      amount: d(amount),
      baseAmount: d(amount),
      note: note,
      createdAt: DateTime(2026, 10, 3, 12, int.parse(id.substring(1))),
    );
    l
      ..addTxn(txn('t1', TxnKind.expense, '120', category: 'lunch', note: '便當\n加蛋 😀'))
      ..addTxn(txn('t2', TxnKind.income, '50000', category: 'job'))
      ..addTxn(
        Txn(
          id: 't3',
          kind: TxnKind.transfer,
          date: DateTime(2026, 10, 3),
          accountId: 'usd',
          toAccountId: 'cash',
          amount: d('100'),
          toAmount: d('3200'),
          baseAmount: d('3200'),
          fxRateDisplay: '32',
          projectId: 'trip',
          createdAt: DateTime(2026, 10, 3, 12, 3),
        ),
      )
      ..addTxn(txn('t4', TxnKind.expense, '15', category: 'fee').copyWith(feeOfTxnId: 't3'))
      ..addTxn(txn('t5', TxnKind.expense, '30'));

    final r = exportCwmoneyCsv(l);
    expect((r.records, r.rows, r.unchanged, r.replacedCharacters), (5, 6, 0, 1));
    final rows = _rows(r.bytes);
    final lunch = rows.firstWhere((r) => r[3] == '午餐');
    expect(lunch, [
      '2026/10/03', '支出', '生活費', '午餐', '現金', '無特別專案', '120', '1', '120', //
      '2026/10/03 12:01:00', '', ' ', '', '0', '便當\n加蛋 ?',
    ]);
    final transfer = rows.where((r) => r[13] == '1').toList();
    expect([for (final r in transfer) (r[1], r[4], r[5], r[6], r[7], r[8], r[14])], [
      ('收入', '現金', '東京旅行', '3200', '1', '3200', '[帳戶轉帳]'),
      ('支出', '美金-測試', '東京旅行', '100', '32', '3200', '[帳戶轉帳]'),
    ]);
    final fee = rows.firstWhere((r) => r[13] == '2');
    expect((fee[2], fee[9], fee[14]), ('手續費', '2026/10/03 12:03:00', '[手續費][帳戶轉帳]'), reason: 'tied by time');

    // CWMoney-format readers (our own importer here) read it back.
    final back = importCwmoneyCsv(r.bytes);
    expect((back.report.transferPairs, back.report.feesLinked, back.ledger.count()), (1, 1, 5));
    expect(back.ledger.transactions().map((t) => t.baseAmount).fold(Decimal.zero, (a, b) => a + b), d('53365'));
  });

  test('GPS positions go out and come back in', () {
    final ledger = importCwmoneyCsv(_bytes).ledger;
    expect(ledger.transactions().where((t) => t.location != null), isEmpty, reason: '"0:0" means none');
    final lunch = ledger.transactions().firstWhere((t) => t.note == '便當');
    final here = const GeoPoint(25.033964, 121.564468);
    ledger.updateTxn(
      Txn(
        id: lunch.id,
        kind: lunch.kind,
        date: lunch.date,
        accountId: lunch.accountId,
        categoryId: lunch.categoryId,
        amount: lunch.amount,
        baseAmount: lunch.baseAmount,
        note: lunch.note,
        place: lunch.place,
        location: here,
        createdAt: lunch.createdAt,
        legacyRows: lunch.legacyRows,
      ),
    );
    final r = exportCwmoneyCsv(ledger, includeCarrier: true);
    expect(r.unchanged, 10);
    final row = _rows(r.bytes).firstWhere((r) => r[0] == '2026/09/18');
    expect(row[10], '25.033964 : 121.564468');
    expect(row.sublist(11), lunch.legacyRows.single.sublist(11), reason: 'the rest as it was');
    final back = importCwmoneyCsv(r.bytes).ledger.transactions().firstWhere((t) => t.note == '便當');
    expect(back.location, here);
  });

  test('GPS field forms', () {
    expect(GeoPoint.tryParse('25.03 : 121.56'), const GeoPoint(25.03, 121.56));
    expect(GeoPoint.tryParse('-33.8688:151.2093'), const GeoPoint(-33.8688, 151.2093));
    for (final none in ['', ' ', '0:0', '0.0 : 0.0', '91:0', 'abc']) {
      expect(GeoPoint.tryParse(none), isNull, reason: none);
    }
    expect(const GeoPoint(25.033964, 121.564468).toString(), '25.03396, 121.56447');
  });

  test('exports a date range', () {
    final ledger = importCwmoneyCsv(_bytes).ledger;
    final r = exportCwmoneyCsv(ledger, from: DateTime(2026, 9, 24), to: DateTime(2026, 9, 25), includeCarrier: true);
    expect(_rows(r.bytes).map((r) => r[0]).toSet(), {'2026/09/24', '2026/09/25'});
    expect(r.rows, 4);
  });
}
