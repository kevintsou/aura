import 'dart:convert';

import 'package:aura_ai/aura_ai.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the AI connection. The config is ordinary preferences; API
/// keys go to the platform keystore (Keychain / Android Keystore), one
/// per preset so switching presets does not lose a key.
abstract interface class AiSettingsStore {
  Future<AiEndpointConfig> loadConfig();
  Future<String?> loadApiKey(AiPreset preset);
  Future<void> saveConfig(AiEndpointConfig config);

  /// Null or empty [apiKey] deletes the stored key.
  Future<void> saveApiKey(AiPreset preset, String? apiKey);
}

class DeviceAiSettingsStore implements AiSettingsStore {
  static const _configKey = 'ai_endpoint_config';
  final _secure = const FlutterSecureStorage();

  String _keyName(AiPreset preset) => 'ai_api_key_${preset.name}';

  @override
  Future<AiEndpointConfig> loadConfig() async {
    final raw = (await SharedPreferences.getInstance()).getString(_configKey);
    if (raw == null) return AiEndpointConfig.defaults;
    try {
      return AiEndpointConfig.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } on Object {
      return AiEndpointConfig.defaults;
    }
  }

  @override
  Future<String?> loadApiKey(AiPreset preset) =>
      _secure.read(key: _keyName(preset));

  @override
  Future<void> saveConfig(AiEndpointConfig config) async {
    await (await SharedPreferences.getInstance()).setString(
      _configKey,
      jsonEncode(config.toJson()),
    );
  }

  @override
  Future<void> saveApiKey(AiPreset preset, String? apiKey) =>
      apiKey == null || apiKey.isEmpty
      ? _secure.delete(key: _keyName(preset))
      : _secure.write(key: _keyName(preset), value: apiKey);
}

/// For tests and previews.
class MemoryAiSettingsStore implements AiSettingsStore {
  MemoryAiSettingsStore({this.config = AiEndpointConfig.defaults});

  AiEndpointConfig config;
  final keys = <AiPreset, String>{};

  @override
  Future<AiEndpointConfig> loadConfig() async => config;
  @override
  Future<String?> loadApiKey(AiPreset preset) async => keys[preset];
  @override
  Future<void> saveConfig(AiEndpointConfig config) async => this.config = config;
  @override
  Future<void> saveApiKey(AiPreset preset, String? apiKey) async =>
      apiKey == null || apiKey.isEmpty
      ? keys.remove(preset)
      : keys[preset] = apiKey;
}
