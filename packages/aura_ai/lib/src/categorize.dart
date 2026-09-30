import 'dart:convert';

import 'ai_client.dart';
import 'messages.dart';

/// Asks the AI which of [categories] (id → name, e.g. "餐飲／早餐") a
/// purchase belongs to, from the seller's name and the item names only.
/// Returns an id from [categories], or null when the AI found none that
/// fits or answered with something else. Errors reaching the AI throw
/// [AiClientException].
Future<String?> aiSuggestCategory(
  AiClient client, {
  required Map<String, String> categories,
  String? seller,
  List<String> items = const [],
}) async {
  if (categories.isEmpty || ((seller == null || seller.trim().isEmpty) && items.isEmpty)) return null;
  final completion = await client.complete(
    messages: [
      const SystemMessage(
        '你是記帳 App 的分類助手。根據商家和購買的品項，從使用者的支出分類清單裡選出最適合的一個。'
        '只回覆 JSON，不要其他文字：{"category":"<代號>"}；清單裡沒有適合的就回覆 {"category":null}。',
      ),
      UserMessage(
        [
          if (seller != null && seller.trim().isNotEmpty) '商家：${seller.trim()}',
          if (items.isNotEmpty) '品項：${items.take(30).join('、')}',
          '',
          '分類清單（代號：名稱）：',
          for (final MapEntry(key: id, value: name) in categories.entries) '$id：$name',
        ].join('\n'),
      ),
    ],
  );
  return _pick(completion.message.content ?? '', categories);
}

String? _pick(String answer, Map<String, String> categories) {
  // The JSON asked for, possibly wrapped in a code fence or a sentence.
  final json = RegExp(r'\{[^{}]*\}').firstMatch(answer)?[0];
  Object? value;
  if (json != null) {
    try {
      value = (jsonDecode(json) as Map)['category'];
    } on Object {
      value = null;
    }
  }
  final said = (value is String ? value : answer).trim();
  if (categories.containsKey(said)) return said;
  // A model that answers with the name instead of the id.
  for (final MapEntry(key: id, value: name) in categories.entries) {
    if (name == said || name.split('／').last == said) return id;
  }
  return null;
}
