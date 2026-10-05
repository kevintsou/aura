import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura/services/theme_settings_store.dart';
import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'device theme preference survives reopening and unknown values use system',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = DeviceThemeSettingsStore();
      expect(await store.load(), ThemeMode.system);
      await store.save(ThemeMode.dark);
      expect(await DeviceThemeSettingsStore().load(), ThemeMode.dark);
      await (await SharedPreferences.getInstance()).setString(
        DeviceThemeSettingsStore.key,
        'unknown',
      );
      expect(await store.load(), ThemeMode.system);
    },
  );

  testWidgets('settings switch the app between dark, light and system', (
    tester,
  ) async {
    final store = MemoryThemeSettingsStore();
    final app = AppState(
      ledger: InMemoryLedger(),
      settings: MemoryAiSettingsStore(),
      themeSettings: store,
    );
    await app.load();
    await tester.pumpWidget(AuraApp(app: app));
    await tester.tap(find.text('設定'));
    await tester.pumpAndSettle();
    for (final entry in {
      '深色': ThemeMode.dark,
      '淺色': ThemeMode.light,
      '跟隨系統': ThemeMode.system,
    }.entries) {
      await tester.tap(find.byKey(const Key('themeMode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry.key).last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        entry.value,
      );
      expect(await store.load(), entry.value);
      if (entry.value != ThemeMode.system) {
        expect(
          Theme.of(
            tester.element(find.byKey(const Key('themeMode'))),
          ).brightness,
          entry.value == ThemeMode.dark ? Brightness.dark : Brightness.light,
        );
      }
    }
  });
}
