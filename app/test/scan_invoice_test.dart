import 'dart:convert';
import 'dart:io';

import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/screens/scan_invoice.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_ai/aura_ai.dart';
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _sample = File('../packages/aura_core/test/fixtures/sample_cwmoney.csv').readAsBytesSync();

String _left(String seller) =>
    'CD11112222' '1150929' '5678' '00000064' '00000069' '00000000' '$seller'
    'abcdefghijklmnopqrstuvwx:**********:2:2:1:茶葉蛋:2:10:鮮奶:1:85';

class _Client implements AiClient {
  _Client(this.answer);
  String answer;
  final asked = <String>[];

  @override
  Future<ChatCompletion> complete({required List<ChatMessage> messages, List<ToolSpec> tools = const []}) async {
    asked.add([for (final m in messages) jsonEncode(m.toWire())].join('\n'));
    return ChatCompletion(message: AssistantMessage(content: answer));
  }

  @override
  Future<List<String>> listModels() async => const [];
}

/// A store the ledger has never seen, selling coffee.
const _newShop =
    'EF33334444' '1150929' '1234' '00000061' '00000065' '00000000' '87654321'
    'abcdefghijklmnopqrstuvwx:**********:1:1:1:大杯拿鐵:1:65';

Future<AppState> _aiApp(WidgetTester tester, _Client client, {bool shareItems = true}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final config = AiEndpointConfig.defaults.copyWith(shareInvoiceItems: shareItems);
  final app = AppState(
    ledger: InMemoryLedger(),
    settings: MemoryAiSettingsStore(config: config)..keys[config.preset] = 'sk',
    clientFactory: (_, _) => client,
    clock: () => DateTime(2026, 9, 29, 8),
  );
  await app.load();
  app.startFresh();
  await tester.pumpWidget(AuraApp(app: app));
  await tester.pumpAndSettle();
  return app;
}

void main() {
  testWidgets('a scanned invoice opens as a filled-in record', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState(ledger: InMemoryLedger(), settings: MemoryAiSettingsStore(), clock: () => DateTime(2026, 9, 29, 8));
    await tester.runAsync(() async {
      await app.load();
      await app.importCwmoney(_sample, 'a.csv');
    });
    await tester.pumpWidget(AuraApp(app: app));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scanInvoice')), findsOneWidget);

    // A store the ledger has bought breakfast from before.
    final before = app.ledger.transactions().firstWhere((t) => t.invoice?.sellerTaxId != null);
    final seller = before.invoice!.sellerTaxId!;
    final context = tester.element(find.byType(Scaffold).first);
    openScannedInvoice(context, app, _left(seller), null);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, '記一筆'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('txnAmount'))).controller!.text, '105');
    expect(find.text('生活費 · 早餐'), findsOneWidget, reason: 'learned from the same seller');
    expect(find.text('2026/09/29'), findsOneWidget);
    expect(find.textContaining('發票 CD11112222・${before.invoice!.sellerName}'), findsOneWidget);
    expect(find.text('鮮奶 ×1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('saveTxn')));
    await tester.pumpAndSettle();

    final saved = app.ledger.transactions().firstWhere((t) => t.invoice?.number == 'CD11112222');
    expect((saved.baseAmount, saved.invoice!.items.length), (Decimal.fromInt(105), 2));

    // The same invoice again asks first.
    openScannedInvoice(context, app, _left(seller), null);
    await tester.pumpAndSettle();
    expect(find.text('這張發票已經記過了'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '記一筆'), findsNothing);
  });

  testWidgets('a shop never seen before: the AI can pick the category', (tester) async {
    final client = _Client('');
    final app = await _aiApp(tester, client);
    final drinks = app.ledger.categories.lastWhere((c) => c.kind == TxnKind.expense && c.parentId != null);
    client.answer = '{"category":"${drinks.id}"}';
    final context = tester.element(find.byType(Scaffold).first);
    openScannedInvoice(context, app, _newShop, null);
    await tester.pumpAndSettle();

    final before = tester.widget<ListTile>(find.byKey(const Key('txnCategory')));
    expect((before.title as Text).data, isNot(contains(drinks.name)));
    await tester.tap(find.byKey(const Key('aiCategory')));
    await tester.pumpAndSettle();
    expect(find.text('AI 建議的分類，點一下可以改'), findsOneWidget);
    expect(find.byKey(const Key('aiCategory')), findsNothing);
    final sent = client.asked.single;
    expect(sent, contains('大杯拿鐵'));
    expect(sent, isNot(contains('87654321')), reason: 'the seller tax id stays on the phone');
    await tester.tap(find.byKey(const Key('saveTxn')));
    await tester.pumpAndSettle();
    expect(app.ledger.transactions().single.categoryId, drinks.id);
  });

  testWidgets('no AI question without anything it may see', (tester) async {
    final client = _Client('{}');
    final app = await _aiApp(tester, client, shareItems: false);
    final context = tester.element(find.byType(Scaffold).first);
    openScannedInvoice(context, app, _newShop, null);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '記一筆'), findsOneWidget);
    expect(find.byKey(const Key('aiCategory')), findsNothing, reason: 'no seller name, items not shared');
  });

  testWidgets('the AI finding nothing leaves the choice to the user', (tester) async {
    final client = _Client('{"category":null}');
    final app = await _aiApp(tester, client);
    final context = tester.element(find.byType(Scaffold).first);
    openScannedInvoice(context, app, _newShop, null);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('aiCategory')));
    await tester.pumpAndSettle();
    expect(find.text('AI 沒有找到適合的分類，請自己選'), findsOneWidget);
    expect(find.byKey(const Key('aiCategory')), findsOneWidget, reason: 'can ask again');
  });
}
