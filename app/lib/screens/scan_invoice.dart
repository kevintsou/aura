import 'dart:async';
import 'dart:convert';

import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app_state.dart';
import 'category_picker.dart';
import 'dialogs.dart';
import 'txn_edit_screen.dart';

/// Scans a paper e-invoice's QR codes, then opens a new record with its
/// date, total, seller and items filled in.
Future<void> scanInvoice(BuildContext context, AppState app) async {
  final codes = await Navigator.push<(String, String?)>(
    context,
    MaterialPageRoute(builder: (_) => const ScanInvoiceScreen()),
  );
  if (codes == null || !context.mounted) return;
  await openScannedInvoice(context, app, codes.$1, codes.$2);
}

/// Turns the codes into a draft record and opens it for checking.
Future<void> openScannedInvoice(BuildContext context, AppState app, String left, String? right) async {
  final EInvoiceQr qr;
  try {
    qr = parseEInvoiceQr(left, right);
  } on EInvoiceFormatException catch (e) {
    showMessage(context, e.message);
    return;
  }
  final l = app.view;
  if (invoiceRecorded(l, qr.number, qr.date) &&
      !await confirm(
        context,
        title: '這張發票已經記過了',
        message: '${qr.number} 已經在帳本裡。還要再記一次嗎？',
        action: '再記一次',
      )) {
    return;
  }
  if (!context.mounted) return;
  final sellerName = knownSellerName(l, qr.sellerTaxId);
  final accounts = app.activeAccounts;
  final accountId = accounts.any((a) => a.id == app.lastAccountId) ? app.lastAccountId : accounts.firstOrNull?.id;
  if (accountId == null) {
    showMessage(context, '請先新增一個帳戶');
    return;
  }
  final guessed = suggestCategory(
    l,
    sellerTaxId: qr.sellerTaxId,
    sellerName: sellerName,
    items: [for (final i in qr.items) i.name],
  );
  final categoryId = guessed ?? defaultCategoryId(l, TxnKind.expense, app.lastCategoryId(TxnKind.expense));
  final total = Decimal.fromInt(qr.total);
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => TxnEditScreen(
        app: app,
        categoryGuessed: guessed != null,
        draft: Txn(
          id: newId('t'),
          kind: TxnKind.expense,
          date: qr.date,
          accountId: accountId,
          categoryId: categoryId,
          amount: total,
          baseAmount: total,
          invoice: qr.toInvoice(sellerName: sellerName),
          createdAt: app.clock(),
        ),
      ),
    ),
  );
}

/// The camera, looking for the left code (and the right one, which
/// carries more items). Pops (left, right).
class ScanInvoiceScreen extends StatefulWidget {
  const ScanInvoiceScreen({super.key});

  @override
  State<ScanInvoiceScreen> createState() => _ScanInvoiceScreenState();
}

class _ScanInvoiceScreenState extends State<ScanInvoiceScreen> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  String? _left, _right;
  Timer? _grace;
  var _done = false;

  @override
  void dispose() {
    _grace?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// The code's text. E-invoices may be Big5, which scanners tend to
  /// misread, so the raw bytes are decoded here when they are available.
  static String _text(Barcode b) {
    final bytes = switch (b.rawDecodedBytes) {
      DecodedBarcodeBytes(:final bytes) => bytes,
      DecodedVisionBarcodeBytes(:final bytes) => bytes,
      null => null,
    };
    if (bytes == null) return b.rawValue ?? '';
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return decodeBig5Hkscs(bytes);
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final text = _text(b);
      if (isEInvoiceLeftCode(text)) _left ??= text;
      if (isEInvoiceRightCode(text)) _right ??= text;
    }
    final left = _left;
    if (left == null) return;
    setState(() {});
    final complete = (() {
      try {
        return parseEInvoiceQr(left, _right).itemsComplete;
      } on EInvoiceFormatException {
        return true;
      }
    })();
    if (complete) return _finish();
    // Give the right-hand code a moment to come into view.
    _grace ??= Timer(const Duration(seconds: 2), _finish);
  }

  void _finish() {
    if (_done || !mounted || _left == null) return;
    _done = true;
    Navigator.pop(context, (_left!, _right));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget status(String label, bool ok) => Chip(
      avatar: Icon(ok ? Icons.check_circle : Icons.radio_button_unchecked, size: 18),
      label: Text(label),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('掃描發票')),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('無法使用相機：${error.errorCode.name}', textAlign: TextAlign.center),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              color: theme.colorScheme.surface.withValues(alpha: 0.9),
              padding: const EdgeInsets.all(16),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('把發票上的兩個 QR Code 放進畫面'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [status('左邊（發票資料）', _left != null), status('右邊（品項）', _right != null)],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
