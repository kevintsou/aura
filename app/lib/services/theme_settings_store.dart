import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeOption {
  light,
  dark,
  system;

  ThemeMode get mode => switch (this) {
    light => ThemeMode.light,
    dark => ThemeMode.dark,
    system => ThemeMode.system,
  };
}

abstract interface class ThemeSettingsStore {
  Future<AppThemeOption> load();
  Future<void> save(AppThemeOption mode);
}

class DeviceThemeSettingsStore implements ThemeSettingsStore {
  static const key = 'theme_mode';

  @override
  Future<AppThemeOption> load() async {
    final value = (await SharedPreferences.getInstance()).getString(key);
    if (value == 'mint') {
      await save(AppThemeOption.light);
      return AppThemeOption.light;
    }
    return AppThemeOption.values
            .where((mode) => mode.name == value)
            .firstOrNull ??
        AppThemeOption.light;
  }

  @override
  Future<void> save(AppThemeOption mode) async {
    await (await SharedPreferences.getInstance()).setString(key, mode.name);
  }
}

class MemoryThemeSettingsStore implements ThemeSettingsStore {
  AppThemeOption mode = AppThemeOption.light;

  @override
  Future<AppThemeOption> load() async => mode;

  @override
  Future<void> save(AppThemeOption mode) async => this.mode = mode;
}
