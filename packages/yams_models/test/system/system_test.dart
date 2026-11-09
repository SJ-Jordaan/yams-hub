import 'package:test/test.dart';
import 'package:yams_models/yams_models.dart';

import '../core/round_trip.dart';

/// The `GET /system/host` sample of API.md §13.1.
final _host = <String, Object?>{
  'hostname': 'Zenith',
  'cpu': {
    'model': 'Intel(R) N100',
    'cores': 4,
    'percent': 12.5,
    'perCorePercent': [10.1, 15.0, 9.8, 15.1],
    'load1': 0.57,
    'load5': 0.89,
    'load15': 1.04,
    'packageTempC': 48.0,
    'coreTempsC': [46.0, 47.0, 48.0, 45.0],
  },
  'memory': {
    'totalBytes': 8059052032,
    'usedBytes': 5100000000,
    'availableBytes': 2959052032,
    'swapTotalBytes': 4026531840,
    'swapUsedBytes': 600000000,
  },
  'uptimeSeconds': 10289,
  'storage': [
    {
      'mount': '/volume1',
      'totalBytes': 7904532574208,
      'usedBytes': 3873220961362,
      'freeBytes': 4031311612846,
      'usedPercent': 49.0,
    },
  ],
  'raid': [
    {
      'device': 'md1',
      'level': 'raid0',
      'state': 'active',
      'members': ['sda2', 'sdb2'],
      'redundant': false,
      'healthy': true,
    },
  ],
  'network': [
    {
      'interface': 'eth0',
      'rxBps': 120000,
      'txBps': 2400000,
      'rxTotalBytes': 1,
      'txTotalBytes': 2,
    },
    {
      'interface': 'tailscale0',
      'rxBps': 0,
      'txBps': 0,
      'rxTotalBytes': 0,
      'txTotalBytes': 0,
    },
  ],
  'diskIo': {'readBps': 0, 'writeBps': 5000000},
  'sampledAt': '2026-11-08T09:00:00Z',
  'sources': {'temperature': true, 'hostNetwork': true},
};

/// The `GET /uptime` sample of API.md §13.3 (with every optional field).
final _uptime = <String, Object?>{
  'title': 'Zenith',
  'incident': {
    'title': 'VPN maintenance',
    'content': 'Switching servers',
    'style': 'warning',
    'createdAt': '2026-11-08T07:50:00Z',
  },
  'groups': [
    {
      'name': 'Media',
      'monitors': [
        {
          'id': 2,
          'name': 'jellyfin',
          'type': 'docker',
          'status': 'up',
          'lastBeatAt': '2026-11-08T08:58:08.391Z',
          'uptime24h': 0.9957,
          'beats': [
            {'t': '2026-11-08T08:57:08.390Z', 'status': 'up'},
            {'t': '2026-11-08T08:58:08.391Z', 'status': 'up'},
          ],
        },
        {
          'id': 5,
          'name': 'jellyfin web',
          'type': 'http',
          'status': 'down',
          'lastBeatAt': '2026-11-08T08:58:10Z',
          'uptime24h': 1,
          'pingMs': 4,
          'beats': [
            {'t': '2026-11-08T08:58:10Z', 'status': 'down'},
          ],
        },
        {
          'id': 30,
          'name': 'new',
          'type': 'docker',
          'status': 'unknown',
          'beats': [],
        },
      ],
    },
  ],
  'counts': {'up': 19, 'down': 0, 'pending': 1, 'maintenance': 0, 'unknown': 1},
};

final _card = <String, Object?>{
  'cpuPercent': 12.5,
  'packageTempC': 68.0,
  'memUsedBytes': 5100000000,
  'memTotalBytes': 8059052032,
  'uptimeSeconds': 10289,
  'volume': {
    'totalBytes': 7904532574208,
    'usedBytes': 3873220961362,
    'usedPercent': 49.0,
  },
  'raid': {
    'level': 'raid0',
    'state': 'active',
    'redundant': false,
    'healthy': true,
  },
  'net': {'rxBps': 120000, 'txBps': 2400000, 'tailscaleActive': true},
  'monitors': {'up': 19, 'down': 1, 'pending': 1, 'total': 21},
  'cpuSparkline': [10.0, 12.5, 11.25],
};

void main() {
  group('HostMetrics', () {
    test('round-trips the API.md sample', () {
      final m = expectRoundTrip(_host, HostMetrics.fromJson, (m) => m.toJson());
      expect(m.cpu!.coreTempsC, [46.0, 47.0, 48.0, 45.0]);
      expect(m.memory!.usedRatio, closeTo(0.633, 0.001));
      expect(m.storage.single.mount, '/volume1');
      expect(m.raid.single.redundant, isFalse);
      expect(m.interfaceNamed('tailscale0')!.rxBps, 0);
      expect(m.interfaceNamed('wlan0'), isNull);
      expect(m.sampledAt, DateTime.utc(2026, 11, 8, 9));
      expect(m.sources.hostNetwork, isTrue);
    });

    test('omits sources the sampler could not read', () {
      final minimal = <String, Object?>{
        'storage': <Object?>[],
        'raid': <Object?>[],
        'network': <Object?>[],
        'sampledAt': '2026-11-08T09:00:00Z',
        'sources': {'temperature': false, 'hostNetwork': false},
      };
      final m = expectRoundTrip(
        minimal,
        HostMetrics.fromJson,
        (m) => m.toJson(),
      );
      expect(m.cpu, isNull);
      expect(m.memory, isNull);
      expect(m.diskIo, isNull);
      expect(m.hostname, isNull);
    });

    test('a first sample without percent keeps the other CPU fields', () {
      final cpu = HostCpu.fromJson(const {
        'model': 'Intel(R) N100',
        'cores': 4,
        'load1': 0.6,
      });
      expect(cpu.percent, isNull);
      expect(cpu.toJson(), {
        'model': 'Intel(R) N100',
        'cores': 4,
        'perCorePercent': <double>[],
        'load1': 0.6,
        'coreTempsC': <double>[],
      });
    });

    test('sampledAt is required', () {
      expect(
        () => HostMetrics.fromJson(const {'cpu': {}}),
        throwsFormatException,
      );
    });
  });

  group('MetricSeries', () {
    test('round-trips', () {
      final sample = <String, Object?>{
        'metric': 'netRx',
        'unit': 'bps',
        'points': [
          {'t': '2026-11-08T09:00:00Z', 'v': 120000.0},
          {'t': '2026-11-08T09:00:05Z', 'v': 125000.5},
        ],
      };
      final s = expectRoundTrip(
        sample,
        MetricSeries.fromJson,
        (s) => s.toJson(),
      );
      expect(s.metric, HostMetricKind.netRx);
      expect(s.points.last.v, 125000.5);
    });

    test('unknown metric and unit strings map to unknown', () {
      final s = MetricSeries.fromJson(const {
        'metric': 'gpu',
        'unit': 'watts',
        'points': [],
      });
      expect(s.metric, HostMetricKind.unknown);
      expect(s.unit, MetricSeriesUnit.unknown);
    });

    test('every metric has a unit and ranges parse their wire value', () {
      expect(HostMetricKind.cpu.unit, MetricSeriesUnit.percent);
      expect(HostMetricKind.memory.unit, MetricSeriesUnit.bytes);
      expect(HostMetricKind.temperature.unit, MetricSeriesUnit.celsius);
      expect(HostMetricKind.diskWrite.unit, MetricSeriesUnit.bps);
      expect(HostMetricKind.queryable, isNot(contains(HostMetricKind.unknown)));
      expect(HostHistoryRange.tryParse('1h'), HostHistoryRange.hour);
      expect(HostHistoryRange.tryParse('24h'), HostHistoryRange.day);
      expect(HostHistoryRange.tryParse('7d'), isNull);
    });
  });

  group('UptimeResponse', () {
    test('round-trips the API.md sample', () {
      final u = expectRoundTrip(
        _uptime,
        UptimeResponse.fromJson,
        (u) => u.toJson(),
      );
      expect(u.incident!.style, 'warning');
      final monitors = u.groups.single.monitors;
      expect(monitors.first.status, UptimeStatus.up);
      expect(monitors[1].pingMs, 4);
      expect(monitors.last.lastBeatAt, isNull);
      expect(u.counts.total, 21);
    });

    test('without an incident', () {
      final sample = <String, Object?>{
        'title': 'Zenith',
        'groups': <Object?>[],
        'counts': {
          'up': 0,
          'down': 0,
          'pending': 0,
          'maintenance': 0,
          'unknown': 0,
        },
      };
      final u = expectRoundTrip(
        sample,
        UptimeResponse.fromJson,
        (u) => u.toJson(),
      );
      expect(u.incident, isNull);
    });

    test('Kuma status codes', () {
      expect(UptimeStatus.fromKuma(0), UptimeStatus.down);
      expect(UptimeStatus.fromKuma(1), UptimeStatus.up);
      expect(UptimeStatus.fromKuma(2), UptimeStatus.pending);
      expect(UptimeStatus.fromKuma(3), UptimeStatus.maintenance);
      expect(UptimeStatus.fromKuma(9), UptimeStatus.unknown);
      expect(UptimeStatus.fromKuma(null), UptimeStatus.unknown);
      expect(UptimeStatus.fromJson('paused'), UptimeStatus.unknown);
    });
  });

  group('SystemCard', () {
    test('round-trips', () {
      final c = expectRoundTrip(_card, SystemCard.fromJson, (c) => c.toJson());
      expect(c.raid!.redundant, isFalse);
      expect(c.monitors!.total, 21);
      expect(c.cpuSparkline, hasLength(3));
      expect(c.volume!.mount, isNull, reason: 'gateways before 2026-11-09');
    });

    test('the volume carries its mount when the gateway sends it', () {
      final sample = <String, Object?>{
        ..._card,
        'volume': {
          'mount': '/srv/media',
          'totalBytes': 10,
          'usedBytes': 5,
          'usedPercent': 50.0,
        },
      };
      final c = expectRoundTrip(sample, SystemCard.fromJson, (c) => c.toJson());
      expect(c.volume!.mount, '/srv/media');
    });

    test('optional parts are omitted', () {
      final sample = <String, Object?>{
        'memUsedBytes': 1,
        'memTotalBytes': 2,
        'uptimeSeconds': 3,
        'cpuSparkline': <Object?>[],
      };
      final c = expectRoundTrip(sample, SystemCard.fromJson, (c) => c.toJson());
      expect(c.volume, isNull);
      expect(c.net, isNull);
      expect(c.monitors, isNull);
      expect(c.cpuPercent, isNull);
    });

    test('decodes from a dashboard Section', () {
      final section = Section.fromJson(
        wire({
          'status': 'ok',
          'data': _card,
          'fetchedAt': '2026-11-08T09:00:00Z',
          'stale': false,
        }),
      );
      expect(section.decode(SystemCard.fromJson)!.net!.tailscaleActive, isTrue);
    });
  });
}
