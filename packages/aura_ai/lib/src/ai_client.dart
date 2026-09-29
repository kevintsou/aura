import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'messages.dart';

/// The one interface Aura needs from any AI backend: OpenAI's hosted
/// models, a compatible gateway, a local model, or a user's own agent.
abstract interface class AiClient {
  Future<ChatCompletion> complete({
    required List<ChatMessage> messages,
    List<ToolSpec> tools = const [],
  });

  /// Model ids the endpoint offers (`GET /models`).
  Future<List<String>> listModels();
}

class AiClientException implements Exception {
  AiClientException(this.message, {this.statusCode});

  /// Human-readable, in Traditional Chinese where Aura wrote it.
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      statusCode == null ? message : '$message（HTTP $statusCode）';
}

/// Speaks the OpenAI Chat Completions protocol (`POST /chat/completions`
/// with `tools`), which OpenAI, OpenRouter, Ollama, LM Studio, vLLM and
/// most agent frameworks accept.
class OpenAiCompatibleClient implements AiClient {
  OpenAiCompatibleClient({
    required this.config,
    this.apiKey,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final AiEndpointConfig config;
  final String? apiKey;
  final http.Client _http;

  Uri _endpoint(String path) {
    final base = config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base/$path');
  }

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    if (apiKey != null && apiKey!.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    ...config.extraHeaders,
  };

  @override
  Future<ChatCompletion> complete({
    required List<ChatMessage> messages,
    List<ToolSpec> tools = const [],
  }) async {
    // Only portable fields: newer OpenAI models reject temperature and
    // max_tokens, so neither is sent.
    final body = {
      'model': config.model,
      'messages': [for (final m in messages) m.toWire()],
      if (tools.isNotEmpty) 'tools': [for (final t in tools) t.toWire()],
      if (tools.isNotEmpty) 'tool_choice': 'auto',
    };
    final json = await _send(
      () => _http.post(
        _endpoint('chat/completions'),
        headers: _headers,
        body: jsonEncode(body),
      ),
    );
    return _parseCompletion(json);
  }

  @override
  Future<List<String>> listModels() async {
    final json = await _send(
      () => _http.get(_endpoint('models'), headers: _headers),
    );
    final data = json['data'];
    if (data is! List) {
      throw AiClientException('這個端點沒有回傳模型清單，請直接輸入模型名稱');
    }
    return [
      for (final m in data)
        if (m is Map && m['id'] is String) m['id'] as String,
    ]..sort();
  }

  Future<Map<String, Object?>> _send(
    Future<http.Response> Function() request,
  ) async {
    final http.Response res;
    try {
      res = await request().timeout(config.timeout);
    } on TimeoutException {
      throw AiClientException('連線逾時（${config.timeout.inSeconds} 秒）');
    } on Exception catch (e) {
      throw AiClientException('無法連線到 ${config.baseUrl}：$e');
    }
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    Object? json;
    try {
      json = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      json = null;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw AiClientException(
        _errorMessage(res.statusCode, json, text),
        statusCode: res.statusCode,
      );
    }
    if (json is! Map<String, Object?>) {
      throw AiClientException('回應不是 JSON 物件，請確認網址是否指向 API 的根路徑（通常以 /v1 結尾）');
    }
    return json;
  }

  static String _errorMessage(int status, Object? json, String text) {
    final detail = switch (json) {
      {'error': {'message': final String m}} => m,
      {'error': final String m} => m,
      {'message': final String m} => m,
      _ => text.length > 200 ? '${text.substring(0, 200)}…' : text,
    };
    final hint = switch (status) {
      401 || 403 => 'API 金鑰無效或沒有權限',
      404 => '找不到端點或模型，請檢查網址和模型名稱',
      429 => '請求太頻繁或額度用完',
      _ => 'AI 服務回傳錯誤',
    };
    return detail.isEmpty ? hint : '$hint：$detail';
  }

  static ChatCompletion _parseCompletion(Map<String, Object?> json) {
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      throw AiClientException('回應裡沒有 choices，這個端點可能不相容 Chat Completions');
    }
    final choice = choices.first as Map;
    final message = choice['message'];
    if (message is! Map) {
      throw AiClientException('回應裡沒有 message');
    }
    final calls = <ToolCall>[];
    final rawCalls = message['tool_calls'];
    if (rawCalls is List) {
      for (final (i, c) in rawCalls.indexed) {
        if (c is! Map || c['function'] is! Map) continue;
        final fn = c['function'] as Map;
        final args = fn['arguments'];
        calls.add(
          ToolCall(
            id: c['id'] as String? ?? 'call_$i',
            name: fn['name'] as String? ?? '',
            argumentsJson: args is String ? args : jsonEncode(args ?? {}),
          ),
        );
      }
    }
    final usage = json['usage'];
    return ChatCompletion(
      message: AssistantMessage(
        content: message['content'] as String?,
        toolCalls: calls,
      ),
      finishReason: choice['finish_reason'] as String?,
      usage: usage is Map
          ? TokenUsage(
              inputTokens: (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
              outputTokens: (usage['completion_tokens'] as num?)?.toInt() ?? 0,
            )
          : null,
    );
  }
}
