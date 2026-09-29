import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import 'txn_edit_screen.dart';

/// Rent, salary, subscriptions, instalments: records the app makes by
/// itself on their day.
class RecurringScreen extends StatelessWidget {
  const RecurringScreen({super.key, required this.app});

  final AppState app;

  void _open(BuildContext context, {Recurring? recurring}) => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => TxnEditScreen(app: app, recurring: recurring, repeat: recurring == null)),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final l = app.view;
      final items = [...l.recurrings]
        // Upcoming first, soonest on top; finished ones last.
        ..sort((a, b) => switch ((a.next, b.next)) {
          (null, null) => 0,
          (null, _) => 1,
          (_, null) => -1,
          (final x?, final y?) => x.compareTo(y),
        });
      final theme = Theme.of(context);
      return Scaffold(
        appBar: AppBar(title: const Text('週期收支')),
        floatingActionButton: FloatingActionButton.extended(
          heroTag: null,
          key: const Key('addRecurring'),
          onPressed: app.activeAccounts.isEmpty ? null : () => _open(context),
          icon: const Icon(Icons.add),
          label: const Text('新增週期收支'),
        ),
        body: items.isEmpty
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
            : ListView.separated(
                padding: const EdgeInsets.only(bottom: 96),
                itemCount: items.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final r = items[i];
                  final t = r.template;
                  final currency = l.account(t.accountId!)?.currency ?? baseCurrency;
                  final color = switch (t.kind) {
                    TxnKind.expense => theme.colorScheme.error,
                    TxnKind.income => theme.colorScheme.primary,
                    TxnKind.transfer => theme.colorScheme.onSurfaceVariant,
                  };
                  return ListTile(
                    key: Key('recurring-${r.id}'),
                    leading: Icon(r.next == null ? Icons.event_available : Icons.event_repeat),
                    title: Text(recurringLabel(l, r)),
                    subtitle: Text(
                      '${describeRepeat(r)}\n${r.next == null ? '已結束' : '下次 ${formatDate(r.next!)}'}',
                    ),
                    isThreeLine: true,
                    trailing: Text(
                      formatMoney(t.amount, currency: currency),
                      style: TextStyle(color: color, fontWeight: FontWeight.w600),
                    ),
                    onTap: () => _open(context, recurring: r),
                  );
                },
              ),
      );
    },
  );
}
