import 'dart:io';

import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_ai/aura_ai.dart';
import 'package:aura_core/aura_core.dart';
import 'package:aura_store/aura_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _sample = File(
  '../packages/aura_core/test/fixtures/sample_cwmoney.csv',
).readAsBytesSync();

class _FakeClient implements AiClient {
  _FakeClient(this.replies);
  final List<ChatCompletion> replies;
  final configs = <AiEndpointConfig>[];
  var calls = 0;

  @override
  Future<ChatCompletion> complete({
    required List<ChatMessage> messages,
    List<ToolSpec> tools = const [],
  }) async => replies[calls++ % replies.length];

  @override
  Future<List<String>> listModels() async => ['gpt-a', 'gpt-b'];
}

Future<AppState> _app({
  AiEndpointConfig? config,
  String? key,
  _FakeClient? client,
  LedgerStore? ledger,
}) async {
  final store = MemoryAiSettingsStore(config: config ?? AiEndpointConfig.defaults);
  if (key != null) store.keys[(config ?? AiEndpointConfig.defaults).preset] = key;
  final fake = client ?? _FakeClient([const ChatCompletion(message: AssistantMessage(content: 'OK'))]);
  final app = AppState(
    ledger: ledger ?? InMemoryLedger(),
    settings: store,
    clientFactory: (c, k) {
      fake.configs.add(c);
      return fake;
    },
    clock: () => DateTime(2026, 9, 29),
  );
  await app.load();
  return app;
}

/// A tall phone screen, so whole forms fit without scrolling.
void _tallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _openAiSettings(WidgetTester tester) async {
  _tallScreen(tester);
  await tester.tap(find.text('設定').last);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('aiSettings')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('assistant asks the user to connect an AI first', (tester) async {
    await tester.pumpWidget(AuraApp(app: await _app()));
    await tester.tap(find.text('AI 助理'));
    await tester.pumpAndSettle();
    expect(find.text('接上你自己的 AI'), findsOneWidget);
  });

  testWidgets('choosing a preset fills in its URL and model', (tester) async {
    await tester.pumpWidget(AuraApp(app: await _app()));
    await _openAiSettings(tester);
    await tester.tap(find.text('Ollama（本機）'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'http://localhost:11434/v1'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'qwen3'), findsOneWidget);
  });

  testWidgets('OpenAI cannot be saved without an API key', (tester) async {
    final app = await _app();
    await tester.pumpWidget(AuraApp(app: app));
    await _openAiSettings(tester);
    await tester.tap(find.text('儲存'));
    await tester.pumpAndSettle();
    // Shown inline and in a snackbar.
    expect(find.text('OpenAI 需要 API 金鑰'), findsNWidgets(2));
    expect(app.aiReady, isFalse);
  });

  testWidgets('a custom agent endpoint is tested and saved', (tester) async {
    final app = await _app();
    await tester.pumpWidget(AuraApp(app: app));
    await _openAiSettings(tester);
    await tester.tap(find.text('自訂 Agent API'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('baseUrl')), 'https://agent.example.com/v1');
    await tester.enterText(find.byKey(const Key('model')), 'family-finance-agent');
    await tester.enterText(find.byKey(const Key('apiKey')), 'secret');

    await tester.tap(find.byKey(const Key('testConnection')));
    await tester.pumpAndSettle();
    expect(find.textContaining('連線成功'), findsOneWidget);

    await tester.tap(find.text('儲存'));
    await tester.pumpAndSettle();
    expect(app.aiReady, isTrue);
    expect(app.aiConfig.preset, AiPreset.custom);
    expect(app.aiConfig.baseUrl, 'https://agent.example.com/v1');
    expect(await app.settings.loadApiKey(AiPreset.custom), 'secret');
    expect(find.textContaining('自訂 Agent API · family-finance-agent'), findsOneWidget);
  });

  testWidgets('assistant runs tools locally and shows what was sent', (tester) async {
    final client = _FakeClient([
      const ChatCompletion(
        message: AssistantMessage(
          toolCalls: [
            ToolCall(
              id: 'c1',
              name: 'aggregate_transactions',
              argumentsJson: '{"group_by":"main_category","date_from":"2026-09-01","date_to":"2026-09-30"}',
            ),
          ],
        ),
      ),
      const ChatCompletion(message: AssistantMessage(content: '九月支出 NT\$4,010，最多是購物娛樂。')),
    ]);
    final app = await _app(key: 'sk-test', client: client);
    expect(await tester.runAsync(() => app.importCwmoney(_sample, 'sample.csv')), isNull);
    await tester.pumpWidget(AuraApp(app: app));
    await tester.tap(find.text('AI 助理'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('這個月花最多錢的是哪些分類？'));
    await tester.pumpAndSettle();
    expect(find.text('彙總收支'), findsOneWidget);
    expect(find.text('九月支出 NT\$4,010，最多是購物娛樂。'), findsOneWidget);

    await tester.tap(find.text('彙總收支'));
    await tester.pumpAndSettle();
    expect(find.text('送給 AI 的資料'), findsOneWidget);
    expect(find.textContaining('"total": 4010'), findsOneWidget);
  });

  testWidgets('imported records are listed with a review banner', (tester) async {
    final app = await _app();
    await tester.runAsync(() => app.importCwmoney(_sample, 'sample.csv'));
    await tester.pumpWidget(AuraApp(app: app));
    await tester.pumpAndSettle();
    expect(find.text('紀錄（11 筆）'), findsOneWidget);
    expect(find.text('有 1 筆轉帳只找到一邊，請確認'), findsOneWidget);
    expect(find.text('生活費 · 早餐'), findsOneWidget);
  });

  test('an import is saved in SQLite and survives a restart', () async {
    final dir = Directory.systemTemp.createTempSync('aura_app');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/aura.db';

    final first = await _app(ledger: SqliteLedger.open(path));
    expect(await first.importCwmoney(_sample, 'sample.csv'), isNull);
    first.ledger.close();

    final second = await _app(ledger: SqliteLedger.open(path));
    addTearDown(second.ledger.close);
    expect(second.ledger.count(), 11);
    expect(second.importedFileName, 'sample.csv');
    expect(second.ledger.transactions(const TxnFilter(keyword: '茶葉蛋')), hasLength(1));
  });

  test('a rejected file leaves the saved ledger alone', () async {
    final app = await _app(ledger: SqliteLedger.inMemory());
    addTearDown(app.ledger.close);
    await app.importCwmoney(_sample, 'sample.csv');
    final error = await app.importCwmoney('<!doctype html><table>'.codeUnits, 'old.csv');
    expect(error, contains('HTML'));
    expect(app.ledger.count(), 11);
    expect(app.importedFileName, 'sample.csv');
  });
}
