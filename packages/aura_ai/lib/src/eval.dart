import 'dart:math';

import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';

import 'agent.dart';
import 'ai_client.dart';
import 'messages.dart';
import 'prompts.dart';
import 'tools/ledger_tools.dart';
import 'tools/tool.dart';

/// The day the evaluation ledger ends and the questions are asked.
final evalToday = DateTime(2026, 9, 30);

/// What a correct answer has to contain.
sealed class Expectation {
  const Expectation();

  bool metBy(String answer);

  /// For the report: what was looked for.
  String describe();
}

/// A number, written any usual way ("4,010", "NT$4010", "4010 元",
/// "1.5 萬"), within [tolerance].
class ExpectNumber extends Expectation {
  ExpectNumber(this.value, {Decimal? tolerance}) : tolerance = tolerance ?? Decimal.one;

  final Decimal value;
  final Decimal tolerance;

  @override
  bool metBy(String answer) => numbersIn(answer).any((n) => (n - value).abs() <= tolerance);

  @override
  String describe() => '數字 $value（±$tolerance）';
}

/// A word or name, or any one of [alternatives] ("2 月", "2月", "二月").
class ExpectText extends Expectation {
  const ExpectText(this.text, {this.alternatives = const []});
  final String text;
  final List<String> alternatives;

  @override
  bool metBy(String answer) => [text, ...alternatives].any(answer.contains);

  @override
  String describe() => [text, ...alternatives].map((t) => '「$t」').join('或');
}

/// Every number in [text], including "萬" amounts.
List<Decimal> numbersIn(String text) {
  final out = <Decimal>[];
  for (final m in RegExp(r'-?\d[\d,]*(?:\.\d+)?\s*(萬)?').allMatches(text)) {
    final raw = m[0]!.replaceAll(RegExp(r'[,\s萬]'), '');
    final n = Decimal.tryParse(raw);
    if (n == null) continue;
    out.add(m[1] == null ? n : n * Decimal.fromInt(10000));
  }
  return out;
}

class EvalCase {
  EvalCase(this.id, this.question, this.expect);

  final String id;
  final String question;

  /// Worked out from the ledger itself, never by the model.
  final List<Expectation> Function(LedgerReader ledger) expect;
}

class EvalResult {
  EvalResult({
    required this.evalCase,
    required this.expected,
    required this.answer,
    required this.passed,
    required this.toolCalls,
    required this.usage,
    required this.elapsed,
    this.error,
  });

  final EvalCase evalCase;
  final List<Expectation> expected;
  final String answer;
  final bool passed;
  final int toolCalls;
  final TokenUsage? usage;
  final Duration elapsed;
  final String? error;

  List<Expectation> get missed => [for (final e in expected) if (!e.metBy(answer)) e];
}

class EvalReport {
  EvalReport(this.results);
  final List<EvalResult> results;

  int get passed => results.where((r) => r.passed).length;
  double get accuracy => results.isEmpty ? 0 : passed / results.length;
  int get inputTokens => results.fold(0, (s, r) => s + (r.usage?.inputTokens ?? 0));
  int get outputTokens => results.fold(0, (s, r) => s + (r.usage?.outputTokens ?? 0));
  int get toolCalls => results.fold(0, (s, r) => s + r.toolCalls);

  Map<String, Object?> toJson() => {
    'passed': passed,
    'total': results.length,
    'accuracy': accuracy,
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'toolCalls': toolCalls,
    'cases': [
      for (final r in results)
        {
          'id': r.evalCase.id,
          'question': r.evalCase.question,
          'passed': r.passed,
          'expected': [for (final e in r.expected) e.describe()],
          'missed': [for (final e in r.missed) e.describe()],
          'answer': r.answer,
          'toolCalls': r.toolCalls,
          'inputTokens': r.usage?.inputTokens,
          'outputTokens': r.usage?.outputTokens,
          'ms': r.elapsed.inMilliseconds,
          'error': ?r.error,
        },
    ],
  };
}

/// Asks every case in a fresh conversation, with Aura's own tools and
/// system prompt, and checks the answers.
Future<EvalReport> runEval(
  AiClient client,
  LedgerReader ledger,
  List<EvalCase> cases, {
  bool stream = true,
  void Function(EvalResult result)? onResult,
}) async {
  final results = <EvalResult>[];
  for (final c in cases) {
    final agent = AuraAgent(
      client: client,
      tools: ToolRegistry(ledgerTools(ledger, shareInvoiceItems: true, clock: () => evalToday)),
      systemPrompt: auraSystemPrompt(today: evalToday, toolsEnabled: true),
      stream: stream,
    );
    final watch = Stopwatch()..start();
    var calls = 0;
    String answer = '';
    String? error;
    TokenUsage? usage;
    await for (final e in agent.ask(c.question)) {
      switch (e) {
        case AgentToolStarted():
          calls++;
        case AgentReply(:final text, usage: final u):
          answer = text;
          usage = u;
        case AgentFailed(:final message):
          error = message;
        case AgentToolFinished() || AgentText():
          break;
      }
    }
    final expected = c.expect(ledger);
    final result = EvalResult(
      evalCase: c,
      expected: expected,
      answer: answer,
      passed: error == null && expected.every((x) => x.metBy(answer)),
      toolCalls: calls,
      usage: usage,
      elapsed: watch.elapsed,
      error: error,
    );
    results.add(result);
    onResult?.call(result);
  }
  return EvalReport(results);
}

// ---------------------------------------------------------------------
// The evaluation ledger: 21 months of made-up everyday spending.

const _cash = 'a-cash', _cardA = 'a-card-a', _cardB = 'a-card-b', _bank = 'a-bank', _easy = 'a-easy';

/// A made-up household's ledger from January 2025 to September 2026:
/// meals, commuting, fuel, rent, bills, shopping, subscriptions, pay.
/// The same every time (fixed random seed).
InMemoryLedger evalLedger() {
  const accounts = [
    Account(id: _cash, name: '現金', type: AccountType.cash, currency: 'TWD'),
    Account(id: _cardA, name: '藍鯨信用卡', type: AccountType.credit, currency: 'TWD'),
    Account(id: _cardB, name: '橘貓信用卡', type: AccountType.credit, currency: 'TWD'),
    Account(id: _bank, name: '活存', type: AccountType.bank, currency: 'TWD'),
    Account(id: _easy, name: '悠遊卡', type: AccountType.epay, currency: 'TWD'),
  ];
  Category main(String id, String name, [TxnKind kind = TxnKind.expense]) => Category(id: id, kind: kind, name: name);
  Category sub(String id, String parent, String name, [TxnKind kind = TxnKind.expense]) =>
      Category(id: id, kind: kind, name: name, parentId: parent);
  final categories = [
    main('food', '餐飲'),
    sub('breakfast', 'food', '早餐'),
    sub('lunch', 'food', '午餐'),
    sub('dinner', 'food', '晚餐'),
    sub('drinks', 'food', '飲料'),
    main('traffic', '交通'),
    sub('fuel', 'traffic', '加油'),
    sub('metro', 'traffic', '捷運'),
    sub('parking', 'traffic', '停車'),
    main('home', '居家'),
    sub('rent', 'home', '房租'),
    sub('bills', 'home', '水電'),
    main('shopping', '購物'),
    sub('daily', 'shopping', '日用品'),
    sub('clothes', 'shopping', '服飾'),
    main('fun', '娛樂'),
    sub('movie', 'fun', '電影'),
    sub('subscription', 'fun', '訂閱'),
    main('health', '醫療'),
    main('work', '工作收入', TxnKind.income),
    sub('salary', 'work', '薪資', TxnKind.income),
    sub('bonus', 'work', '獎金', TxnKind.income),
  ];
  final rng = Random(20260930);
  final txns = <Txn>[];
  var n = 0;
  void add(DateTime d, String category, String account, int amount, {String? place, TxnKind kind = TxnKind.expense}) {
    final a = Decimal.fromInt(amount);
    txns.add(
      Txn(
        id: 'e${n++}',
        kind: kind,
        date: d,
        accountId: account,
        categoryId: category,
        amount: a,
        baseAmount: a,
        note: place,
        place: place,
        createdAt: d.add(Duration(hours: 8 + rng.nextInt(12), minutes: rng.nextInt(60))),
      ),
    );
  }

  int between(int lo, int hi) => lo + rng.nextInt(hi - lo + 1);
  T pick<T>(List<T> xs) => xs[rng.nextInt(xs.length)];

  for (var d = DateTime(2025, 1, 1); !d.isAfter(evalToday); d = DateTime(d.year, d.month, d.day + 1)) {
    final weekday = d.weekday <= 5;
    if (rng.nextDouble() < 0.85) add(d, 'breakfast', _cash, between(45, 95), place: pick(['晨光早餐店', '街角便利商店']));
    if (weekday) add(d, 'lunch', pick([_cash, _easy]), between(90, 170), place: pick(['好吃便當', '麵館', '自助餐']));
    if (rng.nextDouble() < 0.7) add(d, 'dinner', pick([_cash, _cardA]), between(120, 380), place: pick(['巷口小吃', '拉麵店', '家常菜']));
    if (rng.nextDouble() < 0.3) add(d, 'drinks', _easy, between(50, 75), place: '手搖飲');
    if (weekday) add(d, 'metro', _easy, between(20, 45));
    if (rng.nextDouble() < 0.14) add(d, 'fuel', _cardA, between(1100, 1750), place: '測試加油站');
    if (rng.nextDouble() < 0.05) add(d, 'parking', _cash, between(40, 200));
    if (rng.nextDouble() < 0.12) add(d, 'drinks', _cardB, between(110, 180), place: '星光咖啡');
    if (rng.nextDouble() < 0.1) add(d, 'daily', pick([_cardA, _cardB]), between(150, 1200), place: '大賣場');
    if (rng.nextDouble() < 0.03) add(d, 'clothes', _cardB, between(600, 3500), place: '服飾店');
    if (rng.nextDouble() < 0.02) add(d, 'movie', _cardB, between(300, 700), place: '影城');
    if (rng.nextDouble() < 0.01) add(d, 'health', _cash, between(150, 900), place: '診所');
    if (d.day == 5) {
      add(d, 'rent', _bank, 16000, place: '房東');
      add(d, 'salary', _bank, 56000, place: '公司', kind: TxnKind.income);
    }
    if (d.day == 12) add(d, 'subscription', _cardA, 390, place: '串流影音');
    if (d.day == 20 && d.month.isEven) add(d, 'bills', _bank, between(1200, 2600), place: '水電費');
  }
  // One-offs.
  add(DateTime(2026, 2, 10), 'bonus', _bank, 90000, place: '年終獎金', kind: TxnKind.income);
  add(DateTime(2026, 8, 16), 'daily', _cardB, 18900, place: '家電行');
  add(DateTime(2025, 11, 3), 'health', _cardA, 6800, place: '牙醫');

  return InMemoryLedger(accounts: accounts, categories: categories, transactions: txns);
}

Decimal _sum(LedgerReader l, TxnFilter f) => l.transactions(f).fold(Decimal.zero, (s, t) => s + t.baseAmount);

TxnFilter _range(DateTime from, DateTime to, {Set<String>? categories, TxnKind kind = TxnKind.expense}) =>
    TxnFilter(from: from, to: to, kinds: {kind}, categoryIds: categories);

/// The standard questions, each with its answer worked out from the ledger.
List<EvalCase> defaultEvalCases() => [
  EvalCase('month-total', '2026 年 9 月總共花了多少錢？', (l) {
    return [ExpectNumber(_sum(l, _range(DateTime(2026, 9, 1), DateTime(2026, 9, 30))))];
  }),
  EvalCase('month-income', '2026 年 9 月的收入是多少？', (l) {
    return [ExpectNumber(_sum(l, _range(DateTime(2026, 9, 1), DateTime(2026, 9, 30), kind: TxnKind.income)))];
  }),
  EvalCase('top-category', '2026 年 8 月花最多錢的主分類是哪一個？花了多少？', (l) {
    final top = byCategory(l, Period.month(2026, 8), TxnKind.expense).first;
    return [ExpectText(top.category!.name), ExpectNumber(top.total)];
  }),
  EvalCase('fuel-year', '2025 年加油總共花了多少？', (l) {
    return [ExpectNumber(_sum(l, _range(DateTime(2025, 1, 1), DateTime(2025, 12, 31), categories: {'fuel'})))];
  }),
  EvalCase('fuel-yoy', '2026 年 1 到 9 月的加油費，比 2025 年同期多還是少？差多少？', (l) {
    final now = _sum(l, _range(DateTime(2026, 1, 1), DateTime(2026, 9, 30), categories: {'fuel'}));
    final before = _sum(l, _range(DateTime(2025, 1, 1), DateTime(2025, 9, 30), categories: {'fuel'}));
    return [ExpectText(now >= before ? '多' : '少'), ExpectNumber((now - before).abs())];
  }),
  EvalCase('eating-out-quarter', '2026 年第三季（7 到 9 月）早餐、午餐、晚餐加起來花了多少？', (l) {
    return [
      ExpectNumber(
        _sum(l, _range(DateTime(2026, 7, 1), DateTime(2026, 9, 30), categories: {'breakfast', 'lunch', 'dinner'})),
      ),
    ];
  }),
  EvalCase('monthly-average', '2026 年 1 到 9 月，平均每個月支出多少？', (l) {
    final total = _sum(l, _range(DateTime(2026, 1, 1), DateTime(2026, 9, 30)));
    return [ExpectNumber((total / Decimal.fromInt(9)).toDecimal(scaleOnInfinitePrecision: 2), tolerance: Decimal.fromInt(5))];
  }),
  EvalCase('shop-count', '我在「星光咖啡」總共消費了幾次？', (l) {
    return [ExpectNumber(Decimal.fromInt(l.transactions(const TxnFilter(keyword: '星光咖啡')).length), tolerance: Decimal.zero)];
  }),
  EvalCase('card-most', '2026 年藍鯨信用卡和橘貓信用卡，哪一張刷得比較多？', (l) {
    Decimal on(String account) => _sum(
      l,
      TxnFilter(from: DateTime(2026, 1, 1), to: evalToday, kinds: const {TxnKind.expense}, accountIds: {account}),
    );
    return [ExpectText(on(_cardA) >= on(_cardB) ? '藍鯨' : '橘貓')];
  }),
  EvalCase('biggest-expense', '2026 年 8 月金額最大的一筆支出是什麼？多少錢？', (l) {
    final biggest = (l.transactions(_range(DateTime(2026, 8, 1), DateTime(2026, 8, 31))).toList()
          ..sort((a, b) => b.baseAmount.compareTo(a.baseAmount)))
        .first;
    return [ExpectNumber(biggest.baseAmount, tolerance: Decimal.zero), ExpectText(biggest.place ?? biggest.note ?? '')];
  }),
  EvalCase('bonus', '2026 年有領到獎金嗎？是哪個月、多少錢？', (l) {
    final bonus = l.transactions(_range(DateTime(2026, 1, 1), evalToday, categories: {'bonus'}, kind: TxnKind.income)).single;
    final m = bonus.date.month;
    return [
      ExpectText('$m 月', alternatives: ['$m月', '${bonus.date.year}-${m.toString().padLeft(2, '0')}']),
      ExpectNumber(bonus.baseAmount, tolerance: Decimal.zero),
    ];
  }),
  EvalCase('month-change', '2026 年 9 月的總支出，和 8 月比多還是少？差多少？', (l) {
    final sep = _sum(l, _range(DateTime(2026, 9, 1), DateTime(2026, 9, 30)));
    final aug = _sum(l, _range(DateTime(2026, 8, 1), DateTime(2026, 8, 31)));
    return [ExpectText(sep >= aug ? '多' : '少'), ExpectNumber((sep - aug).abs())];
  }),
];
