import 'dart:async';
import 'dart:convert';

import 'package:aura_ai/aura_ai.dart';
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/foundation.dart' hide Category;

import 'cloud/cloud_backup.dart';
import 'cloud/google_drive.dart';
import 'lock/app_lock.dart';
import 'services/ai_settings_store.dart';
import 'services/backup_files.dart';
import 'services/location_source.dart';
import 'services/photo_picker.dart';
import 'services/visible_ledger.dart';
import 'services/snapshot_store.dart';

typedef AiClientFactory =
    AiClient Function(AiEndpointConfig config, String? apiKey);

AiClient _defaultClient(AiEndpointConfig config, String? apiKey) =>
    OpenAiCompatibleClient(config: config, apiKey: apiKey);

const _metaImportFile = 'import.fileName';
const _metaImportedAt = 'import.at';

/// Device-specific meta, not taken from a restored backup.
const _metaLastBackup = 'backup.lastAt';

/// A copy of [source] that can be sent to another isolate.
InMemoryLedger _detached(LedgerReader source) => InMemoryLedger(
  accounts: source.accounts,
  categories: source.categories,
  projects: source.projects,
  transactions: source.transactions(),
  budgets: source.budgets,
  recurrings: source.recurrings,
  photos: source.photos().toList(),
);

Future<Uint8List> _encode(
  ({
    InMemoryLedger ledger,
    DateTime at,
    Map<String, String> meta,
    String? password,
    int iterations,
  })
  job,
) => encodeBackup(
  job.ledger,
  createdAt: job.at,
  meta: job.meta,
  password: job.password,
  iterations: job.iterations,
);

Future<CwmExportResult> _exportCwm(
  ({InMemoryLedger ledger, DateTime? from, DateTime? to, bool includeCarrier}) job,
) async => exportCwmoneyCsv(job.ledger, from: job.from, to: job.to, includeCarrier: job.includeCarrier);

Future<BackupContents> _decode(({List<int> bytes, String? password}) job) =>
    decodeBackup(job.bytes, password: job.password);

(CwmImportResult, CwmMergePlan) _readAndPlan(({List<int> bytes, InMemoryLedger current}) job) {
  final result = importCwmoneyCsv(job.bytes);
  return (result, planCwmoneyMerge(job.current, result.ledger));
}

/// A CWMoney export that has been read and compared with the ledger,
/// waiting for the user to choose between merging and replacing.
class CwmImportPreview {
  CwmImportPreview(this.fileName, this.result, this.plan);

  final String fileName;
  final CwmImportResult result;
  final CwmMergePlan plan;
}

/// App-wide state: the ledger, the AI connection and the assistant
/// conversation. Plain ChangeNotifier until the app outgrows it.
class AppState extends ChangeNotifier {
  AppState({
    required this.ledger,
    required this.settings,
    BackupFiles? files,
    SnapshotStore? snapshots,
    this.clientFactory = _defaultClient,
    this.kdfIterations = backupKdfIterations,
    DateTime Function()? clock,
    AppLock? lock,
    CloudSettingsStore? cloudStore,
    GoogleTokens? google,
    CloudTargetFactory? cloudTargets,
    PhotoPicker? photoPicker,
    LocationSource? locationSource,
  }) : lock = lock ?? AppLock.off(),
       photoPicker = photoPicker ?? DevicePhotoPicker(),
       locationSource = locationSource ?? DeviceLocationSource(),
       _cloudStore = cloudStore ?? MemoryCloudSettingsStore(),
       _google = google,
       _cloudTargets = cloudTargets,
       files = files ?? DeviceBackupFiles(),
       snapshots = snapshots ?? MemorySnapshotStore(),
       clock = clock ?? DateTime.now {
    // Hidden accounts go back into hiding whenever the app locks.
    this.lock.addListener(() {
      if (this.lock.locked && revealHidden) setRevealHidden(false);
    });
  }

  /// Persistent on devices (SQLite), in memory on the web and in tests.
  final LedgerStore ledger;
  final AiSettingsStore settings;

  /// PIN / biometric lock in front of the whole app.
  final AppLock lock;

  final PhotoPicker photoPicker;
  final LocationSource locationSource;

  static const _metaRecordLocation = 'ui.recordLocation';

  /// New income and expense records note where they were made. Off
  /// unless the user turns it on.
  bool get recordLocation => ledger.meta(_metaRecordLocation) == '1';

  /// Turns [recordLocation] on or off; on asks for the permission first.
  /// Returns the user-facing problem, if any.
  Future<String?> setRecordLocation(bool on) async {
    if (on && await lock.whileAway(locationSource.current) == null) {
      return '無法取得位置。請確認手機的定位已開啟，並允許 Aura 使用位置。';
    }
    return write((l) => l.setMeta(_metaRecordLocation, on ? '1' : null));
  }

  final CloudSettingsStore _cloudStore;
  final GoogleTokens? _google;
  final CloudTargetFactory? _cloudTargets;

  /// Automatic encrypted backups to the user's cloud storage.
  late final cloud = CloudBackup(
    store: _cloudStore,
    google: _google,
    targets: _cloudTargets,
    encode: (password) => _encodeCurrent(password: password),
    restore: (bytes, password) => restoreBackup(bytes, password: password),
    hasData: () => ledger.count() > 0,
    clock: clock,
  );
  final BackupFiles files;
  final SnapshotStore snapshots;

  /// Key-derivation rounds for password-protected backups (lower in tests).
  final int kdfIterations;
  final AiClientFactory clientFactory;
  final DateTime Function() clock;

  /// Bumped whenever ledger data changes, so views can drop caches.
  int revision = 0;
  CwmImportReport? lastImport;

  /// Accounts whose balance survived the last import, and those whose
  /// balance had to be dropped because the new file does not reach back
  /// to the date the balance was set for.
  List<String> anchorsKept = const [], anchorsDropped = const [];

  /// Budgets whose category the last replacing import did not have.
  List<String> budgetsDropped = const [];

  /// Recurring items the last replacing import had to drop because an
  /// account or category they use is not in the file.
  List<String> recurringDropped = const [];

  Map<String, AccountBalance>? _balances;
  int _balancesRevision = -1;

  /// Per-account balances, recomputed when the ledger changes.
  Map<String, AccountBalance> get balances {
    if (_balances == null || _balancesRevision != revision) {
      _balances = computeBalances(ledger, today: clock());
      _balancesRevision = revision;
    }
    return _balances!;
  }

  Map<String, FxRate>? _rates;
  int _ratesRevision = -1;

  /// Exchange rates for foreign accounts: set by the user, else from the
  /// newest record in each currency.
  Map<String, FxRate> get rates {
    if (_rates == null || _ratesRevision != revision) {
      _rates = knownRates(
        ledger,
        manual: {
          for (final e in ledger.allMeta().entries)
            if (e.key.startsWith('fx.')) e.key.substring(3): e.value,
        },
      );
      _ratesRevision = revision;
    }
    return _rates!;
  }

  /// Sets (or with null, clears) the rate used for [currency].
  void setManualRate(String currency, Decimal? rate) {
    ledger.setMeta(fxMetaKey(currency), rate?.toString());
    revision++;
    notifyListeners();
  }

  /// Runs a ledger write; returns the user-facing error message instead
  /// of throwing when the ledger rejects it.
  String? write(void Function(LedgerStore ledger) change) {
    try {
      change(ledger);
    } on ArgumentError catch (e) {
      return '${e.message}';
    } on StateError catch (e) {
      return e.message;
    }
    revision++;
    notifyListeners();
    return null;
  }

  void updateAccount(
    String accountId, {
    String? name,
    AccountType? type,
    String? currency,
    bool? archived,
    bool? hidden,
  }) {
    ledger.updateAccount(
      accountId,
      name: name,
      type: type,
      currency: currency,
      archived: archived,
      hidden: hidden,
    );
    revision++;
    notifyListeners();
  }

  /// No accounts and no records: offer to start fresh or import.
  bool get isBlank => ledger.accounts.isEmpty && ledger.count() == 0;

  /// Sets up an empty ledger with default categories and a cash account.
  void startFresh() {
    for (final c in defaultCategories()) {
      ledger.addCategory(c);
    }
    ledger
      ..addAccount(defaultCashAccount())
      ..setMeta('ledger.startedAt', clock().toIso8601String());
    revision++;
    notifyListeners();
  }

  /// Accounts that can take new records.
  List<Account> get activeAccounts => [
    for (final a in view.accounts)
      if (!a.archived) a,
  ];

  /// Whether hidden accounts are showing (until the app locks again).
  bool revealHidden = false;

  /// Ids of hidden accounts while they are hidden.
  Set<String> get hiddenAccountIds => revealHidden
      ? const {}
      : {
          for (final a in ledger.accounts)
            if (a.hidden) a.id,
        };

  /// What screens, reports, budgets and the AI see: the ledger without
  /// hidden accounts and their records, unless they are revealed.
  LedgerReader get view {
    final hidden = hiddenAccountIds;
    return hidden.isEmpty ? ledger : VisibleLedger(ledger, hidden);
  }

  void setRevealHidden(bool reveal) {
    revealHidden = reveal;
    revision++;
    assistant.reset();
    notifyListeners();
  }

  String? get lastAccountId => ledger.meta('ui.lastAccount');
  String? lastCategoryId(TxnKind kind) =>
      ledger.meta('ui.lastCategory.${kind.name}');

  /// Adds or replaces [txn], adds and removes photos, and remembers its
  /// account and category as the defaults for the next record.
  String? saveTxn(
    Txn txn, {
    required bool isNew,
    List<Uint8List> addPhotos = const [],
    List<String> removePhotos = const [],
  }) => write((l) {
    isNew ? l.addTxn(txn) : l.updateTxn(txn);
    removePhotos.forEach(l.deletePhoto);
    for (final bytes in addPhotos) {
      l.addPhoto(Photo(id: newId('ph'), txnId: txn.id, bytes: bytes));
    }
    l.setMeta('ui.lastAccount', txn.accountId);
    if (txn.categoryId != null) {
      l.setMeta('ui.lastCategory.${txn.kind.name}', txn.categoryId);
    }
  });

  void setBalanceAnchor(String accountId, BalanceAnchor? anchor) {
    ledger.setBalanceAnchor(accountId, anchor);
    revision++;
    notifyListeners();
  }
  String? get importedFileName => ledger.meta(_metaImportFile);

  AiEndpointConfig aiConfig = AiEndpointConfig.defaults;
  String? _apiKey;
  bool get hasApiKey => _apiKey != null && _apiKey!.isNotEmpty;
  bool get aiReady => aiConfig.validate(hasApiKey: hasApiKey).isEmpty;

  late final assistant = AssistantSession(this);

  /// The bottom tab showing; screens switch it, e.g. to the assistant.
  final tab = ValueNotifier(0);
  static const assistantTab = 3;

  /// Asks the assistant [question] and shows its tab.
  void askAssistant(String question) {
    if (aiReady) unawaited(assistant.send(question));
    tab.value = assistantTab;
  }

  Future<void> load() async {
    await cloud.load();
    aiConfig = await settings.loadConfig();
    _apiKey = await settings.loadApiKey(aiConfig.preset);
    notifyListeners();
  }

  /// Replaces the ledger with a CWMoney export. Parsing runs off the UI
  /// isolate. Returns an error message, or null on success.
  Future<String?> importCwmoney(List<int> bytes, String fileName) async {
    final CwmImportResult result;
    try {
      result = await compute(importCwmoneyCsv, bytes);
    } on CwmFormatException catch (e) {
      return e.message;
    }
    return _replaceWith(result, fileName);
  }

  /// Reads a CWMoney export and works out what merging it would add,
  /// without changing anything. Throws [CwmFormatException].
  Future<CwmImportPreview> previewCwmoney(List<int> bytes, String fileName) async {
    final (result, plan) = await compute(_readAndPlan, (bytes: bytes, current: _detached(ledger)));
    return CwmImportPreview(fileName, result, plan);
  }

  /// Replaces the ledger with a previewed export.
  Future<String?> replaceWithCwmoney(CwmImportPreview preview) => _replaceWith(preview.result, preview.fileName);

  /// Adds the new records of a previewed export to the ledger. Returns an
  /// error message, or null on success.
  Future<String?> mergeCwmoney(CwmImportPreview preview, {bool skipPossibleDuplicates = true}) async {
    await takeSnapshot(SnapshotReason.beforeImport);
    try {
      ledger.replaceAll(preview.plan.applyTo(ledger, skipPossibleDuplicates: skipPossibleDuplicates));
    } on Exception catch (e) {
      return '寫入資料庫失敗：$e';
    }
    _importDone(preview.fileName, preview.result.report, const [], const []);
    return null;
  }

  Future<String?> _replaceWith(CwmImportResult result, String fileName) async {
    _carryOverAccountDetails(result.ledger);
    final (kept, dropped) = _carryOverAnchors(result.ledger);
    final droppedBudgets = _carryOverBudgets(result.ledger);
    final droppedRecurring = _carryOverRecurring(result.ledger);
    await takeSnapshot(SnapshotReason.beforeImport);
    try {
      ledger.replaceAll(result.ledger);
    } on Exception catch (e) {
      return '寫入資料庫失敗：$e';
    }
    _importDone(fileName, result.report, kept, dropped);
    budgetsDropped = droppedBudgets;
    recurringDropped = droppedRecurring;
    return null;
  }

  void _importDone(String fileName, CwmImportReport report, List<String> kept, List<String> dropped) {
    ledger
      ..setMeta(_metaImportFile, fileName)
      ..setMeta(_metaImportedAt, clock().toIso8601String());
    lastImport = report;
    budgetsDropped = const [];
    recurringDropped = const [];
    anchorsKept = kept;
    anchorsDropped = dropped;
    revision++;
    assistant.reset();
    notifyListeners();
  }

  DateTime? get lastBackupAt => switch (ledger.meta(_metaLastBackup)) {
    final String s => DateTime.parse(s),
    _ => null,
  };

  /// Whether to nudge the user to back up: data exists and there is no
  /// backup file or cloud backup from the last 30 days.
  bool get backupOverdue {
    if (ledger.count() == 0) return false;
    final times = [?lastBackupAt, ?cloud.config.lastSuccess];
    return times.isEmpty || times.every((t) => clock().difference(t).inDays >= 30);
  }

  Future<Uint8List> _encodeCurrent({String? password}) => compute(_encode, (
    ledger: _detached(ledger),
    at: clock(),
    meta: {
      for (final e in ledger.allMeta().entries)
        if (!e.key.startsWith('backup.')) e.key: e.value,
    },
    password: password,
    iterations: kdfIterations,
  ));

  /// Creates a backup file and lets the user choose where to save it.
  /// Returns the file name, or null when the user cancelled.
  Future<String?> exportBackup({String? password}) async {
    final bytes = await _encodeCurrent(password: password);
    final now = clock();
    final name = 'aura-${now.year}${_two(now.month)}${_two(now.day)}-'
        '${_two(now.hour)}${_two(now.minute)}.$backupExtension';
    if (!await lock.whileAway(() => files.save(name, bytes))) return null;
    ledger.setMeta(_metaLastBackup, now.toIso8601String());
    notifyListeners();
    return name;
  }

  /// Writes the ledger (or [from]–[to]) as a CWMoney CSV and lets the
  /// user choose where to save it. Null when they cancelled.
  Future<(String, CwmExportResult)?> exportCwmoney({DateTime? from, DateTime? to, bool includeCarrier = false}) async {
    final result = await compute(_exportCwm, (
      ledger: _detached(ledger),
      from: from,
      to: to,
      includeCarrier: includeCarrier,
    ));
    final now = clock();
    // CWMoney's own naming, so the file is easy to recognise.
    final name = 'cwmoney_ex2_db_CSV_${now.year}${_two(now.month)}${_two(now.day)}.csv';
    if (!await lock.whileAway(() => files.save(name, result.bytes, title: '儲存 CWMoney CSV'))) return null;
    return (name, result);
  }

  /// Replaces the ledger with a backup, after keeping a snapshot of the
  /// current data. Throws [BackupException] for a bad file or password.
  Future<BackupInfo> restoreBackup(List<int> bytes, {String? password}) async {
    final contents = await compute(_decode, (bytes: bytes, password: password));
    await takeSnapshot(SnapshotReason.beforeRestore);
    ledger.replaceAll(contents.ledger);
    for (final e in contents.meta.entries) {
      if (!e.key.startsWith('backup.')) ledger.setMeta(e.key, e.value);
    }
    revision++;
    assistant.reset();
    notifyListeners();
    return contents.info;
  }

  /// Keeps a copy of the current data on the device (not when empty).
  Future<void> takeSnapshot(SnapshotReason reason) async {
    if (isBlank) return;
    await snapshots.save(await _encodeCurrent(), at: clock(), reason: reason);
  }

  /// A daily snapshot, taken at most once a day when the app opens.
  Future<void> dailySnapshot() async {
    final last = (await snapshots.list()).firstOrNull;
    if (last != null && clock().difference(last.at) < const Duration(days: 1)) {
      return;
    }
    await takeSnapshot(SnapshotReason.daily);
  }

  /// Keeps the type and currency of accounts that existed before (matched
  /// by name), so corrections survive a re-import. An unknown currency is
  /// not carried over: the new file may let the importer tell.
  void _carryOverAccountDetails(InMemoryLedger imported) {
    final previous = {for (final a in ledger.accounts) a.name: a};
    for (final a in imported.accounts) {
      final old = previous[a.name];
      if (old == null) continue;
      imported.updateAccount(
        a.id,
        type: old.type,
        currency: old.currency == unknownCurrency ? null : old.currency,
        hidden: old.hidden,
      );
    }
  }

  /// Moves budgets over to the categories of a freshly imported ledger
  /// with the same names. Returns the names of those left without one.
  List<String> _carryOverBudgets(InMemoryLedger imported) {
    String path(LedgerReader l, Category c) =>
        c.parentId == null ? c.name : '${l.category(c.parentId!)?.name}/${c.name}';
    final byPath = {
      for (final c in imported.categories)
        if (c.kind == TxnKind.expense) path(imported, c): c.id,
    };
    final dropped = <String>[];
    for (final b in ledger.budgets) {
      final c = b.categoryId == null ? null : ledger.category(b.categoryId!);
      final target = c == null ? null : byPath[path(ledger, c)];
      if (c != null && target == null) {
        dropped.add(path(ledger, c));
        continue;
      }
      imported.setBudget(Budget(id: b.id, amount: b.amount, categoryId: target));
    }
    return dropped;
  }

  /// Moves recurring items over to a freshly imported ledger, matching
  /// accounts, categories and projects by name. Returns the names of
  /// items that had to be dropped.
  List<String> _carryOverRecurring(InMemoryLedger imported) {
    String path(LedgerReader l, Category c) =>
        '${c.kind.name}/${c.parentId == null ? '' : l.category(c.parentId!)?.name}/${c.name}';
    final accounts = {for (final a in imported.accounts) a.name: a.id};
    final categories = {for (final c in imported.categories) path(imported, c): c.id};
    final projects = {for (final p in imported.projects) p.name: p.id};
    final dropped = <String>[];
    for (final r in ledger.recurrings) {
      final t = r.template;
      String? account(String? id) => id == null ? null : accounts[ledger.account(id)?.name];
      final category = t.categoryId == null ? null : ledger.category(t.categoryId!);
      final project = t.projectId == null ? null : ledger.project(t.projectId!);
      final from = account(t.accountId), to = account(t.toAccountId);
      final categoryId = category == null ? null : categories[path(ledger, category)];
      if (from == null || (t.toAccountId != null && to == null) || (category != null && categoryId == null)) {
        dropped.add(recurringLabel(ledger, r));
        continue;
      }
      final moved = Txn(
        id: t.id,
        kind: t.kind,
        date: t.date,
        accountId: from,
        toAccountId: to,
        amount: t.amount,
        toAmount: t.toAmount,
        baseAmount: t.baseAmount,
        fxRateDisplay: t.fxRateDisplay,
        categoryId: categoryId,
        // A project is optional: drop just the project if it is gone.
        projectId: project == null ? null : projects[project.name],
        note: t.note,
      );
      try {
        imported.setRecurring(
          Recurring(
            id: r.id,
            template: moved,
            unit: r.unit,
            every: r.every,
            until: r.until,
            times: r.times,
            next: r.next,
          ),
        );
      } on ArgumentError {
        dropped.add(recurringLabel(ledger, r));
      }
    }
    return dropped;
  }

  /// Records recurring items that are due. Call on start and whenever
  /// the app comes back to the foreground.
  RecurringRun runRecurring() {
    final run = recordDueRecurring(ledger, today: clock());
    if (run.recorded.isNotEmpty || run.problems.isNotEmpty) {
      revision++;
      notifyListeners();
    }
    return run;
  }

  /// Adds or changes a recurring item and records what is already due.
  /// Returns the error, or how many records were made.
  (String?, int) saveRecurring(Recurring recurring) {
    final error = write((l) => l.setRecurring(recurring));
    if (error != null) return (error, 0);
    return (null, runRecurring().recorded.length);
  }

  void deleteRecurring(String recurringId) => write((l) => l.deleteRecurring(recurringId));

  static const _metaDismissed = 'recurring.dismissed';

  Set<String> get _dismissedCandidates => switch (ledger.meta(_metaDismissed)) {
    final String s => {...(jsonDecode(s) as List).cast<String>()},
    _ => {},
  };

  List<RecurringCandidate>? _candidates;
  int _candidatesRevision = -1;

  /// Repeating records in the history that are not recurring items yet.
  List<RecurringCandidate> get recurringCandidates {
    if (_candidates == null || _candidatesRevision != revision) {
      _candidates = detectRecurring(view, today: clock(), dismissed: _dismissedCandidates);
      _candidatesRevision = revision;
    }
    return _candidates!;
  }

  /// Turns a detected pattern into a recurring item from its next date.
  String? adoptCandidate(RecurringCandidate c) => saveRecurring(c.toRecurring(newId('r'))).$1;

  /// Stops suggesting [c].
  void dismissCandidate(RecurringCandidate c) =>
      write((l) => l.setMeta(_metaDismissed, jsonEncode([..._dismissedCandidates, c.key])));

  static const _metaNotDuplicate = 'duplicates.dismissed';

  Set<String> get _notDuplicates => switch (ledger.meta(_metaNotDuplicate)) {
    final String s => {...(jsonDecode(s) as List).cast<String>()},
    _ => {},
  };

  /// The month's highlights (see [monthlyInsights]).
  List<Insight> insightsFor(Period month) =>
      monthlyInsights(view, month, today: clock(), dismissedDuplicates: _notDuplicates);

  List<List<Txn>>? _duplicates;
  int _duplicatesRevision = -1;

  /// Possible double entries in the last two weeks.
  List<List<Txn>> get recentDuplicates {
    if (_duplicates == null || _duplicatesRevision != revision) {
      final d = clock();
      _duplicates = possibleDuplicates(
        view,
        Period(DateTime(d.year, d.month, d.day - 13), DateTime(d.year, d.month, d.day)),
        dismissed: _notDuplicates,
      );
      _duplicatesRevision = revision;
    }
    return _duplicates!;
  }

  /// The user says [pair] are two real charges.
  void notDuplicate(List<Txn> pair) =>
      write((l) => l.setMeta(_metaNotDuplicate, jsonEncode([..._notDuplicates, duplicateKey(pair)])));

  /// Adds or changes a budget; returns the user-facing error, if any.
  String? setBudget(Budget budget) => write((l) => l.setBudget(budget));

  void deleteBudget(String budgetId) => write((l) => l.deleteBudget(budgetId));

  /// Re-applies the balances the user set, matched by account name, to a
  /// freshly imported ledger. A balance set for a day before the new file
  /// starts cannot be used: the activity in between is missing.
  (List<String>, List<String>) _carryOverAnchors(InMemoryLedger imported) {
    final previous = {
      for (final a in ledger.accounts)
        if (a.anchor != null) a.name: a.anchor!,
    };
    if (previous.isEmpty) return (const [], const []);
    final first = <String, DateTime>{};
    for (final f in imported.accountFlows()) {
      final d = first[f.accountId];
      if (d == null || f.date.isBefore(d)) first[f.accountId] = f.date;
    }
    final kept = <String>[], dropped = <String>[];
    for (final a in imported.accounts) {
      final anchor = previous[a.name];
      if (anchor == null) continue;
      final start = first[a.id];
      final covered =
          start == null ||
          !anchor.date.isBefore(start.subtract(const Duration(days: 1)));
      if (covered) {
        imported.setBalanceAnchor(a.id, anchor);
        kept.add(a.name);
      } else {
        dropped.add(a.name);
      }
    }
    return (kept, dropped);
  }

  Future<String?> apiKeyFor(AiPreset preset) => settings.loadApiKey(preset);

  Future<void> saveAi(AiEndpointConfig config, String? apiKey) async {
    await settings.saveConfig(config);
    await settings.saveApiKey(config.preset, apiKey);
    aiConfig = config;
    _apiKey = apiKey;
    assistant.reset();
    notifyListeners();
  }

  /// What the AI may see of [invoice] to pick a category: the seller's
  /// name, and the item names when the user shares them.
  ({String? seller, List<String> items}) _invoiceClues(Invoice invoice) => (
    seller: invoice.sellerName,
    items: aiConfig.shareInvoiceItems ? [for (final i in invoice.items) i.name] : const [],
  );

  /// Whether the AI can be asked to categorize [invoice].
  bool canAskAiCategory(Invoice invoice) {
    final c = _invoiceClues(invoice);
    return aiReady && ((c.seller?.trim().isNotEmpty ?? false) || c.items.isNotEmpty);
  }

  /// The expense category the AI picks for [invoice]: (id, problem).
  Future<(String?, String?)> aiCategoryFor(Invoice invoice) async {
    final l = view;
    final names = {for (final c in l.categories) c.id: c.name};
    final categories = {
      for (final c in l.categories)
        if (c.kind == TxnKind.expense) c.id: c.parentId == null ? c.name : '${names[c.parentId]}／${c.name}',
    };
    final clues = _invoiceClues(invoice);
    try {
      final id = await aiSuggestCategory(
        clientFactory(aiConfig, _apiKey),
        categories: categories,
        seller: clues.seller,
        items: clues.items,
      );
      return id == null ? (null, 'AI 沒有找到適合的分類，請自己選') : (id, null);
    } on AiClientException catch (e) {
      return (null, e.toString());
    }
  }

  AiClient clientFor(AiEndpointConfig config, String? apiKey) =>
      clientFactory(config, apiKey);

  AuraAgent newAgent() {
    final tools = aiConfig.enableTools
        ? ToolRegistry(
            ledgerTools(
              view,
              shareInvoiceItems: aiConfig.shareInvoiceItems,
              clock: clock,
            ),
          )
        : null;
    return AuraAgent(
      client: clientFactory(aiConfig, _apiKey),
      tools: tools,
      stream: aiConfig.stream,
      systemPrompt: auraSystemPrompt(
        today: clock(),
        toolsEnabled: tools != null,
      ),
    );
  }
}

/// "房租・NT$15,000" style name for a recurring item.
String recurringLabel(LedgerReader l, Recurring r) {
  final t = r.template;
  final what = t.kind == TxnKind.transfer
      ? '轉帳 ${l.account(t.accountId!)?.name ?? '？'} → ${l.account(t.toAccountId!)?.name ?? '？'}'
      : t.note ?? (t.categoryId == null ? '未分類' : l.category(t.categoryId!)?.name ?? '未分類');
  return what;
}

sealed class ChatItem {
  const ChatItem();
}

class UserChatItem extends ChatItem {
  const UserChatItem(this.text);
  final String text;
}

class ToolChatItem extends ChatItem {
  ToolChatItem(this.call);
  final ToolCall call;
  ToolRunResult? result;
}

class ReplyChatItem extends ChatItem {
  ReplyChatItem(this.text, {this.usage, this.writing = false});
  String text;
  TokenUsage? usage;

  /// Still streaming in.
  bool writing;
}

class ErrorChatItem extends ChatItem {
  const ErrorChatItem(this.message);
  final String message;
}

/// The assistant conversation, kept across tab switches.
class AssistantSession extends ChangeNotifier {
  AssistantSession(this._app);

  final AppState _app;
  final items = <ChatItem>[];
  AuraAgent? _agent;
  bool busy = false;

  void reset() {
    _agent = null;
    items.clear();
    busy = false;
    notifyListeners();
  }

  Future<void> send(String text) async {
    final question = text.trim();
    if (question.isEmpty || busy) return;
    final agent = _agent ??= _app.newAgent();
    items.add(UserChatItem(question));
    busy = true;
    notifyListeners();
    final running = <String, ToolChatItem>{};
    ReplyChatItem? writing;
    await for (final event in agent.ask(question)) {
      if (!identical(agent, _agent)) return; // reset mid-flight
      switch (event) {
        case AgentText(:final delta):
          if (writing == null) items.add(writing = ReplyChatItem('', writing: true));
          writing.text += delta;
        case AgentToolStarted(:final call):
          // Words before a tool call ("let me look that up") stay as they are.
          if (writing != null) {
            writing.writing = false;
            if (writing.text.trim().isEmpty) items.remove(writing);
            writing = null;
          }
          final item = ToolChatItem(call);
          running[call.id] = item;
          items.add(item);
        case AgentToolFinished(:final result):
          running[result.call.id]?.result = result;
        case AgentReply(:final text, :final usage):
          final reply = writing ?? ReplyChatItem('');
          if (writing == null) items.add(reply);
          reply
            ..text = text.isEmpty ? '（AI 沒有回覆內容）' : text
            ..usage = usage
            ..writing = false;
          writing = null;
        case AgentFailed(:final message):
          if (writing != null && writing.text.trim().isEmpty) items.remove(writing);
          writing?.writing = false;
          writing = null;
          items.add(ErrorChatItem(message));
      }
      notifyListeners();
    }
    busy = false;
    notifyListeners();
  }
}

String _two(int n) => n.toString().padLeft(2, '0');
