import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura/services/reminders.dart';
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('reminderTimes', () {
    const nine = (hour: 21, minute: 0);
    test('today first when it is still ahead and nothing is recorded', () {
      final t = reminderTimes(DateTime(2026, 9, 29, 8), nine, recordedToday: false, days: 3);
      expect(t, [DateTime(2026, 9, 29, 21), DateTime(2026, 9, 30, 21), DateTime(2026, 10, 1, 21)]);
    });
    test('from tomorrow once recorded or past the time', () {
      final recorded = reminderTimes(DateTime(2026, 9, 29, 8), nine, recordedToday: true, days: 2);
      expect(recorded, [DateTime(2026, 9, 30, 21), DateTime(2026, 10, 1, 21)]);
      final late = reminderTimes(DateTime(2026, 9, 29, 22), nine, recordedToday: false, days: 2);
      expect(late, [DateTime(2026, 9, 30, 21), DateTime(2026, 10, 1, 21)]);
      expect(reminderTimes(DateTime(2026, 12, 31, 23), nine, recordedToday: false, days: 1), [DateTime(2027, 1, 1, 21)]);
    });
  });

  testWidgets('turned on in settings; recording today skips today', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final reminders = MemoryReminders();
    final app = AppState(
      ledger: InMemoryLedger(),
      settings: MemoryAiSettingsStore(),
      clock: () => DateTime(2026, 9, 29, 8),
      reminders: reminders,
    );
    await app.load();
    app.startFresh();
    await tester.pumpWidget(AuraApp(app: app));
    await tester.tap(find.text('設定').last);
    await tester.pumpAndSettle();
    expect(reminders.scheduled, isEmpty, reason: 'off by default');

    await tester.tap(find.byKey(const Key('reminderSwitch')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('確定'));
    await tester.pumpAndSettle();
    expect(app.reminderTime, (hour: 21, minute: 0));
    expect(find.text('每天 21:00，當天記過帳就不提醒'), findsOneWidget);
    expect(reminders.scheduled.first, DateTime(2026, 9, 29, 21));
    expect(reminders.scheduled, hasLength(7));

    // Recording today moves the first reminder to tomorrow...
    final cash = app.ledger.accounts.single.id;
    final cat = app.ledger.categories.firstWhere((c) => c.kind == TxnKind.expense).id;
    final lunch = Txn(
      id: 't1',
      kind: TxnKind.expense,
      date: DateTime(2026, 9, 29),
      accountId: cash,
      categoryId: cat,
      amount: Decimal.fromInt(120),
      baseAmount: Decimal.fromInt(120),
    );
    expect(app.saveTxn(lunch, isNew: true), isNull);
    await tester.pumpAndSettle();
    expect(reminders.scheduled.first, DateTime(2026, 9, 30, 21));
    // ...and deleting it brings today's back.
    expect(app.deleteTxn('t1'), isNull);
    await tester.pumpAndSettle();
    expect(reminders.scheduled.first, DateTime(2026, 9, 29, 21));

    // A recurring item recording by itself does not count.
    app.ledger.addTxn(
      Txn(
        id: 'r@2026-09-29',
        kind: TxnKind.expense,
        date: DateTime(2026, 9, 29),
        accountId: cash,
        categoryId: cat,
        amount: Decimal.one,
        baseAmount: Decimal.one,
        recurringId: 'r',
      ),
    );
    expect(app.recordedToday, isFalse);

    await tester.tap(find.byKey(const Key('reminderSwitch')));
    await tester.pumpAndSettle();
    expect(app.reminderTime, isNull);
    expect(reminders.scheduled, isEmpty);
  });

  testWidgets('without permission it stays off and says why', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final reminders = MemoryReminders(allowed: false);
    final app = AppState(ledger: InMemoryLedger(), settings: MemoryAiSettingsStore(), reminders: reminders);
    await app.load();
    app.startFresh();
    await tester.pumpWidget(AuraApp(app: app));
    await tester.tap(find.text('設定').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reminderSwitch')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('確定'));
    await tester.pumpAndSettle();
    expect(app.reminderTime, isNull);
    expect(find.textContaining('沒有通知權限'), findsOneWidget);
  });
}
