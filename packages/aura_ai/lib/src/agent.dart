import 'ai_client.dart';
import 'messages.dart';
import 'tools/tool.dart';

/// Something the UI can show while the agent works. Tool events make it
/// visible exactly what data left the device.
sealed class AgentEvent {
  const AgentEvent();
}

class AgentToolStarted extends AgentEvent {
  const AgentToolStarted(this.call);
  final ToolCall call;
}

class AgentToolFinished extends AgentEvent {
  const AgentToolFinished(this.result);

  /// [ToolRunResult.content] is the exact text sent to the AI.
  final ToolRunResult result;
}

class AgentReply extends AgentEvent {
  const AgentReply(this.text, {this.usage});
  final String text;

  /// Summed over every request made for this reply, when reported.
  final TokenUsage? usage;
}

class AgentFailed extends AgentEvent {
  const AgentFailed(this.message);
  final String message;
}

/// Runs the tool-calling loop: ask the AI, execute the tools it requests
/// on the device, send the results back, until it answers.
class AuraAgent {
  AuraAgent({
    required this.client,
    required this.tools,
    required String systemPrompt,
    this.maxRounds = 8,
  }) : _history = [SystemMessage(systemPrompt)];

  final AiClient client;

  /// Null when the endpoint does not support tool calling.
  final ToolRegistry? tools;
  final int maxRounds;
  final List<ChatMessage> _history;

  List<ChatMessage> get history => List.unmodifiable(_history);

  /// Forgets the conversation but keeps the system prompt.
  void reset() => _history.removeRange(1, _history.length);

  Stream<AgentEvent> ask(String question) async* {
    final start = _history.length;
    _history.add(UserMessage(question));
    var input = 0, output = 0;
    var reported = false;
    for (var round = 0; round < maxRounds; round++) {
      final ChatCompletion completion;
      try {
        completion = await client.complete(
          messages: _history,
          tools: tools?.specs ?? const [],
        );
      } on AiClientException catch (e) {
        _history.removeRange(start, _history.length);
        yield AgentFailed(e.toString());
        return;
      }
      if (completion.usage case final u?) {
        reported = true;
        input += u.inputTokens;
        output += u.outputTokens;
      }
      final message = completion.message;
      _history.add(message);
      if (message.toolCalls.isEmpty || tools == null) {
        yield AgentReply(
          message.content?.trim() ?? '',
          usage: reported
              ? TokenUsage(inputTokens: input, outputTokens: output)
              : null,
        );
        return;
      }
      for (final call in message.toolCalls) {
        yield AgentToolStarted(call);
        final result = await tools!.run(call);
        _history.add(
          ToolResultMessage(toolCallId: call.id, content: result.content),
        );
        yield AgentToolFinished(result);
      }
    }
    _history.removeRange(start, _history.length);
    yield AgentFailed('AI 查詢了 $maxRounds 輪還沒有得到答案，請把問題問得更具體一點');
  }
}
