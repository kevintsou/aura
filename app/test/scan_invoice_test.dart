import 'dart:io';

import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/screens/scan_invoice.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _sample = File('../packages/aura_core/test/fixtures/sample_cwmoney.csv').readAsBytesSync();

String _left(String seller) =>
    'CD11112222' '1150929' '5678' '00000064' '00000069' '00000000' '$seller'
    'abcdefghijklmnopqrstuvwx:**********:2:2:1:茶葉蛋:2:10:鮮奶:1:85';

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
}
