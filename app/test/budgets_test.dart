import 'dart:io';

import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _sample = File('../packages/aura_core/test/fixtures/sample_cwmoney.csv').readAsBytesSync();

InMemoryLedger _ledger() {
  var n = 0;
  Txn spend(DateTime date, String category, int amount) => Txn(
    id: 't${n++}',
    kind: TxnKind.expense,
    date: date,
    accountId: 'cash',
    categoryId: category,
    amount: Decimal.fromInt(amount),
    baseAmount: Decimal.fromInt(amount),
    note: '紀錄$n',
  );
  return InMemoryLedger(
    accounts: const [Account(id: 'cash', name: '現金', type: AccountType.cash, currency: 'TWD')],
    categories: const [
      Category(id: 'food', kind: TxnKind.expense, name: '生活費'),
      Category(id: 'lunch', kind: TxnKind.expense, name: '午餐', parentId: 'food'),
      Category(id: 'breakfast', kind: TxnKind.expense, name: '早餐', parentId: 'food'),
      Category(id: 'car', kind: TxnKind.expense, name: '行車交通'),
    ],
    transactions: [
      spend(DateTime(2026, 8, 20), 'lunch', 100),
      spend(DateTime(2026, 9, 3), 'lunch', 150),
      spend(DateTime(2026, 9, 4), 'breakfast', 50),
      spend(DateTime(2026, 9, 5), 'car', 300),
    ],
  );
}

Future<AppState> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = AppState(
    ledger: _ledger(),
    settings: MemoryAiSettingsStore(),
    clock: () => DateTime(2026, 9, 29),
  );
  await app.load();
  await tester.pumpWidget(AuraApp(app: app));
  await _tap(tester, find.text('設定'));
  await _tap(tester, find.byKey(const Key('manageBudgets')));
  return app;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _addBudget(WidgetTester tester, String amount, {String? category}) async {
  await _tap(tester, find.byKey(const Key('addBudget')));
  if (category != null) {
    await _tap(tester, find.byKey(const Key('budgetScope')));
    await _tap(tester, find.byKey(const Key('scopeCategory')));
    await _tap(tester, find.text(category));
  }
  await tester.enterText(find.byKey(const Key('budgetAmount')), amount);
  await _tap(tester, find.byKey(const Key('saveBudget')));
}

String _status(WidgetTester tester, int i) => tester
    .widgetList<Text>(
      find.descendant(of: find.byKey(const Key('budgetStatus')).at(i), matching: find.byType(Text)),
    )
    .map((t) => t.data)
    .join(' ');

void main() {
  testWidgets('a total budget shows what is left and a daily allowance', (tester) async {
    final app = await _open(tester);
    expect(find.text('還沒有預算'), findsOneWidget);

    await _tap(tester, find.byKey(const Key('addBudget')));
    expect(find.text('每月總預算（所有支出）'), findsOneWidget, reason: 'the total comes first');
    // June–August averaged (0 + 0 + 100) / 3, rounded up to a hundred.
    await _tap(tester, find.byKey(const Key('useSuggestion')));
    expect(find.text('100'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('budgetAmount')), '1,000');
    await _tap(tester, find.byKey(const Key('saveBudget')));

    expect(app.ledger.budgets.single.amount, Decimal.fromInt(1000));
    expect(app.ledger.budgets.single.categoryId, isNull);
    // 500 spent; 9/29 and 9/30 are left.
    expect(_status(tester, 0), '還剩 NT\$500・每天可花 NT\$250 50%');

    // The records tab shows it too.
    await _tap(tester, find.byType(BackButton));
    await _tap(tester, find.text('紀錄'));
    expect(find.byKey(const Key('budgetSummary')), findsOneWidget);
    expect(_status(tester, 0), '還剩 NT\$500・每天可花 NT\$250 50%');
  });

  testWidgets('a main category budget covers its subcategories and warns when over', (tester) async {
    final app = await _open(tester);
    await _addBudget(tester, '150', category: '整個生活費');
    expect(app.ledger.budgets.single.categoryId, 'food');
    expect(find.text('NT\$200 / NT\$150', findRichText: true), findsOneWidget);
    expect(_status(tester, 0), '超支 NT\$50 133%');
    expect(find.byIcon(Icons.error_outline), findsOneWidget, reason: 'not colour alone');

    // A second budget on the same category is not offered.
    await _tap(tester, find.byKey(const Key('addBudget')));
    await _tap(tester, find.byKey(const Key('budgetScope')));
    await _tap(tester, find.byKey(const Key('scopeCategory')));
    final taken = tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '整個生活費'));
    expect(taken.onSelected, isNull);
  });

  testWidgets('past months are final; edit and delete from the detail screen', (tester) async {
    final app = await _open(tester);
    await _addBudget(tester, '1000');
    await _tap(tester, find.byKey(const Key('prevBudgetMonth')));
    expect(tester.widget<Text>(find.byKey(const Key('budgetMonth'))).data, '2026 年 8 月');
    expect(_status(tester, 0), '沒有超支，剩下 NT\$900 10%');
    await _tap(tester, find.byKey(const Key('nextBudgetMonth')));

    await _tap(tester, find.text('每月總預算'));
    expect(find.byKey(const Key('budgetTrend')), findsOneWidget);
    expect(find.text('每個月都在預算內'), findsOneWidget);
    expect(find.text('這個月花在哪裡'), findsOneWidget);

    await _tap(tester, find.byKey(const Key('editBudget')));
    await tester.enterText(find.byKey(const Key('budgetAmount')), '400');
    await _tap(tester, find.byKey(const Key('saveBudget')));
    expect(app.ledger.budgets.single.amount, Decimal.fromInt(400));
    expect(find.text('有 1 個月超過目前的預算'), findsOneWidget);

    await _tap(tester, find.byKey(const Key('deleteBudget')));
    await _tap(tester, find.byKey(const Key('confirmOk')));
    expect(app.ledger.budgets, isEmpty);
    expect(find.text('還沒有預算'), findsOneWidget);
  });

  test('re-importing CWMoney keeps budgets whose category is still there', () async {
    final app = AppState(ledger: InMemoryLedger(), settings: MemoryAiSettingsStore());
    await app.importCwmoney(_sample, 'a.csv');
    String id(String name) => app.ledger.categories.firstWhere((c) => c.name == name).id;
    app
      ..setBudget(Budget(id: 'total', amount: Decimal.fromInt(9000)))
      ..setBudget(Budget(id: 'food', amount: Decimal.fromInt(3000), categoryId: id('生活費')))
      ..setBudget(Budget(id: 'lunch', amount: Decimal.fromInt(900), categoryId: id('午餐')));
    app.write((l) => l.addCategory(Category(id: 'pets', kind: TxnKind.expense, name: '寵物')));
    app.setBudget(Budget(id: 'pets', amount: Decimal.fromInt(500), categoryId: 'pets'));

    await app.importCwmoney(_sample, 'b.csv');
    expect(
      [for (final b in app.ledger.budgets) (b.id, b.categoryId == null ? null : app.ledger.category(b.categoryId!)!.name)],
      [('total', null), ('food', '生活費'), ('lunch', '午餐')],
    );
    expect(app.ledger.category(app.ledger.budgets[2].categoryId!)!.parentId, id('生活費'));
    expect(app.budgetsDropped, ['寵物']);
  });
}
