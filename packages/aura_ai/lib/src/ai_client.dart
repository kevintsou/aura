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

/// Piece of an answer as it streams in.
sealed class CompletionEvent {
  const CompletionEvent();
}

/// More text of the answer.
class CompletionText extends CompletionEvent {
  const CompletionText(this.delta);
  final String delta;
}

/// The whole answer, once the stream ends.
class CompletionDone extends CompletionEvent {
  const CompletionDone(this.completion);
  final ChatCompletion completion;
}

/// A backend that can send the answer as it is written.
abstract interface class StreamingAiClient implements AiClient {
  /// Text pieces, then exactly one [CompletionDone].
  Stream<CompletionEvent> completeStream({
    required List<ChatMessage> messages,
    List<ToolSpec> tools = const [],
  });
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
class OpenAiCompatibleClient implements StreamingAiClient {
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
    final json = await _send(
      () => _http.post(
        _endpoint('chat/completions'),
        headers: _headers,
        body: jsonEncode(_body(messages, tools)),
      ),
    );
    return _parseCompletion(json);
  }

  // Only portable fields: newer OpenAI models reject temperature and
  // max_tokens, so neither is sent.
  Map<String, Object?> _body(List<ChatMessage> messages, List<ToolSpec> tools, {bool stream = false}) => {
    'model': config.model,
    'messages': [for (final m in messages) m.toWire()],
    if (tools.isNotEmpty) 'tools': [for (final t in tools) t.toWire()],
    if (tools.isNotEmpty) 'tool_choice': 'auto',
    if (stream) 'stream': true,
    if (stream) 'stream_options': {'include_usage': true},
  };

  /// Server-sent events (`data: {...}` lines, then `data: [DONE]`), each
  /// carrying a `delta` of the message. Tool calls arrive in pieces too,
  /// keyed by index; they are put together before [CompletionDone].
  @override
  Stream<CompletionEvent> completeStream({
    required List<ChatMessage> messages,
    List<ToolSpec> tools = const [],
  }) async* {
    final request = http.Request('POST', _endpoint('chat/completions'))
      ..headers.addAll({..._headers, 'Accept': 'text/event-stream'})
      ..body = jsonEncode(_body(messages, tools, stream: true));
    final http.StreamedResponse res;
    try {
      res = await _http.send(request).timeout(config.timeout);
    } on TimeoutException {
      throw AiClientException('連線逾時（${config.timeout.inSeconds} 秒）');
    } on Exception catch (e) {
      throw AiClientException('無法連線到 ${config.baseUrl}：$e');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final text = utf8.decode(await res.stream.toBytes(), allowMalformed: true);
      Object? json;
      try {
        json = text.isEmpty ? null : jsonDecode(text);
      } on FormatException {
        json = null;
      }
      throw AiClientException(_errorMessage(res.statusCode, json, text), statusCode: res.statusCode);
    }
    // Not a stream after all (an endpoint that ignores "stream"): one JSON body.
    if (!(res.headers['content-type'] ?? '').contains('text/event-stream')) {
      final text = utf8.decode(await res.stream.toBytes(), allowMalformed: true);
      final Object? json;
      try {
        json = jsonDecode(text);
      } on FormatException {
        throw AiClientException('回應不是 JSON 物件，請確認網址是否指向 API 的根路徑（通常以 /v1 結尾）');
      }
      if (json is! Map<String, Object?>) throw AiClientException('回應不是 JSON 物件');
      final completion = _parseCompletion(json);
      if (completion.message.content case final text? when text.isNotEmpty) yield CompletionText(text);
      yield CompletionDone(completion);
      return;
    }

    final content = StringBuffer();
    final calls = <int, ({String? id, String name, StringBuffer args})>{};
    String? finish;
    TokenUsage? usage;
    var done = false;
    final lines = res.stream
        .timeout(config.timeout)
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    try {
      await for (final line in lines) {
        if (!line.startsWith('data:')) continue; // comments, event names, blank lines
        final data = line.substring(5).trim();
        if (data == '[DONE]') {
          done = true;
          break;
        }
        final Object? json;
        try {
          json = jsonDecode(data);
        } on FormatException {
          continue;
        }
        if (json is! Map) continue;
        if (json['error'] case final Object error) {
          throw AiClientException(_errorMessage(500, {'error': error}, data));
        }
        if (json['usage'] case {'prompt_tokens': final num i, 'completion_tokens': final num o}) {
          usage = TokenUsage(inputTokens: i.toInt(), outputTokens: o.toInt());
        }
        final choices = json['choices'];
        if (choices is! List || choices.isEmpty || choices.first is! Map) continue;
        final choice = choices.first as Map;
        finish = choice['finish_reason'] as String? ?? finish;
        final delta = choice['delta'];
        if (delta is! Map) continue;
        if (delta['content'] case final String text when text.isNotEmpty) {
          content.write(text);
          yield CompletionText(text);
        }
        if (delta['tool_calls'] case final List pieces) {
          for (final piece in pieces) {
            if (piece is! Map) continue;
            final index = (piece['index'] as num?)?.toInt() ?? calls.length;
            final fn = piece['function'] is Map ? piece['function'] as Map : const {};
            final call = calls[index] ??= (id: piece['id'] as String?, name: '', args: StringBuffer());
            calls[index] = (
              id: call.id ?? piece['id'] as String?,
              name: call.name + (fn['name'] as String? ?? ''),
              args: call.args..write(fn['arguments'] as String? ?? ''),
            );
          }
        }
      }
    } on TimeoutException {
      throw AiClientException('AI 超過 ${config.timeout.inSeconds} 秒沒有繼續回應');
    } on AiClientException {
      rethrow;
    } on Exception catch (e) {
      throw AiClientException('回答傳到一半連線中斷：$e');
    }
    if (!done && finish == null) throw AiClientException('回答傳到一半連線中斷');
    final ordered = calls.keys.toList()..sort();
    yield CompletionDone(
      ChatCompletion(
        message: AssistantMessage(
          content: content.isEmpty ? null : content.toString(),
          toolCalls: [
            for (final i in ordered)
              ToolCall(
                id: calls[i]!.id ?? 'call_$i',
                name: calls[i]!.name,
                argumentsJson: calls[i]!.args.isEmpty ? '{}' : calls[i]!.args.toString(),
              ),
          ],
        ),
        finishReason: finish,
        usage: usage,
      ),
    );
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
