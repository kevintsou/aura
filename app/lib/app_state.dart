import 'package:aura_ai/aura_ai.dart';
import 'package:aura_core/aura_core.dart';
import 'package:flutter/foundation.dart';

import 'services/ai_settings_store.dart';

typedef AiClientFactory =
    AiClient Function(AiEndpointConfig config, String? apiKey);

AiClient _defaultClient(AiEndpointConfig config, String? apiKey) =>
    OpenAiCompatibleClient(config: config, apiKey: apiKey);

const _metaImportFile = 'import.fileName';
const _metaImportedAt = 'import.at';

/// App-wide state: the ledger, the AI connection and the assistant
/// conversation. Plain ChangeNotifier until the app outgrows it.
class AppState extends ChangeNotifier {
  AppState({
    required this.ledger,
    required this.settings,
    this.clientFactory = _defaultClient,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  /// Persistent on devices (SQLite), in memory on the web and in tests.
  final LedgerStore ledger;
  final AiSettingsStore settings;
  final AiClientFactory clientFactory;
  final DateTime Function() clock;

  /// Bumped whenever ledger data changes, so views can drop caches.
  int revision = 0;
  CwmImportReport? lastImport;

  /// Accounts whose balance survived the last import, and those whose
  /// balance had to be dropped because the new file does not reach back
  /// to the date the balance was set for.
  List<String> anchorsKept = const [], anchorsDropped = const [];

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
  }) {
    ledger.updateAccount(
      accountId,
      name: name,
      type: type,
      currency: currency,
      archived: archived,
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
  List<Account> get activeAccounts =>
      [for (final a in ledger.accounts) if (!a.archived) a];

  String? get lastAccountId => ledger.meta('ui.lastAccount');
  String? lastCategoryId(TxnKind kind) =>
      ledger.meta('ui.lastCategory.${kind.name}');

  /// Adds or replaces [txn] and remembers its account and category as the
  /// defaults for the next record.
  String? saveTxn(Txn txn, {required bool isNew}) => write((l) {
    isNew ? l.addTxn(txn) : l.updateTxn(txn);
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

  Future<void> load() async {
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
    _carryOverAccountDetails(result.ledger);
    final (kept, dropped) = _carryOverAnchors(result.ledger);
    try {
      ledger.replaceAll(result.ledger);
    } on Exception catch (e) {
      return '寫入資料庫失敗：$e';
    }
    ledger
      ..setMeta(_metaImportFile, fileName)
      ..setMeta(_metaImportedAt, clock().toIso8601String());
    lastImport = result.report;
    anchorsKept = kept;
    anchorsDropped = dropped;
    revision++;
    assistant.reset();
    notifyListeners();
    return null;
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
      );
    }
  }

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

  AiClient clientFor(AiEndpointConfig config, String? apiKey) =>
      clientFactory(config, apiKey);

  AuraAgent newAgent() {
    final tools = aiConfig.enableTools
        ? ToolRegistry(
            ledgerTools(
              ledger,
              shareInvoiceItems: aiConfig.shareInvoiceItems,
              clock: clock,
            ),
          )
        : null;
    return AuraAgent(
      client: clientFactory(aiConfig, _apiKey),
      tools: tools,
      systemPrompt: auraSystemPrompt(
        today: clock(),
        toolsEnabled: tools != null,
      ),
    );
  }
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
  const ReplyChatItem(this.text, {this.usage});
  final String text;
  final TokenUsage? usage;
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
    await for (final event in agent.ask(question)) {
      if (!identical(agent, _agent)) return; // reset mid-flight
      switch (event) {
        case AgentToolStarted(:final call):
          final item = ToolChatItem(call);
          running[call.id] = item;
          items.add(item);
        case AgentToolFinished(:final result):
          running[result.call.id]?.result = result;
        case AgentReply(:final text, :final usage):
          items.add(ReplyChatItem(text.isEmpty ? '（AI 沒有回覆內容）' : text, usage: usage));
        case AgentFailed(:final message):
          items.add(ErrorChatItem(message));
      }
      notifyListeners();
    }
    busy = false;
    notifyListeners();
  }
}
