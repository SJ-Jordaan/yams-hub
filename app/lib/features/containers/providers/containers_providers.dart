/// Providers of the containers feature (APP.md §9).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/refresh/auto_refresh.dart';
import 'package:yams_models/yams_models.dart';

import '../data/containers_api.dart';

/// `GET /containers`, every 10 s.
final containerListProvider = FutureProvider.autoDispose<ContainerList>((ref) {
  autoRefresh(ref, RefreshIntervals.containers);
  return ref.watch(containersApiProvider).list();
});

/// `GET /containers/{name}`, every 10 s.
final containerDetailProvider = FutureProvider.autoDispose.family<ContainerDetail, String>((ref, name) {
  autoRefresh(ref, RefreshIntervals.containers);
  return ref.watch(containersApiProvider).detail(name);
});

/// `GET /updates` (manual refresh only).
final updatesProvider = FutureProvider.autoDispose<UpdatesResponse>(
  (ref) => ref.watch(containersApiProvider).updates(),
);

/// `GET /maintenance/decluttarr`, every 60 s.
final decluttarrProvider = FutureProvider.autoDispose<DecluttarrStatus>((ref) {
  autoRefresh(ref, RefreshIntervals.sixtySeconds);
  return ref.watch(containersApiProvider).decluttarr();
});

/// `GET /maintenance/recyclarr`, every 60 s.
final recyclarrProvider = FutureProvider.autoDispose<RecyclarrStatus>((ref) {
  autoRefresh(ref, RefreshIntervals.sixtySeconds);
  return ref.watch(containersApiProvider).recyclarr();
});

/// Keys of [containerJobsProvider].
abstract final class ContainerJobKeys {
  static String action(String name) => 'action:$name';
  static String update(String name) => 'update:$name';
  static const check = 'check';
  static const recyclarrSync = 'recyclarr-sync';
}

/// Jobs started from the containers screens that are still being followed:
/// key ([ContainerJobKeys]) → job id. Kept alive so a running restart still
/// shows its chip after navigating between the list and the detail screen.
class ContainerJobs extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const {};

  void track(String key, String jobId) => state = {...state, key: jobId};

  /// Stops following [key] (only if it still points at [jobId]).
  void done(String key, String jobId) {
    if (state[key] != jobId) return;
    state = {...state}..remove(key);
  }
}

final containerJobsProvider = NotifierProvider<ContainerJobs, Map<String, String>>(ContainerJobs.new);

/// One CPU/memory sample of the client-side history.
class ContainerUsageSample {
  const ContainerUsageSample({required this.at, this.cpuPercent, this.memBytes});

  final DateTime at;
  final double? cpuPercent;
  final int? memBytes;
}

/// The last two minutes of CPU/memory figures seen by the detail screen
/// (built from its refreshes; APP.md §9.2).
class ContainerUsageHistory extends Notifier<List<ContainerUsageSample>> {
  ContainerUsageHistory(this.name);

  final String name;

  static const window = Duration(minutes: 2);

  @override
  List<ContainerUsageSample> build() => const [];

  void add(ContainerSummary s, {DateTime? now}) {
    if (s.cpuPercent == null && s.memBytes == null) return;
    final at = now ?? DateTime.now();
    final cutoff = at.subtract(window);
    state = [
      for (final x in state)
        if (x.at.isAfter(cutoff)) x,
      ContainerUsageSample(at: at, cpuPercent: s.cpuPercent, memBytes: s.memBytes),
    ];
  }
}

final containerUsageHistoryProvider = NotifierProvider.autoDispose
    .family<ContainerUsageHistory, List<ContainerUsageSample>, String>(ContainerUsageHistory.new);
