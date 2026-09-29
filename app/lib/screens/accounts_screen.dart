import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import 'account_balance_screen.dart';

const accountTypeLabels = {
  AccountType.cash: '現金',
  AccountType.bank: '銀行',
  AccountType.credit: '信用卡',
  AccountType.epay: '電子支付',
  AccountType.securities: '證券',
  AccountType.other: '其他',
};

class AccountsScreen extends StatelessWidget {
  const AccountsScreen({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final balances = app.balances.values.toList();
      final unset = balances.where((b) => !b.isSet).length;
      return Scaffold(
        appBar: AppBar(title: const Text('帳戶')),
        body: balances.isEmpty
            ? const Center(child: Text('匯入 CWMoney 的 CSV 後，帳戶會出現在這裡。'))
            : ListView(
                children: [
                  _Summary(balances: balances),
                  if (unset > 0) _UnsetNotice(count: unset),
                  for (final type in AccountType.values)
                    ..._section(context, type, balances),
                ],
              ),
      );
    },
  );

  List<Widget> _section(
    BuildContext context,
    AccountType type,
    List<AccountBalance> all,
  ) {
    final items = all.where((b) => b.account.type == type).toList();
    if (items.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          accountTypeLabels[type]!,
          style: Theme.of(context).textTheme.titleSmall,
        ),
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
  const _UnsetNotice({required this.count});
  final int count;

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
              '有 $count 個帳戶還沒設定餘額。CWMoney 的 CSV 沒有期初餘額，'
              '目前的數字只是紀錄的加總。點帳戶輸入今天的實際餘額（例如網銀顯示的金額），'
              '就會自動算出期初餘額。',
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
      leading: balance.isSet
          ? const Icon(Icons.account_balance_wallet_outlined)
          : Icon(Icons.error_outline, color: scheme.tertiary),
      title: Text(a.name),
      subtitle: Text(
        balance.isSet
            ? '期初 ${formatMoney(balance.opening, currency: a.currency)}'
            : '尚未設定餘額',
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
          builder: (_) => AccountBalanceScreen(app: app, accountId: a.id),
        ),
      ),
    );
  }
}
