import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import 'import_action.dart';

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key, required this.app});

  final AppState app;

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  static const _pageSize = 100;

  /// Loaded pages, keyed by page index; dropped when the ledger changes.
  final _pages = <int, List<Txn>>{};
  int? _revision;
  int _count = 0;
  int _review = 0;

  void _refreshIfChanged() {
    if (_revision == widget.app.revision) return;
    _revision = widget.app.revision;
    _pages.clear();
    final ledger = widget.app.ledger;
    _count = ledger.count();
    _review = ledger
        .transactions(const TxnFilter(kinds: {TxnKind.transfer}))
        .where((t) => t.needsReview)
        .length;
  }

  Txn _at(int index) {
    final page = index ~/ _pageSize;
    final rows = _pages.putIfAbsent(
      page,
      () => widget.app.ledger.transactions(
        const TxnFilter(),
        page * _pageSize,
        _pageSize,
      ),
    );
    return rows[index % _pageSize];
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.app,
    builder: (context, _) {
      _refreshIfChanged();
      final banner = _review > 0 ? 1 : 0;
      return Scaffold(
        appBar: AppBar(
          title: Text(_count == 0 ? '紀錄' : '紀錄（$_count 筆）'),
        ),
        body: _count == 0
            ? _Empty(app: widget.app)
            : ListView.separated(
                itemCount: _count + banner,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  if (banner == 1 && i == 0) {
                    return MaterialBanner(
                      content: Text('有 $_review 筆轉帳只找到一邊，請確認'),
                      leading: const Icon(Icons.flag_outlined),
                      actions: const [SizedBox.shrink()],
                    );
                  }
                  return _TxnTile(app: widget.app, txn: _at(i - banner));
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
