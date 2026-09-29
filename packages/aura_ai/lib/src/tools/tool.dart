import 'dart:convert';

import '../messages.dart';

/// A capability the AI may invoke. Tools run on the device, against the
/// local ledger; only their JSON result is sent to the AI.
abstract class AuraTool {
  ToolSpec get spec;

  Future<Map<String, Object?>> run(Map<String, Object?> args);
}

/// Bad arguments from the model. The message is returned to the model so
/// it can correct itself.
class ToolArgumentException implements Exception {
  ToolArgumentException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ToolRunResult {
  const ToolRunResult({
    required this.call,
    required this.ok,
    required this.content,
  });

  final ToolCall call;
  final bool ok;

  /// JSON text sent back to the AI.
  final String content;
}

class ToolRegistry {
  ToolRegistry(List<AuraTool> tools) : _tools = {for (final t in tools) t.spec.name: t};

  final Map<String, AuraTool> _tools;

  List<ToolSpec> get specs => [for (final t in _tools.values) t.spec];

  Future<ToolRunResult> run(ToolCall call) async {
    final tool = _tools[call.name];
    if (tool == null) {
      return _error(call, 'unknown tool "${call.name}"; available: ${_tools.keys.join(', ')}');
    }
    final Object? args;
    try {
      args = call.argumentsJson.trim().isEmpty ? {} : jsonDecode(call.argumentsJson);
    } on FormatException {
      return _error(call, 'arguments must be a JSON object');
    }
    if (args is! Map<String, Object?>) {
      return _error(call, 'arguments must be a JSON object');
    }
    try {
      final result = await tool.run(args);
      return ToolRunResult(call: call, ok: true, content: jsonEncode(result));
    } on ToolArgumentException catch (e) {
      return _error(call, e.message);
    }
  }

  static ToolRunResult _error(ToolCall call, String message) => ToolRunResult(
    call: call,
    ok: false,
    content: jsonEncode({'error': message}),
  );
}
