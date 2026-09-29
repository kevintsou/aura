/// Conversation types, shaped after the OpenAI Chat Completions protocol.
sealed class ChatMessage {
  const ChatMessage();

  Map<String, Object?> toWire();
}

class SystemMessage extends ChatMessage {
  const SystemMessage(this.content);
  final String content;

  @override
  Map<String, Object?> toWire() => {'role': 'system', 'content': content};
}

class UserMessage extends ChatMessage {
  const UserMessage(this.content);
  final String content;

  @override
  Map<String, Object?> toWire() => {'role': 'user', 'content': content};
}

class AssistantMessage extends ChatMessage {
  const AssistantMessage({this.content, this.toolCalls = const []});

  final String? content;
  final List<ToolCall> toolCalls;

  @override
  Map<String, Object?> toWire() => {
    'role': 'assistant',
    'content': content,
    if (toolCalls.isNotEmpty)
      'tool_calls': [for (final c in toolCalls) c.toWire()],
  };
}

class ToolResultMessage extends ChatMessage {
  const ToolResultMessage({required this.toolCallId, required this.content});

  final String toolCallId;

  /// JSON text returned by the tool.
  final String content;

  @override
  Map<String, Object?> toWire() => {
    'role': 'tool',
    'tool_call_id': toolCallId,
    'content': content,
  };
}

class ToolCall {
  const ToolCall({
    required this.id,
    required this.name,
    required this.argumentsJson,
  });

  final String id;
  final String name;

  /// Raw JSON arguments as produced by the model; may be malformed.
  final String argumentsJson;

  Map<String, Object?> toWire() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': argumentsJson},
  };
}

/// A function the model may call, described with JSON Schema.
class ToolSpec {
  const ToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;
  final Map<String, Object?> parameters;

  Map<String, Object?> toWire() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

class TokenUsage {
  const TokenUsage({required this.inputTokens, required this.outputTokens});
  final int inputTokens;
  final int outputTokens;
}

class ChatCompletion {
  const ChatCompletion({required this.message, this.finishReason, this.usage});

  final AssistantMessage message;
  final String? finishReason;
  final TokenUsage? usage;
}
