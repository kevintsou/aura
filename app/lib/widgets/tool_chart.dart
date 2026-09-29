import 'dart:convert';

import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../screens/reports_screen.dart';
import 'charts.dart';

/// What a tool result can be drawn as: columns over time, or a ranked list.
sealed class ToolChartData {
  const ToolChartData(this.title);
  final String title;

  /// A chart for an `aggregate_transactions` result, or null when there is
  /// nothing worth drawing (another tool, an error, a single group, days).
  static ToolChartData? from(String toolName, String content) {
    if (toolName != 'aggregate_transactions') return null;
    final Object? json;
    try {
      json = jsonDecode(content);
    } on FormatException {
      return null;
    }
    if (json is! Map<String, Object?> || json['groups'] is! List) return null;
    final groups = [
      for (final g in json['groups'] as List)
        if (g case {'key': final String key, 'total': final num total}) (key, Decimal.parse(total.toString())),
    ];
    if (groups.length < 2) return null;
    final what = json['kind'] == 'income' ? '收入' : '支出';
    final by = json['group_by'];
    final dimension = switch (by) {
      'main_category' => '主分類',
      'subcategory' => '子分類',
      'account' => '帳戶',
      'project' => '專案',
      'seller' => '商家',
      'year' => '年',
      'month' => '月',
      'week' => '週',
      _ => null,
    };
    if (dimension == null) return null;
    if (by case 'year' || 'month' || 'week') {
      final periods = <Period, Decimal>{};
      for (final (key, total) in groups) {
        final p = _period(by as String, key);
        if (p == null) return null;
        periods[p] = total;
      }
      // Fill the gaps: a period with no records is a zero, not missing.
      final sorted = periods.keys.toList()..sort((a, b) => a.from.compareTo(b.from));
      final all = <PeriodTotal>[];
      for (var p = sorted.first; !p.from.isAfter(sorted.last.from); p = p.next) {
        all.add(PeriodTotal(p, periods[p] ?? Decimal.zero));
        if (all.length > 60) return null; // too many to draw legibly
      }
      return ToolTimeChart('每$dimension$what', all);
    }
    // Shares of everything found, the groups not listed included.
    final total = switch (json['total']) {
      final num t => Decimal.parse(t.toString()),
      _ => groups.fold(Decimal.zero, (s, g) => s + g.$2),
    };
    return ToolRankChart('依$dimension的$what', groups, total: total, more: (json['group_count'] as num? ?? 0).toInt() - groups.length);
  }

  static Period? _period(String by, String key) {
    try {
      return switch (by) {
        'year' => Period.year(int.parse(key)),
        'month' => Period.month(int.parse(key.substring(0, 4)), int.parse(key.substring(5, 7))),
        _ => Period.week(DateTime.parse(key)),
      };
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }
}

class ToolTimeChart extends ToolChartData {
  const ToolTimeChart(super.title, this.periods);
  final List<PeriodTotal> periods;
}

class ToolRankChart extends ToolChartData {
  const ToolRankChart(super.title, this.groups, {required this.total, this.more = 0});
  final List<(String, Decimal)> groups;
  final Decimal total;

  /// Groups the tool left out.
  final int more;
}

/// Draws a tool result in the assistant transcript, so the numbers the
/// answer rests on can be seen at a glance.
class ToolChart extends StatelessWidget {
  const ToolChart({super.key, required this.data});

  static const _shown = 8;

  final ToolChartData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card.outlined(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(data.title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            switch (data) {
              ToolTimeChart(:final periods) => PeriodColumns(
                key: const Key('toolTimeChart'),
                months: periods,
                selected: null,
                onSelect: (_) {},
                height: 160,
              ),
              ToolRankChart(:final groups, :final total, :final more) => Column(
                key: const Key('toolRankChart'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (label, value) in groups.take(_shown))
                    ShareRow(
                      label: label,
                      total: value,
                      share: total == Decimal.zero ? 0 : (value / total).toDouble() * 100,
                      max: groups.first.$2,
                    ),
                  if (groups.length - _shown + more > 0)
                    Text(
                      '另外 ${groups.length - _shown + more} 項沒有畫出來',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                ],
              ),
            },
          ],
        ),
      ),
    );
  }
}
