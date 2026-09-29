import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

var _today = DateTime(2026, 9, 29, 9);

Future<AppState> _open(WidgetTester tester, {void Function(AppState)? setUp}) async {
  _today = DateTime(2026, 9, 29, 9);
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = AppState(ledger: InMemoryLedger(), settings: MemoryAiSettingsStore(), clock: () => _today);
  await app.load();
  app.startFresh();
  setUp?.call(app);
  await tester.pumpWidget(const SizedBox()); // a fresh app each time
  await tester.pumpWidget(AuraApp(app: app));
  await tester.pumpAndSettle();
  return app;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, Key field, String option) async {
  await _tap(tester, find.byKey(field));
  await _tap(tester, find.text(option).last);
}

String _preview(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('repeatPreview'))).data!;

Recurring _rent(AppState app, {DateTime? start}) {
  final cash = app.ledger.accounts.single;
  final rent = app.ledger.categories.firstWhere((c) => c.parentId == null && c.kind == TxnKind.expense);
  final date = start ?? DateTime(2026, 7, 5);
  return Recurring(
    id: 'rent',
    template: Txn(
      id: 'rent',
      kind: TxnKind.expense,
      date: date,
      accountId: cash.id,
      categoryId: rent.id,
      amount: Decimal.fromInt(15000),
      baseAmount: Decimal.fromInt(15000),
      note: '房租',
    ),
    unit: RepeatUnit.month,
    next: date,
  );
}

void main() {
  testWidgets('a new record can repeat monthly, a set number of times', (tester) async {
    final app = await _open(tester);
    await _tap(tester, find.byKey(const Key('addTxn')));
    await tester.enterText(find.byKey(const Key('txnAmount')), '2000');
    await tester.enterText(find.byKey(const Key('txnNote')), '手機分期');
    await _choose(tester, const Key('txnRepeat'), '每月');
    expect(find.text('新增週期收支'), findsOneWidget);
    expect(find.text('開始日期'), findsOneWidget);
    expect(_preview(tester), '每月 29 日。沒有 29 日的月份記在月底。儲存後會記入到今天為止的 1 筆');

    await _choose(tester, const Key('repeatEnd'), '共幾次');
    await tester.enterText(find.byKey(const Key('repeatTimes')), '3');
    await tester.pump();
    expect(_preview(tester), startsWith('每月 29 日，共 3 次。'));
    await _tap(tester, find.byKey(const Key('saveTxn')));

    expect(find.text('已記入 1 筆，下次 2026/10/29'), findsOneWidget);
    final r = app.ledger.recurrings.single;
    expect((r.times, r.next, r.template.amount), (3, DateTime(2026, 10, 29), Decimal.fromInt(2000)));
    final t = app.ledger.transactions().single;
    expect((t.date, t.note, t.recurringId), (DateTime(2026, 9, 29), '手機分期', r.id));
    expect(find.byIcon(Icons.event_repeat), findsOneWidget, reason: 'marked in the list');

    // Two more months pass; the app is brought back.
    _today = DateTime(2026, 12, 1);
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pumpAndSettle();
    expect(find.text('已自動記入 2 筆週期收支'), findsOneWidget);
    expect(app.ledger.count(), 3);
    expect(app.ledger.recurrings.single.next, isNull, reason: 'all 3 recorded');
  });

  testWidgets('records what came due while the app was closed', (tester) async {
    final app = await _open(tester, setUp: (app) => app.saveRecurring(_rent(app)));
    // saveRecurring already caught up; opening again adds nothing.
    expect(app.ledger.count(), 3);
    expect(find.textContaining('已自動記入'), findsNothing);

    final later = await _open(
      tester,
      setUp: (app) => app.write((l) => l.setRecurring(_rent(app))),
    );
    expect(find.text('已自動記入 3 筆週期收支'), findsOneWidget);
    expect(later.ledger.recurrings.single.next, DateTime(2026, 10, 5));
  });

  testWidgets('edit and delete from the list; records made stay', (tester) async {
    final app = await _open(tester, setUp: (app) => app.saveRecurring(_rent(app)));
    await _tap(tester, find.text('設定'));
    await _tap(tester, find.byKey(const Key('manageRecurring')));
    expect(find.text('房租'), findsOneWidget);
    expect(find.text('每月 5 日\n下次 2026/10/05'), findsOneWidget);

    await _tap(tester, find.text('房租'));
    expect(find.text('編輯週期收支'), findsOneWidget);
    expect(find.text('不重複'), findsNothing);
    await tester.enterText(find.byKey(const Key('txnAmount')), '16000');
    await tester.pump();
    expect(_preview(tester), '每月 5 日。下次 2026/10/05 自動記入', reason: 'no catching up again');
    await _tap(tester, find.byKey(const Key('saveTxn')));
    expect(app.ledger.recurrings.single.template.amount, Decimal.fromInt(16000));
    expect(app.ledger.count(), 3);
    expect(app.ledger.transactions().first.amount, Decimal.fromInt(15000), reason: 'past records unchanged');

    await _tap(tester, find.text('房租'));
    await _tap(tester, find.byKey(const Key('deleteTxn')));
    await _tap(tester, find.byKey(const Key('confirmOk')));
    expect(app.ledger.recurrings, isEmpty);
    expect(app.ledger.count(), 3);
    expect(app.ledger.transactions().every((t) => t.recurringId == null), isTrue);
    // The three rent records left behind now look like a pattern again.
    expect(find.text('看起來是固定收支'), findsOneWidget);
  });

  testWidgets('a recorded occurrence links to its recurring item', (tester) async {
    await _open(tester, setUp: (app) => app.saveRecurring(_rent(app)));
    await _tap(tester, find.text('生活費').first);
    expect(find.text('編輯紀錄'), findsOneWidget);
    expect(find.byKey(const Key('txnRepeat')), findsNothing, reason: 'one record cannot start repeating');
    await _tap(tester, find.byKey(const Key('openRecurring')));
    expect(find.text('編輯週期收支'), findsOneWidget);
  });

  testWidgets('accounts a recurring item uses cannot be deleted', (tester) async {
    final app = await _open(tester, setUp: (app) => app.saveRecurring(_rent(app, start: DateTime(2026, 12, 1))));
    final error = app.write((l) => l.deleteAccount(app.ledger.accounts.single.id));
    expect(error, contains('週期收支'));
  });
}
