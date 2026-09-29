import 'model.dart';

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
}

/// Read access to a ledger.
abstract interface class LedgerReader {
  List<Account> get accounts;
  List<Category> get categories;
  List<Project> get projects;

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
}

/// A ledger that can be written and survives restarts (depending on the
/// implementation: SQLite on devices, memory in tests and on the web).
abstract interface class LedgerStore implements LedgerReader {
  /// Atomically replaces every account, category, project and
  /// transaction with those of [source].
  void replaceAll(LedgerReader source);

  /// Small key/value settings kept with the data (e.g. last import).
  String? meta(String key);
  void setMeta(String key, String? value);

  void close();
}

class InMemoryLedger implements LedgerStore {
  InMemoryLedger({
    List<Account> accounts = const [],
    List<Category> categories = const [],
    List<Project> projects = const [],
    List<Txn> transactions = const [],
  }) {
    _load(accounts, categories, projects, transactions);
  }

  Map<String, Account> _accounts = {};
  Map<String, Category> _categories = {};
  Map<String, Project> _projects = {};
  List<Txn> _txns = [];
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
  void replaceAll(LedgerReader source) => _load(
    source.accounts,
    source.categories,
    source.projects,
    source.transactions(),
  );

  @override
  String? meta(String key) => _meta[key];

  @override
  void setMeta(String key, String? value) =>
      value == null ? _meta.remove(key) : _meta[key] = value;

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
