/// Container CPU/memory/network figures from `one-shot` stats samples
/// (integrations/system.md §1.4).
library;

import 'package:yams_models/yams_models.dart';

/// Computed figures of one container (deltas between two samples).
final class ContainerStatsFigures {
  const ContainerStatsFigures({
    required this.cpuPercent,
    required this.memBytes,
    required this.memPercent,
    required this.netRxBps,
    required this.netTxBps,
    required this.sampledAt,
    this.pids,
  });

  final double cpuPercent;
  final int memBytes;
  final double memPercent;
  final int netRxBps;
  final int netTxBps;
  final int? pids;
  final DateTime sampledAt;
}

/// One raw sample of `GET /containers/{id}/stats?stream=false&one-shot=true`.
final class ContainerStatsSample {
  const ContainerStatsSample({
    required this.read,
    required this.cpuTotal,
    required this.systemCpu,
    required this.onlineCpus,
    required this.memUsed,
    required this.memLimit,
    required this.netRx,
    required this.netTx,
    this.pids,
  });

  /// Parses a stats body; null when it has no usable CPU counters (stopped
  /// containers report zeros).
  static ContainerStatsSample? fromJson(JsonMap j, {DateTime? fallbackRead}) {
    final cpu = readMap(j['cpu_stats']);
    final total = readInt(readMap(cpu?['cpu_usage'])?['total_usage']);
    final system = readInt(cpu?['system_cpu_usage']);
    if (total == null || system == null || system == 0) return null;
    final mem = readMap(j['memory_stats']);
    final memStats = readMap(mem?['stats']);
    final usage = readInt(mem?['usage']) ?? 0;
    // cgroup v2 reports inactive_file; v1 total_inactive_file.
    final inactive =
        readInt(memStats?['inactive_file']) ??
        readInt(memStats?['total_inactive_file']) ??
        0;
    var rx = 0;
    var tx = 0;
    final networks = readMap(j['networks']);
    if (networks != null) {
      for (final n in networks.values) {
        final m = readMap(n);
        rx += readInt(m?['rx_bytes']) ?? 0;
        tx += readInt(m?['tx_bytes']) ?? 0;
      }
    }
    final percpu = readList(
      readMap(cpu?['cpu_usage'])?['percpu_usage'],
      (m) => m,
    );
    return ContainerStatsSample(
      read: readInstant(j['read']) ?? fallbackRead ?? DateTime.now().toUtc(),
      cpuTotal: total,
      systemCpu: system,
      onlineCpus:
          readInt(cpu?['online_cpus']) ?? (percpu.isEmpty ? 1 : percpu.length),
      memUsed: (usage - inactive).clamp(0, usage),
      memLimit: readInt(mem?['limit']) ?? 0,
      netRx: rx,
      netTx: tx,
      pids: readInt(readMap(j['pids_stats'])?['current']),
    );
  }

  /// The `precpu_stats` of a `stream=false` (two-sample) body as a sample,
  /// or null when it is zero (one-shot).
  static ContainerStatsSample? previousFromJson(JsonMap j) {
    final pre = readMap(j['precpu_stats']);
    if (pre == null) return null;
    final preread = readInstant(j['preread']);
    if (preread == null) return null;
    final copy = <String, Object?>{
      ...j,
      'cpu_stats': pre,
      'read': j['preread'],
    };
    return fromJson(copy);
  }

  final DateTime read;
  final int cpuTotal;
  final int systemCpu;
  final int onlineCpus;
  final int memUsed;
  final int memLimit;
  final int netRx;
  final int netTx;
  final int? pids;

  /// The figures between [previous] and this sample (`docker stats`
  /// formulas).
  ContainerStatsFigures since(ContainerStatsSample previous) {
    final cpuDelta = cpuTotal - previous.cpuTotal;
    final systemDelta = systemCpu - previous.systemCpu;
    final cpu = systemDelta > 0 && cpuDelta >= 0
        ? cpuDelta / systemDelta * onlineCpus * 100
        : 0.0;
    final seconds = read.difference(previous.read).inMicroseconds / 1e6;
    int rate(int now, int before) {
      if (seconds <= 0 || now < before) return 0;
      return ((now - before) / seconds).round();
    }

    return ContainerStatsFigures(
      cpuPercent: double.parse(cpu.toStringAsFixed(2)),
      memBytes: memUsed,
      memPercent: memLimit > 0
          ? double.parse((memUsed / memLimit * 100).toStringAsFixed(2))
          : 0,
      netRxBps: rate(netRx, previous.netRx),
      netTxBps: rate(netTx, previous.netTx),
      pids: pids,
      sampledAt: read,
    );
  }
}

/// Keeps the previous sample per container id and the computed figures.
final class ContainerStatsStore {
  final _previous = <String, ContainerStatsSample>{};
  final _figures = <String, ContainerStatsFigures>{};
  DateTime? _sampledAt;

  /// When the last round of samples produced figures.
  DateTime? get sampledAt => _sampledAt;

  /// The figures of container [id] (null until two samples exist).
  ContainerStatsFigures? of(String id) => _figures[id];

  /// Every id with figures.
  Iterable<String> get ids => _figures.keys;

  /// Adds a sample of container [id].
  void add(String id, ContainerStatsSample sample) {
    final prev = _previous[id];
    _previous[id] = sample;
    if (prev == null || !sample.read.isAfter(prev.read)) return;
    final f = sample.since(prev);
    _figures[id] = f;
    final at = _sampledAt;
    if (at == null || f.sampledAt.isAfter(at)) _sampledAt = f.sampledAt;
  }

  /// Drops every container not in [liveIds] (removed or stopped).
  void retain(Set<String> liveIds) {
    _previous.removeWhere((id, _) => !liveIds.contains(id));
    _figures.removeWhere((id, _) => !liveIds.contains(id));
  }
}
