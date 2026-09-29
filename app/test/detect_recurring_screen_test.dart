import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('repeating charges are offered as recurring items', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState(ledger: InMemoryLedger(), settings: MemoryAiSettingsStore(), clock: () => DateTime(2026, 9, 29));
    await app.load();
    app.startFresh();
    final cash = app.ledger.accounts.single.id;
    final cat = app.ledger.categories.firstWhere((c) => c.parentId == null).id;
    var n = 0;
    for (final (note, amount, day) in [('串流影音', 390, 5), ('健身房', 1200, 12)]) {
      for (var m = 5; m <= 9; m++) {
        app.saveTxn(
          Txn(
            id: 't${n++}',
            kind: TxnKind.expense,
            date: DateTime(2026, m, day),
            accountId: cash,
            categoryId: cat,
            amount: Decimal.fromInt(amount),
            baseAmount: Decimal.fromInt(amount),
            note: note,
          ),
          isNew: true,
        );
      }
    }
    await tester.pumpWidget(AuraApp(app: app));
    await tester.tap(find.text('設定'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manageRecurring')));
    await tester.pumpAndSettle();

    expect(find.text('看起來是固定收支'), findsOneWidget);
    expect(find.textContaining('每月 NT\$390・現金・已經 5 次'), findsOneWidget);
    final stream = app.recurringCandidates.firstWhere((c) => c.label == '串流影音');
    await tester.tap(find.byKey(Key('adopt-${stream.key}')));
    await tester.pumpAndSettle();
    expect(app.ledger.recurrings.single.next, DateTime(2026, 10, 5));
    expect(app.ledger.count(), 10, reason: 'nothing recorded again');
    expect(find.text('每月 5 日\n下次 2026/10/05'), findsOneWidget);

    await tester.tap(find.text('略過'));
    await tester.pumpAndSettle();
    expect(find.text('看起來是固定收支'), findsNothing);
    expect(app.recurringCandidates, isEmpty, reason: 'dismissal remembered');
  });
}
