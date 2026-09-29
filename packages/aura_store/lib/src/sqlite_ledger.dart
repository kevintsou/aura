import 'dart:convert';
import 'dart:typed_data';

import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:sqlite3/sqlite3.dart';

import 'schema.dart';

/// The ledger persisted in a SQLite file on the device.
///
/// Amounts are stored as decimal TEXT so nothing is lost to floating
/// point; dates as `YYYY-MM-DD` TEXT so they sort and compare correctly.
/// Queries are synchronous (FFI); callers on the UI isolate should keep
/// result sets small or move work to an isolate as data grows.
class SqliteLedger implements LedgerStore {
  SqliteLedger._(this._db) {
    _db.execute('PRAGMA foreign_keys = ON');
    migrate(_db);
    _loadReferenceData();
  }

  /// Opens (creating or migrating as needed) the database at [path].
  factory SqliteLedger.open(String path) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode = WAL');
    return SqliteLedger._(db);
  }

  factory SqliteLedger.inMemory() => SqliteLedger._(sqlite3.openInMemory());

  final Database _db;
  var _accounts = <String, Account>{};
  var _categories = <String, Category>{};
  var _projects = <String, Project>{};
  var _budgets = <Budget>[];
  var _recurrings = <Recurring>[];

  int get schemaVersion => _db.userVersion;

  void _loadReferenceData() {
    _accounts = {
      for (final r in _db.select('SELECT * FROM accounts ORDER BY sort'))
        r['id'] as String: Account(
          id: r['id'] as String,
          name: r['name'] as String,
          type: AccountType.values.byName(r['type'] as String),
          currency: r['currency'] as String,
          archived: (r['archived'] as int) != 0,
          hidden: (r['hidden'] as int) != 0,
          anchor: r['anchor_amount'] == null
              ? null
              : BalanceAnchor(
                  amount: Decimal.parse(r['anchor_amount'] as String),
                  date: _parseDate(r['anchor_date'] as String),
                ),
        ),
    };
    _categories = {
      for (final r in _db.select('SELECT * FROM categories ORDER BY sort'))
        r['id'] as String: Category(
          id: r['id'] as String,
          kind: TxnKind.values.byName(r['kind'] as String),
          name: r['name'] as String,
          parentId: r['parent_id'] as String?,
        ),
    };
    _projects = {
      for (final r in _db.select('SELECT * FROM projects ORDER BY sort'))
        r['id'] as String: Project(
          id: r['id'] as String,
          name: r['name'] as String,
        ),
    };
    _budgets = totalFirst([
      for (final r in _db.select('SELECT * FROM budgets ORDER BY sort'))
        Budget(
          id: r['id'] as String,
          categoryId: r['category_id'] as String?,
          amount: Decimal.parse(r['amount'] as String),
        ),
    ]);
    _recurrings = [
      for (final r in _db.select('SELECT * FROM recurring ORDER BY sort'))
        Recurring(
          id: r['id'] as String,
          template: Txn(
            id: r['id'] as String,
            kind: TxnKind.values.byName(r['kind'] as String),
            date: _parseDate(r['start_date'] as String),
            accountId: r['account_id'] as String,
            toAccountId: r['to_account_id'] as String?,
            amount: Decimal.parse(r['amount'] as String),
            toAmount: switch (r['to_amount']) {
              final String s => Decimal.parse(s),
              _ => null,
            },
            baseAmount: Decimal.parse(r['base_amount'] as String),
            fxRateDisplay: r['fx_rate_display'] as String?,
            categoryId: r['category_id'] as String?,
            projectId: r['project_id'] as String?,
            note: r['note'] as String?,
          ),
          unit: RepeatUnit.values.byName(r['unit'] as String),
          every: r['every'] as int,
          until: switch (r['until']) {
            final String s => _parseDate(s),
            _ => null,
          },
          times: r['times'] as int?,
          next: switch (r['next_date']) {
            final String s => _parseDate(s),
            _ => null,
          },
        ),
    ];
  }

  @override
  List<Account> get accounts => List.unmodifiable(_accounts.values);
  @override
  List<Category> get categories => List.unmodifiable(_categories.values);
  @override
  List<Project> get projects => List.unmodifiable(_projects.values);
  @override
  List<Budget> get budgets => List.unmodifiable(_budgets);
  @override
  List<Recurring> get recurrings => List.unmodifiable(_recurrings);

  @override
  Account? account(String id) => _accounts[id];
  @override
  Category? category(String id) => _categories[id];
  @override
  Project? project(String id) => _projects[id];

  @override
  Iterable<AccountFlow> accountFlows() => flowsOf(
    _db
        .select(
          'SELECT kind, date, account_id, to_account_id, amount, to_amount '
          'FROM txns',
        )
        .map(
          (r) => Txn(
            id: '',
            kind: TxnKind.values.byName(r['kind'] as String),
            date: _parseDate(r['date'] as String),
            accountId: r['account_id'] as String?,
            toAccountId: r['to_account_id'] as String?,
            amount: Decimal.parse(r['amount'] as String),
            toAmount: switch (r['to_amount']) {
              final String s => Decimal.parse(s),
              _ => null,
            },
            baseAmount: Decimal.zero,
          ),
        ),
  );

  @override
  void setBalanceAnchor(String accountId, BalanceAnchor? anchor) {
    _db.execute(
      'UPDATE accounts SET anchor_amount = ?, anchor_date = ? WHERE id = ?',
      [anchor?.amount.toString(), anchor == null ? null : formatIsoDate(anchor.date), accountId],
    );
    if (_db.updatedRows == 0) {
      throw ArgumentError.value(accountId, 'accountId');
    }
    _loadReferenceData();
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
    if (!_accounts.containsKey(accountId)) {
      throw ArgumentError.value(accountId, 'accountId');
    }
    checkAccountDetails(this, name: name, currency: currency, id: accountId);
    _db.execute(
      'UPDATE accounts SET name = coalesce(?, name), type = coalesce(?, type), '
      'currency = coalesce(?, currency), archived = coalesce(?, archived), hidden = coalesce(?, hidden) '
      'WHERE id = ?',
      [
        name,
        type?.name,
        currency,
        archived == null ? null : (archived ? 1 : 0),
        hidden == null ? null : (hidden ? 1 : 0),
        accountId,
      ],
    );
    _loadReferenceData();
  }

  @override
  Map<String, String> allMeta() => {
    for (final r in _db.select('SELECT key, value FROM meta'))
      r['key'] as String: r['value'] as String,
  };

  @override
  String? meta(String key) =>
      _db
              .select('SELECT value FROM meta WHERE key = ?', [key])
              .firstOrNull?['value']
          as String?;

  @override
  void setMeta(String key, String? value) => value == null
      ? _db.execute('DELETE FROM meta WHERE key = ?', [key])
      : _db.execute(
          'INSERT INTO meta (key, value) VALUES (?, ?) '
          'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          [key, value],
        );

  @override
  int count([TxnFilter filter = const TxnFilter()]) {
    final (where, args) = _where(filter);
    return _db.select('SELECT count(*) AS n FROM txns $where', args).first['n']
        as int;
  }

  @override
  List<Txn> transactions([
    TxnFilter filter = const TxnFilter(),
    int offset = 0,
    int? limit,
  ]) {
    final (where, args) = _where(filter);
    // NULL sorts lowest, so DESC puts missing creation times last.
    final page = 'SELECT * FROM txns $where '
        'ORDER BY date DESC, created_at DESC, seq ASC '
        'LIMIT ${limit ?? -1} OFFSET $offset';
    final rows = _db.select(page, args);
    if (rows.isEmpty) return const [];
    final invoices = _invoicesFor(
      'WHERE id IN (SELECT id FROM ($page))',
      args,
    );
    return [for (final r in rows) _txnFromRow(r, invoices[r['id']])];
  }

  (String, List<Object?>) _where(TxnFilter f) {
    final clauses = <String>[];
    final args = <Object?>[];
    String marks(Iterable<Object?> values) {
      args.addAll(values);
      return List.filled(values.length, '?').join(', ');
    }

    if (f.from != null) {
      clauses.add('date >= ?');
      args.add(formatIsoDate(f.from!));
    }
    if (f.to != null) {
      clauses.add('date <= ?');
      args.add(formatIsoDate(f.to!));
    }
    if (f.kinds != null) {
      clauses.add('kind IN (${marks(f.kinds!.map((k) => k.name))})');
    }
    if (f.accountIds != null) {
      final ids = f.accountIds!.toList();
      clauses.add(
        '(account_id IN (${marks(ids)}) OR to_account_id IN (${marks(ids)}))',
      );
    }
    if (f.excludeAccountIds case final ex? when ex.isNotEmpty) {
      final ids = ex.toList();
      clauses.add(
        '(account_id IS NULL OR account_id NOT IN (${marks(ids)})) AND '
        '(to_account_id IS NULL OR to_account_id NOT IN (${marks(ids)}))',
      );
    }
    if (f.categoryIds != null) {
      final ids = f.categoryIds!.toList();
      clauses.add(
        '(category_id IN (${marks(ids)}) OR category_id IN '
        '(SELECT id FROM categories WHERE parent_id IN (${marks(ids)})))',
      );
    }
    if (f.projectIds != null) {
      clauses.add('project_id IN (${marks(f.projectIds!)})');
    }
    final keyword = f.keyword?.trim().toLowerCase();
    if (keyword != null && keyword.isNotEmpty) {
      // instr() rather than LIKE: no wildcard escaping to get wrong.
      final match = [
        'instr(lower(note), ?) > 0',
        'instr(lower(place), ?) > 0',
        'EXISTS (SELECT 1 FROM invoices i WHERE i.txn_id = txns.id '
            'AND instr(lower(i.seller_name), ?) > 0)',
        if (f.searchInvoiceItems)
          'EXISTS (SELECT 1 FROM invoice_items it WHERE it.txn_id = txns.id '
              'AND instr(lower(it.name), ?) > 0)',
      ];
      clauses.add('(${match.join(' OR ')})');
      args.addAll(List.filled(match.length, keyword));
    }
    return (clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}', args);
  }

  Map<String, Invoice> _invoicesFor(String where, List<Object?> args) {
    final scope = 'SELECT id FROM txns $where';
    final items = <String, List<InvoiceItem>>{};
    for (final r in _db.select(
      'SELECT * FROM invoice_items WHERE txn_id IN ($scope) '
      'ORDER BY txn_id, position',
      args,
    )) {
      items
          .putIfAbsent(r['txn_id'] as String, () => [])
          .add(
            InvoiceItem(
              name: r['name'] as String,
              quantity: Decimal.parse(r['quantity'] as String),
              amount: Decimal.parse(r['amount'] as String),
            ),
          );
    }
    return {
      for (final r in _db.select(
        'SELECT * FROM invoices WHERE txn_id IN ($scope)',
        args,
      ))
        r['txn_id'] as String: Invoice(
          number: r['number'] as String,
          sellerTaxId: r['seller_tax_id'] as String?,
          sellerName: r['seller_name'] as String?,
          sellerAddress: r['seller_address'] as String?,
          carrier: r['carrier'] as String?,
          items: items[r['txn_id']] ?? const [],
        ),
    };
  }

  Txn _txnFromRow(Row r, Invoice? invoice) {
    Decimal? dec(String col) {
      final v = r[col] as String?;
      return v == null ? null : Decimal.parse(v);
    }

    final legacy = r['legacy_rows'] as String?;
    return Txn(
      id: r['id'] as String,
      kind: TxnKind.values.byName(r['kind'] as String),
      date: _parseDate(r['date'] as String),
      accountId: r['account_id'] as String?,
      toAccountId: r['to_account_id'] as String?,
      amount: dec('amount')!,
      toAmount: dec('to_amount'),
      baseAmount: dec('base_amount')!,
      fxRateDisplay: r['fx_rate_display'] as String?,
      categoryId: r['category_id'] as String?,
      projectId: r['project_id'] as String?,
      note: r['note'] as String?,
      place: r['place'] as String?,
      invoice: invoice,
      createdAt: switch (r['created_at']) {
        final String s => _parseDateTime(s),
        _ => null,
      },
      feeOfTxnId: r['fee_of_txn_id'] as String?,
      recurringId: r['recurring_id'] as String?,
      needsReview: (r['needs_review'] as int) != 0,
      legacyRows: legacy == null
          ? const []
          : [
              for (final row in jsonDecode(legacy) as List)
                [for (final f in row as List) f as String],
            ],
    );
  }

  @override
  void replaceAll(LedgerReader source) {
    _atomic(() {
      for (final table in const [
        'photos', 'invoice_items', 'invoices', 'txns', 'recurring', 'budgets', 'categories', 'projects', //
        'accounts',
      ]) {
        _db.execute('DELETE FROM $table');
      }
      _insertAll(source);
    });
    _loadReferenceData();
  }

  void _insertAll(LedgerReader source) {
    void each<T>(String sql, Iterable<T> items, List<Object?> Function(T, int) args) {
      final stmt = _db.prepare(sql);
      try {
        var i = 0;
        for (final item in items) {
          stmt.execute(args(item, i++));
        }
      } finally {
        stmt.close();
      }
    }

    each(_insertAccount, source.accounts, _accountArgs);
    each(
      'INSERT INTO projects (id, name, sort) VALUES (?, ?, ?)',
      source.projects,
      (p, i) => [p.id, p.name, i],
    );
    // Parents before children, for the foreign key.
    final cats = [
      ...source.categories.where((c) => c.parentId == null),
      ...source.categories.where((c) => c.parentId != null),
    ];
    final order = {for (final (i, c) in source.categories.indexed) c.id: i};
    each(_insertCategory, cats, (c, _) => _categoryArgs(c, order[c.id]!));
    each(_insertBudget, source.budgets, (b, i) => [b.id, b.categoryId, b.amount.toString(), i]);
    each(_insertRecurring, source.recurrings, _recurringArgs);
    final txns = source.transactions();
    each(_insertTxn, txns, (t, _) => _txnArgs(t));
    final withInvoice = txns.where((t) => t.invoice != null);
    each(_insertInvoice, withInvoice, (t, _) => _invoiceArgs(t));
    final ids = {for (final t in txns) t.id};
    each(
      _insertPhoto,
      [
        for (final p in source.photos())
          if (ids.contains(p.txnId)) p,
      ],
      (p, _) => [p.id, p.txnId, p.mime, p.bytes],
    );
    each(
      _insertItem,
      [
        for (final t in withInvoice)
          for (final (i, item) in t.invoice!.items.indexed) (t.id, i, item),
      ],
      (e, _) => _itemArgs(e.$1, e.$2, e.$3),
    );
  }

  /// Runs [body] atomically; rethrows after rolling back.
  void _atomic(void Function() body) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      body();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  int _nextSort(String table) =>
      (_db.select('SELECT coalesce(max(sort), -1) + 1 AS n FROM $table').first['n'] as int);

  @override
  void addAccount(Account account) {
    checkNewId(_accounts.containsKey(account.id), account.id);
    checkAccountDetails(this, name: account.name, currency: account.currency);
    _db.execute(_insertAccount, _accountArgs(account, _nextSort('accounts')));
    _loadReferenceData();
  }

  @override
  void deleteAccount(String accountId) {
    if (!_accounts.containsKey(accountId)) {
      throw ArgumentError.value(accountId, 'accountId');
    }
    checkUnused(count(TxnFilter(accountIds: {accountId})), '帳戶');
    checkNotRecurring(this, accountId: accountId);
    _db.execute('DELETE FROM accounts WHERE id = ?', [accountId]);
    _loadReferenceData();
  }

  @override
  void addCategory(Category category) {
    checkNewId(_categories.containsKey(category.id), category.id);
    checkCategory(this, category);
    _db.execute(_insertCategory, _categoryArgs(category, _nextSort('categories')));
    _loadReferenceData();
  }

  @override
  void renameCategory(String categoryId, String name) {
    final c = _categories[categoryId];
    if (c == null) throw ArgumentError.value(categoryId, 'categoryId');
    checkCategory(this, c.renamed(name));
    _db.execute('UPDATE categories SET name = ? WHERE id = ?', [name, categoryId]);
    _loadReferenceData();
  }

  @override
  void deleteCategory(String categoryId) {
    if (!_categories.containsKey(categoryId)) {
      throw ArgumentError.value(categoryId, 'categoryId');
    }
    checkUnused(count(TxnFilter(categoryIds: {categoryId})), '分類');
    checkNotRecurring(this, categoryId: categoryId);
    _atomic(() {
      _db
        ..execute('DELETE FROM categories WHERE parent_id = ?', [categoryId])
        ..execute('DELETE FROM categories WHERE id = ?', [categoryId]);
    });
    _loadReferenceData();
  }

  @override
  void reorderCategories(List<String> ids) {
    final marks = List.filled(ids.length, '?').join(', ');
    final slots = [
      for (final r in _db.select(
        'SELECT sort FROM categories WHERE id IN ($marks) ORDER BY sort',
        ids,
      ))
        r['sort'] as int,
    ];
    if (slots.length != ids.length) throw ArgumentError.value(ids, 'ids');
    _atomic(() {
      for (final (i, id) in ids.indexed) {
        _db.execute('UPDATE categories SET sort = ? WHERE id = ?', [slots[i], id]);
      }
    });
    _loadReferenceData();
  }

  @override
  void addProject(Project project) {
    checkNewId(_projects.containsKey(project.id), project.id);
    if (_projects.values.any((p) => p.name == project.name)) {
      throw ArgumentError.value(project.name, 'name', '專案名稱重複');
    }
    _db.execute(
      'INSERT INTO projects (id, name, sort) VALUES (?, ?, ?)',
      [project.id, project.name, _nextSort('projects')],
    );
    _loadReferenceData();
  }

  @override
  void setBudget(Budget budget) {
    checkBudget(this, budget);
    final args = [budget.id, budget.categoryId, budget.amount.toString(), _nextSort('budgets')];
    _db.execute(
      '$_insertBudget ON CONFLICT(id) DO UPDATE SET '
      'category_id = excluded.category_id, amount = excluded.amount',
      args,
    );
    _loadReferenceData();
  }

  @override
  void deleteBudget(String budgetId) {
    _db.execute('DELETE FROM budgets WHERE id = ?', [budgetId]);
    if (_db.updatedRows == 0) throw ArgumentError.value(budgetId, 'budgetId');
    _loadReferenceData();
  }

  @override
  void setRecurring(Recurring recurring) {
    checkRecurring(this, recurring);
    final args = _recurringArgs(recurring, _nextSort('recurring'));
    _db.execute(
      '$_insertRecurring ON CONFLICT(id) DO UPDATE SET '
      'kind = excluded.kind, start_date = excluded.start_date, account_id = excluded.account_id, '
      'to_account_id = excluded.to_account_id, amount = excluded.amount, to_amount = excluded.to_amount, '
      'base_amount = excluded.base_amount, fx_rate_display = excluded.fx_rate_display, '
      'category_id = excluded.category_id, project_id = excluded.project_id, note = excluded.note, '
      'unit = excluded.unit, every = excluded.every, until = excluded.until, times = excluded.times, '
      'next_date = excluded.next_date',
      args,
    );
    _loadReferenceData();
  }

  @override
  void deleteRecurring(String recurringId) {
    _atomic(() {
      _db.execute('DELETE FROM recurring WHERE id = ?', [recurringId]);
      if (_db.updatedRows == 0) throw ArgumentError.value(recurringId, 'recurringId');
      _db.execute('UPDATE txns SET recurring_id = NULL WHERE recurring_id = ?', [recurringId]);
    });
    _loadReferenceData();
  }

  @override
  List<String> photoIds(String txnId) => [
    for (final r in _db.select('SELECT id FROM photos WHERE txn_id = ? ORDER BY seq', [txnId])) r['id'] as String,
  ];

  Photo _photoFromRow(Row r) => Photo(
    id: r['id'] as String,
    txnId: r['txn_id'] as String,
    mime: r['mime'] as String,
    bytes: r['bytes'] as Uint8List,
  );

  @override
  Photo? photo(String id) => switch (_db.select('SELECT * FROM photos WHERE id = ?', [id]).firstOrNull) {
    final r? => _photoFromRow(r),
    _ => null,
  };

  @override
  Iterable<Photo> photos() => [for (final r in _db.select('SELECT * FROM photos ORDER BY seq')) _photoFromRow(r)];

  @override
  void addPhoto(Photo photo) {
    checkNewId(_db.select('SELECT 1 FROM photos WHERE id = ?', [photo.id]).isNotEmpty, photo.id);
    if (!_txnExists(photo.txnId)) throw ArgumentError.value(photo.txnId, 'txnId', '紀錄不存在');
    _db.execute(_insertPhoto, [photo.id, photo.txnId, photo.mime, photo.bytes]);
  }

  @override
  void deletePhoto(String photoId) {
    _db.execute('DELETE FROM photos WHERE id = ?', [photoId]);
    if (_db.updatedRows == 0) throw ArgumentError.value(photoId, 'photoId');
  }

  @override
  Txn? txn(String id) {
    final r = _db.select('SELECT * FROM txns WHERE id = ?', [id]).firstOrNull;
    if (r == null) return null;
    return _txnFromRow(r, _invoicesFor('WHERE id = ?', [id])[id]);
  }

  bool _txnExists(String id) =>
      _db.select('SELECT 1 FROM txns WHERE id = ?', [id]).isNotEmpty;

  void _writeInvoice(Txn t) {
    _db.execute('DELETE FROM invoices WHERE txn_id = ?', [t.id]);
    _db.execute('DELETE FROM invoice_items WHERE txn_id = ?', [t.id]);
    if (t.invoice == null) return;
    _db.execute(_insertInvoice, _invoiceArgs(t));
    for (final (i, item) in t.invoice!.items.indexed) {
      _db.execute(_insertItem, _itemArgs(t.id, i, item));
    }
  }

  @override
  void addTxn(Txn txn) {
    checkNewId(_txnExists(txn.id), txn.id);
    checkTxn(this, txn);
    _atomic(() {
      _db.execute(_insertTxn, _txnArgs(txn));
      _writeInvoice(txn);
    });
  }

  @override
  void updateTxn(Txn txn) {
    if (!_txnExists(txn.id)) throw ArgumentError.value(txn.id, 'txn.id');
    checkTxn(this, txn);
    // UPDATE, not delete + insert: keeps seq, the tie-breaker for ordering.
    final args = _txnArgs(txn);
    _atomic(() {
      _db.execute(
        'UPDATE txns SET kind = ?, date = ?, account_id = ?, to_account_id = ?, '
        'amount = ?, to_amount = ?, base_amount = ?, fx_rate_display = ?, '
        'category_id = ?, project_id = ?, note = ?, place = ?, created_at = ?, '
        'fee_of_txn_id = ?, needs_review = ?, legacy_rows = ?, recurring_id = ? WHERE id = ?',
        [...args.skip(1), txn.id],
      );
      _writeInvoice(txn);
    });
  }

  @override
  void deleteTxn(String txnId) {
    if (!_txnExists(txnId)) throw ArgumentError.value(txnId, 'txnId');
    _atomic(() {
      _db
        ..execute('UPDATE txns SET fee_of_txn_id = NULL WHERE fee_of_txn_id = ?', [txnId])
        ..execute('DELETE FROM txns WHERE id = ?', [txnId]);
    });
  }

  @override
  void close() => _db.close();
}

// Hand-rolled: DateTime.parse dominated load time on large ledgers.
int _int(String s, int start, int end) {
  var n = 0;
  for (var i = start; i < end; i++) {
    n = n * 10 + s.codeUnitAt(i) - 0x30;
  }
  return n;
}

DateTime _parseDate(String s) =>
    DateTime(_int(s, 0, 4), _int(s, 5, 7), _int(s, 8, 10));

DateTime _parseDateTime(String s) => DateTime(
  _int(s, 0, 4),
  _int(s, 5, 7),
  _int(s, 8, 10),
  _int(s, 11, 13),
  _int(s, 14, 16),
  _int(s, 17, 19),
);

String _isoDateTime(DateTime d) =>
    '${formatIsoDate(d)}T${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';

String _two(int n) => n.toString().padLeft(2, '0');

/// `YYYY-MM-DD`.
String formatIsoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

const _insertAccount =
    'INSERT INTO accounts (id, name, type, currency, sort, anchor_amount, '
    'anchor_date, archived, hidden) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)';

List<Object?> _accountArgs(Account a, int sort) => [
  a.id,
  a.name,
  a.type.name,
  a.currency,
  sort,
  a.anchor?.amount.toString(),
  a.anchor == null ? null : formatIsoDate(a.anchor!.date),
  a.archived ? 1 : 0,
  a.hidden ? 1 : 0,
];

const _insertCategory =
    'INSERT INTO categories (id, kind, name, parent_id, sort) VALUES (?, ?, ?, ?, ?)';

List<Object?> _categoryArgs(Category c, int sort) =>
    [c.id, c.kind.name, c.name, c.parentId, sort];

const _insertPhoto = 'INSERT INTO photos (id, txn_id, mime, bytes) VALUES (?, ?, ?, ?)';

const _insertBudget = 'INSERT INTO budgets (id, category_id, amount, sort) VALUES (?, ?, ?, ?)';

const _insertTxn =
    'INSERT INTO txns (id, kind, date, account_id, to_account_id, amount, '
    'to_amount, base_amount, fx_rate_display, category_id, project_id, note, '
    'place, created_at, fee_of_txn_id, needs_review, legacy_rows, recurring_id) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

/// Values for [_insertTxn]; the id comes first.
List<Object?> _txnArgs(Txn t) => [
  t.id,
  t.kind.name,
  formatIsoDate(t.date),
  t.accountId,
  t.toAccountId,
  t.amount.toString(),
  t.toAmount?.toString(),
  t.baseAmount.toString(),
  t.fxRateDisplay,
  t.categoryId,
  t.projectId,
  t.note,
  t.place,
  t.createdAt == null ? null : _isoDateTime(t.createdAt!),
  t.feeOfTxnId,
  t.needsReview ? 1 : 0,
  t.legacyRows.isEmpty ? null : jsonEncode(t.legacyRows),
  t.recurringId,
];

const _insertRecurring =
    'INSERT INTO recurring (id, kind, start_date, account_id, to_account_id, amount, to_amount, '
    'base_amount, fx_rate_display, category_id, project_id, note, unit, every, until, times, '
    'next_date, sort) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

List<Object?> _recurringArgs(Recurring r, int sort) {
  final t = r.template;
  return [
    r.id,
    t.kind.name,
    formatIsoDate(t.date),
    t.accountId,
    t.toAccountId,
    t.amount.toString(),
    t.toAmount?.toString(),
    t.baseAmount.toString(),
    t.fxRateDisplay,
    t.categoryId,
    t.projectId,
    t.note,
    r.unit.name,
    r.every,
    r.until == null ? null : formatIsoDate(r.until!),
    r.times,
    r.next == null ? null : formatIsoDate(r.next!),
    sort,
  ];
}

const _insertInvoice =
    'INSERT INTO invoices (txn_id, number, seller_tax_id, seller_name, '
    'seller_address, carrier) VALUES (?, ?, ?, ?, ?, ?)';

List<Object?> _invoiceArgs(Txn t) => [
  t.id,
  t.invoice!.number,
  t.invoice!.sellerTaxId,
  t.invoice!.sellerName,
  t.invoice!.sellerAddress,
  t.invoice!.carrier,
];

const _insertItem =
    'INSERT INTO invoice_items (txn_id, position, name, quantity, amount) '
    'VALUES (?, ?, ?, ?, ?)';

List<Object?> _itemArgs(String txnId, int position, InvoiceItem item) =>
    [txnId, position, item.name, item.quantity.toString(), item.amount.toString()];
