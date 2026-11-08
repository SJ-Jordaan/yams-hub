/// A time-series line chart for `GET /system/history` (fl_chart). fl_chart
/// does not read the theme, so every text gets an explicit style from
/// `Theme.of(context).textTheme` (ARCHITECTURE §7.1).
library;

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:yams_hub/core/widgets/formatters.dart';
import 'package:yams_models/yams_models.dart';

/// One line of a [MetricChart].
class ChartLine {
  const ChartLine({required this.label, required this.color, required this.points});

  final String label;
  final Color color;
  final List<MetricSeriesPoint> points;
}

/// Formats a value of [unit] for axes and tooltips.
String formatMetricValue(double v, MetricSeriesUnit unit) => switch (unit) {
  MetricSeriesUnit.percent => '${v.round()} %',
  MetricSeriesUnit.celsius => '${v.round()} °C',
  MetricSeriesUnit.bps => formatBps(v.round()),
  MetricSeriesUnit.bytes => formatBytes(v.round()),
  MetricSeriesUnit.unknown => v.toStringAsFixed(1),
};

class MetricChart extends StatelessWidget {
  const MetricChart({
    super.key,
    required this.title,
    required this.lines,
    required this.unit,
    required this.range,
    this.height = 140,
    this.minY,
    this.maxY,
  });

  final String title;
  final List<ChartLine> lines;
  final MetricSeriesUnit unit;
  final HostHistoryRange range;
  final double height;
  final double? minY;
  final double? maxY;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final axisStyle = theme.textTheme.labelSmall!.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final tooltipStyle = theme.textTheme.labelMedium!.copyWith(color: theme.colorScheme.onInverseSurface);
    final hasData = lines.any((l) => l.points.isNotEmpty);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
            if (lines.length > 1)
              for (final l in lines) _LegendEntry(line: l, style: axisStyle),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: height,
          child: hasData
              ? _chart(context, axisStyle, tooltipStyle)
              : Center(child: Text('No samples yet', style: axisStyle)),
        ),
      ],
    );
  }

  Widget _chart(BuildContext context, TextStyle axisStyle, TextStyle tooltipStyle) {
    final theme = Theme.of(context);
    final all = [for (final l in lines) ...l.points];
    final minX = all.map((p) => p.t.millisecondsSinceEpoch).reduce(math.min).toDouble();
    var maxX = all.map((p) => p.t.millisecondsSinceEpoch).reduce(math.max).toDouble();
    if (maxX <= minX) maxX = minX + 1000;
    final maxValue = all.map((p) => p.v).reduce(math.max);
    final top = maxY ?? (maxValue <= 0 ? 1.0 : maxValue * 1.15);
    final bottom = minY ?? 0;
    final xInterval = range == HostHistoryRange.hour
        ? const Duration(minutes: 15).inMilliseconds.toDouble()
        : const Duration(hours: 6).inMilliseconds.toDouble();
    final timeFormat = range == HostHistoryRange.hour ? DateFormat.Hm() : DateFormat('E HH:mm');

    return LineChart(
      LineChartData(
        minX: minX,
        maxX: maxX,
        minY: bottom,
        maxY: top,
        clipData: const FlClipData.all(),
        borderData: FlBorderData(show: false),
        gridData: FlGridData(
          drawVerticalLine: false,
          horizontalInterval: (top - bottom) / 4,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5), strokeWidth: 0.5),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: unit == MetricSeriesUnit.bps || unit == MetricSeriesUnit.bytes ? 60 : 40,
              interval: (top - bottom) / 2,
              minIncluded: true,
              maxIncluded: false,
              getTitlesWidget: (value, meta) => SideTitleWidget(
                meta: meta,
                space: 4,
                child: Text(formatMetricValue(value, unit), style: axisStyle),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: xInterval,
              minIncluded: false,
              maxIncluded: false,
              getTitlesWidget: (value, meta) => SideTitleWidget(
                meta: meta,
                child: Text(
                  timeFormat.format(DateTime.fromMillisecondsSinceEpoch(value.round(), isUtc: true).toLocal()),
                  style: axisStyle,
                ),
              ),
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => theme.colorScheme.inverseSurface,
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            maxContentWidth: 200,
            getTooltipItems: (spots) => [
              for (var i = 0; i < spots.length; i++)
                LineTooltipItem(
                  [
                    if (i == 0)
                      timeFormat.format(DateTime.fromMillisecondsSinceEpoch(spots[i].x.round(), isUtc: true).toLocal()),
                    '${lines.length > 1 ? '${lines[spots[i].barIndex].label} ' : ''}'
                        '${formatMetricValue(spots[i].y, unit)}',
                  ].join('\n'),
                  tooltipStyle,
                ),
            ],
          ),
        ),
        lineBarsData: [
          for (final l in lines)
            LineChartBarData(
              spots: [for (final p in l.points) FlSpot(p.t.millisecondsSinceEpoch.toDouble(), p.v)],
              isCurved: false,
              color: l.color,
              barWidth: 1.5,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(show: lines.length == 1, color: l.color.withValues(alpha: 0.12)),
            ),
        ],
      ),
      duration: Duration.zero,
    );
  }
}

class _LegendEntry extends StatelessWidget {
  const _LegendEntry({required this.line, required this.style});

  final ChartLine line;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 3,
            decoration: BoxDecoration(color: line.color, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 4),
          Text(line.label, style: style),
        ],
      ),
    );
  }
}
