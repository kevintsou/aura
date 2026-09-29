import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';

/// Picks a CWMoney export and imports it: straight in when the ledger is
/// blank, otherwise after the user chooses between merging and replacing.
Future<void> importCwmoneyFile(BuildContext context, AppState app) async {
  final file = await app.lock.whileAway(() => app.files.pick(title: '選擇 CWMoney 匯出的 CSV'));
  if (file == null || !context.mounted) return;
  final bytes = file.bytes;
  if (app.isBlank) {
    final error = await _withProgress(context, '匯入中…', app.importCwmoney(bytes, file.name));
    if (context.mounted) await _showImported(context, app, file.name, error);
    return;
  }

  final CwmImportPreview preview;
  try {
    preview = await _withProgress(context, '讀取中…', app.previewCwmoney(bytes, file.name));
  } on CwmFormatException catch (e) {
    if (context.mounted) await _showResult(context, '無法匯入', e.message);
    return;
  }
  if (!context.mounted) return;
  final choice = await showDialog<_Choice>(
    context: context,
    builder: (_) => _MergeDialog(preview: preview),
  );
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case _Merge(:final skipPossibleDuplicates):
      final error = await _withProgress(
        context,
        '合併中…',
        app.mergeCwmoney(preview, skipPossibleDuplicates: skipPossibleDuplicates),
      );
      if (context.mounted) {
        await _showMerged(context, preview, skipPossibleDuplicates, error);
      }
    case _Replace():
      if (!await _confirmReplace(context, app.ledger.count()) || !context.mounted) return;
      final error = await _withProgress(context, '匯入中…', app.replaceWithCwmoney(preview));
      if (context.mounted) await _showImported(context, app, preview.fileName, error);
  }
}

sealed class _Choice {
  const _Choice();
}

class _Merge extends _Choice {
  const _Merge(this.skipPossibleDuplicates);
  final bool skipPossibleDuplicates;
}

class _Replace extends _Choice {
  const _Replace();
}

/// What merging would add, with the choice to merge or replace instead.
class _MergeDialog extends StatefulWidget {
  const _MergeDialog({required this.preview});

  final CwmImportPreview preview;

  @override
  State<_MergeDialog> createState() => _MergeDialogState();
}

class _MergeDialogState extends State<_MergeDialog> {
  var _skipDuplicates = true;

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final plan = preview.plan;
    final theme = Theme.of(context);
    final fileCount = preview.result.ledger.count();
    final from = plan.from, latest = plan.latestExisting;
    final gap = from != null && latest != null ? from.difference(latest).inDays : 0;
    final duplicates = [
      for (final t in plan.newTxns)
        if (plan.possibleDuplicates.contains(t.id)) t,
    ];
    final lines = <String>[
      if (plan.isEmpty) '檔案裡的 $fileCount 筆紀錄都已經在帳本裡，沒有新紀錄。',
      if (plan.newTxns.isNotEmpty)
        '新紀錄 ${plan.newTxns.length} 筆（${formatDate(plan.from!)}–${formatDate(plan.to!)}）',
      if (plan.completedTransfers.isNotEmpty) '補上 ${plan.completedTransfers.length} 筆轉帳缺少的另一邊',
      if (!plan.isEmpty && plan.alreadyPresent > 0) '已經在帳本裡的 ${plan.alreadyPresent} 筆會略過',
      if (plan.newAccounts.isNotEmpty) '新增帳戶：${plan.newAccounts.map((a) => a.name).join('、')}',
      if (plan.newCategories.isNotEmpty) '新增分類 ${plan.newCategories.length} 個',
      if (plan.newProjects.isNotEmpty) '新增專案 ${plan.newProjects.length} 個',
    ];
    return AlertDialog(
      title: Text(plan.isEmpty ? '沒有新紀錄' : '合併到目前的帳本？'),
      content: SingleChildScrollView(
        child: Column(
          key: const Key('mergeSummary'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(preview.fileName, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            for (final line in lines)
              Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(line)),
            if (!plan.isEmpty && gap > 31) ...[
              const SizedBox(height: 8),
              Text(
                '帳本目前的紀錄到 ${formatDate(latest!)}，新紀錄從 ${formatDate(from!)} 開始，'
                '中間 ${gap - 1} 天沒有紀錄。如果那段期間在 CWMoney 有記帳，也要匯出那段期間再合併一次。',
                key: const Key('mergeGap'),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            if (duplicates.isNotEmpty) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                key: const Key('skipDuplicates'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _skipDuplicates,
                onChanged: (v) => setState(() => _skipDuplicates = v!),
                title: Text('略過 ${duplicates.length} 筆可能重複的紀錄'),
                subtitle: Text(
                  '日期、帳戶和金額都和你在 Aura 記的一樣：\n'
                  '${duplicates.take(3).map((t) => '${formatDate(t.date)} ${formatMoney(t.baseAmount)} ${t.note ?? ''}'.trim()).join('\n')}'
                  '${duplicates.length > 3 ? '\n…' : ''}',
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        TextButton(
          key: const Key('replaceImport'),
          onPressed: () => Navigator.pop(context, const _Replace()),
          child: const Text('全部取代…'),
        ),
        if (!plan.isEmpty)
          FilledButton(
            key: const Key('mergeImport'),
            onPressed: () => Navigator.pop(context, _Merge(_skipDuplicates)),
            child: const Text('合併'),
          ),
      ],
    );
  }
}

Future<void> _showResult(BuildContext context, String title, String body) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title),
    content: SingleChildScrollView(child: Text(body)),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('好')),
    ],
  ),
);

Future<void> _showImported(BuildContext context, AppState app, String fileName, String? error) {
  final report = app.lastImport;
  return _showResult(
    context,
    error == null ? '匯入完成' : '無法匯入',
    error ??
        '$fileName\n\n'
            '共 ${report!.rows} 列\n'
            '支出 ${report.expenses} 筆、收入 ${report.incomes} 筆\n'
            '轉帳 ${report.transferPairs + report.fuzzyTransferPairs + report.oneSidedTransfers} 筆'
            '${report.oneSidedTransfers > 0 ? '（其中 ${report.oneSidedTransfers} 筆只找到一邊，已標記待確認）' : ''}\n'
            '發票 ${report.invoices} 張'
            '${_balanceNote(app)}'
            '${_warnings(report)}',
  );
}

Future<void> _showMerged(BuildContext context, CwmImportPreview preview, bool skipped, String? error) {
  final plan = preview.plan;
  final dropped = skipped ? plan.possibleDuplicates.length : 0;
  final lines = [
    '已加入 ${plan.newTxns.length - dropped} 筆新紀錄',
    if (plan.completedTransfers.isNotEmpty) '補上 ${plan.completedTransfers.length} 筆轉帳缺少的另一邊',
    if (plan.alreadyPresent > 0) '略過已經有的 ${plan.alreadyPresent} 筆',
    if (dropped > 0) '略過可能重複的 $dropped 筆',
    if (plan.newAccounts.isNotEmpty)
      '\n新帳戶 ${plan.newAccounts.map((a) => a.name).join('、')} 還沒有餘額，請到「帳戶」輸入目前的實際餘額。',
  ];
  return _showResult(
    context,
    error == null ? '合併完成' : '無法合併',
    error ?? '${preview.fileName}\n\n${lines.join('\n')}${_warnings(preview.result.report)}',
  );
}

String _warnings(CwmImportReport report) =>
    report.warnings.isEmpty ? '' : '\n\n注意：\n${report.warnings.take(5).join('\n')}';

Future<bool> _confirmReplace(BuildContext context, int count) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('取代目前的紀錄？'),
        content: Text(
          '會刪除目前的帳戶、分類和 $count 筆紀錄，改成檔案裡的內容。'
          '取代前會自動保留一份快照，可以在「備份與還原」救回。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirmReplace'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('取代'),
          ),
        ],
      ),
    ) ??
    false;

/// Shows a blocking spinner until [work] finishes.
Future<T> _withProgress<T>(BuildContext context, String label, Future<T> work) async {
  final navigator = Navigator.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Text(label),
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

String _balanceNote(AppState app) {
  final lines = [
    if (app.anchorsKept.isNotEmpty)
      '已保留 ${app.anchorsKept.length} 個帳戶的餘額設定。',
    if (app.anchorsDropped.isNotEmpty)
      '${app.anchorsDropped.join('、')} 的餘額設定早於這個檔案的第一筆紀錄，'
          '已經清除，請重新設定。',
    if (app.recurringDropped.isNotEmpty)
      '週期收支「${app.recurringDropped.join('、')}」用到的帳戶或分類不在檔案裡，已經移除。',
    if (app.budgetsDropped.isNotEmpty)
      '檔案裡沒有「${app.budgetsDropped.join('、')}」分類，這些預算已經移除。',
    if (app.balances.values.any((b) => !b.isSet))
      'CWMoney 的 CSV 沒有期初餘額，請到「帳戶」輸入各帳戶目前的實際餘額。',
  ];
  return lines.isEmpty ? '' : '\n\n${lines.join('\n')}';
}
