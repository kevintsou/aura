import 'package:decimal/decimal.dart';

import 'balance.dart';

/// Base currency for reports. CWMoney's 小計 column is always in this.
const baseCurrency = 'TWD';

enum TxnKind { expense, income, transfer }

enum AccountType { cash, bank, credit, epay, securities, other }

class Account {
  const Account({
    required this.id,
    required this.name,
    required this.type,
    required this.currency,
    this.anchor,
  });

  final String id;
  final String name;
  final AccountType type;

  /// ISO 4217 code, or `XXX` when the importer could not tell.
  final String currency;

  /// A known real balance, from which opening and current balances are
  /// derived. Null until the user sets one (CWMoney CSVs lack it).
  final BalanceAnchor? anchor;

  Account withAnchor(BalanceAnchor? anchor) => Account(
    id: id,
    name: name,
    type: type,
    currency: currency,
    anchor: anchor,
  );
}

/// Two-level category. A main category has no [parentId].
class Category {
  const Category({
    required this.id,
    required this.kind,
    required this.name,
    this.parentId,
  });

  final String id;

  /// [TxnKind.expense] or [TxnKind.income]; the same name may exist in both.
  final TxnKind kind;
  final String name;
  final String? parentId;
}

class Project {
  const Project({required this.id, required this.name});

  final String id;
  final String name;
}

class InvoiceItem {
  const InvoiceItem({
    required this.name,
    required this.quantity,
    required this.amount,
  });

  final String name;

  /// May be fractional (e.g. litres of fuel).
  final Decimal quantity;

  /// May be negative (discounts, points) or zero (bundled items).
  final Decimal amount;
}

class Invoice {
  const Invoice({
    required this.number,
    this.sellerTaxId,
    this.sellerName,
    this.sellerAddress,
    this.carrier,
    this.items = const [],
  });

  final String number;
  final String? sellerTaxId;
  final String? sellerName;
  final String? sellerAddress;

  /// E-invoice carrier (手機條碼). Sensitive: never send it anywhere.
  final String? carrier;
  final List<InvoiceItem> items;
}

class Txn {
  Txn({
    required this.id,
    required this.kind,
    required this.date,
    required this.amount,
    required this.baseAmount,
    this.accountId,
    this.toAccountId,
    this.toAmount,
    this.fxRateDisplay,
    this.categoryId,
    this.projectId,
    this.note,
    this.place,
    this.invoice,
    this.createdAt,
    this.feeOfTxnId,
    this.needsReview = false,
    this.legacyRows = const [],
  }) : assert(
         kind == TxnKind.transfer || accountId != null,
         'income and expense need an account',
       ),
       assert(
         kind != TxnKind.transfer || accountId != null || toAccountId != null,
         'a transfer needs at least one side',
       );

  final String id;
  final TxnKind kind;

  /// Date only (local calendar day).
  final DateTime date;

  /// Account the money leaves (expense, transfer) or enters (income).
  /// Null only for a one-sided transfer whose source is unknown.
  final String? accountId;

  /// Destination of a transfer. Null for a one-sided transfer.
  final String? toAccountId;

  /// In the currency of [accountId]'s account (the destination for a
  /// one-sided incoming transfer). May be negative.
  final Decimal amount;

  /// Amount received by [toAccountId] when it differs (cross-currency).
  final Decimal? toAmount;

  /// Amount in [baseCurrency]. Authoritative for reports; not always
  /// equal to amount × displayed rate.
  final Decimal baseAmount;

  /// Exchange rate as shown by the source app (rounded).
  final String? fxRateDisplay;

  /// Leaf category (subcategory when present).
  final String? categoryId;
  final String? projectId;
  final String? note;
  final String? place;
  final Invoice? invoice;
  final DateTime? createdAt;

  /// Set on a transfer-fee expense to the transfer it belongs to.
  final String? feeOfTxnId;

  /// Imported data the user should check (e.g. a transfer missing a side).
  final bool needsReview;

  /// Raw source rows, kept so the record can be exported unchanged.
  final List<List<String>> legacyRows;
}
