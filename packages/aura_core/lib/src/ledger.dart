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

/// Read access to a ledger. Implemented in memory today; a SQLite-backed
/// implementation will replace it without changing callers.
abstract interface class LedgerReader {
  List<Account> get accounts;
  List<Category> get categories;
  List<Project> get projects;

  Account? account(String id);
  Category? category(String id);
  Project? project(String id);

  /// Newest first.
  List<Txn> transactions([TxnFilter filter = const TxnFilter()]);
}

class InMemoryLedger implements LedgerReader {
  InMemoryLedger({
    List<Account> accounts = const [],
    List<Category> categories = const [],
    List<Project> projects = const [],
    List<Txn> transactions = const [],
  }) : _accounts = {for (final a in accounts) a.id: a},
       _categories = {for (final c in categories) c.id: c},
       _projects = {for (final p in projects) p.id: p},
       _txns = [...transactions]..sort(_newestFirst);

  final Map<String, Account> _accounts;
  final Map<String, Category> _categories;
  final Map<String, Project> _projects;
  final List<Txn> _txns;

  static int _newestFirst(Txn a, Txn b) {
    final byDate = b.date.compareTo(a.date);
    if (byDate != 0) return byDate;
    final ac = a.createdAt, bc = b.createdAt;
    if (ac == null || bc == null) return 0;
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
  List<Txn> transactions([TxnFilter filter = const TxnFilter()]) {
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
    }).toList();
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
