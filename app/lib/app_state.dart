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
    try {
      ledger.replaceAll(result.ledger);
    } on Exception catch (e) {
      return '寫入資料庫失敗：$e';
    }
    ledger
      ..setMeta(_metaImportFile, fileName)
      ..setMeta(_metaImportedAt, clock().toIso8601String());
    lastImport = result.report;
    revision++;
    assistant.reset();
    notifyListeners();
    return null;
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
