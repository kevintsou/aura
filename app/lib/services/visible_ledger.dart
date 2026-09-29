import 'package:aura_core/aura_core.dart';

/// The ledger without hidden accounts: they, and every record touching
/// them, are left out. Lookups by id still work, so a record already on
/// screen can always be labelled.
class VisibleLedger implements LedgerReader {
  VisibleLedger(this._ledger, this.hidden);

  final LedgerReader _ledger;

  /// Ids of the hidden accounts.
  final Set<String> hidden;

  bool _touches(Txn t) => hidden.contains(t.accountId) || hidden.contains(t.toAccountId);

  @override
  List<Account> get accounts => [for (final a in _ledger.accounts) if (!hidden.contains(a.id)) a];

  @override
  List<Category> get categories => _ledger.categories;

  @override
  List<Project> get projects => _ledger.projects;

  @override
  List<Budget> get budgets => _ledger.budgets;

  @override
  List<Recurring> get recurrings => [for (final r in _ledger.recurrings) if (!_touches(r.template)) r];

  @override
  Account? account(String id) => _ledger.account(id);

  @override
  Category? category(String id) => _ledger.category(id);

  @override
  Project? project(String id) => _ledger.project(id);

  @override
  List<Txn> transactions([TxnFilter filter = const TxnFilter(), int offset = 0, int? limit]) =>
      _ledger.transactions(filter.excluding(hidden), offset, limit);

  @override
  int count([TxnFilter filter = const TxnFilter()]) => _ledger.count(filter.excluding(hidden));

  @override
  Txn? txn(String id) => switch (_ledger.txn(id)) {
    final t? when !_touches(t) => t,
    _ => null,
  };

  @override
  Iterable<AccountFlow> accountFlows() => _ledger.accountFlows().where((f) => !hidden.contains(f.accountId));
}
