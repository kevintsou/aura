import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';

/// Picks a CWMoney export and imports it, then shows what happened.
Future<void> importCwmoneyFile(BuildContext context, AppState app) async {
  final existing = app.ledger.count();
  if (existing > 0 && !await _confirmReplace(context, existing)) return;
  final file = await FilePicker.pickFile();
  if (file == null) return;
  final bytes = await file.readAsBytes();
  if (!context.mounted) return;
  final error = await _withProgress(context, app.importCwmoney(bytes, file.name));
  if (!context.mounted) return;
  final report = app.lastImport;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(error == null ? '匯入完成' : '無法匯入'),
      content: Text(
        error ??
            '${file.name}\n\n'
                '共 ${report!.rows} 列\n'
                '支出 ${report.expenses} 筆、收入 ${report.incomes} 筆\n'
                '轉帳 ${report.transferPairs + report.fuzzyTransferPairs + report.oneSidedTransfers} 筆'
                '${report.oneSidedTransfers > 0 ? '（其中 ${report.oneSidedTransfers} 筆只找到一邊，已標記待確認）' : ''}\n'
                '發票 ${report.invoices} 張'
                '${report.warnings.isEmpty ? '' : '\n\n注意：\n${report.warnings.take(5).join('\n')}'}',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('好')),
      ],
    ),
  );
}

Future<bool> _confirmReplace(BuildContext context, int count) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('取代目前的紀錄？'),
        content: Text('匯入會刪除目前的 $count 筆紀錄，改成檔案裡的內容。這個動作無法復原。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('取代'),
          ),
        ],
      ),
    ) ??
    false;

/// Shows a blocking spinner until [work] finishes.
Future<T> _withProgress<T>(BuildContext context, Future<T> work) async {
  final navigator = Navigator.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Text('匯入中…'),
          ],
        ),
      ),
    ),
  );
  try {
    return await work;
  } finally {
    navigator.pop();
  }
}
