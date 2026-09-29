import 'dart:convert';

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

  int get schemaVersion => _db.userVersion;

  void _loadReferenceData() {
    _accounts = {
      for (final r in _db.select('SELECT * FROM accounts ORDER BY sort'))
        r['id'] as String: Account(
          id: r['id'] as String,
          name: r['name'] as String,
          type: AccountType.values.byName(r['type'] as String),
          currency: r['currency'] as String,
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
  void updateAccount(String accountId, {AccountType? type, String? currency}) {
    if (currency != null && !isCurrencyCode(currency)) {
      throw ArgumentError.value(currency, 'currency');
    }
    _db.execute(
      'UPDATE accounts SET type = coalesce(?, type), '
      'currency = coalesce(?, currency) WHERE id = ?',
      [type?.name, currency, accountId],
    );
    if (_db.updatedRows == 0) {
      throw ArgumentError.value(accountId, 'accountId');
    }
    _loadReferenceData();
  }

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
    _db.execute('BEGIN IMMEDIATE');
    try {
      for (final table in const [
        'invoice_items', 'invoices', 'txns', 'categories', 'projects', //
        'accounts',
      ]) {
        _db.execute('DELETE FROM $table');
      }
      _insertAll(source);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
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

    each(
      'INSERT INTO accounts (id, name, type, currency, sort, anchor_amount, '
      'anchor_date) VALUES (?, ?, ?, ?, ?, ?, ?)',
      source.accounts,
      (a, i) => [
        a.id,
        a.name,
        a.type.name,
        a.currency,
        i,
        a.anchor?.amount.toString(),
        a.anchor == null ? null : formatIsoDate(a.anchor!.date),
      ],
    );
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
    each(
      'INSERT INTO categories (id, kind, name, parent_id, sort) VALUES (?, ?, ?, ?, ?)',
      cats,
      (c, _) => [c.id, c.kind.name, c.name, c.parentId, order[c.id]],
    );
    final txns = source.transactions();
    each(
      'INSERT INTO txns (id, kind, date, account_id, to_account_id, amount, '
      'to_amount, base_amount, fx_rate_display, category_id, project_id, note, '
      'place, created_at, fee_of_txn_id, needs_review, legacy_rows) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      txns,
      (t, _) => [
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
      ],
    );
    final withInvoice = txns.where((t) => t.invoice != null);
    each(
      'INSERT INTO invoices (txn_id, number, seller_tax_id, seller_name, '
      'seller_address, carrier) VALUES (?, ?, ?, ?, ?, ?)',
      withInvoice,
      (t, _) => [
        t.id,
        t.invoice!.number,
        t.invoice!.sellerTaxId,
        t.invoice!.sellerName,
        t.invoice!.sellerAddress,
        t.invoice!.carrier,
      ],
    );
    each(
      'INSERT INTO invoice_items (txn_id, position, name, quantity, amount) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        for (final t in withInvoice)
          for (final (i, item) in t.invoice!.items.indexed) (t.id, i, item),
      ],
      (e, _) => [e.$1, e.$2, e.$3.name, e.$3.quantity.toString(), e.$3.amount.toString()],
    );
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
