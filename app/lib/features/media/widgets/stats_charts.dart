/// Watch-statistics charts (fl_chart; explicit text styles from the theme,
/// ARCHITECTURE §7.1).
///
/// Categorical colours follow the entity (a library keeps its colour for
/// the period: slot = its index in `WatchStats.libraries`), in a fixed order
/// validated for colour-vision deficiencies, with a light and a dark step.
library;

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:yams_models/yams_models.dart';

import 'media_common.dart';

const _categoricalLight = [
  Color(0xFF2A78D6),
  Color(0xFFEB6834),
  Color(0xFF1BAF7A),
  Color(0xFFEDA100),
  Color(0xFFE87BA4),
  Color(0xFF008300),
  Color(0xFF6250D6),
  Color(0xFFE34948),
];

const _categoricalDark = [
  Color(0xFF3987E5),
  Color(0xFFD95926),
  Color(0xFF199E70),
  Color(0xFFC98500),
  Color(0xFFD55181),
  Color(0xFF008300),
  Color(0xFF9085E9),
  Color(0xFFE66767),
];

/// The categorical colour of slot [index] (series 9+ share the last
/// neutral "other" colour rather than inventing hues).
Color chartColor(BuildContext context, int index) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final palette = dark ? _categoricalDark : _categoricalLight;
  if (index < palette.length) return palette[index];
  return Theme.of(context).colorScheme.outline;
}

TextStyle? _axisStyle(BuildContext context) =>
    Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);

FlGridData _grid(BuildContext context) => FlGridData(
  drawVerticalLine: false,
  getDrawingHorizontalLine: (_) =>
      FlLine(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5), strokeWidth: 1),
);

double _niceMax(num max) {
  if (max <= 0) return 4;
  final m = max.toDouble();
  final mag = math.pow(10, (math.log(m) / math.ln10).floor()).toDouble();
  for (final step in [1, 2, 2.5, 5, 10]) {
    if (step * mag >= m) return step * mag;
  }
  return 10 * mag;
}

double _interval(double max) => max <= 4 ? 1 : max / 4;

BarTouchTooltipData _tooltip(BuildContext context, String Function(int group) label) {
  final theme = Theme.of(context);
  return BarTouchTooltipData(
    getTooltipColor: (_) => theme.colorScheme.inverseSurface,
    tooltipBorderRadius: BorderRadius.circular(8),
    fitInsideHorizontally: true,
    fitInsideVertically: true,
    getTooltipItem: (group, _, _, _) => BarTooltipItem(
      label(group.x),
      theme.textTheme.labelMedium!.copyWith(color: theme.colorScheme.onInverseSurface),
    ),
  );
}

/// A legend row of coloured swatches with labels (identity is never colour
/// alone).
class ChartLegend extends StatelessWidget {
  const ChartLegend({super.key, required this.entries});

  final List<({Color color, String label})> entries;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium;
    return Wrap(
      spacing: 16,
      runSpacing: 6,
      children: [
        for (final e in entries)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(color: e.color, borderRadius: BorderRadius.circular(3)),
              ),
              const SizedBox(width: 6),
              Text(e.label, style: style),
            ],
          ),
      ],
    );
  }
}

/// Plays per day, stacked by library.
class ViewsOverTimeChart extends StatelessWidget {
  const ViewsOverTimeChart({super.key, required this.stats, this.height = 200});

  final WatchStats stats;
  final double height;

  @override
  Widget build(BuildContext context) {
    final libs = stats.libraries;
    final points = stats.viewsOverTime;
    final surface = Theme.of(context).colorScheme.surface;
    final maxY = _niceMax(points.fold<int>(0, (m, p) => math.max(m, p.totalPlays)));
    final barWidth = points.isEmpty ? 8.0 : (240 / points.length).clamp(2.0, 14.0);
    final labelEvery = math.max(1, (points.length / 6).ceil());
    String dayLabel(int i) {
      if (i < 0 || i >= points.length) return '';
      final d = DateTime.tryParse(points[i].date);
      return d == null ? points[i].date : '${d.day}/${d.month}';
    }

    // Libraries present in the data, in the stats' library order.
    final used = [
      for (final (i, l) in libs.indexed)
        if (points.any((p) => (p.plays[l.id] ?? 0) > 0)) (index: i, lib: l),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: height,
          child: BarChart(
            BarChartData(
              maxY: maxY,
              minY: 0,
              alignment: BarChartAlignment.spaceBetween,
              gridData: _grid(context),
              borderData: FlBorderData(show: false),
              barTouchData: BarTouchData(
                touchTooltipData: _tooltip(context, (x) {
                  final p = points[x];
                  final lines = [
                    for (final u in used)
                      if ((p.plays[u.lib.id] ?? 0) > 0) '${u.lib.name}: ${p.plays[u.lib.id]}',
                  ];
                  return [dayLabel(x), if (lines.isEmpty) 'No plays' else ...lines].join('\n');
                }),
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 28,
                    interval: _interval(maxY),
                    getTitlesWidget: (v, meta) => SideTitleWidget(
                      meta: meta,
                      child: Text(v.toInt().toString(), style: _axisStyle(context)),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 22,
                    getTitlesWidget: (v, meta) {
                      final i = v.toInt();
                      final show = i % labelEvery == 0 || i == points.length - 1;
                      return SideTitleWidget(
                        meta: meta,
                        child: Text(show ? dayLabel(i) : '', style: _axisStyle(context)),
                      );
                    },
                  ),
                ),
              ),
              barGroups: [
                for (final (x, p) in points.indexed)
                  () {
                    var from = 0.0;
                    final items = <BarChartRodStackItem>[];
                    for (final u in used) {
                      final n = (p.plays[u.lib.id] ?? 0).toDouble();
                      if (n <= 0) continue;
                      items.add(
                        BarChartRodStackItem(
                          from,
                          from + n,
                          chartColor(context, u.index),
                          borderSide: BorderSide(color: surface, width: 1),
                        ),
                      );
                      from += n;
                    }
                    return BarChartGroupData(
                      x: x,
                      barRods: [
                        BarChartRodData(
                          toY: from,
                          width: barWidth,
                          color: Colors.transparent,
                          rodStackItems: items,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                        ),
                      ],
                    );
                  }(),
              ],
            ),
          ),
        ),
        if (used.isNotEmpty) ...[
          const SizedBox(height: 8),
          ChartLegend(entries: [for (final u in used) (color: chartColor(context, u.index), label: u.lib.name)]),
        ],
      ],
    );
  }
}

/// A single-series bar chart (plays by weekday or by hour).
class SimpleBarChart extends StatelessWidget {
  const SimpleBarChart({
    super.key,
    required this.values,
    required this.labelFor,
    this.tooltipFor,
    this.height = 140,
    this.labelEvery = 1,
  });

  final List<int> values;
  final String Function(int index) labelFor;
  final String Function(int index)? tooltipFor;
  final double height;
  final int labelEvery;

  @override
  Widget build(BuildContext context) {
    final maxY = _niceMax(values.fold<int>(0, math.max));
    final color = chartColor(context, 0);
    return SizedBox(
      height: height,
      child: BarChart(
        BarChartData(
          maxY: maxY,
          minY: 0,
          gridData: _grid(context),
          borderData: FlBorderData(show: false),
          barTouchData: BarTouchData(
            touchTooltipData: _tooltip(
              context,
              (x) => tooltipFor?.call(x) ?? '${labelFor(x)}: ${values[x]} ${values[x] == 1 ? 'play' : 'plays'}',
            ),
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                interval: _interval(maxY),
                getTitlesWidget: (v, meta) => SideTitleWidget(
                  meta: meta,
                  child: Text(v.toInt().toString(), style: _axisStyle(context)),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                getTitlesWidget: (v, meta) {
                  final i = v.toInt();
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(i % labelEvery == 0 ? labelFor(i) : '', style: _axisStyle(context)),
                  );
                },
              ),
            ),
          ),
          barGroups: [
            for (final (x, v) in values.indexed)
              BarChartGroupData(
                x: x,
                barRods: [
                  BarChartRodData(
                    toY: v.toDouble(),
                    color: color,
                    width: values.length > 12 ? 6 : 14,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Plays per play method as a donut with percentages.
class PlayMethodDonut extends StatelessWidget {
  const PlayMethodDonut({super.key, required this.methods});

  final List<WatchPlayMethodCount> methods;

  static const _order = [MediaPlayMethod.directPlay, MediaPlayMethod.directStream, MediaPlayMethod.transcode];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final counts = {for (final m in _order) m: 0};
    var other = 0;
    for (final m in methods) {
      if (counts.containsKey(m.method)) {
        counts[m.method] = counts[m.method]! + m.count;
      } else {
        other += m.count;
      }
    }
    final total = counts.values.fold(0, (a, b) => a + b) + other;
    String pct(int n) => total == 0 ? '0 %' : '${(n * 100 / total).round()} %';
    final entries = [
      for (final (i, m) in _order.indexed) (color: chartColor(context, i), label: m.label, count: counts[m]!),
      if (other > 0) (color: theme.colorScheme.outline, label: 'Other', count: other),
    ];
    final sections = total == 0
        ? [
            PieChartSectionData(
              value: 1,
              color: theme.colorScheme.surfaceContainerHighest,
              showTitle: false,
              radius: 18,
            ),
          ]
        : [
            for (final e in entries)
              if (e.count > 0)
                PieChartSectionData(value: e.count.toDouble(), color: e.color, showTitle: false, radius: 18),
          ];
    return Row(
      children: [
        SizedBox(
          width: 120,
          height: 120,
          child: Stack(
            alignment: Alignment.center,
            children: [
              PieChart(PieChartData(sections: sections, centerSpaceRadius: 38, sectionsSpace: total == 0 ? 0 : 2)),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('$total', style: theme.textTheme.titleMedium),
                  Text(total == 1 ? 'play' : 'plays', style: _axisStyle(context)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final e in entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(color: e.color, borderRadius: BorderRadius.circular(3)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(e.label, style: theme.textTheme.bodyMedium)),
                      Text('${pct(e.count)} · ${e.count}', style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Seven bars of listening time (Audiobookshelf), labelled by weekday.
class ListeningWeekChart extends StatelessWidget {
  const ListeningWeekChart({super.key, required this.days});

  final List<AudiobookListeningDay> days;

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    String label(int i) {
      final d = DateTime.tryParse(days[i].date);
      return d == null ? '' : _weekdays[d.weekday - 1];
    }

    final minutes = [for (final d in days) (d.seconds / 60).round()];
    return SimpleBarChart(
      values: minutes,
      labelFor: label,
      tooltipFor: (i) => '${label(i)}: ${formatWatchTime(days[i].seconds)}',
      height: 120,
    );
  }
}
