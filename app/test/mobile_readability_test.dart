import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/screens/account_screen.dart';
import 'package:aura/screens/budgets_screen.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [320.0, 390.0]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets('phone $width with text $scale', (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final amount = Decimal.parse('123456789.12');
        final now = DateTime(2026, 10, 5);
        final ledger = InMemoryLedger(
          accounts: [
            Account(
              id: 'a',
              name: '主要銀行帳戶',
              type: AccountType.bank,
              currency: 'TWD',
              anchor: BalanceAnchor(amount: amount, date: DateTime(2026, 10, 1)),
            ),
          ],
          categories: const [Category(id: 'c', kind: TxnKind.income, name: '收入')],
          transactions: [
            Txn(
              id: 't',
              kind: TxnKind.income,
              date: now,
              accountId: 'a',
              categoryId: 'c',
              amount: amount,
              baseAmount: amount,
            ),
          ],
          budgets: [Budget(id: 'b', amount: amount)],
        );
        final app = AppState(ledger: ledger, settings: MemoryAiSettingsStore(), clock: () => now);
        await app.load();
        await tester.pumpWidget(AuraApp(app: app));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'records');
        for (final tab in [2, 1, 3, 4]) {
          app.tab.value = tab;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'tab $tab');
          if (tab == 1 || tab == 4) {
            for (var scroll = 0; scroll < 3; scroll++) {
              await tester.drag(find.byType(ListView).last, const Offset(0, -450));
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull, reason: 'tab $tab scroll $scroll');
            }
          }
        }
        final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
        nav.push(MaterialPageRoute<void>(builder: (_) => BudgetsScreen(app: app)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'budgets');
        nav.pop();
        await tester.pumpAndSettle();
        nav.push(
          MaterialPageRoute<void>(
            builder: (_) => AccountScreen(app: app, accountId: 'a'),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'account editor');
        await tester.drag(find.byType(ListView).last, const Offset(0, -1000));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'balance preview');
      });
    }
  }
}
