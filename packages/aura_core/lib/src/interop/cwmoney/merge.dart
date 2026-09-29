import '../../ledger.dart';
import '../../model.dart';

/// What merging a CWMoney import into an existing ledger would change.
/// Nothing is written until [applyTo] builds the merged ledger.
///
/// A CWMoney record is recognised by its raw CSV rows, which Aura keeps
/// on every imported record (also after it is edited). So a record that
/// is already in the ledger is skipped even when the new file overlaps
/// earlier imports; only records not seen before are added.
class CwmMergePlan {
  CwmMergePlan._({
    required this.newAccounts,
    required this.newCategories,
    required this.newProjects,
    required this.newTxns,
    required this.completedTransfers,
    required this.alreadyPresent,
    required this.possibleDuplicates,
    required this.latestExisting,
  });

  /// Accounts, categories and projects the added records need, matched
  /// to existing ones by name first.
  final List<Account> newAccounts;
  final List<Category> newCategories;
  final List<Project> newProjects;

  /// Records to add, with ids of the target ledger.
  final List<Txn> newTxns;

  /// Transfers that were imported with one side only and are now
  /// complete. Each keeps the id of the record it replaces.
  final List<Txn> completedTransfers;

  /// Records of the file that are already in the ledger.
  final int alreadyPresent;

  /// Ids (in [newTxns]) of records that look like ones entered in Aura
  /// by hand: same kind, day, account(s) and amount. Typical when both
  /// apps were used for a while.
  final Set<String> possibleDuplicates;

  /// Date of the newest record in the ledger before merging.
  final DateTime? latestExisting;

  bool get isEmpty => newTxns.isEmpty && completedTransfers.isEmpty;

  /// Oldest and newest day among [newTxns].
  DateTime? get from => newTxns.isEmpty
      ? null
      : newTxns.map((t) => t.date).reduce((a, b) => a.isBefore(b) ? a : b);
  DateTime? get to => newTxns.isEmpty
      ? null
      : newTxns.map((t) => t.date).reduce((a, b) => a.isAfter(b) ? a : b);

  /// [current] with this plan applied, for [LedgerStore.replaceAll].
  InMemoryLedger applyTo(LedgerReader current, {bool skipPossibleDuplicates = true}) {
    final skipped = skipPossibleDuplicates ? possibleDuplicates : const <String>{};
    final added = [for (final t in newTxns) if (!skipped.contains(t.id)) t];
    final replaced = {for (final t in completedTransfers) t.id: t};
    return InMemoryLedger(
      accounts: [...current.accounts, ...newAccounts],
      categories: [...current.categories, ...newCategories],
      projects: [...current.projects, ...newProjects],
      budgets: current.budgets,
      recurrings: current.recurrings,
      photos: current.photos().toList(),
      transactions: [
        for (final t in current.transactions()) replaced[t.id] ?? t,
        for (final t in added)
          // The fee's transfer was a skipped duplicate.
          skipped.contains(t.feeOfTxnId) ? t.withoutFeeLink() : t,
      ],
    );
  }
}

/// Works out how to merge [imported] (a fresh CWMoney import) into
/// [current] without duplicating records imported before.
CwmMergePlan planCwmoneyMerge(LedgerReader current, LedgerReader imported) =>
    _Merger(current, imported).run();

String _rowKey(List<String> row) => row.join('\u001f');

String _lookalikeKey(Txn t) =>
    '${t.kind.name}|${t.date.toIso8601String()}|${t.accountId}|${t.toAccountId}|${t.baseAmount}';

class _Merger {
  _Merger(this.current, this.imported);

  final LedgerReader current;
  final LedgerReader imported;

  final newAccounts = <Account>[];
  final newCategories = <Category>[];
  final newProjects = <Project>[];

  late final _accountByName = {for (final a in current.accounts) a.name: a.id};
  late final _categoryByPath = {
    for (final c in current.categories) _path(c.kind, c.parentId, c.name): c.id,
  };
  late final _projectByName = {for (final p in current.projects) p.name: p.id};

  /// Target id of each imported account, category and project used.
  final _ids = <String, String>{};

  String _path(TxnKind kind, String? parentId, String name) => '${kind.name}|${parentId ?? ''}|$name';

  CwmMergePlan run() {
    final existing = current.transactions();
    // Which records own each raw row; consumed as rows are matched, so
    // identical rows count as many times as they occur.
    final owners = <String, List<Txn>>{};
    final lookalikes = <String, int>{};
    for (final t in existing) {
      for (final row in t.legacyRows) {
        owners.putIfAbsent(_rowKey(row), () => []).add(t);
      }
      if (t.legacyRows.isEmpty) {
        final k = _lookalikeKey(t);
        lookalikes[k] = (lookalikes[k] ?? 0) + 1;
      }
    }
    bool present(String key) => owners[key]?.isNotEmpty ?? false;
    Txn take(String key, [bool Function(Txn)? where]) {
      final list = owners[key]!;
      final i = where == null ? 0 : list.indexWhere(where);
      return list.removeAt(i < 0 ? 0 : i);
    }

    // Imported record id -> id in the merged ledger, for fee links.
    final txnIds = <String, String>{};
    final newTxns = <Txn>[];
    final completed = <Txn>[];
    var alreadyPresent = 0;
    // Oldest first, so ids and ties keep the file's order.
    for (final t in imported.transactions().reversed) {
      final keys = [for (final r in t.legacyRows) _rowKey(r)];
      if (keys.isNotEmpty && keys.every(present)) {
        final match = take(keys.first);
        for (final k in keys.skip(1)) {
          take(k, (o) => identical(o, match));
        }
        txnIds[t.id] = match.id;
        alreadyPresent++;
        continue;
      }
      // A transfer that was imported with one side only: the new file has
      // both. Complete it, unless the user already fixed it by hand.
      if (t.kind == TxnKind.transfer && keys.length == 2) {
        final side = keys.where(present).firstOrNull;
        if (side != null) {
          bool oneSided(Txn o) => o.kind == TxnKind.transfer && o.legacyRows.length == 1;
          final old = take(side, oneSided);
          txnIds[t.id] = old.id;
          if (oneSided(old) && old.needsReview) {
            completed.add(_remap(t, old.id));
          } else {
            alreadyPresent++;
          }
          continue;
        }
      }
      final id = newId('t');
      txnIds[t.id] = id;
      newTxns.add(_remap(t, id));
    }

    final possibleDuplicates = <String>{};
    for (final (i, t) in newTxns.indexed) {
      if (t.feeOfTxnId case final fee?) newTxns[i] = _withFee(t, txnIds[fee]);
      final k = _lookalikeKey(t);
      final n = lookalikes[k] ?? 0;
      if (n > 0) {
        lookalikes[k] = n - 1;
        possibleDuplicates.add(t.id);
      }
    }
    return CwmMergePlan._(
      newAccounts: newAccounts,
      newCategories: newCategories,
      newProjects: newProjects,
      newTxns: newTxns,
      completedTransfers: completed,
      alreadyPresent: alreadyPresent,
      possibleDuplicates: possibleDuplicates,
      latestExisting: existing.firstOrNull?.date,
    );
  }

  Txn _withFee(Txn t, String? feeOf) => t.copyWith(feeOfTxnId: feeOf);

  /// [t] with the target ledger's ids. The fee link still points at the
  /// imported id; [run] fixes it once all ids are known.
  Txn _remap(Txn t, String id) => Txn(
    id: id,
    kind: t.kind,
    date: t.date,
    amount: t.amount,
    baseAmount: t.baseAmount,
    accountId: _account(t.accountId),
    toAccountId: _account(t.toAccountId),
    toAmount: t.toAmount,
    fxRateDisplay: t.fxRateDisplay,
    categoryId: _category(t.categoryId),
    projectId: _project(t.projectId),
    note: t.note,
    place: t.place,
    location: t.location,
    invoice: t.invoice,
    createdAt: t.createdAt,
    feeOfTxnId: t.feeOfTxnId,
    needsReview: t.needsReview,
    legacyRows: t.legacyRows,
  );

  String? _account(String? importedId) {
    if (importedId == null) return null;
    return _ids[importedId] ??= () {
      final a = imported.account(importedId)!;
      return _accountByName[a.name] ??= () {
        final added = Account(id: newId('a'), name: a.name, type: a.type, currency: a.currency);
        newAccounts.add(added);
        return added.id;
      }();
    }();
  }

  String? _category(String? importedId) {
    if (importedId == null) return null;
    return _ids[importedId] ??= () {
      final c = imported.category(importedId)!;
      final parent = c.parentId == null ? null : _category(c.parentId);
      return _categoryByPath[_path(c.kind, parent, c.name)] ??= () {
        final added = Category(id: newId('c'), kind: c.kind, name: c.name, parentId: parent);
        newCategories.add(added);
        return added.id;
      }();
    }();
  }

  String? _project(String? importedId) {
    if (importedId == null) return null;
    return _ids[importedId] ??= () {
      final p = imported.project(importedId)!;
      return _projectByName[p.name] ??= () {
        final added = Project(id: newId('p'), name: p.name);
        newProjects.add(added);
        return added.id;
      }();
    }();
  }
}
