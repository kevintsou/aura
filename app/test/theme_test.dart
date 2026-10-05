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
    'device theme preference survives reopening and unknown values use white',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = DeviceThemeSettingsStore();
      expect(await store.load(), AppThemeOption.light);
      await store.save(AppThemeOption.dark);
      expect(await DeviceThemeSettingsStore().load(), AppThemeOption.dark);
      await (await SharedPreferences.getInstance()).setString(
        DeviceThemeSettingsStore.key,
        'unknown',
      );
      expect(await store.load(), AppThemeOption.light);
    },
  );

  test('stored light, dark and system preferences remain compatible', () async {
    for (final option in AppThemeOption.values) {
      SharedPreferences.setMockInitialValues({
        DeviceThemeSettingsStore.key: option.name,
      });
      expect(await DeviceThemeSettingsStore().load(), option);
    }
  });

  test(
    'legacy mint preference migrates to indigo light and persists',
    () async {
      SharedPreferences.setMockInitialValues({
        DeviceThemeSettingsStore.key: 'mint',
      });
      final store = DeviceThemeSettingsStore();
      final app = AppState(
        ledger: InMemoryLedger(),
        settings: MemoryAiSettingsStore(),
        themeSettings: store,
      );
      await app.load();
      expect(app.themeOption, AppThemeOption.light);
      expect(app.themeMode, ThemeMode.light);
      expect(
        (await SharedPreferences.getInstance()).getString(
          DeviceThemeSettingsStore.key,
        ),
        'light',
      );
      expect(await DeviceThemeSettingsStore().load(), AppThemeOption.light);
    },
  );

  testWidgets('settings switch the app between indigo light, dark and system', (
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
    expect(
      tester
          .widget<DropdownButton<AppThemeOption>>(
            find.byKey(const Key('themeMode')),
          )
          .items,
      hasLength(3),
    );
    expect(find.text('淺綠色'), findsNothing);
    for (final entry in {
      '淺色': AppThemeOption.light,
      '深色': AppThemeOption.dark,
      '跟隨系統': AppThemeOption.system,
    }.entries) {
      await tester.tap(find.byKey(const Key('themeMode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry.key).last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        entry.value.mode,
      );
      expect(await store.load(), entry.value);
      final theme = Theme.of(
        tester.element(find.byKey(const Key('themeMode'))),
      );
      if (entry.value == AppThemeOption.light) {
        expect(theme.scaffoldBackgroundColor, Colors.white);
        expect(theme.colorScheme.primary, const Color(0xFF283D70));
        expect(theme.colorScheme.primaryContainer, const Color(0xFFE5EAF7));
        expect(theme.colorScheme.surface, Colors.white);
        expect(theme.appBarTheme.surfaceTintColor, Colors.transparent);
        expect(theme.colorScheme.surfaceContainerLow, const Color(0xFFF8F9FA));
      }
      final reopened = AppState(
        ledger: InMemoryLedger(),
        settings: MemoryAiSettingsStore(),
        themeSettings: store,
      );
      await reopened.load();
      expect(reopened.themeOption, entry.value);
      if (entry.value != AppThemeOption.system) {
        expect(
          Theme.of(
            tester.element(find.byKey(const Key('themeMode'))),
          ).brightness,
          entry.value == AppThemeOption.dark
              ? Brightness.dark
              : Brightness.light,
        );
      }
    }
  });
}
