import 'dart:async';

import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_ai/aura_ai.dart';
import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Streams whatever the test pushes into [events].
class _StreamingClient implements StreamingAiClient {
  StreamController<CompletionEvent>? events;
  var streamed = 0;

  @override
  Stream<CompletionEvent> completeStream({required List<ChatMessage> messages, List<ToolSpec> tools = const []}) {
    streamed++;
    return (events = StreamController<CompletionEvent>()).stream;
  }

  @override
  Future<ChatCompletion> complete({required List<ChatMessage> messages, List<ToolSpec> tools = const []}) async =>
      const ChatCompletion(message: AssistantMessage(content: '整段'));

  @override
  Future<List<String>> listModels() async => const [];
}

Future<AppState> _app(_StreamingClient client, {bool stream = true}) async {
  final config = AiEndpointConfig.defaults.copyWith(stream: stream);
  final store = MemoryAiSettingsStore(config: config)..keys[config.preset] = 'sk';
  final app = AppState(
    ledger: InMemoryLedger(),
    settings: store,
    clientFactory: (_, _) => client,
    clock: () => DateTime(2026, 9, 29),
  );
  await app.load();
  app.startFresh();
  return app;
}

void main() {
  testWidgets('the answer shows as it is written', (tester) async {
    final client = _StreamingClient();
    final app = await _app(client);
    await tester.pumpWidget(AuraApp(app: app));
    await tester.tap(find.text('AI 助理'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('question')), '這個月花多少？');
    await tester.tap(find.byKey(const Key('send')));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget, reason: 'waiting for the first words');

    client.events!.add(const CompletionText('九月支出'));
    await tester.pump();
    await tester.pump();
    expect(find.text('九月支出'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing, reason: 'the words themselves show progress');
    expect(app.assistant.busy, isTrue);

    client.events!
      ..add(const CompletionText(' NT\$4,010。'))
      ..add(
        const CompletionDone(
          ChatCompletion(
            message: AssistantMessage(content: '九月支出 NT\$4,010。'),
            usage: TokenUsage(inputTokens: 30, outputTokens: 8),
          ),
        ),
      );
    await client.events!.close();
    await tester.pumpAndSettle();
    expect(find.text('九月支出 NT\$4,010。'), findsOneWidget);
    expect(find.text('tokens：輸入 30／輸出 8'), findsOneWidget);
    expect(app.assistant.items.whereType<ReplyChatItem>().single.writing, isFalse);
    expect(app.assistant.busy, isFalse);
  });

  testWidgets('with streaming off the answer comes whole', (tester) async {
    final client = _StreamingClient();
    final app = await _app(client, stream: false);
    await tester.pumpWidget(AuraApp(app: app));
    await tester.tap(find.text('AI 助理'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('question')), 'hi');
    await tester.tap(find.byKey(const Key('send')));
    await tester.pumpAndSettle();
    expect(find.text('整段'), findsOneWidget);
    expect(client.streamed, 0);
  });

  testWidgets('the setting is on the AI connection screen', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = await _app(_StreamingClient());
    await tester.pumpWidget(AuraApp(app: app));
    await tester.tap(find.text('設定').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('aiSettings')));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('streamReplies'));
    await tester.scrollUntilVisible(toggle, 200, scrollable: find.byType(Scrollable).first);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
  });
}
