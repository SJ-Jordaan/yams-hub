/// Providers of the System screen (APP.md §12): host every 5 s, uptime every
/// 30 s, the history charts every 30 s (1 h) or 5 min (24 h).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/refresh/auto_refresh.dart';
import 'package:yams_models/yams_models.dart';

import '../data/system_api.dart';

/// `GET /system/host`.
final hostMetricsProvider = FutureProvider.autoDispose<HostMetrics>((ref) {
  autoRefresh(ref, RefreshIntervals.hostMetrics);
  return ref.watch(systemApiProvider).host();
});

/// `GET /uptime`.
final uptimeProvider = FutureProvider.autoDispose<UptimeResponse>((ref) {
  autoRefresh(ref, RefreshIntervals.thirtySeconds);
  return ref.watch(systemApiProvider).uptime();
});

/// The 1 h / 24 h toggle of the charts (kept for the session).
final systemHistoryRangeProvider = NotifierProvider<SystemHistoryRangeController, HostHistoryRange>(
  SystemHistoryRangeController.new,
);

class SystemHistoryRangeController extends Notifier<HostHistoryRange> {
  @override
  HostHistoryRange build() => HostHistoryRange.hour;

  void select(HostHistoryRange range) => state = range;
}

/// One metric over one range: `GET /system/history?metric=&range=`.
final hostHistoryProvider = FutureProvider.autoDispose.family<MetricSeries, (HostMetricKind, HostHistoryRange)>((
  ref,
  key,
) {
  final (metric, range) = key;
  autoRefresh(ref, range == HostHistoryRange.hour ? RefreshIntervals.thirtySeconds : RefreshIntervals.stats);
  return ref.watch(systemApiProvider).history(metric, range);
});
