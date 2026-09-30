import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<(AppState, Category, Category)> _app(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = AppState(ledger: InMemoryLedger(), settings: MemoryAiSettingsStore(), clock: () => DateTime(2026, 9, 15));
  await app.load();
  app.startFresh();
  final cash = app.ledger.accounts.single.id;
  final mains = app.ledger.categories.where((c) => c.kind == TxnKind.expense && c.parentId == null).toList();
  final (big, small) = (mains[0], mains[1]);
  final pay = app.ledger.categories.firstWhere((c) => c.kind == TxnKind.income);
  var n = 0;
  void add(DateTime d, Category c, int amount) => app.saveTxn(
    Txn(
      id: 's${n++}',
      kind: c.kind,
      date: d,
      accountId: cash,
      categoryId: c.id,
      amount: Decimal.fromInt(amount),
      baseAmount: Decimal.fromInt(amount),
    ),
    isNew: true,
  );
  for (final m in [6, 7, 8]) {
    for (var i = 1; i <= 10; i++) {
      add(DateTime(2026, m, i), big, 300);
    }
    add(DateTime(2026, m, 20), small, 1000);
    add(DateTime(2026, m, 5), pay, 40000);
  }
  await tester.pumpWidget(AuraApp(app: app));
  await tester.tap(find.text('報表'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('openBudgets')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('openSimulation')));
  await tester.pumpAndSettle();
  return (app, big, small);
}

String _text(WidgetTester tester, Key key) => tester.widget<Text>(find.byKey(key)).data!;

void main() {
  testWidgets('try spending less and see the saving', (tester) async {
    final (_, big, _) = await _app(tester);
    expect(find.text('省錢試算'), findsOneWidget);
    expect(find.text('用 2026/6–2026/8 這 3 個月的平均來算'), findsOneWidget);
    // Starts on the biggest category, 10% less.
    expect(find.text('平均每月 NT\$3,000・約 10 次・每次約 NT\$300'), findsOneWidget);
    expect(find.textContaining(big.name), findsWidgets);
    expect(_text(tester, const Key('monthlySaving')), 'NT\$300');
    expect(_text(tester, const Key('yearlySaving')), '一年省 NT\$3,600');

    // Three times fewer a month instead.
    await tester.tap(find.text('每月少幾次'));
    await tester.pumpAndSettle();
    final slider = find.byKey(const Key('changeAmount'));
    tester.widget<Slider>(slider).onChanged!(3);
    await tester.pumpAndSettle();
    expect(_text(tester, const Key('changeSaving')), '每月省 NT\$900');
    expect(_text(tester, const Key('monthlySaving')), 'NT\$900');
    expect(find.text('NT\$4,000'), findsOneWidget, reason: 'spending before');
    expect(find.text('NT\$3,100'), findsOneWidget, reason: 'spending after');
    expect(find.text('90%'), findsOneWidget, reason: 'savings rate before');
    expect(find.text('92%'), findsOneWidget, reason: 'savings rate after');
  });

  testWidgets('a plan becomes budgets', (tester) async {
    final (app, big, _) = await _app(tester);
    tester.widget<Slider>(find.byKey(const Key('changeAmount'))).onChanged!(50);
    await tester.pumpAndSettle();
    expect(_text(tester, const Key('monthlySaving')), 'NT\$1,500');
    await tester.tap(find.byKey(const Key('applyAsBudgets')));
    await tester.pumpAndSettle();
    expect(find.text('設成每月預算？'), findsOneWidget);
    await tester.tap(find.text('設定'));
    await tester.pumpAndSettle();
    final budget = app.ledger.budgets.single;
    expect((budget.categoryId, budget.amount), (big.id, Decimal.fromInt(1500)));
    expect(find.text('已設定 1 個預算'), findsOneWidget);
  });

  testWidgets('the AI can weigh the plan', (tester) async {
    final (app, _, _) = await _app(tester);
    await tester.tap(find.byKey(const Key('askAiPlan')));
    await tester.pumpAndSettle();
    expect(app.tab.value, AppState.assistantTab);
    expect(find.text('接上你自己的 AI'), findsOneWidget, reason: 'not set up in this test');
  });
}
