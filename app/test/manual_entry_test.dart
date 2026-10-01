import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _today = DateTime(2026, 9, 29);

Future<AppState> _start(WidgetTester tester, {bool fresh = true}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = AppState(
    ledger: InMemoryLedger(),
    settings: MemoryAiSettingsStore(),
    clock: () => _today,
  );
  await app.load();
  await tester.pumpWidget(AuraApp(app: app));
  if (fresh) {
    await tester.tap(find.byKey(const Key('startFresh')));
    await tester.pumpAndSettle();
  }
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

Decimal _balance(AppState app, String name) =>
    app.balances[app.ledger.accounts.firstWhere((a) => a.name == name).id]!.current;

Future<void> _addAccount(WidgetTester tester, String name, {String? balance, String? currency}) async {
  await _tap(tester, find.text('帳戶'));
  await _tap(tester, find.byKey(const Key('addAccount')));
  await tester.enterText(find.byKey(const Key('newAccountName')), name);
  if (currency != null) await _choose(tester, const Key('accountCurrency'), currency);
  if (balance != null) {
    await tester.enterText(find.byKey(const Key('newAccountBalance')), balance);
  }
  await tester.pump();
  await _tap(tester, find.byKey(const Key('saveNewAccount')));
  await _tap(tester, find.text('紀錄'));
}

void main() {
  testWidgets('a blank app offers to start fresh or import', (tester) async {
    final app = await _start(tester, fresh: false);
    expect(find.text('從頭開始記帳'), findsOneWidget);
    expect(find.text('匯入 CSV'), findsOneWidget);
    expect(find.byKey(const Key('addTxn')), findsNothing);
    expect(app.isBlank, isTrue);
  });

  testWidgets('starting fresh creates categories and a cash account', (tester) async {
    final app = await _start(tester);
    expect(app.ledger.accounts.single.name, '現金');
    expect(app.ledger.categories.where((c) => c.name == '午餐'), hasLength(1));
    expect(find.text('按「記一筆」新增第一筆紀錄。'), findsOneWidget);
    expect(find.byKey(const Key('addTxn')), findsOneWidget);
  });

  testWidgets('records an expense with a chosen category', (tester) async {
    final app = await _start(tester);
    await _tap(tester, find.byKey(const Key('addTxn')));
    expect(find.text('生活費 · 早餐'), findsOneWidget, reason: 'first category by default');

    await _tap(tester, find.byKey(const Key('txnCategory')));
    await _tap(tester, find.text('午餐'));
    await tester.enterText(find.byKey(const Key('txnAmount')), '120');
    await tester.enterText(find.byKey(const Key('txnNote')), '便當');
    await _tap(tester, find.byKey(const Key('saveTxn')));

    expect(find.text('紀錄（1 筆）'), findsOneWidget);
    expect(find.text('生活費 · 午餐'), findsOneWidget);
    expect(find.text('NT\$120'), findsOneWidget);
    expect(_balance(app, '現金'), Decimal.fromInt(-120));
    final t = app.ledger.transactions().single;
    expect((t.note, t.date, t.baseAmount), ('便當', _today, Decimal.fromInt(120)));

    // The next record starts with the same category and account.
    await _tap(tester, find.byKey(const Key('addTxn')));
    expect(find.text('生活費 · 午餐'), findsOneWidget);
  });

  testWidgets('asks for an amount before saving', (tester) async {
    await _start(tester);
    await _tap(tester, find.byKey(const Key('addTxn')));
    await _tap(tester, find.byKey(const Key('saveTxn')));
    expect(find.text('請輸入大於 0 的金額'), findsOneWidget);
  });

  testWidgets('income uses income categories', (tester) async {
    final app = await _start(tester);
    await _tap(tester, find.byKey(const Key('addTxn')));
    await _tap(tester, find.text('收入'));
    expect(find.text('工作收入 · 薪資收入'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('txnAmount')), '50000');
    await _tap(tester, find.byKey(const Key('saveTxn')));
    expect(_balance(app, '現金'), Decimal.fromInt(50000));
  });

  testWidgets('a new account with a balance, then a transfer', (tester) async {
    final app = await _start(tester);
    await _addAccount(tester, '台新銀行', balance: '10000');
    expect(_balance(app, '台新銀行'), Decimal.fromInt(10000));

    await _tap(tester, find.byKey(const Key('addTxn')));
    await _tap(tester, find.text('轉帳'));
    await tester.enterText(find.byKey(const Key('txnAmount')), '3000');
    await _choose(tester, const Key('txnFrom'), '台新銀行');
    await _choose(tester, const Key('txnTo'), '現金');
    await _tap(tester, find.byKey(const Key('saveTxn')));

    expect(find.text('轉帳 台新銀行 → 現金'), findsOneWidget);
    expect(_balance(app, '台新銀行'), Decimal.fromInt(7000));
    expect(_balance(app, '現金'), Decimal.fromInt(3000));
  });

  testWidgets('foreign-currency expenses are valued with a rate', (tester) async {
    final app = await _start(tester);
    await _addAccount(tester, '美金帳戶', currency: 'USD 美元');
    await _tap(tester, find.byKey(const Key('addTxn')));
    await tester.enterText(find.byKey(const Key('txnAmount')), '10');
    await _choose(tester, const Key('txnAccount'), '美金帳戶（USD）');
    await tester.enterText(find.byKey(const Key('txnRate')), '32.5');
    await tester.pump();
    expect(find.text('約 NT\$325'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('saveTxn')));
    final t = app.ledger.transactions().single;
    expect((t.amount, t.baseAmount, t.fxRateDisplay), (Decimal.fromInt(10), Decimal.fromInt(325), '32.5'));
    expect(_balance(app, '美金帳戶'), Decimal.fromInt(-10));
  });

  testWidgets('records can be edited and deleted', (tester) async {
    final app = await _start(tester);
    await _tap(tester, find.byKey(const Key('addTxn')));
    await tester.enterText(find.byKey(const Key('txnAmount')), '120');
    await _tap(tester, find.byKey(const Key('saveTxn')));

    await _tap(tester, find.text('NT\$120'));
    expect(find.text('編輯紀錄'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('txnAmount')), '150');
    await _tap(tester, find.byKey(const Key('saveTxn')));
    expect(find.text('NT\$150'), findsOneWidget);
    expect(app.ledger.count(), 1);

    await _tap(tester, find.text('NT\$150'));
    await _tap(tester, find.byKey(const Key('deleteTxn')));
    await _tap(tester, find.byKey(const Key('confirmOk')));
    expect(app.ledger.count(), 0);
    expect(find.text('按「記一筆」新增第一筆紀錄。'), findsOneWidget);
  });

  testWidgets('projects can be created while recording', (tester) async {
    final app = await _start(tester);
    await _tap(tester, find.byKey(const Key('addTxn')));
    await tester.enterText(find.byKey(const Key('txnAmount')), '5000');
    await _tap(tester, find.byType(DropdownButtonFormField<String?>));
    await _tap(tester, find.text('新增專案…').last);
    await tester.enterText(find.byKey(const Key('askText')), '日本旅遊');
    await _tap(tester, find.byKey(const Key('askTextOk')));
    expect(find.text('日本旅遊'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('saveTxn')));
    final t = app.ledger.transactions().single;
    expect(app.ledger.project(t.projectId!)!.name, '日本旅遊');
  });

  testWidgets('accounts can be renamed, archived and deleted', (tester) async {
    final app = await _start(tester);
    await _addAccount(tester, '舊帳戶');
    await _tap(tester, find.text('帳戶'));
    await _tap(tester, find.widgetWithText(ListTile, '舊帳戶'));
    await tester.enterText(find.byKey(const Key('accountName')), '現金');
    await tester.pump();
    await _tap(tester, find.byKey(const Key('saveAccount')));
    expect(find.text('已經有同名的帳戶'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('accountName')), '備用金');
    await tester.pump();
    await _tap(tester, find.byKey(const Key('saveAccount')));
    expect(find.widgetWithText(ListTile, '備用金'), findsOneWidget);

    await _tap(tester, find.widgetWithText(ListTile, '備用金'));
    await _tap(tester, find.byKey(const Key('accountMenu')));
    await _tap(tester, find.text('封存帳戶'));
    expect(find.text('已封存'), findsOneWidget);
    expect(app.activeAccounts.map((a) => a.name), ['現金']);

    await _tap(tester, find.widgetWithText(ListTile, '備用金'));
    await _tap(tester, find.byKey(const Key('accountMenu')));
    await _tap(tester, find.text('刪除帳戶'));
    await _tap(tester, find.byKey(const Key('confirmOk')));
    expect(app.ledger.accounts.map((a) => a.name), ['現金']);
  });

  testWidgets('categories can be added, renamed and protected when used', (tester) async {
    final app = await _start(tester);
    await _tap(tester, find.byKey(const Key('addTxn')));
    await tester.enterText(find.byKey(const Key('txnAmount')), '80');
    await _tap(tester, find.byKey(const Key('saveTxn'))); // uses 生活費 · 早餐

    await _tap(tester, find.text('設定'));
    await _tap(tester, find.byKey(const Key('manageCategories')));
    await _tap(tester, find.byKey(const Key('addMainCategory')));
    await tester.enterText(find.byKey(const Key('askText')), '寵物');
    await _tap(tester, find.byKey(const Key('askTextOk')));
    await _tap(tester, find.text('寵物'));
    await _tap(tester, find.byKey(const Key('addSubCategory')));
    await tester.enterText(find.byKey(const Key('askText')), '飼料');
    await _tap(tester, find.byKey(const Key('askTextOk')));
    expect(find.text('飼料'), findsOneWidget);
    await _tap(tester, find.byType(BackButton));

    await _tap(tester, find.text('生活費'));
    await _tap(tester, find.byKey(const Key('deleteMain')));
    await _tap(tester, find.byKey(const Key('confirmOk')));
    expect(find.textContaining('無法刪除'), findsOneWidget);

    await _tap(tester, find.text('午餐'));
    await tester.enterText(find.byKey(const Key('askText')), '中餐');
    await _tap(tester, find.byKey(const Key('askTextOk')));
    expect(app.ledger.categories.where((c) => c.name == '中餐'), hasLength(1));
    final pet = app.ledger.categories.firstWhere((c) => c.name == '寵物');
    expect(app.ledger.categories.where((c) => c.parentId == pet.id).single.name, '飼料');
  });
}
