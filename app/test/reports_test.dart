import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

InMemoryLedger _ledger() {
  var n = 0;
  Txn txn(TxnKind kind, DateTime date, String category, int amount, String note) => Txn(
    id: 't${n++}',
    kind: kind,
    date: date,
    accountId: 'cash',
    categoryId: category,
    amount: Decimal.fromInt(amount),
    baseAmount: Decimal.fromInt(amount),
    note: note,
  );
  return InMemoryLedger(
    accounts: const [Account(id: 'cash', name: '現金', type: AccountType.cash, currency: 'TWD')],
    categories: const [
      Category(id: 'food', kind: TxnKind.expense, name: '生活費'),
      Category(id: 'lunch', kind: TxnKind.expense, name: '午餐', parentId: 'food'),
      Category(id: 'breakfast', kind: TxnKind.expense, name: '早餐', parentId: 'food'),
      Category(id: 'car', kind: TxnKind.expense, name: '行車交通'),
      Category(id: 'job', kind: TxnKind.income, name: '薪資收入'),
    ],
    transactions: [
      txn(TxnKind.expense, DateTime(2026, 8, 20), 'lunch', 100, '八月午餐'),
      txn(TxnKind.expense, DateTime(2026, 9, 3), 'lunch', 150, '便當'),
      txn(TxnKind.expense, DateTime(2026, 9, 4), 'breakfast', 50, '蛋餅'),
      txn(TxnKind.expense, DateTime(2026, 9, 5), 'car', 300, '加油'),
      txn(TxnKind.income, DateTime(2026, 9, 5), 'job', 1000, '薪水'),
    ],
  );
}

Future<void> _openReports(WidgetTester tester) async {
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
  await _tap(tester, find.text('報表'));
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  await tester.pumpAndSettle();
}

String _label(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('periodLabel'))).data!;

Finder _in(Key key, String text) => find.descendant(of: find.byKey(key), matching: find.text(text));

void main() {
  testWidgets('shows this month with totals and the change from last month', (tester) async {
    await _openReports(tester);
    expect(_label(tester), '2026 年 9 月');
    expect(_in(const Key('kpiExpense'), 'NT\$500'), findsOneWidget);
    expect(_in(const Key('kpiExpense'), '比上月多 400%'), findsOneWidget);
    expect(_in(const Key('kpiIncome'), 'NT\$1,000'), findsOneWidget);
    expect(_in(const Key('kpiNet'), 'NT\$500'), findsOneWidget);
    // Expense categories, largest first.
    final car = tester.getTopLeft(find.text('行車交通')).dy;
    final food = tester.getTopLeft(find.text('生活費')).dy;
    expect(car, lessThan(food));
    expect(find.text('60.0%'), findsOneWidget);
    expect(find.text('40.0%'), findsOneWidget);
  });

  testWidgets('steps between months and switches to the year', (tester) async {
    await _openReports(tester);
    await _tap(tester, find.byKey(const Key('prevPeriod')));
    expect(_label(tester), '2026 年 8 月');
    expect(_in(const Key('kpiExpense'), 'NT\$100'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('prevPeriod')));
    expect(find.text('2026 年 7 月沒有支出紀錄'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('nextPeriod')));
    await _tap(tester, find.byKey(const Key('nextPeriod')));
    expect(_label(tester), '2026 年 9 月');

    await _tap(tester, find.text('年'));
    expect(_label(tester), '2026 年');
    expect(_in(const Key('kpiExpense'), 'NT\$600'), findsOneWidget);
    expect(find.text('2026 年每月支出'), findsOneWidget);
    await _tap(tester, find.text('月'));
    expect(_label(tester), '2026 年 12 月');
  });

  testWidgets('tapping a column in the trend selects that month', (tester) async {
    final semantics = tester.ensureSemantics();
    await _openReports(tester);
    final chart = tester.getRect(find.byKey(const Key('trendChart')));
    // Twelve columns after a 44px axis; the eleventh is August.
    final slot = (chart.width - 44) / 12;
    await tester.tapAt(Offset(chart.left + 44 + slot * 10.5, chart.center.dy));
    await tester.pumpAndSettle();
    expect(_label(tester), '2026 年 8 月');
    expect(
      find.semantics.byLabel('2026年8月 NT\$100'),
      findsOne,
      reason: 'each column carries its month and amount for screen readers',
    );
    semantics.dispose();
  });

  testWidgets('income categories and drilling into subcategories', (tester) async {
    await _openReports(tester);
    await _tap(tester, _in(const Key('kindToggle'), '收入'));
    expect(find.text('薪資收入'), findsOneWidget);
    expect(find.text('近 12 個月收入'), findsOneWidget);
    await _tap(tester, _in(const Key('kindToggle'), '支出'));

    await _tap(tester, find.text('生活費'));
    expect(find.byKey(const Key('categoryTotal')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('categoryTotal'))).data, 'NT\$200');
    expect(find.text('2026 年 9 月・2 筆'), findsOneWidget);
    expect(find.text('75.0%'), findsOneWidget);
    expect(find.text('25.0%'), findsOneWidget);
    expect(find.text('午餐・便當'), findsOneWidget);
    expect(find.text('早餐・蛋餅'), findsOneWidget);
    expect(find.text('午餐・八月午餐'), findsNothing);

    // Opens the record for editing.
    await _tap(tester, find.text('午餐・便當'));
    expect(find.byKey(const Key('txnAmount')), findsOneWidget);
  });
}
