/// Ready-made connection settings. Every preset speaks the OpenAI Chat
/// Completions protocol, so a user's own agent only has to do the same.
enum AiPreset {
  openAi(
    label: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-6-sol',
    requiresApiKey: true,
  ),
  openRouter(
    label: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    defaultModel: 'openai/gpt-6-sol',
    requiresApiKey: true,
  ),
  ollama(
    label: 'Ollama（本機）',
    baseUrl: 'http://localhost:11434/v1',
    defaultModel: 'qwen3',
    requiresApiKey: false,
  ),
  lmStudio(
    label: 'LM Studio（本機）',
    baseUrl: 'http://localhost:1234/v1',
    defaultModel: '',
    requiresApiKey: false,
  ),
  custom(
    label: '自訂 Agent API',
    baseUrl: '',
    defaultModel: '',
    requiresApiKey: false,
  );

  const AiPreset({
    required this.label,
    required this.baseUrl,
    required this.defaultModel,
    required this.requiresApiKey,
  });

  final String label;
  final String baseUrl;
  final String defaultModel;
  final bool requiresApiKey;

  static AiPreset byName(String? name) =>
      values.where((p) => p.name == name).firstOrNull ?? openAi;
}

/// Where and how Aura talks to the AI. The API key is deliberately not
/// part of this object: it lives in the platform's secure storage.
class AiEndpointConfig {
  const AiEndpointConfig({
    required this.preset,
    required this.baseUrl,
    required this.model,
    this.extraHeaders = const {},
    this.enableTools = true,
    this.shareInvoiceItems = true,
    this.stream = true,
    this.timeout = const Duration(seconds: 90),
  });

  factory AiEndpointConfig.fromPreset(AiPreset preset) => AiEndpointConfig(
    preset: preset,
    baseUrl: preset.baseUrl,
    model: preset.defaultModel,
  );

  static const defaults = AiEndpointConfig(
    preset: AiPreset.openAi,
    baseUrl: 'https://api.openai.com/v1',
    model: 'gpt-6-sol',
  );

  final AiPreset preset;

  /// Root of the API, e.g. `https://api.openai.com/v1`. Aura appends
  /// `/chat/completions` and `/models`.
  final String baseUrl;
  final String model;

  /// Sent with every request, e.g. an agent's own routing headers.
  final Map<String, String> extraHeaders;

  /// Offer Aura's ledger tools to the model. Turn off for endpoints
  /// without tool calling; the AI then only sees the conversation.
  final bool enableTools;

  /// Let tools return invoice line items (product names, quantities).
  final bool shareInvoiceItems;

  /// Show answers as they are written (`"stream": true`). Endpoints that
  /// cannot stream fall back to whole answers by themselves.
  final bool stream;

  /// For connecting, and for each pause while an answer streams in.
  final Duration timeout;

  /// Problems that make the configuration unusable, in Traditional Chinese.
  List<String> validate({required bool hasApiKey}) {
    final uri = Uri.tryParse(baseUrl.trim());
    return [
      if (uri == null || !uri.hasScheme || uri.host.isEmpty)
        '請輸入有效的 API 網址（例如 https://api.openai.com/v1）',
      if (uri != null && uri.scheme == 'http' && !_isLocalHost(uri.host))
        '非本機的網址必須使用 https，避免 API 金鑰外洩',
      if (model.trim().isEmpty) '請輸入模型名稱',
      if (preset.requiresApiKey && !hasApiKey) '${preset.label} 需要 API 金鑰',
    ];
  }

  static bool _isLocalHost(String host) =>
      host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '10.0.2.2' || // Android emulator's view of the host machine
      host.startsWith('192.168.') ||
      host.startsWith('10.') ||
      host.endsWith('.local');

  AiEndpointConfig copyWith({
    AiPreset? preset,
    String? baseUrl,
    String? model,
    Map<String, String>? extraHeaders,
    bool? enableTools,
    bool? shareInvoiceItems,
    bool? stream,
    Duration? timeout,
  }) => AiEndpointConfig(
    preset: preset ?? this.preset,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    extraHeaders: extraHeaders ?? this.extraHeaders,
    enableTools: enableTools ?? this.enableTools,
    shareInvoiceItems: shareInvoiceItems ?? this.shareInvoiceItems,
    stream: stream ?? this.stream,
    timeout: timeout ?? this.timeout,
  );

  Map<String, Object?> toJson() => {
    'preset': preset.name,
    'baseUrl': baseUrl,
    'model': model,
    'extraHeaders': extraHeaders,
    'enableTools': enableTools,
    'shareInvoiceItems': shareInvoiceItems,
    'stream': stream,
    'timeoutSeconds': timeout.inSeconds,
  };

  factory AiEndpointConfig.fromJson(Map<String, Object?> json) =>
      AiEndpointConfig(
        preset: AiPreset.byName(json['preset'] as String?),
        baseUrl: json['baseUrl'] as String? ?? defaults.baseUrl,
        model: json['model'] as String? ?? defaults.model,
        extraHeaders: {
          ...?(json['extraHeaders'] as Map?)?.map(
            (k, v) => MapEntry('$k', '$v'),
          ),
        },
        enableTools: json['enableTools'] as bool? ?? true,
        shareInvoiceItems: json['shareInvoiceItems'] as bool? ?? true,
        stream: json['stream'] as bool? ?? true,
        timeout: Duration(seconds: json['timeoutSeconds'] as int? ?? 90),
      );
}
