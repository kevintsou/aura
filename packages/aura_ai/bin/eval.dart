// Runs Aura's AI evaluation set against an endpoint and prints how many
// answers were right, with tool calls and tokens used.
//
//   OPENAI_API_KEY=sk-... dart run bin/eval.dart
//   dart run bin/eval.dart --base-url http://localhost:11434/v1 --model qwen3 --key-env NONE
//   dart run bin/eval.dart --only month-total,fuel-year --json report.json
//
// Options:
//   --base-url URL     API root (default https://api.openai.com/v1)
//   --model NAME       model id (default gpt-6-sol)
//   --key-env NAME     environment variable holding the API key
//                      (default OPENAI_API_KEY; NONE for no key)
//   --header "K: V"    extra header, may repeat
//   --no-stream        ask for whole answers
//   --only IDS         comma-separated case ids
//   --json FILE        also write the full report as JSON
//   --list             list the cases and their expected answers, ask nothing
import 'dart:convert';
import 'dart:io';

import 'package:aura_ai/aura_ai.dart';
import 'package:aura_ai/eval.dart';

Future<void> main(List<String> args) async {
  final opts = <String, List<String>>{};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (!a.startsWith('--')) _usage('unexpected "$a"');
    final name = a.substring(2);
    if (const {'no-stream', 'list', 'help'}.contains(name)) {
      opts[name] = const [];
    } else {
      if (i + 1 >= args.length) _usage('$a needs a value');
      opts.putIfAbsent(name, () => []).add(args[++i]);
    }
  }
  if (opts.containsKey('help')) _usage(null);
  String? one(String name) => opts[name]?.last;

  final ledger = evalLedger();
  var cases = defaultEvalCases();
  if (one('only') case final only?) {
    final ids = only.split(',').map((s) => s.trim()).toSet();
    cases = [for (final c in cases) if (ids.contains(c.id)) c];
    if (cases.isEmpty) _usage('no case matches --only $only');
  }
  if (opts.containsKey('list')) {
    for (final c in cases) {
      stdout.writeln('${c.id}: ${c.question}');
      stdout.writeln('    → ${[for (final e in c.expect(ledger)) e.describe()].join('、')}');
    }
    return;
  }

  final keyEnv = one('key-env') ?? 'OPENAI_API_KEY';
  final key = keyEnv == 'NONE' ? null : Platform.environment[keyEnv];
  if (keyEnv != 'NONE' && (key == null || key.isEmpty)) _usage('set $keyEnv, or pass --key-env NONE');
  final config = AiEndpointConfig.defaults.copyWith(
    preset: AiPreset.custom,
    baseUrl: one('base-url') ?? AiEndpointConfig.defaults.baseUrl,
    model: one('model') ?? AiEndpointConfig.defaults.model,
    extraHeaders: {
      for (final h in opts['header'] ?? const <String>[])
        if (h.contains(':')) h.substring(0, h.indexOf(':')).trim(): h.substring(h.indexOf(':') + 1).trim(),
    },
    timeout: const Duration(seconds: 120),
  );
  final client = OpenAiCompatibleClient(config: config, apiKey: key);
  stdout.writeln('${config.model} @ ${config.baseUrl} — ${cases.length} 題\n');

  final report = await runEval(
    client,
    ledger,
    cases,
    stream: !opts.containsKey('no-stream'),
    onResult: (r) {
      final tokens = r.usage == null ? '' : '，tokens ${r.usage!.inputTokens}/${r.usage!.outputTokens}';
      stdout.writeln(
        '${r.passed ? '✓' : '✗'} ${r.evalCase.id}（工具 ${r.toolCalls} 次$tokens，${r.elapsed.inMilliseconds} ms）',
      );
      if (!r.passed) {
        if (r.error != null) stdout.writeln('    錯誤：${r.error}');
        stdout.writeln('    缺少：${[for (final e in r.missed) e.describe()].join('、')}');
        final answer = r.answer.replaceAll('\n', ' ');
        stdout.writeln('    回答：${answer.length > 200 ? '${answer.substring(0, 200)}…' : answer}');
      }
    },
  );
  stdout.writeln(
    '\n答對 ${report.passed}/${report.results.length}（${(report.accuracy * 100).toStringAsFixed(0)}%），'
    '工具呼叫 ${report.toolCalls} 次，tokens 輸入 ${report.inputTokens}／輸出 ${report.outputTokens}',
  );
  if (one('json') case final path?) {
    File(path).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report.toJson()));
    stdout.writeln('報告：$path');
  }
  exit(report.passed == report.results.length ? 0 : 1);
}

Never _usage(String? problem) {
  if (problem != null) stderr.writeln(problem);
  stderr.writeln('usage: dart run bin/eval.dart [--base-url URL] [--model NAME] [--key-env NAME] '
      '[--header "K: V"] [--no-stream] [--only IDS] [--json FILE] [--list]');
  exit(problem == null ? 0 : 64);
}
