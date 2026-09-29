import 'package:decimal/decimal.dart';

import 'balance.dart';
import 'model.dart';
import 'recurring.dart';

/// Criteria for selecting transactions. All fields are optional and
/// combined with AND. Date bounds are inclusive.
class TxnFilter {
  const TxnFilter({
    this.from,
    this.to,
    this.kinds,
    this.accountIds,
    this.categoryIds,
    this.projectIds,
    this.keyword,
    this.searchInvoiceItems = true,
    this.excludeAccountIds,
  });

  final DateTime? from;
  final DateTime? to;
  final Set<TxnKind>? kinds;

  /// Matches either side of a transfer.
  final Set<String>? accountIds;

  /// Matches a transaction whose leaf category or its parent is listed.
  final Set<String>? categoryIds;
  final Set<String>? projectIds;

  /// Case-insensitive substring of note, place, seller or invoice items.
  final String? keyword;

  /// Whether [keyword] also matches invoice line item names.
  final bool searchInvoiceItems;

  /// Leaves out records touching any of these accounts (either side of a
  /// transfer): how hidden accounts stay hidden.
  final Set<String>? excludeAccountIds;

  TxnFilter excluding(Set<String> accountIds) => TxnFilter(
    from: from,
    to: to,
    kinds: kinds,
    accountIds: accountIds.isEmpty ? this.accountIds : this.accountIds?.difference(accountIds),
    categoryIds: categoryIds,
    projectIds: projectIds,
    keyword: keyword,
    searchInvoiceItems: searchInvoiceItems,
    excludeAccountIds: accountIds.isEmpty ? excludeAccountIds : {...?excludeAccountIds, ...accountIds},
  );
}

/// Read access to a ledger.
abstract interface class LedgerReader {
  List<Account> get accounts;
  List<Category> get categories;
  List<Project> get projects;

  /// The whole-month total budget (if any) first, then by creation.
  List<Budget> get budgets;

  /// Repeating records, in the order they were created.
  List<Recurring> get recurrings;

  Account? account(String id);
  Category? category(String id);
  Project? project(String id);

  /// Newest first: by date, then creation time (missing last), then the
  /// order records were added. [offset] and [limit] select a page.
  List<Txn> transactions([
    TxnFilter filter = const TxnFilter(),
    int offset = 0,
    int? limit,
  ]);

  /// Number of transactions matching [filter].
  int count([TxnFilter filter = const TxnFilter()]);

  /// The transaction with [id], if any.
  Txn? txn(String id);

  /// Every movement of money per account, for balance calculations.
  /// Cheaper than loading full transactions.
  Iterable<AccountFlow> accountFlows();
}

/// A ledger that can be written and survives restarts (depending on the
/// implementation: SQLite on devices, memory in tests and on the web).
abstract interface class LedgerStore implements LedgerReader {
  /// Atomically replaces every account, category, project, budget,
  /// recurring item and transaction with those of [source].
  void replaceAll(LedgerReader source);

  /// Sets or clears an account's known balance.
  void setBalanceAnchor(String accountId, BalanceAnchor? anchor);

  /// Changes an account's details. Changing the currency relabels it;
  /// amounts are not converted (they were always in the real currency).
  void updateAccount(
    String accountId, {
    String? name,
    AccountType? type,
    String? currency,
    bool? archived,
    bool? hidden,
  });

  void addAccount(Account account);

  /// Only for accounts without records or recurring items; archive used
  /// ones instead.
  void deleteAccount(String accountId);

  /// Appended after its siblings.
  void addCategory(Category category);
  void renameCategory(String categoryId, String name);

  /// Only for categories no record or recurring item uses; removes its
  /// subcategories and their budgets too.
  void deleteCategory(String categoryId);

  /// Reorders sibling categories: [ids] take the positions they occupy
  /// now, in the given order.
  void reorderCategories(List<String> ids);

  void addProject(Project project);

  /// Adds [budget], or replaces the one with the same id.
  void setBudget(Budget budget);
  void deleteBudget(String budgetId);

  /// Adds [recurring], or replaces the one with the same id.
  void setRecurring(Recurring recurring);

  /// Records it made stay, no longer linked to it.
  void deleteRecurring(String recurringId);

  void addTxn(Txn txn);

  /// Replaces the transaction with the same id.
  void updateTxn(Txn txn);
  void deleteTxn(String txnId);

  /// Small key/value settings kept with the data (e.g. last import).
  String? meta(String key);
  void setMeta(String key, String? value);
  Map<String, String> allMeta();

  void close();
}

class InMemoryLedger implements LedgerStore {
  InMemoryLedger({
    List<Account> accounts = const [],
    List<Category> categories = const [],
    List<Project> projects = const [],
    List<Txn> transactions = const [],
    List<Budget> budgets = const [],
    List<Recurring> recurrings = const [],
  }) {
    _load(accounts, categories, projects, transactions);
    _budgets = {for (final b in budgets) b.id: b};
    _recurrings = {for (final r in recurrings) r.id: r};
  }

  Map<String, Account> _accounts = {};
  Map<String, Category> _categories = {};
  Map<String, Project> _projects = {};
  List<Txn> _txns = [];
  Map<String, Budget> _budgets = {};
  Map<String, Recurring> _recurrings = {};
  final Map<String, String> _meta = {};

  void _load(
    List<Account> accounts,
    List<Category> categories,
    List<Project> projects,
    List<Txn> transactions,
  ) {
    _accounts = {for (final a in accounts) a.id: a};
    _categories = {for (final c in categories) c.id: c};
    _projects = {for (final p in projects) p.id: p};
    // List.sort is not stable; the index keeps ties in insertion order.
    final indexed = [...transactions.indexed]
      ..sort((a, b) {
        final c = _newestFirst(a.$2, b.$2);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    _txns = [for (final (_, t) in indexed) t];
  }

  @override
  void replaceAll(LedgerReader source) {
    _load(
      source.accounts,
      source.categories,
      source.projects,
      source.transactions(),
    );
    _budgets = {for (final b in source.budgets) b.id: b};
    _recurrings = {for (final r in source.recurrings) r.id: r};
  }

  @override
  Iterable<AccountFlow> accountFlows() => flowsOf(_txns);

  @override
  void setBalanceAnchor(String accountId, BalanceAnchor? anchor) {
    final account = _accounts[accountId];
    if (account == null) throw ArgumentError.value(accountId, 'accountId');
    _accounts[accountId] = account.withAnchor(anchor);
  }

  @override
  void updateAccount(
    String accountId, {
    String? name,
    AccountType? type,
    String? currency,
    bool? archived,
    bool? hidden,
  }) {
    final account = _accounts[accountId];
    if (account == null) throw ArgumentError.value(accountId, 'accountId');
    checkAccountDetails(this, name: name, currency: currency, id: accountId);
    _accounts[accountId] = account.copyWith(
      name: name,
      type: type,
      currency: currency,
      archived: archived,
      hidden: hidden,
    );
  }

  @override
  void addAccount(Account account) {
    checkNewId(_accounts.containsKey(account.id), account.id);
    checkAccountDetails(this, name: account.name, currency: account.currency);
    _accounts[account.id] = account;
  }

  @override
  void deleteAccount(String accountId) {
    if (!_accounts.containsKey(accountId)) {
      throw ArgumentError.value(accountId, 'accountId');
    }
    checkUnused(count(TxnFilter(accountIds: {accountId})), '帳戶');
    checkNotRecurring(this, accountId: accountId);
    _accounts.remove(accountId);
  }

  @override
  void addCategory(Category category) {
    checkNewId(_categories.containsKey(category.id), category.id);
    checkCategory(this, category);
    _categories[category.id] = category;
  }

  @override
  void renameCategory(String categoryId, String name) {
    final c = _categories[categoryId];
    if (c == null) throw ArgumentError.value(categoryId, 'categoryId');
    final renamed = c.renamed(name);
    checkCategory(this, renamed);
    _categories[categoryId] = renamed;
  }

  @override
  void deleteCategory(String categoryId) {
    if (!_categories.containsKey(categoryId)) {
      throw ArgumentError.value(categoryId, 'categoryId');
    }
    checkUnused(count(TxnFilter(categoryIds: {categoryId})), '分類');
    checkNotRecurring(this, categoryId: categoryId);
    _categories.removeWhere(
      (id, c) => id == categoryId || c.parentId == categoryId,
    );
    _budgets.removeWhere((_, b) => b.categoryId != null && !_categories.containsKey(b.categoryId));
  }

  @override
  void reorderCategories(List<String> ids) {
    final order = [..._categories.keys];
    final slots = [
      for (final (i, id) in order.indexed)
        if (ids.contains(id)) i,
    ];
    if (slots.length != ids.length) throw ArgumentError.value(ids, 'ids');
    for (final (k, slot) in slots.indexed) {
      order[slot] = ids[k];
    }
    _categories = {for (final id in order) id: _categories[id]!};
  }

  @override
  void addProject(Project project) {
    checkNewId(_projects.containsKey(project.id), project.id);
    if (_projects.values.any((p) => p.name == project.name)) {
      throw ArgumentError.value(project.name, 'name', '專案名稱重複');
    }
    _projects[project.id] = project;
  }

  @override
  void setBudget(Budget budget) {
    checkBudget(this, budget);
    _budgets[budget.id] = budget;
  }

  @override
  void deleteBudget(String budgetId) {
    if (_budgets.remove(budgetId) == null) {
      throw ArgumentError.value(budgetId, 'budgetId');
    }
  }

  @override
  void setRecurring(Recurring recurring) {
    checkRecurring(this, recurring);
    _recurrings[recurring.id] = recurring;
  }

  @override
  void deleteRecurring(String recurringId) {
    if (_recurrings.remove(recurringId) == null) {
      throw ArgumentError.value(recurringId, 'recurringId');
    }
    _txns = [for (final t in _txns) t.recurringId == recurringId ? t.copyWith(recurringId: null) : t];
  }

  @override
  Txn? txn(String id) => _txns.where((t) => t.id == id).firstOrNull;

  @override
  void addTxn(Txn txn) {
    checkNewId(_txns.any((t) => t.id == txn.id), txn.id);
    checkTxn(this, txn);
    _load(accounts, categories, projects, [..._txns, txn]);
  }

  @override
  void updateTxn(Txn txn) {
    final i = _txns.indexWhere((t) => t.id == txn.id);
    if (i < 0) throw ArgumentError.value(txn.id, 'txn.id');
    checkTxn(this, txn);
    _load(accounts, categories, projects, [..._txns]..[i] = txn);
  }

  @override
  void deleteTxn(String txnId) {
    if (!_txns.any((t) => t.id == txnId)) {
      throw ArgumentError.value(txnId, 'txnId');
    }
    _txns = [
      for (final t in _txns)
        if (t.id != txnId) t.feeOfTxnId == txnId ? t.withoutFeeLink() : t,
    ];
  }

  @override
  String? meta(String key) => _meta[key];

  @override
  void setMeta(String key, String? value) =>
      value == null ? _meta.remove(key) : _meta[key] = value;

  @override
  Map<String, String> allMeta() => Map.unmodifiable(_meta);

  @override
  void close() {}

  static int _newestFirst(Txn a, Txn b) {
    final byDate = b.date.compareTo(a.date);
    if (byDate != 0) return byDate;
    final ac = a.createdAt, bc = b.createdAt;
    if (ac == null || bc == null) {
      return ac == bc ? 0 : (ac == null ? 1 : -1);
    }
    return bc.compareTo(ac);
  }

  @override
  List<Account> get accounts => List.unmodifiable(_accounts.values);
  @override
  List<Category> get categories => List.unmodifiable(_categories.values);
  @override
  List<Project> get projects => List.unmodifiable(_projects.values);
  @override
  List<Budget> get budgets => List.unmodifiable(totalFirst(_budgets.values));
  @override
  List<Recurring> get recurrings => List.unmodifiable(_recurrings.values);

  @override
  Account? account(String id) => _accounts[id];
  @override
  Category? category(String id) => _categories[id];
  @override
  Project? project(String id) => _projects[id];

  @override
  int count([TxnFilter filter = const TxnFilter()]) =>
      _matching(filter).length;

  @override
  List<Txn> transactions([
    TxnFilter filter = const TxnFilter(),
    int offset = 0,
    int? limit,
  ]) {
    final all = _matching(filter).skip(offset);
    return (limit == null ? all : all.take(limit)).toList();
  }

  Iterable<Txn> _matching(TxnFilter filter) {
    final keyword = filter.keyword?.trim().toLowerCase();
    return _txns.where((t) {
      if (filter.from != null && t.date.isBefore(filter.from!)) return false;
      if (filter.to != null && t.date.isAfter(filter.to!)) return false;
      if (filter.kinds != null && !filter.kinds!.contains(t.kind)) {
        return false;
      }
      if (filter.accountIds != null &&
          !filter.accountIds!.contains(t.accountId) &&
          !filter.accountIds!.contains(t.toAccountId)) {
        return false;
      }
      if (filter.excludeAccountIds case final ex?
          when ex.contains(t.accountId) || ex.contains(t.toAccountId)) {
        return false;
      }
      if (filter.categoryIds != null) {
        final leaf = t.categoryId == null ? null : _categories[t.categoryId];
        if (leaf == null ||
            (!filter.categoryIds!.contains(leaf.id) &&
                !filter.categoryIds!.contains(leaf.parentId))) {
          return false;
        }
      }
      if (filter.projectIds != null &&
          !filter.projectIds!.contains(t.projectId)) {
        return false;
      }
      if (keyword != null && keyword.isNotEmpty && !_matches(t, keyword, filter.searchInvoiceItems)) {
        return false;
      }
      return true;
    });
  }

  static bool _matches(Txn t, String keyword, bool includeItems) {
    bool has(String? s) => s != null && s.toLowerCase().contains(keyword);
    final invoice = t.invoice;
    return has(t.note) ||
        has(t.place) ||
        has(invoice?.sellerName) ||
        (includeItems && (invoice?.items.any((i) => has(i.name)) ?? false));
  }
}

/// Shared validation for [LedgerStore] implementations, so every store
/// enforces the same rules. Messages are shown to users.
void checkNewId(bool exists, String id) {
  if (exists) throw ArgumentError.value(id, 'id', 'id 已存在');
}

void checkUnused(int uses, String what) {
  if (uses > 0) {
    throw StateError('這個$what有 $uses 筆紀錄，無法刪除');
  }
}

void checkAccountDetails(
  LedgerReader ledger, {
  String? name,
  String? currency,
  String? id,
}) {
  if (name != null) {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', '請輸入帳戶名稱');
    }
    if (ledger.accounts.any((a) => a.name == name && a.id != id)) {
      throw ArgumentError.value(name, 'name', '已經有同名的帳戶');
    }
  }
  if (currency != null && !isCurrencyCode(currency)) {
    throw ArgumentError.value(currency, 'currency', '幣別代碼要是三個英文字母');
  }
}

void checkCategory(LedgerReader ledger, Category c) {
  if (c.kind == TxnKind.transfer) {
    throw ArgumentError.value(c.kind, 'kind', '轉帳沒有分類');
  }
  if (c.name.trim().isEmpty) {
    throw ArgumentError.value(c.name, 'name', '請輸入分類名稱');
  }
  if (c.parentId != null) {
    final parent = ledger.category(c.parentId!);
    if (parent == null || parent.parentId != null || parent.kind != c.kind) {
      throw ArgumentError.value(c.parentId, 'parentId', '子分類只能放在同類型的主分類下');
    }
  }
  if (ledger.categories.any(
    (o) =>
        o.id != c.id &&
        o.kind == c.kind &&
        o.parentId == c.parentId &&
        o.name == c.name,
  )) {
    throw ArgumentError.value(c.name, 'name', '已經有同名的分類');
  }
}

/// [budgets] with the whole-month total first, otherwise in order.
List<Budget> totalFirst(Iterable<Budget> budgets) => [
  ...budgets.where((b) => b.categoryId == null),
  ...budgets.where((b) => b.categoryId != null),
];

void checkBudget(LedgerReader ledger, Budget b) {
  if (b.amount <= Decimal.zero) {
    throw ArgumentError.value(b.amount, 'amount', '預算要大於 0');
  }
  if (b.categoryId != null && ledger.category(b.categoryId!)?.kind != TxnKind.expense) {
    throw ArgumentError.value(b.categoryId, 'categoryId', '只能替支出分類設定預算');
  }
  if (ledger.budgets.any((o) => o.id != b.id && o.categoryId == b.categoryId)) {
    throw ArgumentError.value(
      b.categoryId,
      'categoryId',
      b.categoryId == null ? '已經有每月總預算' : '這個分類已經有預算',
    );
  }
}

void checkRecurring(LedgerReader ledger, Recurring r) {
  if (r.every < 1) throw ArgumentError.value(r.every, 'every', '間隔至少是 1');
  if (r.times != null && r.times! < 1) throw ArgumentError.value(r.times, 'times', '次數至少是 1');
  if (r.until != null && r.until!.isBefore(r.start)) {
    throw ArgumentError.value(r.until, 'until', '結束日期不能早於開始日期');
  }
  final t = r.template;
  if (t.accountId == null || (t.kind == TxnKind.transfer && t.toAccountId == null)) {
    throw ArgumentError.value(t.accountId, 'accountId', '請選擇帳戶');
  }
  checkTxn(ledger, t);
}

/// Accounts and categories a recurring item uses cannot be deleted: its
/// next occurrence would have nowhere to go.
void checkNotRecurring(LedgerReader ledger, {String? accountId, String? categoryId}) {
  final uses = ledger.recurrings.where((r) {
    final t = r.template;
    if (accountId != null) return t.accountId == accountId || t.toAccountId == accountId;
    final c = t.categoryId == null ? null : ledger.category(t.categoryId!);
    return c != null && (c.id == categoryId || c.parentId == categoryId);
  }).length;
  if (uses > 0) {
    throw StateError('有 $uses 個週期收支用到它，請先修改或刪除那些週期收支');
  }
}

void checkTxn(LedgerReader ledger, Txn t) {
  void account(String? id) {
    if (id != null && ledger.account(id) == null) {
      throw ArgumentError.value(id, 'accountId', '帳戶不存在');
    }
  }

  account(t.accountId);
  account(t.toAccountId);
  if (t.kind == TxnKind.transfer) {
    if (t.accountId != null && t.accountId == t.toAccountId) {
      throw ArgumentError.value(t.toAccountId, 'toAccountId', '轉出和轉入不能是同一個帳戶');
    }
    if (t.categoryId != null) {
      throw ArgumentError.value(t.categoryId, 'categoryId', '轉帳沒有分類');
    }
  } else if (t.categoryId != null) {
    final c = ledger.category(t.categoryId!);
    if (c == null || c.kind != t.kind) {
      throw ArgumentError.value(t.categoryId, 'categoryId', '分類和收支類型不符');
    }
  }
  if (t.projectId != null && ledger.project(t.projectId!) == null) {
    throw ArgumentError.value(t.projectId, 'projectId', '專案不存在');
  }
}
