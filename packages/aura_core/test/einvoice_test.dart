import 'dart:convert';
import 'dart:io';

import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

/// A made-up invoice laid out as the Ministry of Finance spec says.
String _left({String encoding = '1', String items = '茶葉蛋:2:10:鮮奶:1:45', int inCodes = 3, int total = 3}) =>
    'AB12345678' // number
    '1150929' // ROC 115/09/29
    '1234' // random code
    '00000064' // sales 100
    '00000069' // total 105
    '00000000' // buyer: consumer
    '87654321' // seller
    'abcdefghijklmnopqrstuvwx' // verification
    ':**********:$inCodes:$total:$encoding:$items';

void main() {
  test('reads the left code, with the right one adding items', () {
    final qr = parseEInvoiceQr(_left(), '**衛生紙:1:40');
    expect((qr.number, qr.date, qr.randomCode), ('AB12345678', DateTime(2026, 9, 29), '1234'));
    expect((qr.salesAmount, qr.total, qr.sellerTaxId, qr.buyerTaxId), (100, 105, '87654321', null));
    expect([for (final i in qr.items) (i.name, i.quantity, i.amount)], [
      ('茶葉蛋', Decimal.fromInt(2), Decimal.fromInt(20)),
      ('鮮奶', Decimal.one, Decimal.fromInt(45)),
      ('衛生紙', Decimal.one, Decimal.fromInt(40)),
    ]);
    expect(qr.itemsComplete, isTrue);
    expect(parseEInvoiceQr(_left()).itemsComplete, isFalse, reason: 'the third item is on the right code');
  });

  test('Base64 item names, business buyers, and codes that are not invoices', () {
    final b64 = base64.encode(utf8.encode('加油'));
    final qr = parseEInvoiceQr(_left(encoding: '2', items: '$b64:3.5:30', inCodes: 1, total: 1));
    expect(qr.items.single.name, '加油');
    expect(qr.items.single.amount, Decimal.parse('105'));
    expect(parseEInvoiceQr(_left().replaceFirst('00000000', '12345678')).buyerTaxId, '12345678');
    expect(isEInvoiceLeftCode(_left()), isTrue);
    expect(isEInvoiceRightCode('**衛生紙:1:40'), isTrue);
    expect(() => parseEInvoiceQr('https://example.com'), throwsA(isA<EInvoiceFormatException>()));
    expect(() => parseEInvoiceQr(_left().replaceFirst('1150929', '1151399')), throwsA(isA<EInvoiceFormatException>()));
  });

  test('suggests a category from the seller, then from the items', () {
    final ledger = importCwmoneyCsv(File('test/fixtures/sample_cwmoney.csv').readAsBytesSync()).ledger;
    String name(String? id) => ledger.category(id!)!.name;
    // The fixture's breakfast came from a convenience store with an invoice.
    final breakfast = ledger.transactions().firstWhere((t) => t.categoryId != null && name(t.categoryId) == '早餐');
    final taxId = breakfast.invoice!.sellerTaxId!;
    expect(name(suggestCategory(ledger, sellerTaxId: taxId)), '早餐');
    expect(name(suggestCategory(ledger, items: [breakfast.invoice!.items.first.name])), '早餐');
    expect(suggestCategory(ledger, sellerTaxId: '00000001', items: ['沒買過']), isNull);
    expect(knownSellerName(ledger, taxId), breakfast.invoice!.sellerName);
    expect(invoiceRecorded(ledger, breakfast.invoice!.number, breakfast.date), isTrue);
    expect(invoiceRecorded(ledger, 'ZZ00000000', breakfast.date), isFalse);
  });
}
