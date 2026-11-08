/// The host history charts with the 1 h / 24 h toggle (APP.md §12).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/widgets/skeleton.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/system_providers.dart';
import 'metric_chart.dart';
import 'system_format.dart';

class HostHistoryCharts extends ConsumerWidget {
  const HostHistoryCharts({super.key, required this.sources});

  /// Which optional sources exist (charts without a source show its note).
  final HostSources sources;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(systemHistoryRangeProvider);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(child: Text('History', style: Theme.of(context).textTheme.titleSmall)),
            SegmentedButton<HostHistoryRange>(
              key: const Key('system.historyRange'),
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: HostHistoryRange.hour, label: Text('1 h')),
                ButtonSegment(value: HostHistoryRange.day, label: Text('24 h')),
              ],
              selected: {range},
              onSelectionChanged: (s) => ref.read(systemHistoryRangeProvider.notifier).select(s.first),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _SeriesChart(
          title: 'CPU',
          range: range,
          unit: MetricSeriesUnit.percent,
          maxY: 100,
          metrics: [(HostMetricKind.cpu, 'CPU', scheme.primary)],
        ),
        const SizedBox(height: 20),
        if (sources.temperature)
          _SeriesChart(
            title: 'Temperature',
            range: range,
            unit: MetricSeriesUnit.celsius,
            metrics: [(HostMetricKind.temperature, 'Package', scheme.tertiary)],
          )
        else
          const _ChartNote(title: 'Temperature', text: temperatureUnavailableText),
        const SizedBox(height: 20),
        if (sources.hostNetwork)
          _SeriesChart(
            title: 'Network',
            range: range,
            unit: MetricSeriesUnit.bps,
            metrics: [(HostMetricKind.netRx, 'Down', scheme.primary), (HostMetricKind.netTx, 'Up', scheme.tertiary)],
          )
        else
          const _ChartNote(title: 'Network', text: hostNetworkUnavailableText),
        const SizedBox(height: 20),
        _SeriesChart(
          title: 'Disk',
          range: range,
          unit: MetricSeriesUnit.bps,
          metrics: [
            (HostMetricKind.diskRead, 'Read', scheme.primary),
            (HostMetricKind.diskWrite, 'Write', scheme.tertiary),
          ],
        ),
      ],
    );
  }
}

class _SeriesChart extends ConsumerWidget {
  const _SeriesChart({required this.title, required this.range, required this.unit, required this.metrics, this.maxY});

  final String title;
  final HostHistoryRange range;
  final MetricSeriesUnit unit;
  final List<(HostMetricKind, String, Color)> metrics;
  final double? maxY;

  static const _height = 140.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final values = [for (final m in metrics) ref.watch(hostHistoryProvider((m.$1, range)))];
    final theme = Theme.of(context);
    if (values.any((v) => !v.hasValue)) {
      final error = values.where((v) => v.hasError && !v.hasValue).firstOrNull;
      if (error == null) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            const SkeletonBox(height: _height),
          ],
        );
      }
      return _ChartNote(
        title: title,
        text: "Couldn't load the history: ${ApiException.from(error.error!).message}",
        onRetry: () {
          for (final m in metrics) {
            ref.invalidate(hostHistoryProvider((m.$1, range)));
          }
        },
      );
    }
    return MetricChart(
      key: Key('system.chart.${metrics.first.$1.name}'),
      title: title,
      unit: unit,
      range: range,
      height: _height,
      maxY: maxY,
      lines: [
        for (var i = 0; i < metrics.length; i++)
          ChartLine(label: metrics[i].$2, color: metrics[i].$3, points: values[i].value!.points),
      ],
    );
  }
}

class _ChartNote extends StatelessWidget {
  const _ChartNote({required this.title, required this.text, this.onRetry});

  final String title;
  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Row(
          children: [
            Icon(Icons.info_outline, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
            if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ],
    );
  }
}
