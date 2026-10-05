import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class ThemeSettingsStore {
  Future<ThemeMode> load();
  Future<void> save(ThemeMode mode);
}

class DeviceThemeSettingsStore implements ThemeSettingsStore {
  static const key = 'theme_mode';

  @override
  Future<ThemeMode> load() async {
    final value = (await SharedPreferences.getInstance()).getString(key);
    return ThemeMode.values.where((mode) => mode.name == value).firstOrNull ??
        ThemeMode.system;
  }

  @override
  Future<void> save(ThemeMode mode) async {
    await (await SharedPreferences.getInstance()).setString(key, mode.name);
  }
}

class MemoryThemeSettingsStore implements ThemeSettingsStore {
  ThemeMode mode = ThemeMode.system;

  @override
  Future<ThemeMode> load() async => mode;

  @override
  Future<void> save(ThemeMode mode) async => this.mode = mode;
}
