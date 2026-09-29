import 'dart:io';

import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_ai/aura_ai.dart';
import 'package:aura_core/aura_core.dart';
import 'package:aura_store/aura_store.dart';
import 'package:decimal/decimal.dart';
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

  group('opening balances', () {
    Future<AppState> imported(WidgetTester tester) async {
      final app = await _app();
      await tester.runAsync(() => app.importCwmoney(_sample, 'sample.csv'));
      return app;
    }

    testWidgets('accounts list totals and flags unset balances', (tester) async {
      _tallScreen(tester);
      await tester.pumpWidget(AuraApp(app: await imported(tester)));
      await tester.tap(find.text('帳戶'));
      await tester.pumpAndSettle();
      // TWD accounts: 2,880 − 25,645 − 1,865 + 100,000 − 1,874.5 = 73,495.5;
      // −1,000 USD at 32.37 and −10,000 JPY at 0.201 (their newest records).
      expect(tester.widget<Text>(find.byKey(const Key('netWorth'))).data, 'NT\$39,116');
      expect(find.text('1 USD = NT\$32.37（2026/09/22 的紀錄）'), findsOneWidget);
      expect(find.text('1 JPY = NT\$0.201（2026/09/20 的紀錄）'), findsOneWidget);
      expect(find.textContaining('有 7 個帳戶還沒設定餘額'), findsOneWidget);
    });

    testWidgets("entering today's balance derives the opening balance", (tester) async {
      _tallScreen(tester);
      final app = await imported(tester);
      await tester.pumpWidget(AuraApp(app: app));
      await tester.tap(find.text('帳戶'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('活存-測試'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('balanceAmount')), '200,000');
      await tester.pump();
      expect(find.text('NT\$225,645'), findsOneWidget); // opening preview
      expect(find.text('NT\$200,000'), findsOneWidget);

      await tester.tap(find.byKey(const Key('saveAccount')));
      await tester.pumpAndSettle();
      expect(find.text('期初 NT\$225,645'), findsOneWidget);
      expect(find.textContaining('有 6 個帳戶還沒設定餘額'), findsOneWidget);
      final savings = app.ledger.accounts.firstWhere((a) => a.name == '活存-測試');
      expect(savings.anchor!.date, DateTime(2026, 9, 29));
    });

    testWidgets('an opening balance can be entered directly', (tester) async {
      _tallScreen(tester);
      final app = await imported(tester);
      await tester.pumpWidget(AuraApp(app: app));
      await tester.tap(find.text('帳戶'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('活存-測試'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('期初'));
      await tester.enterText(find.byKey(const Key('balanceAmount')), '1000');
      await tester.pump();
      expect(
        tester.widget<Text>(find.descendant(of: find.byKey(const Key('previewCurrent')), matching: find.byType(Text)).last).data,
        '-NT\$24,645',
      );
      await tester.tap(find.byKey(const Key('saveAccount')));
      await tester.pumpAndSettle();
      final savings = app.ledger.accounts.firstWhere((a) => a.name == '活存-測試');
      expect(savings.anchor!.date, DateTime(2026, 9, 20)); // day before first record
    });
  });

  test('re-importing keeps balances the new file can still support', () async {
    final app = await _app(ledger: SqliteLedger.inMemory());
    addTearDown(app.ledger.close);
    await app.importCwmoney(_sample, 'sample.csv');
    String id(String name) => app.ledger.accounts.firstWhere((a) => a.name == name).id;
    final today = BalanceAnchor(amount: Decimal.fromInt(200000), date: DateTime(2026, 9, 29));
    final ancient = BalanceAnchor(amount: Decimal.fromInt(1), date: DateTime(2020, 1, 1));
    app.setBalanceAnchor(id('活存-測試'), today);
    app.setBalanceAnchor(id('現金'), ancient);

    await app.importCwmoney(_sample, 'sample.csv');
    expect(app.anchorsKept, ['活存-測試']);
    expect(app.anchorsDropped, ['現金']);
    expect(app.ledger.account(id('活存-測試'))!.anchor, today);
    expect(app.ledger.account(id('現金'))!.anchor, isNull);
    expect(app.balances[id('活存-測試')]!.current, Decimal.fromInt(200000));
  });

  group('account type and currency', () {
    Future<AppState> openAccount(WidgetTester tester, String name) async {
      _tallScreen(tester);
      final app = await _app();
      await tester.runAsync(() => app.importCwmoney(_sample, 'sample.csv'));
      await tester.pumpWidget(AuraApp(app: app));
      await tester.tap(find.text('帳戶'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, name));
      await tester.pumpAndSettle();
      return app;
    }

    Future<void> choose(WidgetTester tester, Key field, String option) async {
      await tester.tap(find.byKey(field));
      await tester.pumpAndSettle();
      await tester.tap(find.text(option).last);
      await tester.pumpAndSettle();
    }

    testWidgets('changing the type regroups the account', (tester) async {
      final app = await openAccount(tester, '股票-測試');
      await choose(tester, const Key('accountType'), '銀行');
      await tester.tap(find.byKey(const Key('saveAccount')));
      await tester.pumpAndSettle();
      final account = app.ledger.accounts.firstWhere((a) => a.name == '股票-測試');
      expect(account.type, AccountType.bank);
      expect(account.anchor, isNull, reason: 'balance untouched');
      expect(find.text('證券'), findsNothing, reason: 'no securities left');
    });

    testWidgets('changing the currency relabels the balance without converting it', (tester) async {
      final app = await openAccount(tester, '定存-測試');
      await choose(tester, const Key('accountCurrency'), 'USD 美元');
      expect(find.text('只會更改幣別標示，金額數字不會換算。'), findsOneWidget);
      await tester.tap(find.byKey(const Key('saveAccount')));
      await tester.pumpAndSettle();
      expect(app.ledger.accounts.firstWhere((a) => a.name == '定存-測試').currency, 'USD');
      // Its records were in NT$, so the newest "USD" record now implies a
      // rate of 1: TWD −26,504.5, USD 99,000 × 1, JPY −2,010.
      expect(find.text('1 USD = NT\$1（2026/09/23 的紀錄）'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('netWorth'))).data, 'NT\$70,486');
    });

    testWidgets('any ISO code can be typed; invalid ones cannot be saved', (tester) async {
      final app = await openAccount(tester, '現金');
      await choose(tester, const Key('accountCurrency'), '其他…');
      await tester.enterText(find.byKey(const Key('customCurrency')), 'my');
      await tester.pump();
      expect(find.text('請輸入三個英文字母'), findsOneWidget);
      final save = find.byKey(const Key('saveAccount'));
      expect(tester.widget<TextButton>(save).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('customCurrency')), 'myr');
      await tester.pump();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(app.ledger.accounts.firstWhere((a) => a.name == '現金').currency, 'MYR');
    });

    testWidgets('an unknown currency is flagged and must be chosen', (tester) async {
      _tallScreen(tester);
      final app = await _app();
      app.ledger.replaceAll(
        InMemoryLedger(
          accounts: const [
            Account(id: 'a', name: '外幣帳戶', type: AccountType.bank, currency: unknownCurrency),
          ],
        ),
      );
      await tester.pumpWidget(AuraApp(app: app));
      await tester.tap(find.text('帳戶'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 個外幣帳戶無法從名稱判斷幣別'), findsOneWidget);
      expect(find.textContaining('幣別未知'), findsOneWidget);
      await tester.tap(find.text('外幣帳戶'));
      await tester.pumpAndSettle();
      expect(find.text('請選擇幣別'), findsOneWidget);
      expect(tester.widget<TextButton>(find.byKey(const Key('saveAccount'))).onPressed, isNull);
    });
  });

  test('re-importing keeps corrected types and currencies', () async {
    final app = await _app(ledger: SqliteLedger.inMemory());
    addTearDown(app.ledger.close);
    await app.importCwmoney(_sample, 'sample.csv');
    String id(String name) => app.ledger.accounts.firstWhere((a) => a.name == name).id;
    app.updateAccount(id('股票-測試'), type: AccountType.bank, currency: 'USD');
    await app.importCwmoney(_sample, 'sample.csv');
    final stock = app.ledger.account(id('股票-測試'))!;
    expect(stock.type, AccountType.bank);
    expect(stock.currency, 'USD');
    expect(app.ledger.account(id('現金'))!.type, AccountType.cash, reason: 'others as guessed');
  });
}
