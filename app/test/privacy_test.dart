import 'dart:io';

import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/screens/privacy_screen.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the policy splits into title, headings, bullets and paragraphs', () {
    final blocks = markdownBlocks('# 標題\n\n第一行\n接著\n\n## 小節\n\n- 一\n- 二\n');
    expect([for (final b in blocks) (b.kind, b.text)], [
      (MdKind.title, '標題'),
      (MdKind.paragraph, '第一行接著'),
      (MdKind.heading, '小節'),
      (MdKind.bullet, '一'),
      (MdKind.bullet, '二'),
    ]);
  });

  test('the published policy states what the app does', () {
    final text = File(PrivacyScreen.asset).readAsStringSync();
    for (final must in ['沒有伺服器', '載具號碼和賣方統編一律不送', '只限 Aura 自己建立的檔案', '預設關閉', 'Keychain', '整機備份']) {
      expect(text, contains(must));
    }
  });

  testWidgets('opens from settings', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState(ledger: InMemoryLedger(), settings: MemoryAiSettingsStore());
    await app.load();
    app.startFresh();
    await tester.pumpWidget(AuraApp(app: app));
    await tester.tap(find.text('設定').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('privacyPolicy')), 200, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.byKey(const Key('privacyPolicy')));
    await tester.pumpAndSettle();
    expect(find.text('Aura 記帳 隱私權政策'), findsOneWidget);
    expect(find.text('什麼時候資料會離開手機'), findsOneWidget);
  });
}
