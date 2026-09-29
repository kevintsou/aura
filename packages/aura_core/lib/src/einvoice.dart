import 'dart:convert';

import 'package:decimal/decimal.dart';

import 'interop/cwmoney/big5hkscs.dart';
import 'ledger.dart';
import 'model.dart';

/// What the two QR codes on a Taiwanese e-invoice (電子發票證明聯) say.
class EInvoiceQr {
  const EInvoiceQr({
    required this.number,
    required this.date,
    required this.randomCode,
    required this.salesAmount,
    required this.total,
    required this.sellerTaxId,
    this.buyerTaxId,
    this.items = const [],
    this.itemsComplete = true,
    this.itemsOnInvoice = 0,
  });

  final String number;
  final DateTime date;
  final String randomCode;

  /// Before tax.
  final int salesAmount;
  final int total;
  final String sellerTaxId;

  /// Null for a consumer (00000000).
  final String? buyerTaxId;
  final List<InvoiceItem> items;

  /// False until every item the codes carry has been read (the
  /// right-hand code may still be missing).
  final bool itemsComplete;

  /// Items on the paper invoice; can be more than the codes carry.
  final int itemsOnInvoice;

  Invoice toInvoice({String? sellerName}) =>
      Invoice(number: number, sellerTaxId: sellerTaxId, sellerName: sellerName, items: items);
}

class EInvoiceFormatException implements Exception {
  const EInvoiceFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

final _left = RegExp(r'^([A-Z]{2}\d{8})(\d{3})(\d{2})(\d{2})(\d{4})([0-9A-Fa-f]{8})([0-9A-Fa-f]{8})(\d{8})(\d{8})');

/// Whether [text] is the left-hand code (the one with the invoice data).
bool isEInvoiceLeftCode(String text) => _left.hasMatch(text);

/// Whether [text] is the right-hand code (more items, starting "**").
bool isEInvoiceRightCode(String text) => text.startsWith('**');

/// Reads the left code and, when there is one, the right code.
///
/// Left: number (10), date as ROC yyyMMdd (7), random code (4), sales
/// and total amounts in hex (8 + 8), buyer and seller tax ids (8 + 8),
/// 24 characters of verification data, then `:`-separated fields: 10
/// characters for the seller's own use, the number of items in the
/// codes, the number of items on the invoice, the text encoding (0 Big5,
/// 1 UTF-8, 2 Base64 of UTF-8), and items as name:quantity:unit price.
/// The right code starts with `**` and continues the items.
EInvoiceQr parseEInvoiceQr(String left, [String? right]) {
  final m = _left.firstMatch(left);
  if (m == null) throw const EInvoiceFormatException('這不是電子發票左邊的 QR Code');
  final year = int.parse(m[2]!) + 1911;
  final date = DateTime(year, int.parse(m[3]!), int.parse(m[4]!));
  if (date.month != int.parse(m[3]!)) throw const EInvoiceFormatException('發票日期看不懂');
  final buyer = m[8]!;
  var itemsInCodes = 0, itemsOnInvoice = 0;
  var items = <InvoiceItem>[];
  final colon = left.indexOf(':', 77 > left.length ? left.length : 77);
  if (colon >= 0) {
    final head = left.substring(colon + 1).split(':');
    if (head.length >= 4) {
      itemsInCodes = int.tryParse(head[1].trim()) ?? 0;
      itemsOnInvoice = int.tryParse(head[2].trim()) ?? 0;
      final encoding = head[3].trim();
      var rest = head.skip(4).join(':');
      if (right != null && right.startsWith('**')) rest = '$rest${rest.isEmpty ? '' : ':'}${right.substring(2)}';
      items = _items(_decode(rest, encoding));
    }
  }
  return EInvoiceQr(
    number: m[1]!,
    date: date,
    randomCode: m[5]!,
    salesAmount: int.parse(m[6]!, radix: 16),
    total: int.parse(m[7]!, radix: 16),
    buyerTaxId: buyer == '00000000' ? null : buyer,
    sellerTaxId: m[9]!,
    items: items,
    itemsComplete: items.length >= itemsInCodes,
    itemsOnInvoice: itemsOnInvoice,
  );
}

String _decode(String text, String encoding) {
  if (encoding != '2') return text; // scanners already give text
  // Base64 fields separated by ':' (names), numbers are plain.
  return [
    for (final (i, part) in text.split(':').indexed)
      if (i % 3 == 0) _base64Text(part) else part,
  ].join(':');
}

String _base64Text(String s) {
  try {
    final bytes = base64.decode(s.trim());
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return decodeBig5Hkscs(bytes);
    }
  } on FormatException {
    return s;
  }
}

List<InvoiceItem> _items(String text) {
  final parts = text.split(':');
  final items = <InvoiceItem>[];
  for (var i = 0; i + 2 < parts.length; i += 3) {
    final name = parts[i].trim();
    final qty = Decimal.tryParse(parts[i + 1].trim());
    final price = Decimal.tryParse(parts[i + 2].trim());
    if (name.isEmpty || qty == null || price == null) continue;
    items.add(InvoiceItem(name: name, quantity: qty, amount: (qty * price).round(scale: 2)));
  }
  return items;
}

/// A likely category for a purchase, learned from the ledger: what past
/// purchases from the same seller were filed under, else what records
/// with the same items were. Null when nothing matches.
String? suggestCategory(LedgerReader ledger, {String? sellerTaxId, String? sellerName, List<String> items = const []}) {
  final bySeller = <String, int>{}, byItem = <String, int>{};
  final names = {for (final n in items) n.trim()};
  for (final t in ledger.transactions(const TxnFilter(kinds: {TxnKind.expense}), 0, 3000)) {
    final c = t.categoryId, inv = t.invoice;
    if (c == null || inv == null) continue;
    final sameSeller = (sellerTaxId != null && inv.sellerTaxId == sellerTaxId) ||
        (sellerName != null && sellerName.isNotEmpty && inv.sellerName == sellerName);
    if (sameSeller) bySeller[c] = (bySeller[c] ?? 0) + 1;
    if (names.isNotEmpty && inv.items.any((i) => names.contains(i.name.trim()))) byItem[c] = (byItem[c] ?? 0) + 1;
  }
  String? top(Map<String, int> m) => m.isEmpty ? null : (m.entries.toList()..sort((a, b) => b.value - a.value)).first.key;
  return top(bySeller) ?? top(byItem);
}

/// The seller's name as recorded on an earlier invoice from [taxId].
String? knownSellerName(LedgerReader ledger, String taxId) {
  for (final t in ledger.transactions(const TxnFilter(kinds: {TxnKind.expense}), 0, 3000)) {
    final inv = t.invoice;
    if (inv != null && inv.sellerTaxId == taxId && inv.sellerName != null) return inv.sellerName;
  }
  return null;
}

/// Whether the invoice [number] of [date] is already recorded (looked
/// for within two months of its date).
bool invoiceRecorded(LedgerReader ledger, String number, DateTime date) => ledger
    .transactions(
      TxnFilter(
        from: DateTime(date.year, date.month - 2, date.day),
        to: DateTime(date.year, date.month + 2, date.day),
        kinds: const {TxnKind.expense},
      ),
    )
    .any((t) => t.invoice?.number == number);
