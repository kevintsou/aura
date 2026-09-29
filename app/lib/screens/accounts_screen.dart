import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import 'account_fields.dart';
import 'account_screen.dart';
import 'new_account_screen.dart';

class AccountsScreen extends StatelessWidget {
  const AccountsScreen({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final balances = app.balances.values.toList();
      final unset = balances.where((b) => !b.isSet).length;
      final unknown = balances
          .where((b) => b.account.currency == unknownCurrency)
          .length;
      final archived = balances.where((b) => b.account.archived).toList();
      return Scaffold(
        appBar: AppBar(title: const Text('帳戶')),
        floatingActionButton: FloatingActionButton.extended(
          heroTag: null, // several screens have one; skip the hero animation
          key: const Key('addAccount'),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => NewAccountScreen(app: app)),
          ),
          icon: const Icon(Icons.add),
          label: const Text('新增帳戶'),
        ),
        body: balances.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    '還沒有帳戶。按「新增帳戶」建立，或到「紀錄」選擇從頭開始或匯入 CWMoney。',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView(
                children: [
                  _Summary(balances: balances),
                  if (unset > 0 || unknown > 0)
                    _UnsetNotice(unset: unset, unknownCurrency: unknown),
                  for (final type in AccountType.values)
                    ..._section(
                      context,
                      accountTypeLabels[type]!,
                      [for (final b in balances) if (!b.account.archived && b.account.type == type) b],
                    ),
                  ..._section(context, '已封存', archived),
                  const SizedBox(height: 80), // room for the button
                ],
              ),
      );
    },
  );

  List<Widget> _section(
    BuildContext context,
    String title,
    List<AccountBalance> items,
  ) {
    if (items.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      ),
      for (final b in items) _AccountTile(app: app, balance: b),
    ];
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.balances});
  final List<AccountBalance> balances;

  @override
  Widget build(BuildContext context) {
    var local = Decimal.zero;
    final foreign = <String, Decimal>{};
    for (final b in balances) {
      final c = b.account.currency;
      if (c == baseCurrency) {
        local += b.current;
      } else {
        foreign[c] = (foreign[c] ?? Decimal.zero) + b.current;
      }
    }
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('台幣帳戶合計', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(
              formatMoney(local),
              key: const Key('netWorth'),
              style: theme.textTheme.headlineMedium,
            ),
            if (foreign.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '外幣：${foreign.entries.map((e) => formatMoney(e.value, currency: e.key)).join('、')}',
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _UnsetNotice extends StatelessWidget {
  const _UnsetNotice({required this.unset, required this.unknownCurrency});
  final int unset;
  final int unknownCurrency;

  @override
  Widget build(BuildContext context) => Card.outlined(
    margin: const EdgeInsets.symmetric(horizontal: 16),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              [
                if (unset > 0)
                  '有 $unset 個帳戶還沒設定餘額，目前的數字只是紀錄的加總。'
                      '點帳戶輸入實際餘額（例如錢包裡的現金、網銀顯示的金額），'
                      '就會自動算出期初餘額。',
                if (unknownCurrency > 0)
                  '有 $unknownCurrency 個外幣帳戶無法從名稱判斷幣別，請點帳戶選擇幣別。',
              ].join('\n'),
            ),
          ),
        ],
      ),
    ),
  );
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({required this.app, required this.balance});
  final AppState app;
  final AccountBalance balance;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final a = balance.account;
    return ListTile(
      leading: balance.isSet && a.currency != unknownCurrency
          ? const Icon(Icons.account_balance_wallet_outlined)
          : Icon(Icons.error_outline, color: scheme.tertiary),
      title: Text(a.name),
      subtitle: Text(
        [
          if (a.currency == unknownCurrency) '幣別未知',
          balance.isSet
              ? '期初 ${formatMoney(balance.opening, currency: a.currency)}'
              : '尚未設定餘額',
        ].join(' · '),
      ),
      trailing: Text(
        formatMoney(balance.current, currency: a.currency),
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: balance.current < Decimal.zero ? scheme.error : null,
        ),
      ),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AccountScreen(app: app, accountId: a.id),
        ),
      ),
    );
  }
}
