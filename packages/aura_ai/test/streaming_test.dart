import 'dart:convert';

import 'package:aura_ai/aura_ai.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

String _sse(List<Object> events, {bool done = true}) => [
  for (final e in events) 'data: ${jsonEncode(e)}\n\n',
  if (done) 'data: [DONE]\n\n',
].join();

Map<String, Object?> _text(String t) => {
  'choices': [
    {
      'index': 0,
      'delta': {'content': t},
    },
  ],
};

const _usage = {
  'choices': <Object>[],
  'usage': {'prompt_tokens': 12, 'completion_tokens': 4},
};

/// Answers streaming requests with [sse] (split in small byte chunks, so
/// lines and characters are cut in the middle) and plain ones with [json].
MockClient _server({
  String? sse,
  Map<String, Object?>? json,
  int streamStatus = 200,
  List<Map<String, Object?>>? bodies,
}) => MockClient.streaming((req, body) async {
  final sent = jsonDecode(await body.bytesToString()) as Map<String, Object?>;
  bodies?.add(sent);
  if (sent['stream'] == true && streamStatus != 200) {
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"error":{"message":"stream_options is not supported"}}')),
      streamStatus,
    );
  }
  if (sent['stream'] == true && sse != null) {
    final bytes = utf8.encode(sse);
    return http.StreamedResponse(
      Stream.fromIterable([for (var i = 0; i < bytes.length; i += 7) bytes.sublist(i, i + 7 > bytes.length ? bytes.length : i + 7)]),
      200,
      headers: {'content-type': 'text/event-stream; charset=utf-8'},
    );
  }
  return http.StreamedResponse(
    Stream.value(utf8.encode(jsonEncode(json))),
    200,
    headers: {'content-type': 'application/json'},
  );
});

OpenAiCompatibleClient _client(http.Client http) =>
    OpenAiCompatibleClient(config: AiEndpointConfig.defaults, apiKey: 'sk', httpClient: http);

void main() {
  group('completeStream', () {
    test('text comes in pieces, then the whole answer with usage', () async {
      final bodies = <Map<String, Object?>>[];
      final client = _client(
        _server(sse: _sse([_text('九月'), _text('支出 NT\$4,010'), _text('。'), _usage]), bodies: bodies),
      );
      final events = await client.completeStream(messages: const [UserMessage('hi')]).toList();
      expect([for (final e in events) if (e is CompletionText) e.delta], ['九月', '支出 NT\$4,010', '。']);
      final done = events.last as CompletionDone;
      expect(done.completion.message.content, '九月支出 NT\$4,010。');
      expect(done.completion.usage!.outputTokens, 4);
      expect(bodies.single['stream'], isTrue);
      expect(bodies.single['stream_options'], {'include_usage': true});
    });

    test('tool calls sent in pieces are put back together', () async {
      Map<String, Object?> piece(Map<String, Object?> call) => {
        'choices': [
          {
            'delta': {
              'tool_calls': [call],
            },
          },
        ],
      };
      final client = _client(
        _server(
          sse: _sse([
            piece({
              'index': 0,
              'id': 'c1',
              'function': {'name': 'aggregate_transactions', 'arguments': '{"group'},
            }),
            piece({
              'index': 1,
              'id': 'c2',
              'function': {'name': 'get_ledger_overview', 'arguments': ''},
            }),
            piece({
              'index': 0,
              'function': {'arguments': '_by":"month"}'},
            }),
            {
              'choices': [
                {'delta': <String, Object?>{}, 'finish_reason': 'tool_calls'},
              ],
            },
          ]),
        ),
      );
      final done = (await client.completeStream(messages: const [UserMessage('hi')]).last) as CompletionDone;
      final calls = done.completion.message.toolCalls;
      expect([for (final c in calls) (c.id, c.name, c.argumentsJson)], [
        ('c1', 'aggregate_transactions', '{"group_by":"month"}'),
        ('c2', 'get_ledger_overview', '{}'),
      ]);
      expect(done.completion.message.content, isNull);
      expect(done.completion.finishReason, 'tool_calls');
    });

    test('an endpoint that ignores "stream" still works', () async {
      final client = _client(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': '好'},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      final events = await client.completeStream(messages: const [UserMessage('hi')]).toList();
      expect((events.first as CompletionText).delta, '好');
      expect((events.last as CompletionDone).completion.message.content, '好');
    });

    test('a stream cut off in the middle is an error', () async {
      final client = _client(_server(sse: _sse([_text('九月')], done: false)));
      expect(
        client.completeStream(messages: const [UserMessage('hi')]).toList(),
        throwsA(isA<AiClientException>().having((e) => e.message, 'message', contains('中斷'))),
      );
    });
  });

  group('AuraAgent streaming', () {
    test('passes the text on as it comes, then the reply', () async {
      final agent = AuraAgent(
        client: _client(_server(sse: _sse([_text('共 '), _text('3 筆'), _usage]))),
        tools: null,
        systemPrompt: 's',
      );
      final events = await agent.ask('幾筆？').toList();
      expect([for (final e in events) if (e is AgentText) e.delta], ['共 ', '3 筆']);
      final reply = events.last as AgentReply;
      expect((reply.text, reply.usage!.inputTokens), ('共 3 筆', 12));
    });

    test('falls back to whole answers when the endpoint cannot stream', () async {
      final bodies = <Map<String, Object?>>[];
      final agent = AuraAgent(
        client: _client(
          _server(
            streamStatus: 400,
            bodies: bodies,
            json: {
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': '好'},
                },
              ],
            },
          ),
        ),
        tools: null,
        systemPrompt: 's',
      );
      expect((await agent.ask('a').last as AgentReply).text, '好');
      expect((await agent.ask('b').last as AgentReply).text, '好');
      expect([for (final b in bodies) b['stream'] == true], [true, false, false], reason: 'tries streaming once');
    });

    test('streaming can be turned off', () async {
      final bodies = <Map<String, Object?>>[];
      final agent = AuraAgent(
        client: _client(
          _server(
            bodies: bodies,
            json: {
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': '好'},
                },
              ],
            },
          ),
        ),
        tools: null,
        systemPrompt: 's',
        stream: false,
      );
      final events = await agent.ask('a').toList();
      expect(events.whereType<AgentText>(), isEmpty);
      expect(bodies.single.containsKey('stream'), isFalse);
    });

    test('the stream setting is saved', () {
      final c = AiEndpointConfig.defaults.copyWith(stream: false);
      expect(AiEndpointConfig.fromJson(c.toJson()).stream, isFalse);
      expect(AiEndpointConfig.fromJson(const {}).stream, isTrue);
    });
  });
}
