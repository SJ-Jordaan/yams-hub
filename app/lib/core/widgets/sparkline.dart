import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// A minimal line chart without axes (host CPU history, ...). Built on
/// fl_chart, the app's only chart library.
class Sparkline extends StatelessWidget {
  const Sparkline({super.key, required this.values, this.color, this.height = 40, this.minY, this.maxY, this.fill = true});

  final List<double> values;
  final Color? color;
  final double height;
  final double? minY;
  final double? maxY;
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    if (values.length < 2) return SizedBox(height: height);
    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minY: minY,
          maxY: maxY,
          gridData: const FlGridData(show: false),
          titlesData: const FlTitlesData(show: false),
          borderData: FlBorderData(show: false),
          lineTouchData: const LineTouchData(enabled: false),
          clipData: const FlClipData.all(),
          lineBarsData: [
            LineChartBarData(
              spots: [for (var i = 0; i < values.length; i++) FlSpot(i.toDouble(), values[i])],
              isCurved: true,
              curveSmoothness: 0.2,
              color: c,
              barWidth: 2,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(show: fill, color: c.withValues(alpha: 0.15)),
            ),
          ],
        ),
        duration: Duration.zero,
      ),
    );
  }
}
