import 'dart:math' as math;

import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../format.dart';

/// Chart colours, validated with the dataviz palette checks: the accent
/// and the de-emphasis gray clear 3:1 on both surfaces and stay apart
/// under colour-vision deficiency.
class ChartColors {
  const ChartColors._({
    required this.accent,
    required this.muted,
    required this.grid,
    required this.baseline,
    required this.good,
    required this.bad,
  });

  static const _light = ChartColors._(
    accent: Color(0xFF2A78D6),
    muted: Color(0xFF898781),
    grid: Color(0xFFE1E0D9),
    baseline: Color(0xFFC3C2B7),
    good: Color(0xFF006300),
    bad: Color(0xFFD03B3B),
  );
  static const _dark = ChartColors._(
    accent: Color(0xFF3987E5),
    muted: Color(0xFF898781),
    grid: Color(0xFF2C2C2A),
    baseline: Color(0xFF383835),
    good: Color(0xFF0CA30C),
    bad: Color(0xFFD03B3B),
  );

  static ChartColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? _dark : _light;

  /// The highlighted mark.
  final Color accent;

  /// Marks that give context (emphasis form: one accent, the rest gray).
  final Color muted;
  final Color grid;
  final Color baseline;

  /// Delta text: a change for the better / worse. Always paired with an
  /// arrow icon and words, never colour alone.
  final Color good;
  final Color bad;
}

/// `1,234` below ten thousand, then `1.2萬`, `3.4億`.
String compactNumber(num value) {
  final v = value.abs();
  final sign = value < 0 ? '-' : '';
  String trim(double x) => x.toStringAsFixed(x >= 100 ? 0 : 1).replaceAll(RegExp(r'\.0$'), '');
  if (v >= 1e8) return '$sign${trim(v / 1e8)}億';
  if (v >= 1e4) return '$sign${trim(v / 1e4)}萬';
  return sign + v.round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
}

/// A round step so that [max] fits in about three gridlines.
double niceStep(double max) {
  if (max <= 0) return 1;
  final raw = max / 3;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  for (final m in const [1, 2, 2.5, 5, 10]) {
    if (m * mag >= raw) return m * mag;
  }
  return 10 * mag;
}

/// Monthly columns in the emphasis form: the selected month in the
/// accent, the others in gray. Tap a column to select its month.
class MonthColumns extends StatelessWidget {
  const MonthColumns({
    super.key,
    required this.months,
    required this.selected,
    required this.onSelect,
    this.height = 180,
    this.reference,
    this.referenceLabel = '預算',
  });

  final List<MonthTotal> months;

  /// A level to compare against (a budget), drawn as a dashed line.
  final Decimal? reference;
  final String referenceLabel;

  /// Year and month of the highlighted column, if it is on the chart.
  final (int, int)? selected;
  final ValueChanged<MonthTotal> onSelect;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = ChartColors.of(context);
    final text = Theme.of(context).textTheme.labelSmall!;
    return LayoutBuilder(
      builder: (context, box) {
        final painter = _ColumnsPainter(
          months: months,
          selected: selected,
          colors: colors,
          reference: reference?.toDouble(),
          referenceLabel: referenceLabel,
          referenceColor: Theme.of(context).colorScheme.onSurfaceVariant,
          textStyle: text.copyWith(color: colors.muted),
          valueStyle: text.copyWith(
            color: Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        );
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            final i = painter.indexAt(d.localPosition, Size(box.maxWidth, height));
            if (i != null) onSelect(months[i]);
          },
          child: CustomPaint(size: Size(box.maxWidth, height), painter: painter),
        );
      },
    );
  }
}

class _ColumnsPainter extends CustomPainter {
  _ColumnsPainter({
    required this.months,
    required this.selected,
    required this.colors,
    required this.textStyle,
    required this.valueStyle,
    this.reference,
    this.referenceLabel = '',
    this.referenceColor = const Color(0xFF000000),
  });

  final List<MonthTotal> months;
  final (int, int)? selected;
  final ChartColors colors;
  final double? reference;
  final String referenceLabel;
  final Color referenceColor;
  final TextStyle textStyle;
  final TextStyle valueStyle;

  static const _axisWidth = 44.0;
  static const _labelHeight = 30.0;
  static const _top = 20.0; // room for the selected column's value

  double get _max => months.fold(reference ?? 0.0, (m, e) => math.max(m, e.total.toDouble()));
  double get _min => months.fold(0.0, (m, e) => math.min(m, e.total.toDouble()));

  double _slot(Size size) => (size.width - _axisWidth) / months.length;

  int? indexAt(Offset p, Size size) {
    if (p.dx < _axisWidth || months.isEmpty) return null;
    final i = ((p.dx - _axisWidth) / _slot(size)).floor();
    return i >= 0 && i < months.length ? i : null;
  }

  TextPainter _text(String s, {TextAlign align = TextAlign.center}) =>
      TextPainter(text: TextSpan(text: s, style: textStyle), textDirection: TextDirection.ltr, textAlign: align)
        ..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final step = niceStep(math.max(_max, -_min));
    final top = (_max / step).ceil() * step;
    final bottom = (_min / step).floor() * step;
    final span = (top - bottom) == 0 ? 1 : top - bottom;
    final plotH = size.height - _labelHeight - _top;
    double y(double v) => _top + (top - v) / span * plotH;

    // Gridlines and tick labels: recessive hairlines, clean numbers.
    final grid = Paint()
      ..color = colors.grid
      ..strokeWidth = 1;
    for (var v = bottom; v <= top + step / 2; v += step) {
      final yy = y(v).roundToDouble() + 0.5;
      canvas.drawLine(Offset(_axisWidth, yy), Offset(size.width, yy), grid);
      final label = _text(compactNumber(v), align: TextAlign.right);
      label.paint(canvas, Offset(_axisWidth - 6 - label.width, yy - label.height / 2));
    }
    // Baseline at zero.
    canvas.drawLine(
      Offset(_axisWidth, y(0)),
      Offset(size.width, y(0)),
      Paint()
        ..color = colors.baseline
        ..strokeWidth = 1,
    );

    final slot = _slot(size);
    final barW = math.min(24.0, slot * 0.6);
    for (final (i, m) in months.indexed) {
      final isSel = selected == (m.year, m.month);
      final cx = _axisWidth + slot * i + slot / 2;
      final v = m.total.toDouble();
      if (v != 0) {
        final rect = Rect.fromLTRB(cx - barW / 2, math.min(y(v), y(0)), cx + barW / 2, math.max(y(v), y(0)));
        // 4px rounded data end, square at the baseline.
        final rr = v > 0
            ? RRect.fromRectAndCorners(rect, topLeft: const Radius.circular(4), topRight: const Radius.circular(4))
            : RRect.fromRectAndCorners(rect, bottomLeft: const Radius.circular(4), bottomRight: const Radius.circular(4));
        // With nothing selected every column is the one series, in the accent.
        canvas.drawRRect(rr, Paint()..color = isSel || selected == null ? colors.accent : colors.muted);
      }
      // Month numbers; the year under the first column and each January.
      final label = _text(m.month == 1 || i == 0 ? '${m.month}\n${m.year}' : '${m.month}');
      label.paint(canvas, Offset(cx - label.width / 2, size.height - _labelHeight + 4));
      if (isSel && v != 0 && !(reference != null && (y(v) - y(reference!)).abs() < 14)) {
        // The highlighted column's value sits on its cap, in text ink.
        final value = TextPainter(
          text: TextSpan(text: compactNumber(v), style: valueStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        final capY = v > 0 ? y(v) - value.height - 2 : y(v) + 2;
        final x = (cx - value.width / 2).clamp(_axisWidth, size.width - value.width);
        value.paint(canvas, Offset(x, capY.clamp(0, size.height - _labelHeight - value.height)));
      }
    }
    if (reference != null) _paintReference(canvas, size, y(reference!).roundToDouble() + 0.5);
  }

  void _paintReference(Canvas canvas, Size size, double y) {
    final paint = Paint()
      ..color = referenceColor
      ..strokeWidth = 1.5;
    for (var x = _axisWidth; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, y), Offset(math.min(x + 4, size.width), y), paint);
    }
    final label = TextPainter(
      text: TextSpan(text: referenceLabel, style: textStyle.copyWith(color: referenceColor)),
      textDirection: TextDirection.ltr,
    )..layout();
    // At the left end, where the oldest (least relevant) column is.
    label.paint(canvas, Offset(_axisWidth + 2, y - label.height - 1));
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
    final slot = _slot(size);
    return [
      for (final (i, m) in months.indexed)
        CustomPainterSemantics(
          rect: Rect.fromLTWH(_axisWidth + slot * i, 0, slot, size.height),
          properties: SemanticsProperties(
            label: '${m.year}年${m.month}月 ${formatMoney(m.total)}',
            selected: selected == (m.year, m.month),
            textDirection: TextDirection.ltr,
          ),
        ),
    ];
  };

  @override
  bool shouldRepaint(_ColumnsPainter old) =>
      old.months != months || old.selected != selected || old.colors != colors || old.reference != reference;

  @override
  bool shouldRebuildSemantics(_ColumnsPainter old) => shouldRepaint(old);
}

/// One horizontal magnitude bar (single hue), for ranked lists.
class ShareBar extends StatelessWidget {
  const ShareBar({super.key, required this.fraction});

  /// 0–1 of the longest bar in the list.
  final double fraction;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 8,
    child: Align(
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: fraction.clamp(0, 1),
        heightFactor: 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: ChartColors.of(context).accent,
            // Rounded at the data end, square at the baseline.
            borderRadius: const BorderRadius.horizontal(right: Radius.circular(4)),
          ),
        ),
      ),
    ),
  );
}

/// Fraction of [value] relative to [max], 0 when either is not positive.
double fractionOf(Decimal value, Decimal max) =>
    max > Decimal.zero && value > Decimal.zero ? (value / max).toDouble() : 0;

/// Budget progress: a bar of the share spent, a tick for how much of the
/// month has gone by, and the over-budget state in the "bad" colour
/// (always with words next to it, never colour alone).
class BudgetMeter extends StatelessWidget {
  const BudgetMeter({super.key, required this.used, this.elapsed, this.over = false});

  /// Share spent; above 1 when over budget.
  final double used;

  /// Share of the month gone; null outside the current month.
  final double? elapsed;
  final bool over;

  @override
  Widget build(BuildContext context) {
    final colors = ChartColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '已用 ${(used * 100).round()}%'
          '${elapsed == null ? '' : '，本月已過 ${(elapsed! * 100).round()}%'}',
      child: SizedBox(
        height: 16,
        child: LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            final fill = (used.clamp(0.0, 1.0) * w).toDouble();
            return Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 3,
                  height: 10,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  width: fill,
                  top: 3,
                  height: 10,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: over ? colors.bad : colors.accent,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                if (elapsed != null)
                  Positioned(
                    left: (elapsed!.clamp(0.0, 1.0) * w - 1).clamp(0.0, w - 2).toDouble(),
                    width: 2,
                    top: 0,
                    bottom: 0,
                    child: ColoredBox(color: scheme.onSurface),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
