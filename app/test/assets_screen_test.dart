import 'dart:io';

import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _sample = File('../packages/aura_core/test/fixtures/sample_cwmoney.csv').readAsBytesSync();

void main() {
  testWidgets('net worth converts foreign accounts; a rate can be set by hand', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState(ledger: InMemoryLedger(), settings: MemoryAiSettingsStore(), clock: () => DateTime(2026, 9, 29));
    await tester.runAsync(() async {
      await app.load();
      await app.importCwmoney(_sample, 'a.csv');
    });
    await tester.pumpWidget(AuraApp(app: app));
    await tester.tap(find.text('帳戶'));
    await tester.pumpAndSettle();

    String net() => tester.widget<Text>(find.byKey(const Key('netWorth'))).data!;
    expect(find.byKey(const Key('rate-USD')), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('accountRates')));
    await tester.tap(find.byKey(const Key('accountRates')));
    await tester.pumpAndSettle();
    expect(find.text('1 USD = NT\$32.37（2026/09/22 的紀錄）'), findsOneWidget);
    final before = net();
    final usd = app.balances.values.firstWhere((b) => b.account.currency == 'USD').current;

    await tester.tap(find.byKey(const Key('rate-USD')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('askText')), '30');
    await tester.tap(find.byKey(const Key('askTextOk')));
    await tester.pumpAndSettle();
    expect(find.text('1 USD = NT\$30（自訂）'), findsOneWidget);
    final diff = (usd * Decimal.parse('2.37')).round(scale: 0);
    String digits(String s) => s.replaceAll(RegExp(r'[^\d-]'), '');
    expect(
      (Decimal.parse(digits(before)) - Decimal.parse(digits(net()))).abs(),
      diff.abs(),
      reason: 'the USD balance is now worth 2.37 less per dollar',
    );
    expect(app.ledger.meta('fx.USD'), '30', reason: 'kept with the ledger, so backups have it');
  });
}
