import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import 'import_action.dart';

class TransactionsScreen extends StatelessWidget {
  const TransactionsScreen({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final txns = app.ledger.transactions();
      final review = txns.where((t) => t.needsReview).length;
      return Scaffold(
        appBar: AppBar(title: const Text('紀錄')),
        body: txns.isEmpty
            ? _Empty(app: app)
            : ListView.separated(
                itemCount: txns.length + (review > 0 ? 1 : 0),
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  if (review > 0 && i == 0) {
                    return MaterialBanner(
                      content: Text('有 $review 筆轉帳只找到一邊，請確認'),
                      leading: const Icon(Icons.flag_outlined),
                      actions: const [SizedBox.shrink()],
                    );
                  }
                  return _TxnTile(app: app, txn: txns[i - (review > 0 ? 1 : 0)]);
                },
              ),
      );
    },
  );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.receipt_long_outlined, size: 48),
          const SizedBox(height: 16),
          const Text('還沒有紀錄', style: TextStyle(fontSize: 20)),
          const SizedBox(height: 8),
          const Text('從 CWMoney 經典版匯出 CSV，就能把歷史紀錄搬過來。', textAlign: TextAlign.center),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => importCwmoneyFile(context, app),
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('匯入 CWMoney CSV'),
          ),
        ],
      ),
    ),
  );
}

class _TxnTile extends StatelessWidget {
  const _TxnTile({required this.app, required this.txn});
  final AppState app;
  final Txn txn;

  String _title() {
    final l = app.ledger;
    if (txn.kind == TxnKind.transfer) {
      final from = txn.accountId == null ? '？' : l.account(txn.accountId!)?.name;
      final to = txn.toAccountId == null ? '？' : l.account(txn.toAccountId!)?.name;
      return '轉帳 $from → $to';
    }
    final leaf = txn.categoryId == null ? null : l.category(txn.categoryId!);
    final parent = leaf?.parentId == null ? null : l.category(leaf!.parentId!);
    return [parent?.name, leaf?.name].whereType<String>().join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final account = txn.accountId == null ? null : app.ledger.account(txn.accountId!);
    final detail = [
      formatDate(txn.date),
      if (txn.kind != TxnKind.transfer && account != null) account.name,
      if (txn.invoice?.sellerName != null) txn.invoice!.sellerName!,
      if (txn.note != null) txn.note!,
    ].join('　');
    final color = switch (txn.kind) {
      TxnKind.expense => scheme.error,
      TxnKind.income => scheme.primary,
      TxnKind.transfer => scheme.onSurfaceVariant,
    };
    return ListTile(
      leading: txn.needsReview ? const Icon(Icons.flag_outlined) : null,
      title: Text(_title()),
      subtitle: Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(
        formatMoney(
          txn.kind == TxnKind.transfer ? txn.amount : txn.baseAmount,
          currency: txn.kind == TxnKind.transfer ? account?.currency ?? baseCurrency : baseCurrency,
        ),
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
