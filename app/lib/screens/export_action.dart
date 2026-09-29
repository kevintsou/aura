import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';

enum _Range { all, thisYear, custom }

/// Asks what to export, writes a CWMoney CSV and lets the user save it.
Future<void> exportCwmoneyFile(BuildContext context, AppState app) async {
  final choice = await showDialog<_Choice>(
    context: context,
    builder: (_) => _ExportDialog(app: app),
  );
  if (choice == null || !context.mounted) return;
  final navigator = Navigator.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: AlertDialog(content: Row(children: [CircularProgressIndicator(), SizedBox(width: 20), Text('匯出中…')])),
    ),
  );
  final (String, CwmExportResult)? saved;
  try {
    saved = await app.exportCwmoney(from: choice.from, to: choice.to, includeCarrier: choice.includeCarrier);
  } finally {
    navigator.pop();
  }
  if (saved == null || !context.mounted) return;
  final (name, result) = saved;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('匯出完成'),
      content: Text(
        [
          name,
          '',
          '${result.records} 筆紀錄，${result.rows} 列（轉帳在 CWMoney 是兩列）',
          if (result.replacedCharacters > 0) '有 ${result.replacedCharacters} 個字（例如表情符號）CWMoney 的 Big5 編碼存不下，已經換成「?」。',
          if (!choice.includeCarrier) '手機條碼載具號碼已經隱藏。',
        ].join('\n'),
        key: const Key('exportSummary'),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('好'))],
    ),
  );
}

class _Choice {
  const _Choice(this.from, this.to, this.includeCarrier);
  final DateTime? from;
  final DateTime? to;
  final bool includeCarrier;
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.app});
  final AppState app;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  var _range = _Range.all;
  DateTimeRange? _custom;
  var _carrier = false;

  Future<void> _pickRange() async {
    final now = widget.app.clock();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1990),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: _custom ?? DateTimeRange(start: DateTime(now.year, now.month), end: now),
    );
    if (picked != null) {
      setState(() {
        _custom = picked;
        _range = _Range.custom;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.app.clock();
    final (from, to) = switch (_range) {
      _Range.all => (null, null),
      _Range.thisYear => (DateTime(now.year), DateTime(now.year, 12, 31)),
      _Range.custom => (_custom?.start, _custom?.end),
    };
    return AlertDialog(
      title: const Text('匯出 CWMoney CSV'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('和 CWMoney 經典版匯出的格式一樣，可以用 Excel 開啟，或匯入其他支援的 App。'),
            const SizedBox(height: 8),
            RadioGroup<_Range>(
              groupValue: _range,
              onChanged: (r) => r == _Range.custom ? _pickRange() : setState(() => _range = r!),
              child: Column(
                children: [
                  const RadioListTile(
                    key: Key('exportAll'),
                    contentPadding: EdgeInsets.zero,
                    title: Text('全部紀錄'),
                    value: _Range.all,
                  ),
                  RadioListTile(
                    key: const Key('exportThisYear'),
                    contentPadding: EdgeInsets.zero,
                    title: Text('${now.year} 年'),
                    value: _Range.thisYear,
                  ),
                  RadioListTile(
                    key: const Key('exportCustom'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自訂期間'),
                    subtitle: _custom == null
                        ? null
                        : Text('${formatDate(_custom!.start)}–${formatDate(_custom!.end)}'),
                    value: _Range.custom,
                  ),
                ],
              ),
            ),
            CheckboxListTile(
              key: const Key('exportCarrier'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _carrier,
              onChanged: (v) => setState(() => _carrier = v!),
              title: const Text('包含手機條碼載具號碼'),
              subtitle: const Text('預設隱藏，檔案要分享給別人比較安全'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          key: const Key('confirmExport'),
          onPressed: _range == _Range.custom && _custom == null
              ? null
              : () => Navigator.pop(context, _Choice(from, to, _carrier)),
          child: const Text('匯出'),
        ),
      ],
    );
  }
}
