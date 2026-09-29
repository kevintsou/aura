import 'dart:convert';
import 'dart:io';

import 'package:aura_ai/aura_ai.dart';
import 'package:aura_core/aura_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

final _ledger = importCwmoneyCsv(
  File('../aura_core/test/fixtures/sample_cwmoney.csv').readAsBytesSync(),
).ledger;

ToolRegistry _tools({bool share = true}) => ToolRegistry(
  ledgerTools(
    _ledger,
    shareInvoiceItems: share,
    clock: () => DateTime(2026, 9, 29),
  ),
);

Future<(bool, Map<String, Object?>)> _call(
  ToolRegistry tools,
  String name, [
  Map<String, Object?> args = const {},
]) async {
  final r = await tools.run(
    ToolCall(id: 'c1', name: name, argumentsJson: jsonEncode(args)),
  );
  return (r.ok, jsonDecode(r.content) as Map<String, Object?>);
}

void main() {
  group('AiEndpointConfig', () {
    test('round-trips through JSON without the API key', () {
      final c = AiEndpointConfig.fromPreset(AiPreset.openRouter).copyWith(
        model: 'm',
        extraHeaders: {'X-Agent': 'aura'},
        shareInvoiceItems: false,
      );
      final json = c.toJson();
      expect(json.keys, isNot(contains('apiKey')));
      final back = AiEndpointConfig.fromJson(jsonDecode(jsonEncode(json)));
      expect(back.preset, AiPreset.openRouter);
      expect(back.baseUrl, 'https://openrouter.ai/api/v1');
      expect(back.model, 'm');
      expect(back.extraHeaders, {'X-Agent': 'aura'});
      expect(back.shareInvoiceItems, isFalse);
    });

    test('requires https except for local endpoints', () {
      final custom = AiEndpointConfig.fromPreset(AiPreset.custom);
      expect(
        custom.copyWith(baseUrl: 'http://example.com/v1', model: 'x')
            .validate(hasApiKey: true),
        [contains('https')],
      );
      expect(
        custom.copyWith(baseUrl: 'http://192.168.1.5:8000/v1', model: 'x')
            .validate(hasApiKey: false),
        isEmpty,
      );
    });

    test('OpenAI needs a key and a model', () {
      final c = AiEndpointConfig.defaults.copyWith(model: ' ');
      expect(c.validate(hasApiKey: false), hasLength(2));
    });
  });

  group('OpenAiCompatibleClient', () {
    test('sends a Chat Completions request and parses tool calls', () async {
      late http.Request sent;
      final client = OpenAiCompatibleClient(
        config: AiEndpointConfig.defaults.copyWith(
          baseUrl: 'https://agent.example.com/v1/',
          model: 'my-agent',
          extraHeaders: {'X-Team': 't1'},
        ),
        apiKey: 'sk-test',
        httpClient: MockClient((req) async {
          sent = req;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'tool_calls',
                  'message': {
                    'role': 'assistant',
                    'content': null,
                    'tool_calls': [
                      {
                        'id': 'call_1',
                        'type': 'function',
                        'function': {
                          'name': 'get_ledger_overview',
                          'arguments': '{}',
                        },
                      },
                    ],
                  },
                },
              ],
              'usage': {'prompt_tokens': 10, 'completion_tokens': 3},
            }),
            200,
          );
        }),
      );
      final result = await client.complete(
        messages: const [UserMessage('hi')],
        tools: _tools().specs,
      );
      expect(sent.url.toString(), 'https://agent.example.com/v1/chat/completions');
      expect(sent.headers['Authorization'], 'Bearer sk-test');
      expect(sent.headers['X-Team'], 't1');
      final body = jsonDecode(sent.body) as Map<String, Object?>;
      expect(body['model'], 'my-agent');
      expect(body.keys, isNot(contains('temperature')));
      expect((body['tools'] as List).length, 4);
      expect(result.message.toolCalls.single.name, 'get_ledger_overview');
      expect(result.usage!.inputTokens, 10);
    });

    test('turns HTTP errors into readable messages', () async {
      final client = OpenAiCompatibleClient(
        config: AiEndpointConfig.defaults,
        apiKey: 'bad',
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {'message': 'Incorrect API key provided'},
            }),
            401,
          ),
        ),
      );
      expect(
        () => client.complete(messages: const [UserMessage('hi')]),
        throwsA(
          isA<AiClientException>()
              .having((e) => e.statusCode, 'status', 401)
              .having((e) => e.message, 'message', contains('API 金鑰無效')),
        ),
      );
    });

    test('lists models', () async {
      final client = OpenAiCompatibleClient(
        config: AiEndpointConfig.defaults,
        httpClient: MockClient(
          (req) async => http.Response(
            jsonEncode({
              'data': [
                {'id': 'b-model'},
                {'id': 'a-model'},
              ],
            }),
            200,
          ),
        ),
      );
      expect(await client.listModels(), ['a-model', 'b-model']);
    });
  });

  group('ledger tools', () {
    test('overview lists the category tree and date range', () async {
      final (ok, r) = await _call(_tools(), 'get_ledger_overview');
      expect(ok, isTrue);
      expect(r['today'], '2026-09-29');
      expect(r['first_date'], '2026-09-18');
      expect((r['expense_categories'] as Map)['生活費'], ['早餐', '午餐']);
      expect(r['needs_review_count'], 1);
    });

    test('aggregates expenses by main category, excluding transfers', () async {
      final (ok, r) = await _call(_tools(), 'aggregate_transactions', {
        'group_by': 'main_category',
        'date_from': '2026-09-01',
        'date_to': '2026-09-30',
      });
      expect(ok, isTrue);
      expect(r['total'], 4010); // 65 + 1800 + 15 + 2010 + 120
      final groups = r['groups'] as List;
      expect(groups.first, {'key': '購物娛樂', 'total': 2010, 'count': 1, 'share': 50.12});
      expect(
        groups.firstWhere((g) => (g as Map)['key'] == '生活費'),
        containsPair('total', 185),
      );
    });

    test('aggregates by month in chronological order', () async {
      final (_, r) = await _call(_tools(), 'aggregate_transactions', {
        'kind': 'income',
        'group_by': 'month',
      });
      expect(r['groups'], [
        {'key': '2026-09', 'total': 48125.5, 'count': 2, 'share': 100},
      ]);
    });

    test('filters by a subcategory name', () async {
      final (_, r) = await _call(_tools(), 'aggregate_transactions', {
        'group_by': 'subcategory',
        'category': '加油',
      });
      expect(r['total'], 1800);
    });

    test('rejects unknown names so the AI can correct itself', () async {
      final (ok, r) = await _call(_tools(), 'aggregate_transactions', {
        'group_by': 'month',
        'category': '不存在',
      });
      expect(ok, isFalse);
      expect(r['error'], contains('get_ledger_overview'));
    });

    test('search shares invoice items but never carrier or tax id', () async {
      final tools = _tools();
      final r = await tools.run(
        ToolCall(
          id: 'c',
          name: 'search_transactions',
          argumentsJson: jsonEncode({'keyword': '茶葉蛋'}),
        ),
      );
      expect(r.content, contains('茶葉蛋'));
      expect(r.content, isNot(contains('/TEST123')));
      expect(r.content, isNot(contains('12345678')));
      final tx = (jsonDecode(r.content)['transactions'] as List).single as Map;
      expect(tx['seller'], '測試便利商店股份有限公司');
      expect((tx['invoice_items'] as List).length, 3);
    });

    test('without shared items, neither results nor keywords expose them', () async {
      final tools = _tools(share: false);
      expect(tools.specs.map((s) => s.name), isNot(contains('search_invoice_items')));
      final (_, byItem) = await _call(tools, 'search_transactions', {'keyword': '茶葉蛋'});
      expect(byItem['matched'], 0);
      final (_, all) = await _call(tools, 'search_transactions', {'category': '早餐'});
      expect((all['transactions'] as List).single, isNot(contains('invoice_items')));
    });

    test('finds invoice items by keyword', () async {
      final (_, r) = await _call(_tools(), 'search_invoice_items', {'keyword': '汽油'});
      expect(r['matched_items'], 1);
      expect(r['total_quantity'], 56.68);
    });

    test('reports foreign amounts alongside the base amount', () async {
      final (_, r) = await _call(_tools(), 'search_transactions', {'keyword': '東京'});
      expect((r['transactions'] as List).single, allOf(
        containsPair('amount_base', 2010),
        containsPair('amount', 10000),
        containsPair('currency', 'JPY'),
      ));
    });

    test('redact masks long numbers but keeps short ones', () {
      expect(redact('卡號 1234-5678-9012-3456 付 120 元'), '卡號 ****3456 付 120 元');
    });
  });

  group('AuraAgent', () {
    test('runs requested tools on the device and returns the answer', () async {
      final client = _ScriptedClient([
        const ChatCompletion(
          message: AssistantMessage(
            toolCalls: [
              ToolCall(
                id: 't1',
                name: 'aggregate_transactions',
                argumentsJson: '{"group_by":"main_category"}',
              ),
            ],
          ),
          usage: TokenUsage(inputTokens: 100, outputTokens: 10),
        ),
        const ChatCompletion(
          message: AssistantMessage(content: '九月最大宗是購物娛樂。'),
          usage: TokenUsage(inputTokens: 200, outputTokens: 20),
        ),
      ]);
      final agent = AuraAgent(
        client: client,
        tools: _tools(),
        systemPrompt: auraSystemPrompt(today: DateTime(2026, 9, 29), toolsEnabled: true),
      );
      final events = await agent.ask('九月花最多的是什麼？').toList();
      expect(events, [
        isA<AgentToolStarted>(),
        isA<AgentToolFinished>().having((e) => e.result.ok, 'ok', isTrue),
        isA<AgentReply>()
            .having((e) => e.text, 'text', '九月最大宗是購物娛樂。')
            .having((e) => e.usage!.inputTokens, 'input', 300),
      ]);
      // The second request carried the tool result back to the AI.
      final second = client.requests.last;
      expect(second.last, isA<ToolResultMessage>());
      expect((second.last as ToolResultMessage).content, contains('"total":4010'));
      expect(agent.history, hasLength(5));
    });

    test('drops the failed turn from history on errors', () async {
      final agent = AuraAgent(
        client: _ScriptedClient([]),
        tools: _tools(),
        systemPrompt: 's',
      );
      final events = await agent.ask('hi').toList();
      expect(events.single, isA<AgentFailed>());
      expect(agent.history, hasLength(1));
    });

    test('stops after maxRounds of tool calls', () async {
      const loop = ChatCompletion(
        message: AssistantMessage(
          toolCalls: [ToolCall(id: 'x', name: 'get_ledger_overview', argumentsJson: '{}')],
        ),
      );
      final agent = AuraAgent(
        client: _ScriptedClient(List.filled(3, loop)),
        tools: _tools(),
        systemPrompt: 's',
        maxRounds: 3,
      );
      final events = await agent.ask('loop').toList();
      expect(events.last, isA<AgentFailed>());
    });
  });
}

class _ScriptedClient implements AiClient {
  _ScriptedClient(this.script);
  final List<ChatCompletion> script;
  final requests = <List<ChatMessage>>[];

  @override
  Future<ChatCompletion> complete({
    required List<ChatMessage> messages,
    List<ToolSpec> tools = const [],
  }) async {
    requests.add([...messages]);
    if (requests.length > script.length) {
      throw AiClientException('no more scripted replies');
    }
    return script[requests.length - 1];
  }

  @override
  Future<List<String>> listModels() async => const [];
}
