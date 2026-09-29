import 'package:decimal/decimal.dart';

import 'balance.dart';
import 'ledger.dart';
import 'model.dart';

/// How much one unit of a currency is worth in [baseCurrency].
class FxRate {
  const FxRate(this.rate, {this.asOf, this.manual = false});

  final Decimal rate;

  /// Date of the record it was taken from; null for a rate the user set.
  final DateTime? asOf;
  final bool manual;
}

/// Meta key holding a rate the user set for [currency].
String fxMetaKey(String currency) => 'fx.$currency';

/// A rate for every foreign currency the accounts use: the one the user
/// set, else the one implied by the newest record in that currency
/// (its base amount over its amount).
Map<String, FxRate> knownRates(LedgerReader ledger, {Map<String, String> manual = const {}}) {
  final rates = <String, FxRate>{};
  final byCurrency = <String, List<Account>>{};
  for (final a in ledger.accounts) {
    if (a.currency == baseCurrency || a.currency == unknownCurrency) continue;
    byCurrency.putIfAbsent(a.currency, () => []).add(a);
  }
  for (final MapEntry(key: currency, value: accounts) in byCurrency.entries) {
    if (Decimal.tryParse(manual[currency] ?? '') case final r? when r > Decimal.zero) {
      rates[currency] = FxRate(r, manual: true);
      continue;
    }
    final ids = {for (final a in accounts) a.id};
    for (final t in ledger.transactions(TxnFilter(accountIds: ids), 0, 50)) {
      // The amount in this currency: the sending side, or what arrived.
      final amount = ids.contains(t.accountId) ? t.amount : t.toAmount ?? t.amount;
      if (amount == Decimal.zero || t.baseAmount == Decimal.zero) continue;
      final rate = (t.baseAmount / amount).toDecimal(scaleOnInfinitePrecision: 4).abs();
      rates[currency] = FxRate(rate, asOf: t.date);
      break;
    }
  }
  return rates;
}

/// Where the money is, in [baseCurrency].
class AssetSummary {
  const AssetSummary({
    required this.assets,
    required this.liabilities,
    required this.byType,
    required this.unconverted,
  });

  /// Sum of positive balances.
  final Decimal assets;

  /// Sum of negative balances, as a positive number (credit cards, loans).
  final Decimal liabilities;

  /// Net balance per account type.
  final Map<AccountType, Decimal> byType;

  /// Accounts left out: unknown currency or no rate yet.
  final List<Account> unconverted;

  Decimal get net => assets - liabilities;
}

/// Adds up [balances] in [baseCurrency] using [rates].
AssetSummary summarizeAssets(Iterable<AccountBalance> balances, Map<String, FxRate> rates) {
  var assets = Decimal.zero, liabilities = Decimal.zero;
  final byType = <AccountType, Decimal>{};
  final unconverted = <Account>[];
  for (final b in balances) {
    final c = b.account.currency;
    final rate = c == baseCurrency ? Decimal.one : rates[c]?.rate;
    if (rate == null) {
      if (b.current != Decimal.zero) unconverted.add(b.account);
      continue;
    }
    final value = (b.current * rate).round(scale: 2);
    value >= Decimal.zero ? assets += value : liabilities -= value;
    byType[b.account.type] = (byType[b.account.type] ?? Decimal.zero) + value;
  }
  return AssetSummary(assets: assets, liabilities: liabilities, byType: byType, unconverted: unconverted);
}
