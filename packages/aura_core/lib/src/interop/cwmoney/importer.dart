import 'package:decimal/decimal.dart';

import '../../ledger.dart';
import '../../model.dart';
import 'csv_reader.dart';

/// Summary shown to the user after an import.
class CwmImportReport {
  int rows = 0;
  int expenses = 0;
  int incomes = 0;

  /// Transfers whose two rows share date and creation time.
  int transferPairs = 0;

  /// Transfers whose rows were created up to [fuzzyWindow] apart.
  int fuzzyTransferPairs = 0;

  /// Transfer rows with no counterpart; imported with `needsReview`.
  int oneSidedTransfers = 0;
  int fees = 0;
  int feesLinked = 0;
  int invoices = 0;
  final List<String> warnings = [];
}

class CwmImportResult {
  CwmImportResult(this.ledger, this.report);
  final InMemoryLedger ledger;
  final CwmImportReport report;
}

const fuzzyWindow = Duration(seconds: 2);
const _noProject = '無特別專案';
const _transferNote = '[帳戶轉帳]';
const _feeNote = '[手續費][帳戶轉帳]';

/// Imports a CWMoney classic CSV export. See docs/cwmoney-format.md.
CwmImportResult importCwmoneyCsv(List<int> bytes) =>
    _Importer().run(readCwmCsv(bytes));

class _Importer {
  final report = CwmImportReport();
  final accounts = <String, Account>{};
  final categories = <String, Category>{};
  final projects = <String, Project>{};
  final txns = <Txn>[];
  final foreignAccounts = <String>{};
  var _seq = 0;

  String _id(String prefix) => '$prefix${++_seq}';

  CwmImportResult run(List<CwmRow> rows) {
    report.rows = rows.length;
    for (final r in rows) {
      if (r.rate != '1') foreignAccounts.add(r.account);
    }
    final transferRows = <_Parsed>[];
    final feeRows = <_Parsed>[];
    for (final row in rows) {
      final p = _parse(row);
      if (p == null) continue;
      switch (row.transferFlag) {
        case '1':
          transferRows.add(p);
        case '2':
          feeRows.add(p);
        case '0':
          txns.add(_incomeOrExpense(p));
        default:
          report.warnings.add('第 ${row.lineNumber} 筆：未知的轉帳旗標 '
              '"${row.transferFlag}"，當成一般收支匯入');
          txns.add(_incomeOrExpense(p));
      }
    }
    final transfers = _pairTransfers(transferRows);
    txns.addAll(transfers);
    for (final fee in feeRows) {
      txns.add(_fee(fee, transfers));
    }
    final ledger = InMemoryLedger(
      accounts: accounts.values.toList(),
      categories: categories.values.toList(),
      projects: projects.values.toList(),
      transactions: txns,
    );
    return CwmImportResult(ledger, report);
  }

  _Parsed? _parse(CwmRow row) {
    final date = _parseDate(row.date);
    final amount = Decimal.tryParse(row.amount);
    final subtotal = Decimal.tryParse(row.subtotal);
    final isIncome = row.type == '收入';
    if (date == null ||
        amount == null ||
        subtotal == null ||
        (!isIncome && row.type != '支出')) {
      report.warnings.add('第 ${row.lineNumber} 筆：日期、類別或金額無法解析，已略過');
      return null;
    }
    return _Parsed(
      row: row,
      date: date,
      createdAt: _parseDateTime(row.createdAt),
      isIncome: isIncome,
      amount: amount,
      subtotal: subtotal,
      accountId: _account(row.account).id,
    );
  }

  Txn _incomeOrExpense(_Parsed p) {
    final row = p.row;
    final kind = p.isIncome ? TxnKind.income : TxnKind.expense;
    p.isIncome ? report.incomes++ : report.expenses++;
    final invoice = row.invoiceNumber.isEmpty ? null : _invoice(row);
    if (invoice != null) report.invoices++;
    return Txn(
      id: _id('t'),
      kind: kind,
      date: p.date,
      accountId: p.accountId,
      amount: p.amount,
      baseAmount: p.subtotal,
      fxRateDisplay: row.rate == '1' ? null : row.rate,
      categoryId: _category(kind, row.mainCategory, row.subCategory)?.id,
      projectId: _project(row.project)?.id,
      note: invoice == null ? _clean(row.note) : _invoiceUserNote(row.note),
      place: invoice == null ? _clean(row.address) : null,
      invoice: invoice,
      createdAt: p.createdAt,
      legacyRows: [row.fields],
    );
  }

  List<Txn> _pairTransfers(List<_Parsed> rows) {
    final groups = <String, List<_Parsed>>{};
    for (final p in rows) {
      groups.putIfAbsent('${p.row.date}|${p.row.createdAt}', () => []).add(p);
    }
    final result = <Txn>[];
    final singles = <_Parsed>[];
    for (final group in groups.values) {
      final ins = group.where((p) => p.isIncome).toList();
      final outs = group.where((p) => !p.isIncome).toList();
      final n = ins.length < outs.length ? ins.length : outs.length;
      for (var i = 0; i < n; i++) {
        result.add(_transfer(outs[i], ins[i]));
        report.transferPairs++;
      }
      singles
        ..addAll(ins.skip(n))
        ..addAll(outs.skip(n));
    }
    final used = <_Parsed>{};
    for (final s in singles) {
      if (used.contains(s) || s.createdAt == null) continue;
      _Parsed? best;
      for (final o in singles) {
        if (identical(o, s) ||
            used.contains(o) ||
            o.isIncome == s.isIncome ||
            o.date != s.date ||
            o.createdAt == null ||
            o.createdAt!.difference(s.createdAt!).abs() > fuzzyWindow) {
          continue;
        }
        if (best == null || o.subtotal == s.subtotal) best = o;
        if (o.subtotal == s.subtotal) break;
      }
      if (best != null) {
        used.addAll([s, best]);
        final (out, inn) = s.isIncome ? (best, s) : (s, best);
        result.add(_transfer(out, inn));
        report.fuzzyTransferPairs++;
      }
    }
    for (final s in singles.where((s) => !used.contains(s))) {
      result.add(_transfer(s.isIncome ? null : s, s.isIncome ? s : null));
      report.oneSidedTransfers++;
    }
    return result;
  }

  Txn _transfer(_Parsed? out, _Parsed? inn) {
    final main = (out ?? inn)!;
    final note = _clean(main.row.note);
    return Txn(
      id: _id('t'),
      kind: TxnKind.transfer,
      date: main.date,
      accountId: out?.accountId,
      toAccountId: inn?.accountId,
      amount: main.amount,
      toAmount: out != null && inn != null && inn.amount != out.amount
          ? inn.amount
          : null,
      baseAmount: main.subtotal,
      fxRateDisplay: main.row.rate == '1' ? null : main.row.rate,
      note: note == _transferNote ? null : note,
      createdAt: main.createdAt,
      needsReview: out == null || inn == null,
      legacyRows: [
        if (inn != null) inn.row.fields,
        if (out != null) out.row.fields,
      ],
    );
  }

  Txn _fee(_Parsed p, List<Txn> transfers) {
    report.fees++;
    final match = p.createdAt == null
        ? null
        : transfers
              .where((t) => t.date == p.date && t.createdAt == p.createdAt)
              .firstOrNull;
    if (match != null) report.feesLinked++;
    final note = _clean(p.row.note);
    report.expenses++;
    return Txn(
      id: _id('t'),
      kind: TxnKind.expense,
      date: p.date,
      accountId: p.accountId,
      amount: p.amount,
      baseAmount: p.subtotal,
      categoryId: _category(
        TxnKind.expense,
        p.row.mainCategory,
        p.row.subCategory,
      )?.id,
      projectId: _project(p.row.project)?.id,
      note: note == _feeNote ? null : note,
      createdAt: p.createdAt,
      feeOfTxnId: match?.id,
      legacyRows: [p.row.fields],
    );
  }

  Account _account(String name) => accounts.putIfAbsent(
    name,
    () => Account(
      id: _id('a'),
      name: name,
      type: guessAccountType(name),
      currency: guessCurrency(name, foreign: foreignAccounts.contains(name)),
    ),
  );

  Category? _category(TxnKind kind, String main, String sub) {
    if (main.isEmpty) return null;
    final parent = categories.putIfAbsent(
      '${kind.name}|$main',
      () => Category(id: _id('c'), kind: kind, name: main),
    );
    if (sub.isEmpty) return parent;
    return categories.putIfAbsent(
      '${kind.name}|$main|$sub',
      () => Category(id: _id('c'), kind: kind, name: sub, parentId: parent.id),
    );
  }

  Project? _project(String name) => name.isEmpty || name == _noProject
      ? null
      : projects.putIfAbsent(name, () => Project(id: _id('p'), name: name));
}

class _Parsed {
  _Parsed({
    required this.row,
    required this.date,
    required this.createdAt,
    required this.isIncome,
    required this.amount,
    required this.subtotal,
    required this.accountId,
  });

  final CwmRow row;
  final DateTime date;
  final DateTime? createdAt;
  final bool isIncome;
  final Decimal amount;
  final Decimal subtotal;
  final String accountId;
}

final _dateRe = RegExp(r'^(\d{4})/(\d{1,2})/(\d{1,2})$');
final _dateTimeRe = RegExp(
  r'^(\d{4})/(\d{1,2})/(\d{1,2}) (\d{1,2}):(\d{2})(?::(\d{2}))?$',
);

DateTime? _parseDate(String s) {
  final m = _dateRe.firstMatch(s.trim());
  if (m == null) return null;
  return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

DateTime? _parseDateTime(String s) {
  final m = _dateTimeRe.firstMatch(s.trim());
  if (m == null) return null;
  return DateTime(
    int.parse(m[1]!),
    int.parse(m[2]!),
    int.parse(m[3]!),
    int.parse(m[4]!),
    int.parse(m[5]!),
    int.parse(m[6] ?? '0'),
  );
}

String? _clean(String s) {
  final t = s.trim();
  return t.isEmpty ? null : t;
}

final _itemRe = RegExp(r'^(.*)x(-?\d+(?:\.\d+)?)=(-?\d+(?:\.\d+)?)$');
final _sellerRe = RegExp(r'^\((\d{8}),(.*)\)$');
final _carrierRe = RegExp(r'^\[([^,\]]+),(.*)\]$');
final _addressRe = RegExp(r'^\((.*)\)$');

Invoice _invoice(CwmRow row) {
  String? taxId, sellerName, carrier;
  final items = <InvoiceItem>[];
  for (final line in row.note.split('\n')) {
    final item = _itemRe.firstMatch(line);
    final seller = _sellerRe.firstMatch(line);
    final carrierMatch = _carrierRe.firstMatch(line);
    if (item != null) {
      items.add(
        InvoiceItem(
          name: item[1]!.trim(),
          quantity: Decimal.parse(item[2]!),
          amount: Decimal.parse(item[3]!),
        ),
      );
    } else if (seller != null) {
      taxId = seller[1];
      sellerName = seller[2];
    } else if (carrierMatch != null) {
      carrier = carrierMatch[2];
    }
  }
  String? address;
  final addr = _addressRe.firstMatch(row.address.trim());
  if (addr != null) {
    final comma = addr[1]!.indexOf(',');
    sellerName ??= comma < 0 ? addr[1] : addr[1]!.substring(0, comma);
    address = comma < 0 ? null : addr[1]!.substring(comma + 1);
  }
  return Invoice(
    number: row.invoiceNumber,
    sellerTaxId: taxId,
    sellerName: sellerName,
    sellerAddress: address,
    carrier: carrier,
    items: items,
  );
}

/// The part of an invoice note the user typed (not generated lines).
String? _invoiceUserNote(String note) => _clean(
  note
      .split('\n')
      .where(
        (l) =>
            !_itemRe.hasMatch(l) &&
            !_sellerRe.hasMatch(l) &&
            !_carrierRe.hasMatch(l),
      )
      .join('\n'),
);

AccountType guessAccountType(String name) {
  bool has(List<String> words) => words.any(name.contains);
  if (has(['信用卡'])) return AccountType.credit;
  if (has(['現金', '錢包'])) return AccountType.cash;
  if (has(['股票', '證券', '基金'])) return AccountType.securities;
  if (has(['Pay', 'pay', '一卡通', '悠遊', '街口', '電子支付'])) {
    return AccountType.epay;
  }
  if (has(['活存', '定存', '銀行', '郵局', '存款', '帳戶'])) return AccountType.bank;
  return AccountType.other;
}

String guessCurrency(String name, {required bool foreign}) {
  bool has(List<String> words) => words.any(name.contains);
  if (has(['美金', '美元', 'USD'])) return 'USD';
  if (has(['日幣', '日圓', '日元', 'JPY'])) return 'JPY';
  if (has(['歐元', 'EUR'])) return 'EUR';
  if (has(['人民幣', 'CNY', 'RMB'])) return 'CNY';
  if (has(['港幣', 'HKD'])) return 'HKD';
  return foreign ? 'XXX' : baseCurrency;
}
