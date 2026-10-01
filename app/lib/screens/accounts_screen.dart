import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import '../lock/lock_settings_screen.dart';
import '../widgets/charts.dart';
import 'account_fields.dart';
import 'dialogs.dart';
import 'account_screen.dart';
import 'new_account_screen.dart';

class AccountsScreen extends StatelessWidget {
  const AccountsScreen({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final hiddenIds = app.hiddenAccountIds;
      final all = app.balances.values.toList();
      final balances = [for (final b in all) if (!hiddenIds.contains(b.account.id)) b];
      final hasHidden = all.any((b) => b.account.hidden);
      final unset = balances.where((b) => !b.isSet).length;
      final unknown = balances
          .where((b) => b.account.currency == unknownCurrency)
          .length;
      final archived = balances.where((b) => b.account.archived && !b.account.hidden).toList();
      final hidden = balances.where((b) => b.account.hidden).toList();
      return Scaffold(
        appBar: AppBar(
          title: const Text('帳戶'),
          actions: [
            if (hasHidden)
              TextButton.icon(
                key: const Key('toggleHidden'),
                onPressed: () => _toggleHidden(context),
                icon: Icon(app.revealHidden ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                label: Text(app.revealHidden ? '隱藏' : '顯示隱藏的帳戶'),
              ),
          ],
        ),
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
                    '還沒有帳戶。按「新增帳戶」建立，或到「紀錄」選擇從頭開始或匯入 CSV。',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView(
                children: [
                  _Summary(app: app, balances: balances),
                  if (unset > 0 || unknown > 0)
                    _UnsetNotice(unset: unset, unknownCurrency: unknown),
                  for (final type in AccountType.values)
                    ..._section(
                      context,
                      accountTypeLabels[type]!,
                      [
                        for (final b in balances)
                          if (!b.account.archived && !b.account.hidden && b.account.type == type) b,
                      ],
                    ),
                  ..._section(context, '已封存', archived),
                  ..._section(context, '隱藏的帳戶', hidden),
                  const SizedBox(height: 80), // room for the button
                ],
              ),
      );
    },
  );

  /// Revealing needs the PIN when the app lock is on.
  Future<void> _toggleHidden(BuildContext context) async {
    if (app.revealHidden) return app.setRevealHidden(false);
    if (app.lock.enabled) {
      final ok = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => PinCheckScreen(lock: app.lock, title: '顯示隱藏的帳戶', check: app.lock.check),
        ),
      );
      if (ok != true) return;
    }
    app.setRevealHidden(true);
  }

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
  const _Summary({required this.app, required this.balances});
  final AppState app;
  final List<AccountBalance> balances;

  Future<void> _editRate(BuildContext context, String currency, FxRate? current) async {
    final text = await askText(
      context,
      title: '$currency 匯率',
      label: '1 $currency = 多少新台幣',
      initial: current?.manual ?? false ? current!.rate.toString() : '',
      message: '只用來換算淨資產。留空就用最近一筆紀錄的匯率。',
    );
    if (!context.mounted) return;
    final rate = Decimal.tryParse(text ?? '');
    app.setManualRate(currency, rate != null && rate > Decimal.zero ? rate : null);
  }

  @override
  Widget build(BuildContext context) {
    final rates = app.rates;
    final s = summarizeAssets(balances, rates);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final positive = [
      for (final e in s.byType.entries)
        if (e.value > Decimal.zero) e,
    ]..sort((a, b) => b.value.compareTo(a.value));
    final negative = [
      for (final e in s.byType.entries)
        if (e.value < Decimal.zero) e,
    ];
    final currencies = {
      for (final b in balances)
        if (b.account.currency != baseCurrency && b.account.currency != unknownCurrency) b.account.currency,
    };
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('淨資產', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(formatMoney(s.net.round(scale: 0)), key: const Key('netWorth'), style: theme.textTheme.headlineMedium),
            const SizedBox(height: 4),
            Text(
              '資產 ${formatMoney(s.assets.round(scale: 0))}・負債 ${formatMoney(s.liabilities.round(scale: 0))}',
              key: const Key('assetsLiabilities'),
              style: muted,
            ),
            if (positive.isNotEmpty || negative.isNotEmpty) const SizedBox(height: 12),
            for (final e in [...positive, ...negative])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(accountTypeLabels[e.key]!)),
                        Text(formatMoney(e.value.round(scale: 0)), style: const TextStyle(fontWeight: FontWeight.w600)),
                      ],
                    ),
                    if (e.value > Decimal.zero) ...[
                      const SizedBox(height: 4),
                      ShareBar(fraction: fractionOf(e.value, s.assets)),
                    ],
                  ],
                ),
              ),
            if (currencies.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final c in currencies.toList()..sort())
                InkWell(
                  key: Key('rate-$c'),
                  onTap: () => _editRate(context, c, rates[c]),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(switch (rates[c]) {
                            null => '$c：沒有匯率，點這裡輸入',
                            FxRate(:final rate, manual: true) => '1 $c = NT\$$rate（自訂）',
                            FxRate(:final rate, :final asOf) => '1 $c = NT\$$rate（${formatDate(asOf!)} 的紀錄）',
                          }, style: muted),
                        ),
                        Icon(Icons.edit_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
                      ],
                    ),
                  ),
                ),
            ],
            if (s.unconverted.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('沒有算進去：${s.unconverted.map((a) => a.name).join('、')}（幣別或匯率未知）', style: muted),
              ),
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
