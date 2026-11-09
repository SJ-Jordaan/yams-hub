/// System feature DTOs: host metrics, metric history, Uptime Kuma and the
/// dashboard card (API.md §13).
library;

import 'json.dart';

// ---------------------------------------------------------------------------
// Host metrics (API.md §13.1)
// ---------------------------------------------------------------------------

/// `GET /system/host`: one sample of the host sampler. Fields the sampler
/// could not read are omitted; [sources] says which optional sources exist.
final class HostMetrics {
  const HostMetrics({
    required this.sampledAt,
    this.hostname,
    this.cpu,
    this.memory,
    this.uptimeSeconds,
    this.storage = const [],
    this.raid = const [],
    this.network = const [],
    this.diskIo,
    this.sources = const HostSources(),
  });

  factory HostMetrics.fromJson(JsonMap j) => HostMetrics(
    hostname: readString(j['hostname']),
    cpu: _mapOrNull(j['cpu'], HostCpu.fromJson),
    memory: _mapOrNull(j['memory'], HostMemory.fromJson),
    uptimeSeconds: readInt(j['uptimeSeconds']),
    storage: readList(j['storage'], HostStorage.fromJson),
    raid: readList(j['raid'], HostRaid.fromJson),
    network: readList(j['network'], HostNetwork.fromJson),
    diskIo: _mapOrNull(j['diskIo'], HostDiskIo.fromJson),
    sampledAt: req(readInstant(j['sampledAt']), 'sampledAt'),
    sources:
        _mapOrNull(j['sources'], HostSources.fromJson) ?? const HostSources(),
  );

  final String? hostname;
  final HostCpu? cpu;
  final HostMemory? memory;
  final int? uptimeSeconds;

  /// Usage of the data volume (`/volume1`).
  final List<HostStorage> storage;

  /// Linux md arrays from `/proc/mdstat`.
  final List<HostRaid> raid;

  /// Host NICs (`eth0`, `tailscale0`); empty without the host netns counters.
  final List<HostNetwork> network;
  final HostDiskIo? diskIo;
  final DateTime sampledAt;
  final HostSources sources;

  /// The interface named [name], if reported.
  HostNetwork? interfaceNamed(String name) {
    for (final n in network) {
      if (n.interfaceName == name) return n;
    }
    return null;
  }

  JsonMap toJson() => compactJson({
    'hostname': hostname,
    'cpu': cpu?.toJson(),
    'memory': memory?.toJson(),
    'uptimeSeconds': uptimeSeconds,
    'storage': [for (final s in storage) s.toJson()],
    'raid': [for (final r in raid) r.toJson()],
    'network': [for (final n in network) n.toJson()],
    'diskIo': diskIo?.toJson(),
    'sampledAt': instantToJson(sampledAt),
    'sources': sources.toJson(),
  });
}

/// CPU usage, load and temperatures.
final class HostCpu {
  const HostCpu({
    this.model,
    this.cores,
    this.percent,
    this.perCorePercent = const [],
    this.load1,
    this.load5,
    this.load15,
    this.packageTempC,
    this.coreTempsC = const [],
  });

  factory HostCpu.fromJson(JsonMap j) => HostCpu(
    model: readString(j['model']),
    cores: readInt(j['cores']),
    percent: readDouble(j['percent']),
    perCorePercent: _readDoubles(j['perCorePercent']),
    load1: readDouble(j['load1']),
    load5: readDouble(j['load5']),
    load15: readDouble(j['load15']),
    packageTempC: readDouble(j['packageTempC']),
    coreTempsC: _readDoubles(j['coreTempsC']),
  );

  /// `Intel(R) N100`.
  final String? model;

  /// Logical CPUs.
  final int? cores;

  /// Host-wide busy share since the previous sample, 0..100 (absent on the
  /// very first sample).
  final double? percent;
  final List<double> perCorePercent;
  final double? load1;
  final double? load5;
  final double? load15;

  /// coretemp `Package id 0`.
  final double? packageTempC;
  final List<double> coreTempsC;

  JsonMap toJson() => compactJson({
    'model': model,
    'cores': cores,
    'percent': percent,
    'perCorePercent': perCorePercent,
    'load1': load1,
    'load5': load5,
    'load15': load15,
    'packageTempC': packageTempC,
    'coreTempsC': coreTempsC,
  });
}

/// Memory from `/proc/meminfo` (used = MemTotal − MemAvailable).
final class HostMemory {
  const HostMemory({
    required this.totalBytes,
    required this.usedBytes,
    required this.availableBytes,
    this.swapTotalBytes = 0,
    this.swapUsedBytes = 0,
  });

  factory HostMemory.fromJson(JsonMap j) => HostMemory(
    totalBytes: req(readInt(j['totalBytes']), 'totalBytes'),
    usedBytes: req(readInt(j['usedBytes']), 'usedBytes'),
    availableBytes: req(readInt(j['availableBytes']), 'availableBytes'),
    swapTotalBytes: readInt(j['swapTotalBytes']) ?? 0,
    swapUsedBytes: readInt(j['swapUsedBytes']) ?? 0,
  );

  final int totalBytes;
  final int usedBytes;
  final int availableBytes;
  final int swapTotalBytes;
  final int swapUsedBytes;

  /// 0..1.
  double get usedRatio => totalBytes <= 0 ? 0 : usedBytes / totalBytes;

  /// 0..1.
  double get swapUsedRatio =>
      swapTotalBytes <= 0 ? 0 : swapUsedBytes / swapTotalBytes;

  JsonMap toJson() => {
    'totalBytes': totalBytes,
    'usedBytes': usedBytes,
    'availableBytes': availableBytes,
    'swapTotalBytes': swapTotalBytes,
    'swapUsedBytes': swapUsedBytes,
  };
}

/// Usage of one mounted volume (statvfs).
final class HostStorage {
  const HostStorage({
    required this.mount,
    required this.totalBytes,
    required this.usedBytes,
    required this.freeBytes,
    required this.usedPercent,
  });

  factory HostStorage.fromJson(JsonMap j) => HostStorage(
    mount: req(readString(j['mount']), 'mount'),
    totalBytes: req(readInt(j['totalBytes']), 'totalBytes'),
    usedBytes: req(readInt(j['usedBytes']), 'usedBytes'),
    freeBytes: req(readInt(j['freeBytes']), 'freeBytes'),
    usedPercent: readDouble(j['usedPercent']) ?? 0,
  );

  /// Host path the numbers describe (`/volume1`).
  final String mount;
  final int totalBytes;
  final int usedBytes;

  /// Space available to unprivileged users.
  final int freeBytes;

  /// 0..100, like `df` (used / (used + free)).
  final double usedPercent;

  JsonMap toJson() => {
    'mount': mount,
    'totalBytes': totalBytes,
    'usedBytes': usedBytes,
    'freeBytes': freeBytes,
    'usedPercent': usedPercent,
  };
}

/// One md array from `/proc/mdstat`.
final class HostRaid {
  const HostRaid({
    required this.device,
    required this.level,
    required this.state,
    this.members = const [],
    required this.redundant,
    required this.healthy,
  });

  factory HostRaid.fromJson(JsonMap j) => HostRaid(
    device: req(readString(j['device']), 'device'),
    level: readString(j['level']) ?? 'unknown',
    state: readString(j['state']) ?? 'unknown',
    members: readStringList(j['members']),
    redundant: readBool(j['redundant']) ?? false,
    healthy: readBool(j['healthy']) ?? false,
  );

  /// `md1`.
  final String device;

  /// `raid0`, `raid1`, ... (`unknown` for an inactive array).
  final String level;

  /// `active`, `inactive`, ... (the mdstat word).
  final String state;

  /// Member partitions (`sda2`, `sdb2`).
  final List<String> members;

  /// False for raid0 and linear: a single disk failure loses the array.
  final bool redundant;

  /// Active, with no failed member and no missing mirror.
  final bool healthy;

  JsonMap toJson() => {
    'device': device,
    'level': level,
    'state': state,
    'members': members,
    'redundant': redundant,
    'healthy': healthy,
  };
}

/// Throughput and counters of one host interface.
final class HostNetwork {
  const HostNetwork({
    required this.interfaceName,
    required this.rxBps,
    required this.txBps,
    required this.rxTotalBytes,
    required this.txTotalBytes,
  });

  factory HostNetwork.fromJson(JsonMap j) => HostNetwork(
    interfaceName: req(readString(j['interface']), 'interface'),
    rxBps: readInt(j['rxBps']) ?? 0,
    txBps: readInt(j['txBps']) ?? 0,
    rxTotalBytes: readInt(j['rxTotalBytes']) ?? 0,
    txTotalBytes: readInt(j['txTotalBytes']) ?? 0,
  );

  /// JSON `interface` (`eth0`, `tailscale0`).
  final String interfaceName;
  final int rxBps;
  final int txBps;
  final int rxTotalBytes;
  final int txTotalBytes;

  JsonMap toJson() => {
    'interface': interfaceName,
    'rxBps': rxBps,
    'txBps': txBps,
    'rxTotalBytes': rxTotalBytes,
    'txTotalBytes': txTotalBytes,
  };
}

/// Read/write throughput of the data volume (`dm-0`).
final class HostDiskIo {
  const HostDiskIo({required this.readBps, required this.writeBps});

  factory HostDiskIo.fromJson(JsonMap j) => HostDiskIo(
    readBps: readInt(j['readBps']) ?? 0,
    writeBps: readInt(j['writeBps']) ?? 0,
  );

  final int readBps;
  final int writeBps;

  JsonMap toJson() => {'readBps': readBps, 'writeBps': writeBps};
}

/// Which optional sources the sampler can read.
final class HostSources {
  const HostSources({this.temperature = false, this.hostNetwork = false});

  factory HostSources.fromJson(JsonMap j) => HostSources(
    temperature: readBool(j['temperature']) ?? false,
    hostNetwork: readBool(j['hostNetwork']) ?? false,
  );

  /// A `coretemp` hwmon device was found.
  final bool temperature;

  /// `HOST_NET_DEV` (the host's `/proc/1/net/dev`) is mounted.
  final bool hostNetwork;

  JsonMap toJson() => {'temperature': temperature, 'hostNetwork': hostNetwork};
}

// ---------------------------------------------------------------------------
// History (API.md §13.2)
// ---------------------------------------------------------------------------

/// The `metric` of `GET /system/history`.
enum HostMetricKind {
  cpu,
  memory,
  temperature,
  netRx,
  netTx,
  diskRead,
  diskWrite,
  unknown;

  /// The unit the gateway reports this metric in.
  MetricSeriesUnit get unit => switch (this) {
    cpu => MetricSeriesUnit.percent,
    memory => MetricSeriesUnit.bytes,
    temperature => MetricSeriesUnit.celsius,
    netRx || netTx || diskRead || diskWrite => MetricSeriesUnit.bps,
    unknown => MetricSeriesUnit.unknown,
  };

  /// Every queryable metric (all but [unknown]).
  static List<HostMetricKind> get queryable => [
    for (final m in values)
      if (m != unknown) m,
  ];

  static HostMetricKind fromJson(Object? v) => readEnum(v, values, unknown);

  String toJson() => name;
}

/// The `range` of `GET /system/history`.
enum HostHistoryRange {
  /// 5 s resolution.
  hour('1h', Duration(hours: 1)),

  /// 1 min averages.
  day('24h', Duration(hours: 24));

  const HostHistoryRange(this.wire, this.duration);

  /// The query value (`1h`, `24h`).
  final String wire;
  final Duration duration;

  /// Parses a query value; null when unknown.
  static HostHistoryRange? tryParse(String? v) {
    for (final r in values) {
      if (r.wire == v) return r;
    }
    return null;
  }
}

/// The unit of a [MetricSeries].
enum MetricSeriesUnit {
  percent,
  bytes,
  celsius,
  bps,
  unknown;

  static MetricSeriesUnit fromJson(Object? v) => readEnum(v, values, unknown);

  String toJson() => name;
}

/// `GET /system/history`.
final class MetricSeries {
  const MetricSeries({
    required this.metric,
    required this.unit,
    this.points = const [],
  });

  factory MetricSeries.fromJson(JsonMap j) => MetricSeries(
    metric: HostMetricKind.fromJson(j['metric']),
    unit: MetricSeriesUnit.fromJson(j['unit']),
    points: readList(j['points'], MetricSeriesPoint.fromJson),
  );

  final HostMetricKind metric;
  final MetricSeriesUnit unit;

  /// Oldest first.
  final List<MetricSeriesPoint> points;

  JsonMap toJson() => {
    'metric': metric.toJson(),
    'unit': unit.toJson(),
    'points': [for (final p in points) p.toJson()],
  };
}

/// One point of a [MetricSeries].
final class MetricSeriesPoint {
  const MetricSeriesPoint({required this.t, required this.v});

  factory MetricSeriesPoint.fromJson(JsonMap j) => MetricSeriesPoint(
    t: req(readInstant(j['t']), 't'),
    v: req(readDouble(j['v']), 'v'),
  );

  final DateTime t;
  final double v;

  JsonMap toJson() => {'t': instantToJson(t), 'v': v};
}

// ---------------------------------------------------------------------------
// Uptime Kuma (API.md §13.3)
// ---------------------------------------------------------------------------

/// State of a monitor or heartbeat.
enum UptimeStatus {
  down,
  up,
  pending,
  maintenance,
  unknown;

  /// Uptime Kuma's numeric status (0 down, 1 up, 2 pending, 3 maintenance).
  static UptimeStatus fromKuma(Object? v) => switch (readInt(v)) {
    0 => down,
    1 => up,
    2 => pending,
    3 => maintenance,
    _ => unknown,
  };

  static UptimeStatus fromJson(Object? v) => readEnum(v, values, unknown);

  String toJson() => name;
}

/// `GET /uptime`.
final class UptimeResponse {
  const UptimeResponse({
    required this.title,
    this.incident,
    this.groups = const [],
    this.counts = const UptimeCounts(),
  });

  factory UptimeResponse.fromJson(JsonMap j) => UptimeResponse(
    title: readString(j['title']) ?? '',
    incident: _mapOrNull(j['incident'], UptimeIncident.fromJson),
    groups: readList(j['groups'], UptimeGroup.fromJson),
    counts:
        _mapOrNull(j['counts'], UptimeCounts.fromJson) ?? const UptimeCounts(),
  );

  /// Status page title (`Zenith`).
  final String title;

  /// The pinned incident, if any.
  final UptimeIncident? incident;

  /// Ordered by the status page's group weight.
  final List<UptimeGroup> groups;
  final UptimeCounts counts;

  JsonMap toJson() => compactJson({
    'title': title,
    'incident': incident?.toJson(),
    'groups': [for (final g in groups) g.toJson()],
    'counts': counts.toJson(),
  });
}

/// A pinned status-page incident.
final class UptimeIncident {
  const UptimeIncident({
    required this.title,
    this.content = '',
    this.style = 'info',
    this.createdAt,
  });

  factory UptimeIncident.fromJson(JsonMap j) => UptimeIncident(
    title: readString(j['title']) ?? '',
    content: readString(j['content']) ?? '',
    style: readString(j['style']) ?? 'info',
    createdAt: readInstant(j['createdAt']),
  );

  final String title;

  /// Markdown text written in Kuma.
  final String content;

  /// Kuma's banner style: `info`, `warning`, `danger`, `primary`, `light`,
  /// `dark`.
  final String style;
  final DateTime? createdAt;

  JsonMap toJson() => compactJson({
    'title': title,
    'content': content,
    'style': style,
    'createdAt': optionalInstantToJson(createdAt),
  });
}

/// One status-page group.
final class UptimeGroup {
  const UptimeGroup({required this.name, this.monitors = const []});

  factory UptimeGroup.fromJson(JsonMap j) => UptimeGroup(
    name: readString(j['name']) ?? '',
    monitors: readList(j['monitors'], UptimeMonitor.fromJson),
  );

  final String name;
  final List<UptimeMonitor> monitors;

  JsonMap toJson() => {
    'name': name,
    'monitors': [for (final m in monitors) m.toJson()],
  };
}

/// One monitor with its latest beats.
final class UptimeMonitor {
  const UptimeMonitor({
    required this.id,
    required this.name,
    required this.type,
    required this.status,
    this.lastBeatAt,
    this.uptime24h,
    this.pingMs,
    this.beats = const [],
  });

  factory UptimeMonitor.fromJson(JsonMap j) => UptimeMonitor(
    id: req(readInt(j['id']), 'id'),
    name: readString(j['name']) ?? '',
    type: readString(j['type']) ?? 'unknown',
    status: UptimeStatus.fromJson(j['status']),
    lastBeatAt: readInstant(j['lastBeatAt']),
    uptime24h: readDouble(j['uptime24h']),
    pingMs: readInt(j['pingMs']),
    beats: readList(j['beats'], UptimeBeat.fromJson),
  );

  final int id;
  final String name;

  /// Kuma monitor type (`docker`, `http`, ...).
  final String type;

  /// The latest beat's status (`unknown` without beats).
  final UptimeStatus status;
  final DateTime? lastBeatAt;

  /// 24 h uptime ratio 0..1.
  final double? uptime24h;

  /// Latest ping (http monitors only).
  final int? pingMs;

  /// Up to 30, oldest first.
  final List<UptimeBeat> beats;

  JsonMap toJson() => compactJson({
    'id': id,
    'name': name,
    'type': type,
    'status': status.toJson(),
    'lastBeatAt': optionalInstantToJson(lastBeatAt),
    'uptime24h': uptime24h,
    'pingMs': pingMs,
    'beats': [for (final b in beats) b.toJson()],
  });
}

/// One heartbeat.
final class UptimeBeat {
  const UptimeBeat({required this.t, required this.status});

  factory UptimeBeat.fromJson(JsonMap j) => UptimeBeat(
    t: req(readInstant(j['t']), 't'),
    status: UptimeStatus.fromJson(j['status']),
  );

  final DateTime t;
  final UptimeStatus status;

  JsonMap toJson() => {'t': instantToJson(t), 'status': status.toJson()};
}

/// Monitors per status.
final class UptimeCounts {
  const UptimeCounts({
    this.up = 0,
    this.down = 0,
    this.pending = 0,
    this.maintenance = 0,
    this.unknown = 0,
  });

  factory UptimeCounts.fromJson(JsonMap j) => UptimeCounts(
    up: readInt(j['up']) ?? 0,
    down: readInt(j['down']) ?? 0,
    pending: readInt(j['pending']) ?? 0,
    maintenance: readInt(j['maintenance']) ?? 0,
    unknown: readInt(j['unknown']) ?? 0,
  );

  final int up;
  final int down;
  final int pending;
  final int maintenance;
  final int unknown;

  int get total => up + down + pending + maintenance + unknown;

  JsonMap toJson() => {
    'up': up,
    'down': down,
    'pending': pending,
    'maintenance': maintenance,
    'unknown': unknown,
  };
}

// ---------------------------------------------------------------------------
// Dashboard card (API.md §13.4)
// ---------------------------------------------------------------------------

/// The `system` dashboard card.
final class SystemCard {
  const SystemCard({
    this.cpuPercent,
    this.packageTempC,
    required this.memUsedBytes,
    required this.memTotalBytes,
    required this.uptimeSeconds,
    this.volume,
    this.raid,
    this.net,
    this.monitors,
    this.cpuSparkline = const [],
  });

  factory SystemCard.fromJson(JsonMap j) => SystemCard(
    cpuPercent: readDouble(j['cpuPercent']),
    packageTempC: readDouble(j['packageTempC']),
    memUsedBytes: readInt(j['memUsedBytes']) ?? 0,
    memTotalBytes: readInt(j['memTotalBytes']) ?? 0,
    uptimeSeconds: readInt(j['uptimeSeconds']) ?? 0,
    volume: _mapOrNull(j['volume'], SystemCardVolume.fromJson),
    raid: _mapOrNull(j['raid'], SystemCardRaid.fromJson),
    net: _mapOrNull(j['net'], SystemCardNet.fromJson),
    monitors: _mapOrNull(j['monitors'], SystemCardMonitors.fromJson),
    cpuSparkline: _readDoubles(j['cpuSparkline']),
  );

  final double? cpuPercent;
  final double? packageTempC;
  final int memUsedBytes;
  final int memTotalBytes;
  final int uptimeSeconds;
  final SystemCardVolume? volume;
  final SystemCardRaid? raid;
  final SystemCardNet? net;
  final SystemCardMonitors? monitors;

  /// CPU % of the last 60 samples (5 s apart), oldest first.
  final List<double> cpuSparkline;

  JsonMap toJson() => compactJson({
    'cpuPercent': cpuPercent,
    'packageTempC': packageTempC,
    'memUsedBytes': memUsedBytes,
    'memTotalBytes': memTotalBytes,
    'uptimeSeconds': uptimeSeconds,
    'volume': volume?.toJson(),
    'raid': raid?.toJson(),
    'net': net?.toJson(),
    'monitors': monitors?.toJson(),
    'cpuSparkline': cpuSparkline,
  });
}

/// [SystemCard.volume].
final class SystemCardVolume {
  const SystemCardVolume({
    this.mount,
    required this.totalBytes,
    required this.usedBytes,
    required this.usedPercent,
  });

  factory SystemCardVolume.fromJson(JsonMap j) => SystemCardVolume(
    mount: readString(j['mount']),
    totalBytes: readInt(j['totalBytes']) ?? 0,
    usedBytes: readInt(j['usedBytes']) ?? 0,
    usedPercent: readDouble(j['usedPercent']) ?? 0,
  );

  /// Host path the numbers describe (null from gateways before 2026-11-09).
  final String? mount;
  final int totalBytes;
  final int usedBytes;
  final double usedPercent;

  JsonMap toJson() => {
    'mount': ?mount,
    'totalBytes': totalBytes,
    'usedBytes': usedBytes,
    'usedPercent': usedPercent,
  };
}

/// [SystemCard.raid].
final class SystemCardRaid {
  const SystemCardRaid({
    required this.level,
    required this.state,
    required this.redundant,
    required this.healthy,
  });

  factory SystemCardRaid.fromJson(JsonMap j) => SystemCardRaid(
    level: readString(j['level']) ?? 'unknown',
    state: readString(j['state']) ?? 'unknown',
    redundant: readBool(j['redundant']) ?? false,
    healthy: readBool(j['healthy']) ?? false,
  );

  final String level;
  final String state;
  final bool redundant;
  final bool healthy;

  JsonMap toJson() => {
    'level': level,
    'state': state,
    'redundant': redundant,
    'healthy': healthy,
  };
}

/// [SystemCard.net].
final class SystemCardNet {
  const SystemCardNet({
    required this.rxBps,
    required this.txBps,
    required this.tailscaleActive,
  });

  factory SystemCardNet.fromJson(JsonMap j) => SystemCardNet(
    rxBps: readInt(j['rxBps']) ?? 0,
    txBps: readInt(j['txBps']) ?? 0,
    tailscaleActive: readBool(j['tailscaleActive']) ?? false,
  );

  final int rxBps;
  final int txBps;

  /// Traffic is flowing over `tailscale0` (remote use).
  final bool tailscaleActive;

  JsonMap toJson() => {
    'rxBps': rxBps,
    'txBps': txBps,
    'tailscaleActive': tailscaleActive,
  };
}

/// [SystemCard.monitors].
final class SystemCardMonitors {
  const SystemCardMonitors({
    required this.up,
    required this.down,
    required this.pending,
    required this.total,
  });

  factory SystemCardMonitors.fromJson(JsonMap j) => SystemCardMonitors(
    up: readInt(j['up']) ?? 0,
    down: readInt(j['down']) ?? 0,
    pending: readInt(j['pending']) ?? 0,
    total: readInt(j['total']) ?? 0,
  );

  final int up;
  final int down;
  final int pending;
  final int total;

  JsonMap toJson() => {
    'up': up,
    'down': down,
    'pending': pending,
    'total': total,
  };
}

// ---------------------------------------------------------------------------

T? _mapOrNull<T>(Object? v, T Function(JsonMap) f) {
  final m = readMap(v);
  return m == null ? null : f(m);
}

List<double> _readDoubles(Object? v) {
  if (v is! List) return const <double>[];
  return [for (final e in v) ?readDouble(e)];
}
