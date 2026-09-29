import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

/// An export in the older format (2018): an Excel HTML table in Big5,
/// made up, following docs/cwmoney-format.md §3.
List<int> _html() {
  String row(List<String> cells, {String tag = 'td'}) =>
      '<tr height=19>${cells.map((c) => '<$tag class=xl24 x:str>$c</$tag>').join()}</tr>\r\n';
  const blank = ' ';
  final body = [
    row([...cwmColumns, '樞紐分析'], tag: 'td'),
    row(['2018/9/5', '支出', '生活費', '午餐', '現金', '無特別專案', '120', '1', '120', '2018/9/5 12:30', '0:0', blank, '', '0', '便當 &amp; 飲料', '120']),
    row(['2018/9/6', '收入', '', '', '定存', '無特別專案', '5000', '1', '5000', '2018/9/6 9:05', '0:0', blank, '', '1', '[帳戶轉帳]', '']),
    row(['2018/9/6', '支出', '', '', '活存', '無特別專案', '5000', '1', '5000', '2018/9/6 9:05', '0:0', blank, '', '1', '[帳戶轉帳]', '']),
    row([
      '2018/9/7', '支出', '生活費', '早餐', '信用卡', '無特別專案', '1,050', '1', '1,050', '2018/9/7 8:01', '0.0 : 0.0', //
      '(測試商店,台北市測試路1號)', 'AB00000001', '0',
      '茶葉蛋x2=20鮮奶x1=30(12345678,測試商店股份有限公司)[手機條碼,/ABC1234]', '',
    ]),
    row(['', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '合計']),
  ].join();
  final html = '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" '
      '"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">\r\n'
      '<html xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:x="urn:schemas-microsoft-com:office:excel">'
      '<head><meta http-equiv="Content-Type" content="text/html; charset=big5">'
      '<!--[if gte mso 9]><xml><x:ExcelWorkbook><x:ExcelWorksheets><x:ExcelWorksheet><x:Name>cwmoney</x:Name>'
      '</x:ExcelWorksheet></x:ExcelWorksheets></x:ExcelWorkbook></xml><![endif]--></head>\r\n'
      '<body><table border=0 cellpadding=0 cellspacing=0>\r\n$body</table></body></html>';
  return encodeBig5Hkscs(html);
}

void main() {
  test('reads the older HTML export like the CSV one', () {
    final bytes = _html();
    expect(detectCwmFormat(bytes), CwmExportFormat.html);
    final rows = readCwmCsv(bytes);
    expect(rows, hasLength(4), reason: 'header, extra column and the blank totals row dropped');
    expect(rows.first.fields, hasLength(15));

    final result = importCwmoneyCsv(bytes);
    final r = result.report;
    expect((r.rows, r.expenses, r.incomes, r.transferPairs, r.invoices), (4, 2, 0, 1, 1));
    final l = result.ledger;
    final lunch = l.transactions().firstWhere((t) => t.date == DateTime(2018, 9, 5));
    expect((lunch.note, lunch.createdAt, lunch.baseAmount), ('便當 & 飲料', DateTime(2018, 9, 5, 12, 30), Decimal.fromInt(120)));
    final breakfast = l.transactions().firstWhere((t) => t.invoice != null);
    final inv = breakfast.invoice!;
    expect(breakfast.amount, Decimal.fromInt(1050), reason: 'thousands separator removed');
    expect([for (final i in inv.items) (i.name, i.quantity, i.amount)], [
      ('茶葉蛋', Decimal.fromInt(2), Decimal.fromInt(20)),
      ('鮮奶', Decimal.one, Decimal.fromInt(30)),
    ]);
    expect((inv.sellerTaxId, inv.sellerName, inv.carrier, inv.sellerAddress), (
      '12345678',
      '測試商店股份有限公司',
      '/ABC1234',
      '台北市測試路1號',
    ));
    final transfer = l.transactions().firstWhere((t) => t.kind == TxnKind.transfer);
    expect((l.account(transfer.accountId!)!.name, l.account(transfer.toAccountId!)!.name), ('活存', '定存'));
  });
}
