import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_ai/aura_ai.dart';
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeClient implements AiClient {
  final asked = <String>[];

  @override
  Future<ChatCompletion> complete({required List<ChatMessage> messages, List<ToolSpec> tools = const []}) async {
    asked.add(messages.whereType<UserMessage>().last.content);
    return const ChatCompletion(message: AssistantMessage(content: '九月花得比平常多。'));
  }

  @override
  Future<List<String>> listModels() async => const [];
}

Future<AppState> _app({_FakeClient? client}) async {
  final store = MemoryAiSettingsStore(config: AiEndpointConfig.defaults);
  if (client != null) store.keys[AiEndpointConfig.defaults.preset] = 'secret';
  final app = AppState(
    ledger: InMemoryLedger(),
    settings: store,
    clientFactory: (_, _) => client ?? _FakeClient(),
    clock: () => DateTime(2026, 9, 29),
  );
  await app.load();
  app.startFresh();
  final cash = app.ledger.accounts.single.id;
  final cats = app.ledger.categories.where((c) => c.parentId == null && c.kind == TxnKind.expense).toList();
  var n = 0;
  void spend(DateTime date, Category cat, int amount, [String? note]) => app.saveTxn(
    Txn(
      id: 't${n++}',
      kind: TxnKind.expense,
      date: date,
      accountId: cash,
      categoryId: cat.id,
      amount: Decimal.fromInt(amount),
      baseAmount: Decimal.fromInt(amount),
      note: note,
    ),
    isNew: true,
  );
  for (final m in [6, 7, 8]) {
    spend(DateTime(2026, m, 10), cats[0], 3000);
    spend(DateTime(2026, m, 12), cats[1], 1000);
  }
  spend(DateTime(2026, 9, 10), cats[0], 3000);
  spend(DateTime(2026, 9, 12), cats[1], 4000);
  spend(DateTime(2026, 9, 25), cats[0], 180, '便當');
  spend(DateTime(2026, 9, 25), cats[0], 180, '便當');
  return app;
}

void _tallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('a possible double entry is flagged on the records tab', (tester) async {
    _tallScreen(tester);
    final app = await _app();
    await tester.pumpWidget(AuraApp(app: app));
    await tester.pumpAndSettle();

    expect(find.textContaining('可能重複記帳：便當 NT\$180'), findsOneWidget);
    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
    expect(find.text('可能重複的紀錄'), findsOneWidget);
    expect(find.text('2 筆'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    await tester.tap(find.text('不是重複'));
    await tester.pumpAndSettle();
    expect(find.textContaining('可能重複記帳'), findsNothing);
    expect(app.recentDuplicates, isEmpty);
    expect(app.insightsFor(Period.month(2026, 9)).where((i) => i.kind == InsightKind.duplicate), isEmpty);
  });

  testWidgets('the monthly report lists what stands out and links to it', (tester) async {
    _tallScreen(tester);
    final app = await _app();
    await tester.pumpWidget(AuraApp(app: app));
    await tester.tap(find.text('報表'));
    await tester.pumpAndSettle();

    expect(find.text('9 月重點'), findsOneWidget);
    expect(find.textContaining('支出 NT\$7,360，比上月多 84%'), findsOneWidget);
    final cat = app.ledger.categories.where((c) => c.parentId == null && c.kind == TxnKind.expense).elementAt(1);
    final jump = find.text('${cat.name} NT\$4,000，比平常多 NT\$3,000（前三個月平均 NT\$1,000）');
    expect(jump, findsOneWidget);
    expect(find.textContaining('是不是重複記帳'), findsOneWidget);

    await tester.tap(jump);
    await tester.pumpAndSettle();
    expect(find.textContaining(cat.name), findsWidgets);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('是不是重複記帳'));
    await tester.pumpAndSettle();
    expect(find.text('2 筆'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    // Without an AI connection the button leads to setting one up.
    await tester.tap(find.byKey(const Key('askAiReport')));
    await tester.pumpAndSettle();
    expect(app.tab.value, AppState.assistantTab);
    expect(find.text('接上你自己的 AI'), findsOneWidget);
    expect(app.assistant.items, isEmpty);
  });

  testWidgets('the assistant writes the month up from the highlights', (tester) async {
    _tallScreen(tester);
    final client = _FakeClient();
    final app = await _app(client: client);
    await tester.pumpWidget(AuraApp(app: app));
    await tester.tap(find.text('報表'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('askAiReport')));
    await tester.pumpAndSettle();

    expect(app.tab.value, AppState.assistantTab);
    expect(client.asked.single, startsWith('請幫我寫 2026 年 9 月的月報'));
    expect(client.asked.single, contains('- 支出 NT\$7,360'));
    expect(find.text('九月花得比平常多。'), findsOneWidget);
  });
}
