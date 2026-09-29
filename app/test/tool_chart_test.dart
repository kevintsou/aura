import 'dart:convert';

import 'package:aura/widgets/tool_chart.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String _result(String groupBy, List<(String, num)> groups, {String kind = 'expense', int? groupCount}) => jsonEncode({
  'kind': kind,
  'group_by': groupBy,
  'total': groups.fold<num>(0, (s, g) => s + g.$2),
  'group_count': groupCount ?? groups.length,
  'groups': [
    for (final (k, t) in groups) {'key': k, 'total': t, 'count': 1},
  ],
});

void main() {
  test('months become columns, with empty months as zero', () {
    final chart = ToolChartData.from('aggregate_transactions', _result('month', [('2026-06', 100), ('2026-09', 250.5)]));
    expect(chart, isA<ToolTimeChart>());
    chart as ToolTimeChart;
    expect(chart.title, '每月支出');
    expect([for (final p in chart.periods) (p.period.from.month, p.total)], [
      (6, Decimal.fromInt(100)),
      (7, Decimal.zero),
      (8, Decimal.zero),
      (9, Decimal.parse('250.5')),
    ]);
  });

  test('weeks and years too', () {
    final weeks = ToolChartData.from('aggregate_transactions', _result('week', [('2026-09-07', 1), ('2026-09-21', 2)]));
    expect([for (final p in (weeks as ToolTimeChart).periods) p.period.from.day], [7, 14, 21]);
    final years = ToolChartData.from('aggregate_transactions', _result('year', [('2024', 1), ('2026', 2)], kind: 'income'));
    expect(years!.title, '每年收入');
    expect((years as ToolTimeChart).periods, hasLength(3));
  });

  test('other groupings become a ranked list', () {
    final chart = ToolChartData.from(
      'aggregate_transactions',
      _result('main_category', [('餐飲', 600), ('交通', 300), ('其他', 100)], groupCount: 5),
    );
    chart as ToolRankChart;
    expect(chart.title, '依主分類的支出');
    expect(chart.groups.first, ('餐飲', Decimal.fromInt(600)));
    expect(chart.more, 2);
  });

  test('nothing to draw', () {
    expect(ToolChartData.from('search_transactions', _result('month', [('2026-06', 1), ('2026-07', 1)])), isNull);
    expect(ToolChartData.from('aggregate_transactions', _result('main_category', [('餐飲', 1)])), isNull);
    expect(ToolChartData.from('aggregate_transactions', _result('day', [('2026-06-01', 1), ('2026-06-02', 1)])), isNull);
    expect(ToolChartData.from('aggregate_transactions', 'not json'), isNull);
    expect(ToolChartData.from('aggregate_transactions', _result('month', [('2020-01', 1), ('2026-01', 1)])), isNull);
  });

  testWidgets('a ranked list writes out every value it draws', (tester) async {
    final chart = ToolChartData.from(
      'aggregate_transactions',
      _result('seller', [for (var i = 1; i <= 10; i++) ('商家$i', 1100 - i * 100)]),
    )!;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ToolChart(data: chart)))));
    expect(find.text('依商家的支出'), findsOneWidget);
    expect(find.text('商家1'), findsOneWidget);
    expect(find.text('NT\$1,000'), findsOneWidget);
    expect(find.text('商家9'), findsNothing);
    expect(find.text('另外 2 項沒有畫出來'), findsOneWidget);
  });

  testWidgets('columns are readable by screen readers', (tester) async {
    final chart = ToolChartData.from('aggregate_transactions', _result('month', [('2026-08', 100), ('2026-09', 200)]))!;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ToolChart(data: chart))));
    expect(find.byKey(const Key('toolTimeChart')), findsOneWidget);
    expect(find.semantics.byLabel(RegExp('2026年9月 NT\\\$200')), findsOneWidget);
  });
}
