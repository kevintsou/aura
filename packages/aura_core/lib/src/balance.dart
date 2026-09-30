import 'package:decimal/decimal.dart';

import 'ledger.dart';
import 'model.dart';

/// The real balance of an account at the end of [date], as the user saw it
/// (e.g. in their banking app). Everything else is derived from it.
///
/// Anchoring to a date rather than storing an opening balance means a
/// re-import that covers a different period does not shift balances.
class BalanceAnchor {
  const BalanceAnchor({required this.amount, required this.date});

  /// In the account's currency. Negative for debt (credit cards).
  final Decimal amount;

  /// Date only; the balance is as of the end of this day.
  final DateTime date;

  @override
  bool operator ==(Object other) =>
      other is BalanceAnchor && other.amount == amount && other.date == date;

  @override
  int get hashCode => Object.hash(amount, date);
}

/// Money entering (+) or leaving (−) one account, in its currency.
class AccountFlow {
  const AccountFlow(this.accountId, this.date, this.delta);

  final String accountId;
  final DateTime date;
  final Decimal delta;
}

/// Flows implied by [txns]: expenses leave, income enters, transfers do
/// both (the receiving side in its own currency).
Iterable<AccountFlow> flowsOf(Iterable<Txn> txns) sync* {
  for (final t in txns) {
    switch (t.kind) {
      case TxnKind.expense:
        yield AccountFlow(t.accountId!, t.date, -t.amount);
      case TxnKind.income:
        yield AccountFlow(t.accountId!, t.date, t.amount);
      case TxnKind.transfer:
        if (t.accountId != null) {
          yield AccountFlow(t.accountId!, t.date, -t.amount);
        }
        if (t.toAccountId != null) {
          yield AccountFlow(t.toAccountId!, t.date, t.toAmount ?? t.amount);
        }
    }
  }
}

class AccountBalance {
  const AccountBalance({
    required this.account,
    required this.anchor,
    required this.opening,
    required this.current,
    required this.firstDate,
    required this.lastDate,
    required this.flowCount,
  });

  final Account account;

  /// The anchor used ([Account.anchor], or a candidate being previewed).
  /// Null means the opening balance is unknown and assumed to be zero.
  final BalanceAnchor? anchor;

  /// Balance before the first record.
  final Decimal opening;

  /// Balance at the end of today; records dated in the future are not
  /// included yet.
  final Decimal current;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final int flowCount;

  bool get isSet => anchor != null;

  /// The anchor that makes [opening] equal to [amount]: the balance at the
  /// end of the day before the first record.
  BalanceAnchor openingAnchor(Decimal amount, {required DateTime today}) =>
      BalanceAnchor(
        amount: amount,
        date: firstDate == null
            ? dateOnly(today)
            : DateTime(firstDate!.year, firstDate!.month, firstDate!.day - 1),
      );
}

/// Balance of [account] from its [flows], using [anchor] (defaults to the
/// account's own). With an anchor (A, D): balance(t) = A + S(t) − S(D),
/// where S(x) is the sum of flows up to the end of day x.
AccountBalance balanceOf(
  Account account,
  Iterable<AccountFlow> flows, {
  required DateTime today,
  BalanceAnchor? anchor,
  bool useAccountAnchor = true,
}) {
  final a = anchor ?? (useAccountAnchor ? account.anchor : null);
  final end = dateOnly(today);
  var toToday = Decimal.zero, toAnchor = Decimal.zero;
  DateTime? first, last;
  var n = 0;
  for (final f in flows) {
    n++;
    if (!f.date.isAfter(end)) toToday += f.delta;
    if (a != null && !f.date.isAfter(a.date)) toAnchor += f.delta;
    if (first == null || f.date.isBefore(first)) first = f.date;
    if (last == null || f.date.isAfter(last)) last = f.date;
  }
  final base = a == null ? Decimal.zero : a.amount - toAnchor;
  return AccountBalance(
    account: account,
    anchor: a,
    opening: base,
    current: base + toToday,
    firstDate: first,
    lastDate: last,
    flowCount: n,
  );
}

/// Balances of every account in [ledger].
Map<String, AccountBalance> computeBalances(
  LedgerReader ledger, {
  required DateTime today,
}) {
  final byAccount = <String, List<AccountFlow>>{};
  for (final f in ledger.accountFlows()) {
    byAccount.putIfAbsent(f.accountId, () => []).add(f);
  }
  return {
    for (final a in ledger.accounts)
      a.id: balanceOf(a, byAccount[a.id] ?? const [], today: today),
  };
}

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Calendar days from [from] to [to] (negative when [to] is earlier).
/// Counted on the dates alone: a day with a daylight-saving change is
/// 23 or 25 hours long, which `difference().inDays` gets wrong.
int daysBetween(DateTime from, DateTime to) =>
    DateTime.utc(to.year, to.month, to.day).difference(DateTime.utc(from.year, from.month, from.day)).inDays;
