import 'dart:io';

import 'package:aura/app_state.dart';
import 'package:aura/lock/app_lock.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _sample = File('../packages/aura_core/test/fixtures/sample_cwmoney.csv').readAsBytesSync();

Future<AppState> _open(WidgetTester tester, {AppLock? lock}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = AppState(
    ledger: InMemoryLedger(),
    settings: MemoryAiSettingsStore(),
    lock: lock,
    clock: () => DateTime(2026, 9, 29, 21),
  );
  await tester.runAsync(() async {
    await app.load();
    await app.importCwmoney(_sample, 'a.csv');
  });
  await tester.pumpWidget(AuraApp(app: app));
  await tester.pumpAndSettle();
  return app;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a hidden account and its records leave lists, reports and the AI', (tester) async {
    final app = await _open(tester);
    expect(find.text('紀錄（11 筆）'), findsOneWidget);

    await _tap(tester, find.text('帳戶'));
    await _tap(tester, find.text('信用卡-測試'));
    await _tap(tester, find.byKey(const Key('accountHidden')));
    await _tap(tester, find.byType(BackButton));

    expect(find.text('信用卡-測試'), findsNothing);
    await _tap(tester, find.text('紀錄'));
    expect(find.text('紀錄（9 筆）'), findsOneWidget);
    expect(totalsFor(app.view, Period.month(2026, 9)).expense, Decimal.parse('2145'), reason: '4010 − 65 − 1800');
    expect(totalsFor(app.ledger, Period.month(2026, 9)).expense, Decimal.parse('4010'), reason: 'still stored');
    expect(app.view.accounts.map((a) => a.name), isNot(contains('信用卡-測試')));
    expect(app.activeAccounts.map((a) => a.name), isNot(contains('信用卡-測試')));

    // Shown again on request.
    await _tap(tester, find.text('帳戶'));
    await _tap(tester, find.byKey(const Key('toggleHidden')));
    expect(find.text('隱藏的帳戶'), findsOneWidget);
    expect(find.text('信用卡-測試'), findsOneWidget);
    expect(app.view.count(), 11);
    await _tap(tester, find.byKey(const Key('toggleHidden')));
    expect(find.text('信用卡-測試'), findsNothing);
  });

  testWidgets('showing hidden accounts needs the PIN when the lock is on', (tester) async {
    final store = MemoryLockStore();
    final lock = AppLock(store: store, iterations: 1000);
    await tester.runAsync(() async {
      await lock.setPin('2468');
    });
    final app = await _open(tester, lock: lock);
    app.updateAccount(app.ledger.accounts.firstWhere((a) => a.name == '現金').id, hidden: true);
    await tester.pumpAndSettle();

    await _tap(tester, find.text('帳戶'));
    await _tap(tester, find.byKey(const Key('toggleHidden')));
    expect(find.text('顯示隱藏的帳戶'), findsWidgets);
    for (final d in '2468'.split('')) {
      await tester.tap(find.byKey(Key('pin$d')));
      await tester.pump();
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(app.revealHidden, isTrue);
    expect(find.text('現金'), findsOneWidget);

    // Locking the app hides them again.
    await lock.setTimeout(LockTimeout.immediately);
    lock
      ..backgrounded()
      ..resumed();
    await tester.pumpAndSettle();
    expect(app.revealHidden, isFalse);
  });
}
