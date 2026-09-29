import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';

/// Picks a CWMoney export and imports it, then shows what happened.
Future<void> importCwmoneyFile(BuildContext context, AppState app) async {
  final file = await FilePicker.pickFile();
  if (file == null) return;
  final bytes = await file.readAsBytes();
  if (!context.mounted) return;
  final error = app.importCwmoney(bytes, file.name);
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
