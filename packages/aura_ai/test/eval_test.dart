import 'dart:convert';

import 'package:aura_ai/aura_ai.dart';
import 'package:aura_ai/eval.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

Decimal d(String s) => Decimal.parse(s);

/// Answers with a tool call first, then [answer], counting tokens.
class _Scripted implements AiClient {
  _Scripted(this.answer);
  final String Function(String question) answer;

  @override
  Future<ChatCompletion> complete({required List<ChatMessage> messages, List<ToolSpec> tools = const []}) async {
    final question = messages.whereType<UserMessage>().last.content;
    if (messages.last is UserMessage) {
      return const ChatCompletion(
        message: AssistantMessage(
          toolCalls: [ToolCall(id: 'c1', name: 'get_ledger_overview', argumentsJson: '{}')],
        ),
        usage: TokenUsage(inputTokens: 100, outputTokens: 10),
      );
    }
    return ChatCompletion(
      message: AssistantMessage(content: answer(question)),
      usage: const TokenUsage(inputTokens: 200, outputTokens: 20),
    );
  }

  @override
  Future<List<String>> listModels() async => const [];
}

void main() {
  final ledger = evalLedger();
  final cases = defaultEvalCases();
  final tools = ToolRegistry(ledgerTools(ledger, shareInvoiceItems: true, clock: () => evalToday));

  Future<Map<String, Object?>> tool(String name, Map<String, Object?> args) async {
    final r = await tools.run(ToolCall(id: 'x', name: name, argumentsJson: jsonEncode(args)));
    expect(r.ok, isTrue, reason: r.content);
    return jsonDecode(r.content) as Map<String, Object?>;
  }

  Decimal total(Map<String, Object?> json) => Decimal.parse('${json['total']}');
  List<Expectation> expectOf(String id) => cases.firstWhere((c) => c.id == id).expect(ledger);

  test('numbers are read the way people write them', () {
    expect(numbersIn('共 NT\$4,010 元，約 1.5 萬，少了 -20.5'), [d('4010'), d('15000'), d('-20.5')]);
    expect(ExpectNumber(d('39802.77'), tolerance: d('5')).metBy('平均每月約 NT\$39,800'), isTrue);
    expect(ExpectNumber(d('87'), tolerance: Decimal.zero).metBy('一共 86 次'), isFalse);
    expect(const ExpectText('2 月', alternatives: ['2月']).metBy('在2月領到'), isTrue);
  });

  test('the ledger is the same every time and covers the questions', () {
    final again = evalLedger();
    expect(again.count(), ledger.count());
    expect(ledger.transactions().first.date, DateTime(2026, 9, 30));
    expect(ledger.count(), greaterThan(2000));
    expect(cases.map((c) => c.id).toSet(), hasLength(cases.length), reason: 'unique ids');
  });

  // Each answer can be reached with Aura's tools: the tool output (or a
  // sum of outputs) meets the expectation.
  group('answerable with the tools', () {
    test('totals', () async {
      final sep = await tool('aggregate_transactions', {
        'group_by': 'main_category',
        'date_from': '2026-09-01',
        'date_to': '2026-09-30',
      });
      expect((expectOf('month-total').single as ExpectNumber).metBy('${total(sep)}'), isTrue);

      final income = await tool('aggregate_transactions', {
        'kind': 'income',
        'group_by': 'main_category',
        'date_from': '2026-09-01',
        'date_to': '2026-09-30',
      });
      expect(expectOf('month-income').single.metBy('${total(income)}'), isTrue);

      final fuel = await tool('aggregate_transactions', {
        'group_by': 'year',
        'category': '加油',
        'date_from': '2025-01-01',
        'date_to': '2025-12-31',
      });
      expect(expectOf('fuel-year').single.metBy('${total(fuel)}'), isTrue);
    });

    test('rankings and single records', () async {
      final aug = await tool('aggregate_transactions', {
        'group_by': 'main_category',
        'date_from': '2026-08-01',
        'date_to': '2026-08-31',
      });
      final top = (aug['groups'] as List).first as Map;
      expect(expectOf('top-category').every((e) => e.metBy('${top['key']} ${top['total']}')), isTrue);

      final biggest = await tool('search_transactions', {
        'kind': 'expense',
        'date_from': '2026-08-01',
        'date_to': '2026-08-31',
        'sort': 'amount_desc',
        'limit': 1,
      });
      expect(expectOf('biggest-expense').every((e) => e.metBy(jsonEncode(biggest))), isTrue);

      final cards = await tool('aggregate_transactions', {
        'group_by': 'account',
        'date_from': '2026-01-01',
        'date_to': '2026-09-30',
      });
      final byName = {for (final g in cards['groups'] as List) (g as Map)['key']: Decimal.parse('${g['total']}')};
      final winner = byName['藍鯨信用卡']! >= byName['橘貓信用卡']! ? '藍鯨' : '橘貓';
      expect(expectOf('card-most').single.metBy(winner), isTrue);
    });

    test('counts and sums across categories', () async {
      final coffee = await tool('aggregate_transactions', {'group_by': 'year', 'keyword': '星光咖啡'});
      expect(expectOf('shop-count').single.metBy('${coffee['count']}'), isTrue);

      var meals = Decimal.zero;
      for (final c in ['早餐', '午餐', '晚餐']) {
        meals += total(
          await tool('aggregate_transactions', {
            'group_by': 'year',
            'category': c,
            'date_from': '2026-07-01',
            'date_to': '2026-09-30',
          }),
        );
      }
      expect(expectOf('eating-out-quarter').single.metBy('$meals'), isTrue);
    });
  });

  test('runEval asks each question fresh and grades the answers', () async {
    final expected = {for (final c in cases) c.question: c.expect(ledger)};
    String right(String q) => [
      for (final e in expected[q]!)
        switch (e) {
          ExpectNumber(:final value) => 'NT\$$value',
          ExpectText(:final text) => text,
        },
    ].join('，');
    final picked = [cases.first, cases[3]];
    final report = await runEval(
      _Scripted((q) => q == picked.first.question ? right(q) : '不知道'),
      ledger,
      picked,
      stream: false,
    );
    expect([for (final r in report.results) r.passed], [true, false]);
    expect((report.passed, report.toolCalls, report.inputTokens, report.outputTokens), (1, 2, 600, 60));
    expect(report.results.last.missed, isNotEmpty);
    final json = report.toJson();
    expect(json['accuracy'], 0.5);
    expect(((json['cases'] as List).last as Map)['answer'], '不知道');
  });
}
