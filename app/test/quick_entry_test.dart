import 'dart:io';

import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _sample = File('../packages/aura_core/test/fixtures/sample_cwmoney.csv').readAsBytesSync();

Future<AppState> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = AppState(ledger: InMemoryLedger(), settings: MemoryAiSettingsStore(), clock: () => DateTime(2026, 9, 29, 12));
  await tester.runAsync(() async {
    await app.load();
    await app.importCwmoney(_sample, 'a.csv');
  });
  await tester.pumpWidget(AuraApp(app: app));
  await tester.pumpAndSettle();
  return app;
}

String _field(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

String _category(WidgetTester tester) =>
    (tester.widget<ListTile>(find.byKey(const Key('txnCategory'))).title! as Text).data!;

void main() {
  testWidgets('a note typed before completes, with its usual category, account and amount', (tester) async {
    final app = await _open(tester);
    await tester.tap(find.byKey(const Key('addTxn')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('txnNote')), '便');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('noteOption-0')), findsOneWidget);
    await tester.tap(find.byKey(const Key('noteOption-0')));
    await tester.pumpAndSettle();

    expect(_field(tester, 'txnNote'), '便當');
    expect(_category(tester), '生活費 · 午餐');
    expect(_field(tester, 'txnAmount'), '120');
    expect(find.byKey(const Key('applyUsual')), findsNothing, reason: 'already applied');
    await tester.tap(find.byKey(const Key('saveTxn')));
    await tester.pumpAndSettle();
    final lunches = app.ledger.transactions().where((t) => t.note == '便當').toList();
    expect(lunches, hasLength(2));
    expect(lunches.first.date, DateTime(2026, 9, 29));
    expect(lunches.first.accountId, lunches.last.accountId);
  });

  testWidgets('a note typed in full offers its usual entry', (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(const Key('addTxn')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('txnAmount')), '150');
    await tester.enterText(find.byKey(const Key('txnNote')), '便當');
    await tester.pumpAndSettle();
    final chip = find.byKey(const Key('applyUsual'));
    expect(find.descendant(of: chip, matching: find.text('上次：生活費 · 午餐・現金・NT\$120，套用')), findsOneWidget);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(_category(tester), '生活費 · 午餐');
    expect(_field(tester, 'txnAmount'), '150', reason: 'an amount already typed is kept');
    expect(chip, findsNothing);
  });

  testWidgets('a record can be copied to today', (tester) async {
    final app = await _open(tester);
    final before = app.ledger.count();
    await tester.tap(find.text('NT\$1,800'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('copyTxn')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '記一筆'), findsOneWidget);
    expect(_field(tester, 'txnAmount'), '1800');
    expect(find.text('2026/09/29'), findsOneWidget);
    await tester.tap(find.byKey(const Key('saveTxn')));
    await tester.pumpAndSettle();
    expect(app.ledger.count(), before + 1);
    final copy = app.ledger.transactions().firstWhere((t) => t.date == DateTime(2026, 9, 29));
    final original = app.ledger.transactions().firstWhere((t) => t.date == DateTime(2026, 9, 27));
    expect((copy.amount, copy.categoryId, copy.accountId), (Decimal.fromInt(1800), original.categoryId, original.accountId));
    expect(copy.invoice, isNull, reason: 'the invoice belongs to the original');
    expect(copy.legacyRows, isEmpty);
  });
}
