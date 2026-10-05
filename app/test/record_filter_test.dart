import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> choose(WidgetTester tester, String key, String label) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> apply(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('applyRecordsFilter')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('applyRecordsFilter')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('combined filters include dates, both transfer sides, archived accounts and keyword', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Txn txn(String id, DateTime date, {TxnKind kind = TxnKind.expense, String account = 'a', String? to}) => Txn(
      id: id,
      date: date,
      kind: kind,
      accountId: account,
      toAccountId: to,
      amount: Decimal.fromInt(100),
      baseAmount: Decimal.fromInt(100),
      note: id,
    );
    final ledger = InMemoryLedger(
      accounts: const [
        Account(id: 'a', name: '現金', type: AccountType.cash, currency: 'TWD'),
        Account(id: 'b', name: '銀行', type: AccountType.bank, currency: 'TWD', archived: true),
        Account(id: 'h', name: '秘密帳戶', type: AccountType.bank, currency: 'TWD', hidden: true),
      ],
      transactions: [
        txn('九月最後一天', DateTime(2026, 9, 30)),
        txn('十月第一天', DateTime(2026, 10, 1)),
        txn('十月最後一天', DateTime(2026, 10, 31)),
        txn('十一月', DateTime(2026, 11, 1)),
        txn('轉入測試', DateTime(2026, 10, 5), kind: TxnKind.transfer, to: 'b'),
        txn('隱藏', DateTime(2026, 10, 5), account: 'h'),
      ],
    );
    final app = AppState(ledger: ledger, settings: MemoryAiSettingsStore(), clock: () => DateTime(2026, 10, 5));
    await app.load();
    await tester.pumpWidget(AuraApp(app: app));
    await tester.pumpAndSettle();
    expect(find.text('紀錄（5 筆）'), findsOneWidget);
    await tester.tap(find.byKey(const Key('recordsFilter')));
    await tester.pumpAndSettle();
    expect(find.text('秘密帳戶'), findsNothing);
    await choose(tester, 'recordsPeriod', '本月');
    await apply(tester);
    expect(find.text('紀錄（3 筆）'), findsOneWidget);
    expect(find.textContaining('九月最後一天'), findsNothing);
    await tester.tap(find.byKey(const Key('recordsFilter')));
    await tester.pumpAndSettle();
    await choose(tester, 'recordsAccount', '銀行（已封存）');
    await choose(tester, 'recordsKind', '轉帳');
    await tester.enterText(find.byKey(const Key('recordsKeyword')), '轉入測試');
    await apply(tester);
    expect(find.text('紀錄（1 筆）'), findsOneWidget);
    expect(find.textContaining('轉入測試'), findsWidgets);
    await tester.tap(find.byKey(const Key('recordsFilter')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('recordsKeyword')), '不存在');
    await apply(tester);
    expect(find.text('沒有符合條件的紀錄'), findsOneWidget);
    await tester.tap(find.text('清除篩選'));
    await tester.pumpAndSettle();
    expect(find.text('紀錄（5 筆）'), findsOneWidget);
    await tester.tap(find.byKey(const Key('recordsFilter')));
    await tester.pumpAndSettle();
    await choose(tester, 'recordsPeriod', '上月');
    await apply(tester);
    expect(find.text('紀錄（1 筆）'), findsOneWidget);
    app.write((l) => l.addTxn(txn('新九月紀錄', DateTime(2026, 9, 1))));
    await tester.pumpAndSettle();
    expect(find.text('紀錄（2 筆）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('filter sheet works on narrow phones with enlarged text', (tester) async {
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final app = AppState(ledger: InMemoryLedger(), settings: MemoryAiSettingsStore());
    await app.load();
    await tester.pumpWidget(AuraApp(app: app));
    await tester.tap(find.byKey(const Key('recordsFilter')));
    await tester.pumpAndSettle();
    await choose(tester, 'recordsPeriod', '自訂日期');
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const Key('applyRecordsFilter'))).onPressed, isNull);
    await choose(tester, 'recordsPeriod', '本月');
    await apply(tester);
    expect(find.text('沒有符合條件的紀錄'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('filtered records retain the filter beyond the first 100 rows', (tester) async {
    final amount = Decimal.fromInt(10);
    final ledger = InMemoryLedger(
      accounts: const [Account(id: 'a', name: '現金', type: AccountType.cash, currency: 'TWD')],
      transactions: [
        for (var i = 0; i < 220; i++)
          Txn(
            id: 't$i',
            kind: TxnKind.income,
            accountId: 'a',
            date: DateTime(2026, 1, 1).add(Duration(days: i)),
            amount: amount,
            baseAmount: amount,
            note: i == 0 ? '搜尋頁尾' : (i.isEven ? '搜尋$i' : '排除$i'),
          ),
      ],
    );
    final app = AppState(ledger: ledger, settings: MemoryAiSettingsStore());
    await app.load();
    await tester.pumpWidget(AuraApp(app: app));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recordsFilter')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('recordsKeyword')), '搜尋');
    await apply(tester);
    expect(find.text('紀錄（110 筆）'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('搜尋頁尾'), 500, maxScrolls: 40);
    await tester.pumpAndSettle();
    expect(find.textContaining('搜尋頁尾'), findsOneWidget);
    expect(find.textContaining('排除'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
