/// Dashboard alerts of the system feature (API.md §13.4). Every alert opens
/// the System screen (`/system`).
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

/// App route of the System screen (APP.md §1).
const systemRoute = '/system';

const _feature = 'system';

/// RAID, temperature and volume alerts from a host sample.
List<Alert> hostAlerts(HostMetrics m, AlertThresholds thresholds) {
  final alerts = <Alert>[];

  final broken = [
    for (final r in m.raid)
      if (!r.healthy) r,
  ];
  if (broken.isNotEmpty) {
    alerts.add(
      Alert(
        id: 'raid.degraded',
        severity: AlertSeverity.critical,
        source: ServiceId.host,
        feature: _feature,
        title: broken.length == 1
            ? 'RAID ${broken.single.device} is ${_raidProblem(broken.single)}'
            : 'RAID arrays need attention',
        message: [
          for (final r in broken)
            '${r.device} (${r.level}): ${_raidProblem(r)}',
        ].join('; '),
        route: systemRoute,
      ),
    );
  }

  final unprotected = [
    for (final r in m.raid)
      if (!r.redundant) r,
  ];
  if (unprotected.isNotEmpty) {
    final levels = {for (final r in unprotected) r.level.toUpperCase()};
    alerts.add(
      Alert(
        id: 'raid.noRedundancy',
        severity: AlertSeverity.info,
        source: ServiceId.host,
        feature: _feature,
        title:
            'Storage is ${levels.join('/')}: a single disk failure loses all data',
        message: 'Keep backups of anything you cannot download again.',
        route: systemRoute,
        dismissible: true,
      ),
    );
  }

  final temp = m.cpu?.packageTempC;
  if (temp != null && temp > thresholds.cpuTempWarnC) {
    alerts.add(
      Alert(
        id: 'host.temperature',
        severity: AlertSeverity.warning,
        source: ServiceId.host,
        feature: _feature,
        title: 'CPU temperature is ${temp.round()} °C',
        message:
            'Above the ${_number(thresholds.cpuTempWarnC)} °C warning threshold.',
        route: systemRoute,
        since: m.sampledAt,
      ),
    );
  }

  for (final s in m.storage) {
    if (s.usedPercent <= thresholds.volumeUsedWarnPercent) continue;
    alerts.add(
      Alert(
        id: 'host.volume',
        severity: AlertSeverity.warning,
        source: ServiceId.host,
        feature: _feature,
        title: '${s.mount} is ${s.usedPercent.round()} % full',
        message: '${_tib(s.freeBytes)} free of ${_tib(s.totalBytes)}.',
        route: systemRoute,
      ),
    );
    break; // One volume is reported (API.md §13.4: a single `host.volume`).
  }
  return alerts;
}

/// `uptime.down.<id>` per monitor whose latest beat is down, and
/// `uptime.incident` when an incident is pinned.
List<Alert> uptimeAlerts(UptimeResponse u) {
  final alerts = <Alert>[];
  final seen = <int>{};
  for (final g in u.groups) {
    for (final m in g.monitors) {
      if (m.status != UptimeStatus.down || !seen.add(m.id)) continue;
      alerts.add(
        Alert(
          id: 'uptime.down.${m.id}',
          severity: AlertSeverity.error,
          source: ServiceId.uptimeKuma,
          feature: _feature,
          title: '${m.name} is down',
          message: 'Uptime Kuma · ${g.name}',
          route: systemRoute,
          since: _downSince(m),
        ),
      );
    }
  }
  final incident = u.incident;
  if (incident != null) {
    alerts.add(
      Alert(
        id: 'uptime.incident',
        severity: AlertSeverity.warning,
        source: ServiceId.uptimeKuma,
        feature: _feature,
        title: incident.title,
        message: incident.content.isEmpty ? null : _truncate(incident.content),
        route: systemRoute,
        since: incident.createdAt,
      ),
    );
  }
  return alerts;
}

/// The first beat of the trailing run of down beats.
DateTime? _downSince(UptimeMonitor m) {
  DateTime? since;
  for (final b in m.beats.reversed) {
    if (b.status != UptimeStatus.down) break;
    since = b.t;
  }
  return since ?? m.lastBeatAt;
}

String _raidProblem(HostRaid r) => r.state == 'active' ? 'degraded' : r.state;

String _number(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

String _tib(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
}

String _truncate(String s, [int max = 200]) =>
    s.length <= max ? s : '${s.substring(0, max - 1)}…';
