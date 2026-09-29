import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import 'budgets_screen.dart';
import 'category_picker.dart';
import 'import_action.dart';
import 'txn_edit_screen.dart';

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
    final ledger = widget.app.view;
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
      () => widget.app.view.transactions(
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
      final headers = [
        ?budgetSummary(context, widget.app),
        if (_review > 0)
          MaterialBanner(
            content: Text('有 $_review 筆轉帳只找到一邊，請確認'),
            leading: const Icon(Icons.flag_outlined),
            actions: const [SizedBox.shrink()],
          ),
      ];
      final canRecord = widget.app.activeAccounts.isNotEmpty;
      return Scaffold(
        appBar: AppBar(
          title: Text(_count == 0 ? '紀錄' : '紀錄（$_count 筆）'),
        ),
        floatingActionButton: canRecord
            ? FloatingActionButton.extended(
                heroTag: null, // several screens have one; skip the hero animation
                key: const Key('addTxn'),
                onPressed: () => openTxnEditor(context, widget.app),
                icon: const Icon(Icons.add),
                label: const Text('記一筆'),
              )
            : null,
        body: _count == 0
            ? _Empty(app: widget.app)
            : ListView.separated(
                itemCount: _count + headers.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) =>
                    i < headers.length ? headers[i] : _TxnTile(app: widget.app, txn: _at(i - headers.length)),
              ),
      );
    },
  );
}

Future<void> openTxnEditor(BuildContext context, AppState app, [Txn? txn]) =>
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TxnEditScreen(app: app, txn: txn)),
    );

class _Empty extends StatelessWidget {
  const _Empty({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final blank = app.isBlank;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.receipt_long_outlined, size: 48),
            const SizedBox(height: 16),
            Text(blank ? '開始記帳' : '還沒有紀錄', style: const TextStyle(fontSize: 20)),
            const SizedBox(height: 8),
            Text(
              blank
                  ? '從頭開始會建立常用的分類和一個「現金」帳戶，之後都可以修改。'
                        '用過 CWMoney 的話，也可以匯入它的 CSV 把歷史紀錄搬過來。'
                  : '按「記一筆」新增第一筆紀錄。',
              textAlign: TextAlign.center,
            ),
            if (blank) ...[
              const SizedBox(height: 24),
              FilledButton.icon(
                key: const Key('startFresh'),
                onPressed: app.startFresh,
                icon: const Icon(Icons.edit_note),
                label: const Text('從頭開始記帳'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => importCwmoneyFile(context, app),
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('匯入 CWMoney CSV'),
              ),
            ],
          ],
        ),
      ),
    );
  }
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
    return categoryLabel(l, txn.categoryId);
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
      onTap: () => openTxnEditor(context, app, txn),
      leading: txn.needsReview
          ? const Icon(Icons.flag_outlined)
          : txn.recurringId != null
          ? Icon(Icons.event_repeat, semanticLabel: '週期收支', color: scheme.onSurfaceVariant)
          : null,
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
