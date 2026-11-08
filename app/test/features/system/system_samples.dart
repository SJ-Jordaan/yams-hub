/// Gateway-shaped samples for the system feature tests (API.md §13).
library;

import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import '../../support/fake_api.dart';

HostMetrics buildHostMetrics({
  bool temperature = true,
  bool hostNetwork = true,
  bool raidHealthy = true,
  int tailscaleBps = 0,
}) => HostMetrics(
  hostname: 'Zenith',
  cpu: HostCpu(
    model: 'Intel(R) N100',
    cores: 4,
    percent: 22.1,
    perCorePercent: const [10.1, 15.0, 9.8, 15.1],
    load1: 0.60,
    load5: 0.86,
    load15: 1.02,
    packageTempC: temperature ? 68.0 : null,
    coreTempsC: temperature ? const [65.0, 66.0, 63.0, 65.0] : const [],
  ),
  memory: const HostMemory(
    totalBytes: 8059052032,
    usedBytes: 5123432448,
    availableBytes: 2935619584,
    swapTotalBytes: 6173995008,
    swapUsedBytes: 775569408,
  ),
  uptimeSeconds: 10322,
  storage: const [
    HostStorage(
      mount: '/volume1',
      totalBytes: 7904532574208,
      usedBytes: 3855598743552,
      freeBytes: 4048917053440,
      usedPercent: 48.8,
    ),
  ],
  raid: [
    HostRaid(
      device: 'md1',
      level: 'raid0',
      state: raidHealthy ? 'active' : 'inactive',
      members: const ['sda2', 'sdb2'],
      redundant: false,
      healthy: raidHealthy,
    ),
  ],
  network: hostNetwork
      ? [
          const HostNetwork(
            interfaceName: 'eth0',
            rxBps: 120000,
            txBps: 2400000,
            rxTotalBytes: 2333451724,
            txTotalBytes: 7631403758,
          ),
          HostNetwork(
            interfaceName: 'tailscale0',
            rxBps: tailscaleBps,
            txBps: tailscaleBps,
            rxTotalBytes: 86,
            txTotalBytes: 15805,
          ),
        ]
      : const [],
  diskIo: const HostDiskIo(readBps: 102400, writeBps: 4999987),
  sampledAt: testNow,
  sources: HostSources(temperature: temperature, hostNetwork: hostNetwork),
);

UptimeResponse buildUptime({bool incident = false, bool gluetunDown = false}) {
  List<UptimeBeat> beats(UptimeStatus last, {int n = 30}) => [
    for (var i = 0; i < n; i++)
      UptimeBeat(
        t: testNow.subtract(Duration(minutes: n - i)),
        status: i == n - 1 ? last : UptimeStatus.up,
      ),
  ];
  return UptimeResponse(
    title: 'Zenith',
    incident: incident
        ? UptimeIncident(
            title: 'VPN switch',
            content: 'Downloads pause while gluetun reconnects.',
            style: 'warning',
            createdAt: testNow.subtract(const Duration(minutes: 20)),
          )
        : null,
    groups: [
      UptimeGroup(
        name: 'Media',
        monitors: [
          UptimeMonitor(
            id: 2,
            name: 'jellyfin',
            type: 'docker',
            status: UptimeStatus.up,
            lastBeatAt: testNow,
            uptime24h: 1,
            beats: beats(UptimeStatus.up),
          ),
          UptimeMonitor(
            id: 5,
            name: 'jellyfin web',
            type: 'http',
            status: UptimeStatus.up,
            lastBeatAt: testNow,
            uptime24h: 0.9957,
            pingMs: 4,
            beats: beats(UptimeStatus.up, n: 12),
          ),
          const UptimeMonitor(id: 3, name: 'seerr', type: 'docker', status: UptimeStatus.unknown),
        ],
      ),
      UptimeGroup(
        name: 'Downloads',
        monitors: [
          UptimeMonitor(
            id: 14,
            name: 'gluetun (VPN)',
            type: 'docker',
            status: gluetunDown ? UptimeStatus.down : UptimeStatus.up,
            lastBeatAt: testNow,
            uptime24h: 0.8956521739130435,
            beats: beats(gluetunDown ? UptimeStatus.down : UptimeStatus.up),
          ),
        ],
      ),
    ],
    counts: UptimeCounts(up: gluetunDown ? 2 : 3, down: gluetunDown ? 1 : 0, unknown: 1),
  );
}

MetricSeries buildSeries(HostMetricKind metric, {int points = 12, double base = 20}) => MetricSeries(
  metric: metric,
  unit: metric.unit,
  points: [
    for (var i = 0; i < points; i++)
      MetricSeriesPoint(
        t: testNow.subtract(Duration(seconds: 5 * (points - i))),
        v: base + i,
      ),
  ],
);

SystemCard buildSystemCard({bool raidHealthy = true, int down = 0, bool tailscale = true}) => SystemCard(
  cpuPercent: 22.1,
  packageTempC: 68.0,
  memUsedBytes: 5123432448,
  memTotalBytes: 8059052032,
  uptimeSeconds: 10322,
  volume: const SystemCardVolume(totalBytes: 7904532574208, usedBytes: 3855598743552, usedPercent: 48.8),
  raid: SystemCardRaid(
    level: 'raid0',
    state: raidHealthy ? 'active' : 'inactive',
    redundant: false,
    healthy: raidHealthy,
  ),
  net: SystemCardNet(rxBps: 120000, txBps: 2400000, tailscaleActive: tailscale),
  monitors: SystemCardMonitors(up: 21 - down - 1, down: down, pending: 1, total: 21),
  cpuSparkline: const [10, 12, 30, 22.1],
);

/// Serves every system endpoint on [api] (history: every metric).
void serveSystem(FakeApi api, {HostMetrics? host, UptimeResponse? uptime}) {
  api
    ..getJson('/system/host', (host ?? buildHostMetrics()).toJson())
    ..getJson('/uptime', (uptime ?? buildUptime()).toJson())
    ..on('GET', '/system/history', (r) {
      final metric = HostMetricKind.fromJson(r.uri.queryParameters['metric']);
      return FakeResponse(buildSeries(metric).toJson());
    });
}
