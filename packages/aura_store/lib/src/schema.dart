import 'package:sqlite3/sqlite3.dart';

/// Schema migrations, applied in order. `PRAGMA user_version` records how
/// many have run. Never edit a released step; append a new one.
const migrations = <String>[
  // 1: initial schema.
  '''
  CREATE TABLE meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );
  CREATE TABLE accounts (
    id       TEXT PRIMARY KEY,
    name     TEXT NOT NULL,
    type     TEXT NOT NULL,
    currency TEXT NOT NULL,
    sort     INTEGER NOT NULL
  );
  CREATE TABLE categories (
    id        TEXT PRIMARY KEY,
    kind      TEXT NOT NULL CHECK (kind IN ('expense', 'income')),
    name      TEXT NOT NULL,
    parent_id TEXT REFERENCES categories (id),
    sort      INTEGER NOT NULL
  );
  CREATE TABLE projects (
    id   TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    sort INTEGER NOT NULL
  );
  CREATE TABLE txns (
    seq             INTEGER PRIMARY KEY,
    id              TEXT NOT NULL UNIQUE,
    kind            TEXT NOT NULL CHECK (kind IN ('expense', 'income', 'transfer')),
    date            TEXT NOT NULL,          -- YYYY-MM-DD
    account_id      TEXT REFERENCES accounts (id),
    to_account_id   TEXT REFERENCES accounts (id),
    amount          TEXT NOT NULL,          -- exact decimal
    to_amount       TEXT,
    base_amount     TEXT NOT NULL,          -- exact decimal, base currency
    fx_rate_display TEXT,
    category_id     TEXT REFERENCES categories (id),
    project_id      TEXT REFERENCES projects (id),
    note            TEXT,
    place           TEXT,
    created_at      TEXT,                   -- YYYY-MM-DDTHH:MM:SS, local time
    fee_of_txn_id   TEXT,
    needs_review    INTEGER NOT NULL DEFAULT 0,
    legacy_rows     TEXT                    -- JSON: source rows for lossless export
  );
  CREATE INDEX txns_by_date ON txns (date DESC, created_at DESC);
  CREATE INDEX txns_by_category ON txns (category_id);
  CREATE INDEX txns_by_account ON txns (account_id);
  CREATE INDEX txns_by_to_account ON txns (to_account_id);
  CREATE TABLE invoices (
    txn_id         TEXT PRIMARY KEY REFERENCES txns (id) ON DELETE CASCADE,
    number         TEXT NOT NULL,
    seller_tax_id  TEXT,
    seller_name    TEXT,
    seller_address TEXT,
    carrier        TEXT                     -- sensitive; never leaves the device
  );
  CREATE TABLE invoice_items (
    txn_id   TEXT NOT NULL REFERENCES txns (id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    name     TEXT NOT NULL,
    quantity TEXT NOT NULL,
    amount   TEXT NOT NULL,
    PRIMARY KEY (txn_id, position)
  );
  ''',
  // 2: known account balances (BalanceAnchor).
  '''
  ALTER TABLE accounts ADD COLUMN anchor_amount TEXT;  -- exact decimal
  ALTER TABLE accounts ADD COLUMN anchor_date TEXT;    -- YYYY-MM-DD
  ''',
  // 3: archived accounts; unique account names (re-imports match by name).
  '''
  ALTER TABLE accounts ADD COLUMN archived INTEGER NOT NULL DEFAULT 0;
  CREATE UNIQUE INDEX accounts_by_name ON accounts (name);
  ''',
  // 4: monthly budgets; a NULL category is the total of all expenses.
  '''
  CREATE TABLE budgets (
    id          TEXT PRIMARY KEY,
    category_id TEXT REFERENCES categories (id) ON DELETE CASCADE,
    amount      TEXT NOT NULL,              -- exact decimal, base currency
    sort        INTEGER NOT NULL
  );
  ''',
  // 5: recurring records, and the link from each record they made.
  '''
  CREATE TABLE recurring (
    id              TEXT PRIMARY KEY,
    kind            TEXT NOT NULL CHECK (kind IN ('expense', 'income', 'transfer')),
    start_date      TEXT NOT NULL,          -- YYYY-MM-DD, the first occurrence
    account_id      TEXT NOT NULL REFERENCES accounts (id),
    to_account_id   TEXT REFERENCES accounts (id),
    amount          TEXT NOT NULL,
    to_amount       TEXT,
    base_amount     TEXT NOT NULL,
    fx_rate_display TEXT,
    category_id     TEXT REFERENCES categories (id),
    project_id      TEXT REFERENCES projects (id),
    note            TEXT,
    unit            TEXT NOT NULL CHECK (unit IN ('day', 'week', 'month', 'year')),
    every           INTEGER NOT NULL CHECK (every >= 1),
    until           TEXT,                   -- YYYY-MM-DD, inclusive
    times           INTEGER,
    next_date       TEXT,                   -- NULL once finished
    sort            INTEGER NOT NULL
  );
  ALTER TABLE txns ADD COLUMN recurring_id TEXT;
  CREATE INDEX txns_by_recurring ON txns (recurring_id);
  ''',
  // 6: hidden (private) accounts.
  '''
  ALTER TABLE accounts ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0;
  ''',
];

/// Brings [db] up to the latest schema. Each step runs in a transaction.
void migrate(Database db) {
  final current = db.userVersion;
  if (current > migrations.length) {
    throw StateError(
      '資料庫版本 $current 比這個 App 支援的 ${migrations.length} 還新，請更新 App',
    );
  }
  for (var v = current; v < migrations.length; v++) {
    db.execute('BEGIN');
    try {
      db.execute(migrations[v]);
      db.userVersion = v + 1;
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}
