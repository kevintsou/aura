import 'package:aura_ai/aura_ai.dart';
import 'package:test/test.dart';

class _Client implements AiClient {
  _Client(this.answer);
  final String? answer;
  final sent = <List<ChatMessage>>[];

  @override
  Future<ChatCompletion> complete({required List<ChatMessage> messages, List<ToolSpec> tools = const []}) async {
    sent.add(messages);
    return ChatCompletion(message: AssistantMessage(content: answer));
  }

  @override
  Future<List<String>> listModels() async => const [];
}

const _cats = {'c-food': '生活費', 'c-lunch': '生活費／午餐', 'c-fun': '購物娛樂'};

void main() {
  test('sends only the seller and item names, and reads the id back', () async {
    final client = _Client('{"category":"c-lunch"}');
    final id = await aiSuggestCategory(client, categories: _cats, seller: '好吃便當', items: ['排骨便當', '紅茶']);
    expect(id, 'c-lunch');
    final user = (client.sent.single.last as UserMessage).content;
    expect(user, contains('商家：好吃便當'));
    expect(user, contains('品項：排骨便當、紅茶'));
    expect(user, contains('c-lunch：生活費／午餐'));
    expect(client.sent.single.first, isA<SystemMessage>());
  });

  test('tolerates code fences, names instead of ids, and no match', () async {
    Future<String?> ask(String? answer) => aiSuggestCategory(_Client(answer), categories: _cats, items: ['x']);
    expect(await ask('```json\n{"category": "c-fun"}\n```'), 'c-fun');
    expect(await ask('{"category":"午餐"}'), 'c-lunch');
    expect(await ask('購物娛樂'), 'c-fun');
    expect(await ask('{"category":null}'), isNull);
    expect(await ask('{"category":"c-made-up"}'), isNull);
    expect(await ask(null), isNull);
  });

  test('nothing to go on means no request', () async {
    final client = _Client('{"category":"c-fun"}');
    expect(await aiSuggestCategory(client, categories: _cats), isNull);
    expect(await aiSuggestCategory(client, categories: const {}, items: ['x']), isNull);
    expect(client.sent, isEmpty);
  });
}
