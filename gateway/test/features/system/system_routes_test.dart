import 'dart:io';

import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/features/system/system_module.dart';

import '../../support/test_hub.dart';
import 'host_fixture.dart';

const _host = '/api/v1/system/host';

void _kuma(
  TestHub hub, {
  String page = 'system/uptimekuma_status_page.json',
  String? heartbeatData,
}) {
  hub.fakes.onFixture(
    ServiceId.uptimeKuma,
    'GET',
    '/api/status-page/zenith',
    page,
  );
  if (heartbeatData != null) {
    hub.fakes.on(
      ServiceId.uptimeKuma,
      'GET',
      '/api/status-page/heartbeat/zenith',
      (_) => FakeResponse.text(
        systemData(heartbeatData),
        contentType: 'application/json',
      ),
    );
  } else {
    hub.fakes.onFixture(
      ServiceId.uptimeKuma,
      'GET',
      '/api/status-page/heartbeat/zenith',
      'system/uptimekuma_status_page_heartbeat.json',
    );
  }
}

/// Two samples 5 s apart (t0 then t1).
Future<void> _twoSamples(TestHub hub) async {
  await hub.ready;
  writeHubHost(hub);
  final module = systemModuleOf(hub);
  await module.sampler.sample();
  hub.clock.advance(const Duration(seconds: 5));
  writeHubHost(hub, t1: true);
  await module.sampler.sample();
}

void main() {
  group('GET /system/host', () {
    late TestHub hub;
    setUp(() => hub = systemTestHub());
    tearDown(() => hub.close());

    test('maps every source of the snapshot (member)', () async {
      await _twoSamples(hub);
      final r = await hub.get(_host, as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      final m = HostMetrics.fromJson(r.map);

      final cpu = m.cpu!;
      expect(cpu.model, 'Intel(R) N100');
      expect(cpu.cores, 4);
      expect(cpu.percent, 22.1); // 96 busy of 434 jiffies
      expect(cpu.perCorePercent, hasLength(4));
      expect((cpu.load1, cpu.load5, cpu.load15), (0.60, 0.86, 1.02));
      expect(cpu.packageTempC, 68.0);
      expect(cpu.coreTempsC, [65.0, 66.0, 63.0, 65.0]);

      final mem = m.memory!;
      expect(mem.totalBytes, 8059052032);
      expect(mem.usedBytes, (7870168 - 2866816) * 1024);
      expect(mem.availableBytes, 2866816 * 1024);
      expect(mem.swapUsedBytes, (6029292 - 5271900) * 1024);

      expect(m.uptimeSeconds, 10322);

      final vol = m.storage.single;
      expect(vol.mount, '/volume1');
      expect(vol.totalBytes, 7904532574208);
      expect(vol.usedBytes, 3765233148 * 1024);
      expect(vol.freeBytes, 3954020560 * 1024);
      expect(vol.usedPercent, 48.8);

      final md = m.raid.single;
      expect((md.device, md.level, md.state), ('md1', 'raid0', 'active'));
      expect(md.members, ['sda2', 'sdb2']);
      expect(md.redundant, isFalse);
      expect(md.healthy, isTrue);

      expect(
        [for (final n in m.network) n.interfaceName],
        ['eth0', 'tailscale0'],
      );
      final eth0 = m.interfaceNamed('eth0')!;
      expect(eth0.rxBps, eth0RxDelta ~/ 5);
      expect(eth0.txBps, eth0TxDelta ~/ 5);
      expect(eth0.rxTotalBytes, 2333451724 + eth0RxDelta);
      expect(m.interfaceNamed('tailscale0')!.rxBps, tailscaleDelta ~/ 5);

      expect(m.diskIo!.readBps, 1000 * 512 ~/ 5);
      expect(m.diskIo!.writeBps, (48828 * 512 / 5).round());

      expect(m.sources.temperature, isTrue);
      expect(m.sources.hostNetwork, isTrue);
      expect(m.sampledAt, hub.clock.now());
      // Never leaks container paths.
      expect(r.body, isNot(contains(hub.config.procDir)));
    });

    test('the first sample has no rates; a fresh sample is reused', () async {
      await hub.ready;
      writeHubHost(hub);
      final r = await hub.get(_host);
      expect(r.status, 200);
      final m = HostMetrics.fromJson(r.map);
      expect(m.cpu!.percent, isNull);
      expect(m.cpu!.load1, 0.60);
      expect(m.diskIo, isNull);
      expect(m.interfaceNamed('eth0')!.rxBps, 0);
      // Within two intervals the same sample is served.
      hub.clock.advance(const Duration(seconds: 3));
      final again = HostMetrics.fromJson((await hub.get(_host)).map);
      expect(again.sampledAt, m.sampledAt);
      // Later, the handler samples again and the rates appear.
      hub.clock.advance(const Duration(seconds: 7));
      writeHubHost(hub, t1: true);
      final later = HostMetrics.fromJson((await hub.get(_host)).map);
      expect(later.cpu!.percent, 22.1);
      expect(later.interfaceNamed('eth0')!.rxBps, eth0RxDelta ~/ 10);
    });

    test('missing sources: flags false, fields omitted, never an error', () async {
      await hub.ready;
      // The default TestHub host dir: a one-line /proc/stat, an empty net/dev,
      // no sysfs, no meminfo.
      final r = await hub.get(_host);
      expect(r.status, 200, reason: r.body);
      final json = r.map;
      expect(json['sources'], {'temperature': false, 'hostNetwork': false});
      expect(json['network'], isEmpty);
      expect(json.containsKey('memory'), isFalse);
      expect(json.containsKey('diskIo'), isFalse);
      expect(readMap(json['cpu'])!.containsKey('packageTempC'), isFalse);

      writeHubHost(hub, withNet: false, hwmon: false);
      hub.clock.advance(const Duration(seconds: 30));
      final m = HostMetrics.fromJson((await hub.get(_host)).map);
      expect(m.sources.hostNetwork, isFalse);
      expect(m.network, isEmpty);
      expect(m.sources.temperature, isFalse);
      expect(m.memory, isNotNull);
    });

    test('statvfs unavailable → storage empty', () async {
      final h = systemTestHub(usage: null);
      addTearDown(h.close);
      await h.ready;
      writeHubHost(h);
      final m = HostMetrics.fromJson((await h.get(_host)).map);
      expect(m.storage, isEmpty);
      expect(m.raid, hasLength(1));
    });

    test('anonymous callers are refused', () async {
      final r = await hub.get(_host, as: TestAs.anonymous);
      expect(r.status, 401);
    });
  });

  group('GET /system/history', () {
    late TestHub hub;
    setUp(() => hub = systemTestHub());
    tearDown(() => hub.close());

    test('series per metric with units', () async {
      await _twoSamples(hub);
      final cpu = MetricSeries.fromJson(
        (await hub.get(
          '/api/v1/system/history?metric=cpu',
          as: TestAs.member,
        )).map,
      );
      expect(cpu.metric, HostMetricKind.cpu);
      expect(cpu.unit, MetricSeriesUnit.percent);
      expect(
        [for (final p in cpu.points) p.v],
        [22.1],
      ); // the first sample has no CPU %
      expect(cpu.points.single.t, hub.clock.now());

      final mem = MetricSeries.fromJson(
        (await hub.get('/api/v1/system/history?metric=memory&range=1h')).map,
      );
      expect(mem.unit, MetricSeriesUnit.bytes);
      expect(mem.points, hasLength(2));

      final temp = MetricSeries.fromJson(
        (await hub.get('/api/v1/system/history?metric=temperature')).map,
      );
      expect(temp.unit, MetricSeriesUnit.celsius);
      expect(temp.points.last.v, 68.0);

      final rx = MetricSeries.fromJson(
        (await hub.get('/api/v1/system/history?metric=netRx')).map,
      );
      expect(rx.unit, MetricSeriesUnit.bps);
      expect(rx.points.single.v, eth0RxDelta / 5);

      final write = MetricSeries.fromJson(
        (await hub.get('/api/v1/system/history?metric=diskWrite')).map,
      );
      expect(write.points.single.v, (48828 * 512 / 5).round());

      final day = MetricSeries.fromJson(
        (await hub.get('/api/v1/system/history?metric=memory&range=24h')).map,
      );
      // Both samples fall in the 09:00 minute: one averaged point.
      expect(day.points, hasLength(1));
      expect(day.points.single.t, DateTime.utc(2026, 11, 8, 9));
    });

    test('invalid metric or range → 400', () async {
      for (final q in [
        '',
        '?metric=gpu',
        '?metric=unknown',
        '?metric=cpu&range=7d',
      ]) {
        final r = await hub.get('/api/v1/system/history$q');
        expect(r.status, 400, reason: q);
        expect(r.errorCode, 'bad_request');
      }
    });
  });

  group('GET /uptime', () {
    late TestHub hub;
    setUp(() => hub = systemTestHub());
    tearDown(() => hub.close());

    test('maps the status page and heartbeats (member)', () async {
      await hub.ready;
      _kuma(hub);
      final r = await hub.get('/api/v1/uptime', as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      final u = UptimeResponse.fromJson(r.map);
      expect(u.title, 'Zenith');
      expect(u.incident, isNull);
      expect(
        [for (final g in u.groups) g.name],
        ['Media', 'Automation', 'Downloads', 'System'],
      );
      final gluetun = u.groups[2].monitors.first;
      expect(gluetun.name, 'gluetun (VPN)');
      expect(gluetun.status, UptimeStatus.up);
      expect(gluetun.beats.first.status, UptimeStatus.pending);
      expect(gluetun.beats.first.t, DateTime.utc(2026, 11, 8, 7, 55, 14, 629));
      expect(gluetun.lastBeatAt, DateTime.utc(2026, 11, 8, 8, 58, 14, 666));
      expect(gluetun.uptime24h, closeTo(0.8957, 1e-4));
      final web = u.groups.first.monitors.firstWhere((m) => m.id == 5);
      expect(web.type, 'http');
      expect(web.pingMs, 4);
      final seerr = u.groups.first.monitors.firstWhere((m) => m.id == 3);
      expect(seerr.status, UptimeStatus.unknown);
      expect(seerr.beats, isEmpty);
      expect(u.counts.up, 5);
      expect(u.counts.unknown, 11);
      expect(u.counts.total, 16);
      // Wire format: instants with Z, no Kuma fields.
      final raw = readList(
        readMap(readList(r.map['groups'], (g) => g)[2])!['monitors'],
        (m) => m,
      ).first;
      expect(raw['lastBeatAt'], '2026-11-08T08:58:14.666Z');
      expect(raw.containsKey('sendUrl'), isFalse);

      final calls = hub.fakes.callsTo(ServiceId.uptimeKuma);
      expect([for (final c in calls) c.path]..sort(), [
        '/api/status-page/heartbeat/zenith',
        '/api/status-page/zenith',
      ]);
    });

    test('is cached for 30 s', () async {
      await hub.ready;
      _kuma(hub);
      await hub.get('/api/v1/uptime');
      await hub.get('/api/v1/uptime');
      expect(hub.fakes.callsTo(ServiceId.uptimeKuma), hasLength(2));
      hub.clock.advance(const Duration(seconds: 31));
      await hub.get('/api/v1/uptime');
      expect(hub.fakes.callsTo(ServiceId.uptimeKuma), hasLength(4));
    });

    test('incident, weight order and down monitors (synthetic)', () async {
      await hub.ready;
      hub.fakes.on(
        ServiceId.uptimeKuma,
        'GET',
        '/api/status-page/zenith',
        (_) => FakeResponse.text(
          systemData('uptimekuma_status_page_incident.synthetic.json'),
          contentType: 'application/json',
        ),
      );
      hub.fakes.on(
        ServiceId.uptimeKuma,
        'GET',
        '/api/status-page/heartbeat/zenith',
        (_) => FakeResponse.text(
          systemData('uptimekuma_heartbeat_down.synthetic.json'),
          contentType: 'application/json',
        ),
      );
      final u = UptimeResponse.fromJson((await hub.get('/api/v1/uptime')).map);
      expect([for (final g in u.groups) g.name], ['Media', 'Downloads']);
      expect(u.incident!.title, 'VPN switch');
      expect(u.incident!.style, 'warning');
      expect(u.incident!.createdAt, DateTime.utc(2026, 11, 8, 7, 50));
      expect(u.groups[1].monitors.single.status, UptimeStatus.down);
      expect(u.counts.down, 1);
      expect(u.counts.up, 1);
    });

    test('unknown slug → 502 naming UPTIME_KUMA_SLUG', () async {
      await hub.ready;
      hub.fakes.on(
        ServiceId.uptimeKuma,
        'GET',
        '/api/status-page/zenith',
        (_) => FakeResponse.json({
          'status': 'fail',
          'msg': 'Status Page Not Found',
        }, status: 404),
      );
      hub.fakes.on(
        ServiceId.uptimeKuma,
        'GET',
        '/api/status-page/heartbeat/zenith',
        (_) => FakeResponse.json({'heartbeatList': {}, 'uptimeList': {}}),
      );
      final r = await hub.get('/api/v1/uptime');
      expect(r.status, 502);
      expect(r.errorCode, 'upstream_error');
      expect(readMap(r.map['error'])!['message'], contains('UPTIME_KUMA_SLUG'));
      expect(readMap(r.map['error'])!['service'], 'uptimeKuma');
    });

    test('Kuma unreachable → 503; stale cache served afterwards', () async {
      await hub.ready;
      _kuma(hub);
      expect((await hub.get('/api/v1/uptime')).status, 200);
      hub.fakes.on(
        ServiceId.uptimeKuma,
        '*',
        RegExp('.*'),
        (_) => throw const SocketException('refused'),
      );
      hub.clock.advance(const Duration(seconds: 31));
      final stale = await hub.get('/api/v1/uptime');
      expect(stale.status, 200, reason: 'served from cache within maxStale');
      hub.clock.advance(const Duration(minutes: 11));
      final r = await hub.get('/api/v1/uptime');
      expect(r.status, 503, reason: r.body);
      expect(r.errorCode, 'upstream_unavailable');
    });

    test('not configured → 503 service_not_configured', () async {
      final h = systemTestHub(unconfigured: {ServiceId.uptimeKuma});
      addTearDown(h.close);
      final r = await h.get('/api/v1/uptime');
      expect(r.status, 503);
      expect(r.errorCode, 'service_not_configured');
      expect(h.fakes.callsTo(ServiceId.uptimeKuma), isEmpty);
    });
  });

  group('dashboard card', () {
    Future<(SystemCard, List<Alert>, JsonMap)> card(TestHub hub) async {
      final r = await hub.get(
        '/api/v1/dashboard?cards=system',
        as: TestAs.member,
      );
      expect(r.status, 200, reason: r.body);
      final d = DashboardResponse.fromJson(r.map);
      final s = d.cards['system']!;
      expect(s.status, SectionState.ok, reason: r.body);
      return (s.decode(SystemCard.fromJson)!, d.alerts, s.data!);
    }

    test('host, volume, RAID, network and monitors', () async {
      final hub = systemTestHub();
      addTearDown(hub.close);
      _kuma(hub);
      await _twoSamples(hub);
      final (c, alerts, raw) = await card(hub);
      expect(c.cpuPercent, 22.1);
      expect(c.packageTempC, 68.0);
      expect(c.memTotalBytes, 8059052032);
      expect(c.memUsedBytes, (7870168 - 2866816) * 1024);
      expect(c.uptimeSeconds, 10322);
      expect(c.volume!.usedPercent, 48.8);
      expect(c.volume!.totalBytes, 7904532574208);
      expect(c.raid!.level, 'raid0');
      expect(c.raid!.redundant, isFalse);
      expect(c.net!.rxBps, eth0RxDelta ~/ 5);
      expect(c.net!.txBps, eth0TxDelta ~/ 5);
      expect(c.net!.tailscaleActive, isTrue); // 4,000 B/s ≥ threshold
      expect(c.monitors!.total, 16);
      expect(c.monitors!.up, 5);
      expect(c.cpuSparkline, [22.1]);
      expect(
        raw.keys,
        containsAll(['cpuPercent', 'memUsedBytes', 'cpuSparkline']),
      );

      final ids = [for (final a in alerts) a.id];
      expect(ids, ['raid.noRedundancy']);
      final a = alerts.single;
      expect(a.severity, AlertSeverity.info);
      expect(a.dismissible, isTrue);
      expect(a.title, 'Storage is RAID0: a single disk failure loses all data');
      expect(a.route, '/system');
      expect(a.feature, 'system');
    });

    test('threshold, RAID, uptime and incident alerts', () async {
      final hub = systemTestHub(
        policyYaml:
            'alerts:\n  cpuTempWarnC: 60\n  volumeUsedWarnPercent: 40\n',
      );
      addTearDown(hub.close);
      await hub.ready;
      hub.fakes.on(
        ServiceId.uptimeKuma,
        'GET',
        '/api/status-page/zenith',
        (_) => FakeResponse.text(
          systemData('uptimekuma_status_page_incident.synthetic.json'),
          contentType: 'application/json',
        ),
      );
      hub.fakes.on(
        ServiceId.uptimeKuma,
        'GET',
        '/api/status-page/heartbeat/zenith',
        (_) => FakeResponse.text(
          systemData('uptimekuma_heartbeat_down.synthetic.json'),
          contentType: 'application/json',
        ),
      );
      writeHubHost(hub);
      // md1 lost a member.
      File('${hub.config.procDir}/mdstat').writeAsStringSync(
        'Personalities : [raid0]\nmd1 : inactive sda2[0]\n      3890885632 blocks super 1.2\n\nunused devices: <none>\n',
      );
      final (c, alerts, _) = await card(hub);
      expect(c.raid!.healthy, isFalse);
      expect(c.raid!.state, 'inactive');
      expect(c.monitors!.down, 1);

      final byId = {for (final a in alerts) a.id: a};
      expect(
        byId.keys,
        containsAll([
          'raid.degraded',
          'host.temperature',
          'host.volume',
          'uptime.down.14',
          'uptime.incident',
        ]),
      );
      expect(byId['raid.degraded']!.severity, AlertSeverity.critical);
      expect(byId['raid.degraded']!.title, 'RAID md1 is inactive');
      expect(byId['host.temperature']!.severity, AlertSeverity.warning);
      expect(byId['host.temperature']!.title, 'CPU temperature is 68 °C');
      expect(byId['host.volume']!.title, '/volume1 is 49 % full');
      final down = byId['uptime.down.14']!;
      expect(down.severity, AlertSeverity.error);
      expect(down.source, ServiceId.uptimeKuma);
      expect(down.title, 'gluetun (VPN) is down');
      expect(down.since, DateTime.utc(2026, 11, 8, 8, 57, 14, 665));
      expect(byId['uptime.incident']!.title, 'VPN switch');
      for (final a in alerts) {
        expect(a.route, '/system', reason: a.id);
      }
      // Sorted by severity (core).
      expect(alerts.first.id, 'raid.degraded');
    });

    test('monitors from a stale Kuma cache mark the card stale', () async {
      final hub = systemTestHub();
      addTearDown(hub.close);
      _kuma(hub);
      await _twoSamples(hub);
      var r = await hub.get('/api/v1/dashboard?cards=system');
      var section = DashboardResponse.fromJson(r.map).cards['system']!;
      expect(section.stale, isFalse);
      hub.fakes.on(
        ServiceId.uptimeKuma,
        '*',
        RegExp('.*'),
        (_) => throw const SocketException('refused'),
      );
      hub.clock.advance(const Duration(seconds: 31));
      writeHubHost(hub);
      r = await hub.get('/api/v1/dashboard?cards=system');
      section = DashboardResponse.fromJson(r.map).cards['system']!;
      expect(section.status, SectionState.ok, reason: r.body);
      expect(section.stale, isTrue);
      expect(section.error, isNotNull);
      expect(section.decode(SystemCard.fromJson)!.monitors, isNotNull);
    });

    test('Kuma failing or unconfigured never breaks the card', () async {
      final hub = systemTestHub();
      addTearDown(hub.close);
      await hub.ready;
      writeHubHost(hub);
      hub.fakes.on(
        ServiceId.uptimeKuma,
        '*',
        RegExp('.*'),
        (_) => FakeResponse.json({'msg': 'boom'}, status: 500),
      );
      final (c, alerts, raw) = await card(hub);
      expect(c.monitors, isNull);
      expect(raw.containsKey('monitors'), isFalse);
      expect(alerts.where((a) => a.id.startsWith('uptime.')), isEmpty);

      final off = systemTestHub(unconfigured: {ServiceId.uptimeKuma});
      addTearDown(off.close);
      await off.ready;
      writeHubHost(off);
      final (c2, _, _) = await card(off);
      expect(c2.monitors, isNull);
      expect(c2.memTotalBytes, 8059052032);
    });

    test('without host network the card has no net part', () async {
      final hub = systemTestHub(unconfigured: {ServiceId.uptimeKuma});
      addTearDown(hub.close);
      await hub.ready;
      writeHubHost(hub, withNet: false);
      final (c, _, _) = await card(hub);
      expect(c.net, isNull);
    });
  });

  group('start()', () {
    test(
      'samples in the background and resolves the hostname from Docker /info',
      () async {
        final fakes = FakeUpstreams()
          ..onFixture(
            ServiceId.docker,
            'GET',
            '/v1.54/info',
            'system/docker_info.json',
          );
        final hub = systemTestHub(startOnly: {'system'}, fakes: fakes);
        addTearDown(hub.close);
        await hub.ready;
        final module = systemModuleOf(hub);
        expect(module.sampler.running, isTrue);
        expect(module.sampler.latest, isNotNull);
        for (var i = 0; i < 20 && module.sampler.hostname == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(module.sampler.hostname, 'Zenith');
        hub.clock.advance(const Duration(seconds: 30));
        final m = HostMetrics.fromJson((await hub.get(_host)).map);
        expect(m.hostname, 'Zenith');
        await module.stop();
        expect(module.sampler.running, isFalse);
      },
    );
  });

  test('routes are member reads registered by the module', () async {
    final hub = systemTestHub();
    addTearDown(hub.close);
    await hub.ready;
    final specs = [
      for (final r in hub.hub.router.routes)
        if (r.path.startsWith('/system') || r.path == '/uptime') r,
    ];
    expect(
      [for (final s in specs) '$s'],
      ['GET /system/host', 'GET /system/history', 'GET /uptime'],
    );
    for (final s in specs) {
      expect(s.role, Role.member);
    }
    expect(systemModuleOf(hub), isA<SystemModule>());
  });
}
