import 'dart:io';

import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

Decimal d(String s) => Decimal.parse(s);

void main() {
  final bytes = File('test/fixtures/sample_cwmoney.csv').readAsBytesSync();

  group('decodeBig5Hkscs', () {
    test('decodes ASCII, Big5 and HKSCS characters', () {
      // 支出 = A4E4 A558; 0x9DE8 is an HKSCS-only character.
      expect(decodeBig5Hkscs([0x41, 0xA4, 0xE4, 0xA5, 0x58]), 'A支出');
      expect(decodeBig5Hkscs([0x9D, 0xE8]), '肽');
    });

    test('replaces invalid bytes instead of failing', () {
      expect(decodeBig5Hkscs([0x80, 0x41, 0xA4]), '�A�');
    });
  });

  group('readCwmCsv', () {
    test('splits records on CRLF and keeps LF and quotes inside notes', () {
      final rows = readCwmCsv(bytes);
      expect(rows, hasLength(14));
      expect(rows.first.note, contains('13"鮮奶肽x1=55\n'));
      expect(rows.first.note.split('\n'), hasLength(5));
    });

    test('detects the legacy HTML export and rejects it clearly', () {
      final html = '<!doctype html public "-//w3c//dtd xhtml 1.0">'.codeUnits;
      expect(detectCwmFormat(html), CwmExportFormat.html);
      expect(() => readCwmCsv(html), throwsA(isA<CwmFormatException>()));
    });
  });

  group('importCwmoneyCsv', () {
    final result = importCwmoneyCsv(bytes);
    final ledger = result.ledger;
    final report = result.report;
    Account acct(String name) =>
        ledger.accounts.firstWhere((a) => a.name == name);

    test('reports what was imported', () {
      expect(report.rows, 14);
      expect(report.transferPairs, 2);
      expect(report.fuzzyTransferPairs, 1);
      expect(report.oneSidedTransfers, 1);
      expect(report.fees, 1);
      expect(report.feesLinked, 1);
      expect(report.invoices, 2);
      expect(report.warnings, isEmpty);
    });

    test('parses invoice items, seller and carrier from the note', () {
      final t = ledger.transactions(const TxnFilter(keyword: '茶葉蛋')).single;
      final inv = t.invoice!;
      expect(inv.number, 'AB12345678');
      expect(inv.sellerTaxId, '12345678');
      expect(inv.sellerName, '測試便利商店股份有限公司');
      expect(inv.sellerAddress, '臺北市測試路１號');
      expect(inv.carrier, '/TEST123');
      expect(inv.items.map((i) => i.name), ['茶葉蛋', '13"鮮奶肽', '點數折抵']);
      expect(inv.items.last.amount, d('-10'));
      expect(t.note, isNull, reason: 'generated lines are not a user note');
    });

    test('keeps fractional invoice quantities', () {
      final t = ledger.transactions(const TxnFilter(keyword: '汽油')).single;
      expect(t.invoice!.items.single.quantity, d('56.68'));
      expect(t.amount, d('1800'), reason: 'paid amount wins over items');
    });

    test('pairs transfers, including cross-currency ones', () {
      final fx = ledger
          .transactions(const TxnFilter(kinds: {TxnKind.transfer}))
          .firstWhere((t) => t.accountId == acct('美金-測試').id);
      expect(fx.toAccountId, acct('活存-測試').id);
      expect(fx.amount, d('1000'));
      expect(fx.toAmount, d('32370'));
      expect(fx.baseAmount, d('32370'));
      expect(fx.note, isNull);
      expect(fx.legacyRows, hasLength(2));
    });

    test('pairs rows created a second apart and keeps custom notes', () {
      final t = ledger
          .transactions(const TxnFilter(keyword: '轉定存'))
          .single;
      expect(t.kind, TxnKind.transfer);
      expect(t.accountId, acct('活存-測試').id);
      expect(t.toAccountId, acct('定存-測試').id);
      expect(t.needsReview, isFalse);
    });

    test('flags one-sided transfers for review', () {
      final t = ledger
          .transactions(const TxnFilter(kinds: {TxnKind.transfer}))
          .singleWhere((t) => t.needsReview);
      expect(t.accountId, acct('活存-測試').id);
      expect(t.toAccountId, isNull);
      expect(t.amount, d('5000'));
    });

    test('links a transfer fee to its transfer', () {
      final fee = ledger
          .transactions(const TxnFilter(kinds: {TxnKind.expense}))
          .singleWhere((t) => t.feeOfTxnId != null);
      final transfer = ledger
          .transactions()
          .singleWhere((t) => t.id == fee.feeOfTxnId);
      expect(transfer.toAccountId, acct('現金').id);
      expect(ledger.category(fee.categoryId!)!.name, '手續費');
      expect(fee.note, isNull);
    });

    test('keeps the source subtotal instead of amount x rate', () {
      final t = ledger.transactions(const TxnFilter(keyword: '東京')).single;
      expect(t.amount, d('10000'));
      expect(t.baseAmount, d('2010'));
      expect(t.fxRateDisplay, '0.2');
      expect(acct('日幣-測試').currency, 'JPY');
      expect(acct('美金-測試').currency, 'USD');
      expect(acct('現金').currency, 'TWD');
    });

    test('accepts negative amounts and a missing creation time', () {
      final t = ledger.transactions(const TxnFilter(keyword: '虧損')).single;
      expect(t.kind, TxnKind.income);
      expect(t.amount, d('-1874.5'));
      expect(t.createdAt, isNull);
    });

    test('builds two-level categories, projects and account types', () {
      final lunch = ledger.categories.singleWhere((c) => c.name == '午餐');
      expect(ledger.category(lunch.parentId!)!.name, '生活費');
      expect(ledger.projects.map((p) => p.name), ['測試專案']);
      expect(acct('信用卡-測試').type, AccountType.credit);
      expect(acct('股票-測試').type, AccountType.securities);
      expect(acct('現金').type, AccountType.cash);
    });

    test('stores a typed place for manual records', () {
      final t = ledger.transactions(const TxnFilter(keyword: '便當')).single;
      expect(t.place, '公司樓下');
    });
  });

  group('InMemoryLedger.transactions', () {
    final ledger = importCwmoneyCsv(bytes).ledger;

    test('filters by main category, including its subcategories', () {
      final main = ledger.categories.singleWhere(
        (c) => c.name == '生活費' && c.parentId == null,
      );
      final txns = ledger.transactions(TxnFilter(categoryIds: {main.id}));
      expect(txns, hasLength(2));
    });

    test('filters by inclusive date range and returns newest first', () {
      final txns = ledger.transactions(
        TxnFilter(from: DateTime(2026, 9, 22), to: DateTime(2026, 9, 24)),
      );
      expect(txns.first.date, DateTime(2026, 9, 24));
      expect(txns.last.date, DateTime(2026, 9, 22));
    });
  });
}
