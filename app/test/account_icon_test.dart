import 'dart:io';
import 'dart:typed_data';
import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura/services/photo_picker.dart';
import 'package:aura/widgets/account_icon.dart';
import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class Picker implements PhotoPicker {
  @override
  bool get hasCamera => false;
  @override
  Future<Uint8List?> pick({required bool camera}) async => File('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@1x.png').readAsBytes();
}
void main() {
  testWidgets('choose, upload, back up and reset account icon', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState(ledger: InMemoryLedger(accounts: [const Account(id: 'a', name: '測試銀行', type: AccountType.bank, currency: 'TWD')]), settings: MemoryAiSettingsStore(), photoPicker: Picker());
    await app.load();
    await tester.pumpWidget(AuraApp(app: app));
    await tester.tap(find.text('帳戶'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('測試銀行').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('accountIcon-travel')));
    await tester.pumpAndSettle();
    expect(app.ledger.meta(accountIconKey('a')), isNull);
    await tester.tap(find.byKey(const Key('saveAccount')));
    await tester.pumpAndSettle();
    expect(app.ledger.meta(accountIconKey('a')), 'travel');
    await tester.tap(find.text('測試銀行').first);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('uploadAccountIcon')));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsWidgets);
    await tester.tap(find.byKey(const Key('saveAccount')));
    await tester.pumpAndSettle();
    final value = app.ledger.meta(accountIconKey('a'))!;
    expect(value, startsWith('image:'));
    final bytes = await encodeBackup(app.ledger, createdAt: DateTime(2026), meta: app.ledger.allMeta());
    final restored = await decodeBackup(bytes);
    expect(restored.meta[accountIconKey('a')], value);
    await tester.tap(find.text('測試銀行').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('依帳戶類型'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('saveAccount')));
    await tester.pumpAndSettle();
    expect(app.ledger.meta(accountIconKey('a')), isNull);
  });
}
