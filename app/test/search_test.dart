import 'dart:io';

import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/screens/transactions_screen.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _sample = File('../packages/aura_core/test/fixtures/sample_cwmoney.csv').readAsBytesSync();

Future<AppState> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = AppState(ledger: InMemoryLedger(), settings: MemoryAiSettingsStore(), clock: () => DateTime(2026, 9, 29));
  await tester.runAsync(() async {
    await app.load();
    await app.importCwmoney(_sample, 'a.csv');
  });
  await tester.pumpWidget(AuraApp(app: app));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('openSearch')));
  await tester.pumpAndSettle();
  return app;
}

String _summary(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('searchSummary'))).data!;

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('searchField')), text);
  await tester.pump(const Duration(milliseconds: 350)); // debounce
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('finds records by words, in notes, sellers and invoice items', (tester) async {
    await _open(tester);
    expect(find.text('輸入關鍵字，或選擇日期、帳戶、分類、金額'), findsOneWidget);

    await _type(tester, '便當');
    expect(_summary(tester), '1 筆・支出 NT\$120');
    expect(find.text('生活費 · 午餐'), findsOneWidget);

    await _type(tester, '鮮奶'); // an invoice item
    expect(_summary(tester), startsWith('1 筆'));
    await _type(tester, '加油站'); // the seller
    expect(_summary(tester), '1 筆・支出 NT\$1,800');
    await _type(tester, '沒有這種東西');
    expect(find.text('找不到符合的紀錄'), findsOneWidget);
  });

  testWidgets('narrows by type, amount and account', (tester) async {
    final app = await _open(tester);
    await tester.tap(find.text('支出').first);
    await tester.pumpAndSettle();
    expect(_summary(tester), '${app.ledger.count(const TxnFilter(kinds: {TxnKind.expense}))} 筆・支出 NT\$4,010');

    await tester.tap(find.byKey(const Key('searchAmount')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('searchMin')), '2000'); // the wrong way round
    await tester.enterText(find.byKey(const Key('searchMax')), '100');
    await tester.tap(find.byKey(const Key('searchAmountOk')));
    await tester.pumpAndSettle();
    expect(find.text('NT\$100–NT\$2,000'), findsOneWidget);
    expect(_summary(tester), '2 筆・支出 NT\$1,920');

    final cash = app.ledger.accounts.firstWhere((a) => a.name == '現金');
    await tester.tap(find.byKey(const Key('searchAccounts')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('searchAccount-${cash.id}')));
    await tester.tap(find.byKey(const Key('searchAccountsOk')));
    await tester.pumpAndSettle();
    expect(_summary(tester), '1 筆・支出 NT\$120');

    // Clearing the amount brings the rest of the cash expenses back.
    await tester.tap(find.byTooltip('清除金額'));
    await tester.pumpAndSettle();
    expect(_summary(tester), startsWith('1 筆'));
  });

  testWidgets('hidden accounts stay hidden in search', (tester) async {
    final app = await _open(tester);
    final card = app.ledger.accounts.firstWhere((a) => a.name == '信用卡-測試');
    app.updateAccount(card.id, hidden: true);
    await _type(tester, '加油站');
    expect(find.text('找不到符合的紀錄'), findsOneWidget);
  });

  testWidgets('a long result list pages', (tester) async {
    final app = await _open(tester);
    final cash = app.ledger.accounts.firstWhere((a) => a.name == '現金');
    final cat = app.ledger.categories.firstWhere((c) => c.kind == TxnKind.expense);
    for (var i = 0; i < 130; i++) {
      app.saveTxn(
        Txn(
          id: 'many$i',
          kind: TxnKind.expense,
          date: DateTime(2026, 8, 1 + i % 28),
          accountId: cash.id,
          categoryId: cat.id,
          amount: Decimal.one,
          baseAmount: Decimal.one,
          note: '咖啡',
        ),
        isNew: true,
      );
    }
    await _type(tester, '咖啡');
    expect(_summary(tester), '130 筆・支出 NT\$130');
    await tester.scrollUntilVisible(
      find.byKey(const Key('searchMore')),
      500,
      scrollable: find.ancestor(of: find.byType(TxnTile).first, matching: find.byType(Scrollable)).first,
    );
    expect(find.text('再顯示 30 筆'), findsOneWidget);
  });
}
