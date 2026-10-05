import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import '../widgets/amount_list_tile.dart';
import '../lock/lock_settings_screen.dart';
import '../widgets/charts.dart';
import '../widgets/account_icon.dart';
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
      final balances = [
        for (final b in all)
          if (!hiddenIds.contains(b.account.id)) b,
      ];
      final hasHidden = all.any((b) => b.account.hidden);
      final unset = balances.where((b) => !b.isSet).length;
      final unknown = balances
          .where((b) => b.account.currency == unknownCurrency)
          .length;
      final archived = balances
          .where((b) => b.account.archived && !b.account.hidden)
          .toList();
      final hidden = balances.where((b) => b.account.hidden).toList();
      return Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: Image.asset(
                  'assets/branding/aura-logo-indigo.png',
                  width: 32,
                  height: 32,
                ),
              ),
              const SizedBox(width: 10),
              const Text('帳戶'),
            ],
          ),
          actions: [
            if (hasHidden)
              TextButton.icon(
                key: const Key('toggleHidden'),
                onPressed: () => _toggleHidden(context),
                icon: Icon(
                  app.revealHidden
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
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
            : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      _Summary(app: app, balances: balances),
                      if (unset > 0 || unknown > 0)
                        _UnsetNotice(unset: unset, unknownCurrency: unknown),
                      for (final type in AccountType.values)
                        ..._section(context, accountTypeLabels[type]!, [
                          for (final b in balances)
                            if (!b.account.archived &&
                                !b.account.hidden &&
                                b.account.type == type)
                              b,
                        ]),
                      ..._section(context, '已封存', archived),
                      ..._section(context, '隱藏的帳戶', hidden),
                      const SizedBox(height: 80), // room for the button
                    ],
                  ),
                ),
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
          builder: (_) => PinCheckScreen(
            lock: app.lock,
            title: '顯示隱藏的帳戶',
            check: app.lock.check,
          ),
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
    final theme = Theme.of(context);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 10),
        child: Row(
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${items.length}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      Card(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        elevation: 0,
        color: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 20, endIndent: 20),
              _AccountTile(app: app, balance: items[i]),
            ],
          ],
        ),
      ),
    ];
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.app, required this.balances});
  final AppState app;
  final List<AccountBalance> balances;

  Future<void> _editRate(
    BuildContext context,
    String currency,
    FxRate? current,
  ) async {
    final text = await askText(
      context,
      title: '$currency 匯率',
      label: '1 $currency = 多少新台幣',
      initial: current?.manual ?? false ? current!.rate.toString() : '',
      message: '只用來換算淨資產。留空就用最近一筆紀錄的匯率。',
    );
    if (!context.mounted) return;
    final rate = Decimal.tryParse(text ?? '');
    app.setManualRate(
      currency,
      rate != null && rate > Decimal.zero ? rate : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final rates = app.rates;
    final s = summarizeAssets(balances, rates);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
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
        if (b.account.currency != baseCurrency &&
            b.account.currency != unknownCurrency)
          b.account.currency,
    };
    final scheme = theme.colorScheme;
    Widget metric(String label, Decimal amount, {bool compact = false}) =>
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
          ),
          child: compact
              ? Row(
                  children: [
                    Text(label, style: muted),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        formatMoney(amount.round(scale: 0)),
                        textAlign: TextAlign.right,
                        style: moneyStyle(context, amount),
                      ),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: muted),
                    const SizedBox(height: 6),
                    Text(
                      formatMoney(amount.round(scale: 0)),
                      style: moneyStyle(context, amount),
                    ),
                  ],
                ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('資產總覽', style: theme.textTheme.titleMedium),
                    ),
                    Text('${balances.length} 個帳戶', style: muted),
                  ],
                ),
                const SizedBox(height: 20),
                Text('淨資產', style: muted),
                const SizedBox(height: 8),
                Text(
                  formatMoney(s.net.round(scale: 0)),
                  key: const Key('netWorth'),
                  style: moneyStyle(context, s.net, size: 30),
                ),
                const SizedBox(height: 24),
                LayoutBuilder(
                  builder: (context, box) {
                    if (box.maxWidth < 480 ||
                        MediaQuery.textScalerOf(context).scale(18) > 23) {
                      return Column(
                        key: const Key('assetsLiabilities'),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          metric(
                            '資產',
                            s.assets,
                            compact:
                                box.maxWidth >= 280 &&
                                MediaQuery.textScalerOf(context).scale(18) <=
                                    23,
                          ),
                          const SizedBox(height: 12),
                          metric(
                            '負債',
                            -s.liabilities,
                            compact:
                                box.maxWidth >= 280 &&
                                MediaQuery.textScalerOf(context).scale(18) <=
                                    23,
                          ),
                        ],
                      );
                    }
                    return Row(
                      key: const Key('assetsLiabilities'),
                      children: [
                        Expanded(child: metric('資產', s.assets)),
                        const SizedBox(width: 12),
                        Expanded(child: metric('負債', -s.liabilities)),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          if (positive.isNotEmpty || negative.isNotEmpty) ...[
            const SizedBox(height: 16),
            Card(
              margin: EdgeInsets.zero,
              elevation: 0,
              color: scheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: scheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '資產分布',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    LayoutBuilder(
                      builder: (context, box) {
                        final columns =
                            box.maxWidth >= 600 &&
                                MediaQuery.textScalerOf(context).scale(18) <= 23
                            ? 2
                            : 1;
                        final width =
                            (box.maxWidth - (columns - 1) * 24) / columns;
                        return Wrap(
                          spacing: 24,
                          runSpacing: 4,
                          children: [
                            for (final e in [...positive, ...negative])
                              SizedBox(
                                width: width,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              accountTypeLabels[e.key]!,
                                            ),
                                          ),
                                          if (e.value > Decimal.zero)
                                            Text(
                                              fractionOf(e.value, s.assets) <
                                                      0.001
                                                  ? '< 0.1%'
                                                  : '${(fractionOf(e.value, s.assets) * 100).toStringAsFixed(1)}%',
                                              style: muted,
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        formatMoney(e.value.round(scale: 0)),
                                        style: moneyStyle(context, e.value),
                                      ),
                                      if (e.value > Decimal.zero) ...[
                                        const SizedBox(height: 10),
                                        ShareBar(
                                          color: scheme.primary,
                                          fraction: fractionOf(
                                            e.value,
                                            s.assets,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (currencies.isNotEmpty || s.unconverted.isNotEmpty) ...[
            const SizedBox(height: 16),
            Card(
              margin: EdgeInsets.zero,
              elevation: 0,
              color: scheme.surfaceContainerLow,
              child: ExpansionTile(
                key: const Key('accountRates'),
                leading: const Icon(Icons.currency_exchange),
                title: const Text('匯率與換算'),
                subtitle: Text(
                  '${currencies.length} 種外幣${s.unconverted.isEmpty ? '' : '・${s.unconverted.length} 個帳戶尚未計入'}',
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  for (final c in currencies.toList()..sort())
                    ListTile(
                      key: Key('rate-$c'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(switch (rates[c]) {
                        null => '$c：沒有匯率，點這裡輸入',
                        FxRate(:final rate, manual: true) =>
                          '1 $c = NT\$$rate（自訂）',
                        FxRate(:final rate, :final asOf) =>
                          '1 $c = NT\$$rate（${formatDate(asOf!)} 的紀錄）',
                      }, style: muted),
                      trailing: const Icon(Icons.edit_outlined, size: 20),
                      onTap: () => _editRate(context, c, rates[c]),
                    ),
                  if (s.unconverted.isNotEmpty)
                    Text(
                      '沒有算進去：${s.unconverted.map((a) => a.name).join('、')}（幣別或匯率未知）',
                      style: muted,
                    ),
                ],
              ),
            ),
          ],
        ],
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
    margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
    child: ExpansionTile(
      key: const Key('accountBalanceNotice'),
      leading: const Icon(Icons.info_outline),
      title: const Text('帳戶資料待確認'),
      subtitle: Text(
        [
          if (unset > 0) '$unset 個餘額未設定',
          if (unknownCurrency > 0) '$unknownCurrency 個幣別未設定',
        ].join('・'),
      ),
      childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      children: [
        Text(
          [
            if (unset > 0)
              '有 $unset 個帳戶還沒設定餘額，目前的數字只是紀錄的加總。'
                  '點帳戶輸入實際餘額（例如錢包裡的現金、網銀顯示的金額），就會自動算出期初餘額。',
            if (unknownCurrency > 0)
              '有 $unknownCurrency 個外幣帳戶無法從名稱判斷幣別，請點帳戶選擇幣別。',
          ].join('\n'),
        ),
      ],
    ),
  );
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({required this.app, required this.balance});
  final AppState app;
  final AccountBalance balance;

  @override
  Widget build(BuildContext context) {
    final a = balance.account;
    return AmountListTile(
      leading: Container(
        width: 48,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
        ),
        child: AccountIcon(
          value: app.ledger.meta(accountIconKey(a.id)),
          type: a.type,
          size: 28,
        ),
      ),
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
          fontSize: 18,
          color: moneyColor(context, balance.current),
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
