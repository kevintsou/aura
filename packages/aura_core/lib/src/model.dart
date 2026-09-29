import 'dart:math';

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
    this.archived = false,
  });

  final String id;

  /// Unique within a ledger; re-imports match accounts by name.
  final String name;
  final AccountType type;

  /// ISO 4217 code, or `XXX` when the importer could not tell.
  final String currency;

  /// A known real balance, from which opening and current balances are
  /// derived. Null until the user sets one (CWMoney CSVs lack it).
  final BalanceAnchor? anchor;

  /// Hidden from pickers for new records; its history stays.
  final bool archived;

  Account withAnchor(BalanceAnchor? anchor) => Account(
    id: id,
    name: name,
    type: type,
    currency: currency,
    anchor: anchor,
    archived: archived,
  );

  Account copyWith({
    String? name,
    AccountType? type,
    String? currency,
    bool? archived,
  }) => Account(
    id: id,
    name: name ?? this.name,
    type: type ?? this.type,
    currency: currency ?? this.currency,
    anchor: anchor,
    archived: archived ?? this.archived,
  );
}

final _random = Random.secure();

/// A new unique id for records created in the app. Imported records use
/// short sequential ids; these never collide with them.
String newId(String prefix) {
  final time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final rand = List.generate(6, (_) => _random.nextInt(36).toRadixString(36)).join();
  return '$prefix-$time$rand';
}

/// Placeholder currency for accounts whose currency is not known.
const unknownCurrency = 'XXX';

final _currencyCode = RegExp(r'^[A-Z]{3}$');

/// Whether [code] looks like an ISO 4217 code (three capital letters).
bool isCurrencyCode(String code) => _currencyCode.hasMatch(code);

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

  Category renamed(String name) =>
      Category(id: id, kind: kind, name: name, parentId: parentId);
}

/// A monthly spending limit in the base currency.
class Budget {
  const Budget({required this.id, required this.amount, this.categoryId});

  final String id;

  /// An expense category; a main category includes its subcategories.
  /// Null for all expenses together.
  final String? categoryId;

  /// Per calendar month.
  final Decimal amount;
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
    this.recurringId,
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

  /// The [Recurring] item that recorded this, if any.
  final String? recurringId;

  /// Imported data the user should check (e.g. a transfer missing a side).
  final bool needsReview;

  /// Raw source rows, kept so the record can be exported unchanged.
  final List<List<String>> legacyRows;

  /// This transaction with [feeOfTxnId] cleared (its transfer was deleted).
  Txn withoutFeeLink() => copyWith(feeOfTxnId: null);

  /// A copy with the given fields changed. [feeOfTxnId] and
  /// [recurringId] can be cleared by passing null.
  Txn copyWith({
    String? id,
    DateTime? date,
    DateTime? createdAt,
    Object? feeOfTxnId = _keep,
    Object? recurringId = _keep,
  }) => Txn(
    id: id ?? this.id,
    kind: kind,
    date: date ?? this.date,
    amount: amount,
    baseAmount: baseAmount,
    accountId: accountId,
    toAccountId: toAccountId,
    toAmount: toAmount,
    fxRateDisplay: fxRateDisplay,
    categoryId: categoryId,
    projectId: projectId,
    note: note,
    place: place,
    invoice: invoice,
    createdAt: createdAt ?? this.createdAt,
    feeOfTxnId: identical(feeOfTxnId, _keep) ? this.feeOfTxnId : feeOfTxnId as String?,
    recurringId: identical(recurringId, _keep) ? this.recurringId : recurringId as String?,
    needsReview: needsReview,
    legacyRows: legacyRows,
  );
}

const _keep = Object();
