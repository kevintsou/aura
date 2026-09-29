import 'package:aura_ai/aura_ai.dart';
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';

/// `NT$12,345` / `-NT$1,874.5`; other currencies use their code.
String formatMoney(Decimal amount, {String currency = baseCurrency}) {
  final negative = amount < Decimal.zero;
  final text = amount.abs().round(scale: 2).toString();
  final dot = text.indexOf('.');
  final whole = dot < 0 ? text : text.substring(0, dot);
  final fraction = dot < 0 ? '' : text.substring(dot);
  final grouped = whole.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  final symbol = currency == baseCurrency ? 'NT\$' : '$currency ';
  return '${negative ? '-' : ''}$symbol$grouped$fraction';
}

String formatDate(DateTime d) =>
    '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

/// Human label for a tool call, shown in the assistant transcript.
String describeToolCall(ToolCall call) => switch (call.name) {
  'get_ledger_overview' => '讀取帳本結構（帳戶、分類、日期範圍）',
  'aggregate_transactions' => '彙總收支',
  'search_transactions' => '搜尋交易明細',
  'search_invoice_items' => '搜尋發票品項',
  _ => '呼叫工具 ${call.name}',
};
