import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import '../widgets/amount_list_tile.dart';
import 'category_picker.dart';
import 'dialogs.dart';
import 'txn_edit_screen.dart';

/// Rent, salary, subscriptions, instalments: records the app makes by
/// itself on their day.
class RecurringScreen extends StatelessWidget {
  const RecurringScreen({super.key, required this.app});

  final AppState app;

  void _open(BuildContext context, {Recurring? recurring}) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => TxnEditScreen(app: app, recurring: recurring, repeat: recurring == null),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final l = app.view;
      final items = [...l.recurrings]
        // Upcoming first, soonest on top; finished ones last.
        ..sort(
          (a, b) => switch ((a.next, b.next)) {
            (null, null) => 0,
            (null, _) => 1,
            (_, null) => -1,
            (final x?, final y?) => x.compareTo(y),
          },
        );
      final theme = Theme.of(context);
      final candidates = app.recurringCandidates;
      return Scaffold(
        appBar: AppBar(title: const Text('週期收支')),
        floatingActionButton: FloatingActionButton.extended(
          heroTag: null,
          key: const Key('addRecurring'),
          onPressed: app.activeAccounts.isEmpty ? null : () => _open(context),
          icon: const Icon(Icons.add),
          label: const Text('新增週期收支'),
        ),
        body: items.isEmpty && candidates.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.event_repeat, size: 48),
                      const SizedBox(height: 16),
                      const Text('還沒有週期收支', style: TextStyle(fontSize: 20)),
                      const SizedBox(height: 8),
                      Text(
                        '房租、薪水、訂閱、信用卡分期這類固定的收支，設定一次，'
                        '之後每到那天打開 App 就會自動記好。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  if (candidates.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Text('看起來是固定收支', style: theme.textTheme.titleSmall),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text('從最近兩年的紀錄找到的規律。加入後從下一次開始自動記帳，已經記過的不會重複。', style: theme.textTheme.bodySmall),
                    ),
                    for (final c in candidates) _CandidateTile(app: app, candidate: c),
                    const Divider(),
                  ],
                  for (final (i, r) in items.indexed) ...[
                    if (i > 0) const Divider(height: 1),
                    _item(context, l, r, theme),
                  ],
                ],
              ),
      );
    },
  );

  Widget _item(BuildContext context, LedgerReader l, Recurring r, ThemeData theme) {
    final t = r.template;
    final currency = l.account(t.accountId!)?.currency ?? baseCurrency;
    final color = moneyColor(context, t.amount);
    return AmountListTile(
      key: Key('recurring-${r.id}'),
      leading: Icon(r.next == null ? Icons.event_available : Icons.event_repeat),
      title: Text(recurringLabel(l, r)),
      subtitle: Text('${describeRepeat(r)}\n${r.next == null ? '已結束' : '下次 ${formatDate(r.next!)}'}'),
      isThreeLine: true,
      trailing: Text(
        formatMoney(t.amount, currency: currency),
        style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 18),
      ),
      onTap: () => _open(context, recurring: r),
    );
  }
}

class _CandidateTile extends StatelessWidget {
  const _CandidateTile({required this.app, required this.candidate});

  final AppState app;
  final RecurringCandidate candidate;

  @override
  Widget build(BuildContext context) {
    final c = candidate;
    final t = c.latest;
    final l = app.view;
    final what = [if (t.categoryId != null) categoryLabel(l, t.categoryId), ?c.label].join('・');
    final every = switch (c.unit) {
      RepeatUnit.week => '每週',
      RepeatUnit.month => '每月',
      RepeatUnit.year => '每年',
      RepeatUnit.day => '每天',
    };
    return AmountListTile(
      key: Key('candidate-${c.key}'),
      leading: const Icon(Icons.auto_awesome_outlined),
      title: Text(what.isEmpty ? '未分類' : what),
      subtitle: Text(
        '$every${c.fixedAmount ? '' : '約'} ${formatMoney(t.baseAmount)}・${l.account(t.accountId!)?.name ?? ''}・已經 ${c.times} 次\n'
        '下次約 ${formatDate(c.next)}',
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(onPressed: () => app.dismissCandidate(c), child: const Text('略過')),
          FilledButton.tonal(
            key: Key('adopt-${c.key}'),
            onPressed: () {
              final error = app.adoptCandidate(c);
              showMessage(context, error ?? '已加入，下次 ${formatDate(c.next)} 自動記帳');
            },
            child: const Text('加入'),
          ),
        ],
      ),
    );
  }
}
