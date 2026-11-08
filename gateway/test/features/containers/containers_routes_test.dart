import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'containers_support.dart';

const _v = '/v1.54';

void main() {
  group('GET /containers', () {
    late TestHub hub;
    setUp(() {
      hub = containersHub();
      hub.fakeDocker();
    });
    tearDown(() => hub.close());

    test(
      'lists every container from the pinned API with mapped fields',
      () async {
        final r = await hub.get('/api/v1/containers', as: TestAs.member);
        expect(r.status, 200, reason: r.body);
        final list = ContainerList.fromJson(r.map);
        expect(list.items.map((c) => c.name), [
          'decluttarr',
          'gluetun',
          'homepage',
          'jellystat-db',
          'portainer',
          'qbittorrent',
          'recyclarr',
          'sonarr',
          'uptime-kuma',
          'yams-hub',
        ]);
        final calls = hub.dockerCalls('$_v/containers/json');
        expect(calls, isNotEmpty);
        expect(calls.first.query['all'], ['true']);

        ContainerSummary c(String n) =>
            list.items.firstWhere((x) => x.name == n);
        final homepage = c('homepage');
        expect(homepage.group, 'system');
        expect(homepage.health, ContainerHealth.healthy);
        expect(homepage.statusText, 'Up 25 minutes');
        expect(homepage.autoUpdate, isTrue);
        expect(homepage.pinned, isFalse);
        final qbit = c('qbittorrent');
        expect(qbit.sharesNetworkWith, 'gluetun');
        expect(qbit.pinned, isTrue);
        expect(qbit.protection, ContainerProtection.confirm);
        expect(c('yams-hub').protection, ContainerProtection.locked);
        expect(c('sonarr').links.single.toJson(), {
          'app': 'sonarr',
          'path': '/',
        });
        expect(c('sonarr').imageVersion, '4.0.20.3014-ls2');
        expect(c('uptime-kuma').links.single.app, ExternalApp.uptimeKuma);
        expect(c('portainer').state, ContainerState.exited);
        expect(c('portainer').uptimeSeconds, isNull);
        // sonarr's StartedAt comes from inspect (fixture: 06:21:17Z).
        expect(
          c('sonarr').startedAt,
          DateTime.parse('2026-11-08T06:21:17.288940Z'),
        );
        expect(
          c('sonarr').uptimeSeconds,
          hub.clock.now().difference(c('sonarr').startedAt!).inSeconds,
        );
        // Containers without an inspect answer fall back to the status text.
        expect(c('homepage').uptimeSeconds, 25 * 60);
        expect(list.engine.toJson(), {
          'version': '29.4.3',
          'running': 21,
          'stopped': 0,
          'total': 21,
          'images': 114,
        });
        // Stats are absent until the poller has two samples.
        expect(c('sonarr').cpuPercent, isNull);
        expect(r.body, isNot(contains('/volume1')));
      },
    );

    test(
      'a restart missed by the event stream refreshes the start time',
      () async {
        var started = '2026-11-08T06:21:17.288940434Z';
        void fakeInspect() {
          final inspect = readMap(
            fixture('system/docker_container_inspect.json'),
          )!;
          hub.fakes.on(
            ServiceId.docker,
            'GET',
            '$_v/containers/${idOf('sonarr')}/json',
            (_) {
              return FakeResponse.json({
                ...inspect,
                'State': {...readMap(inspect['State'])!, 'StartedAt': started},
              });
            },
          );
        }

        fakeInspect();
        ContainerSummary sonarr(TestResponse r) =>
            ContainerList.fromJson(r.map).items
                .firstWhere((c) => c.name == 'sonarr');
        expect(
          sonarr(await hub.get('/api/v1/containers')).uptimeSeconds,
          greaterThan(9000),
        );
        // sonarr restarted two minutes ago: Docker now says "Up 2 minutes".
        started = '2026-11-08T08:58:00Z';
        hub.fakeDocker(
          list: [
            for (final e in dockerList())
              if (readStringList(e['Names']).first == '/sonarr')
                {...e, 'Status': 'Up 2 minutes'}
              else
                e,
          ],
        );
        fakeInspect();
        hub.clock.advance(
          const Duration(seconds: 6),
        ); // the list cache (5 s) expires
        expect(
          sonarr(await hub.get('/api/v1/containers')).uptimeSeconds,
          2 * 60 + 6,
        );
      },
    );

    test('filters by group and q', () async {
      final r = await hub.get('/api/v1/containers?group=downloads');
      expect(ContainerList.fromJson(r.map).items.map((c) => c.name), [
        'gluetun',
        'qbittorrent',
      ]);
      final q = await hub.get('/api/v1/containers?q=JELLY');
      expect(ContainerList.fromJson(q.map).items.map((c) => c.name), [
        'jellystat-db',
      ]);
    });

    test(
      'adds stats after two poller rounds (shared netns counters hidden)',
      () async {
        await hub.ready;
        var round = 0;
        JsonMap sample(int cpu, int rx) => {
          'read': instantToJson(
            DateTime.utc(2026, 11, 8, 9).add(Duration(seconds: round * 10)),
          ),
          'cpu_stats': {
            'cpu_usage': {'total_usage': cpu},
            'system_cpu_usage': 1000000 + round * 1000000,
            'online_cpus': 4,
          },
          'memory_stats': {
            'usage': 300,
            'stats': {'inactive_file': 100},
            'limit': 1000,
          },
          'networks': {
            'eth0': {'rx_bytes': rx, 'tx_bytes': rx ~/ 2},
          },
          'pids_stats': {'current': 7},
        };
        hub.fakes.on(
          ServiceId.docker,
          'GET',
          RegExp(r'^/v1\.54/containers/[0-9a-f]{64}/stats$'),
          (req) {
            expect(req.query['one-shot'], ['true']);
            expect(req.query['stream'], ['false']);
            return FakeResponse.json(sample(round * 10000, round * 10000));
          },
        );
        final service = hub.containers.service;
        await service.sampleStats();
        round = 1;
        await service.sampleStats();
        final r = await hub.get('/api/v1/containers');
        final list = ContainerList.fromJson(r.map);
        final sonarr = list.items.firstWhere((c) => c.name == 'sonarr');
        expect(sonarr.cpuPercent, 4.0);
        expect(sonarr.memBytes, 200);
        expect(sonarr.memPercent, 20.0);
        expect(sonarr.netRxBps, 1000);
        expect(sonarr.netTxBps, 500);
        final qbit = list.items.firstWhere((c) => c.name == 'qbittorrent');
        expect(qbit.cpuPercent, 4.0);
        expect(qbit.netRxBps, isNull);
        expect(list.statsAt, DateTime.utc(2026, 11, 8, 9, 0, 10));
        expect(
          list.items.firstWhere((c) => c.name == 'portainer').cpuPercent,
          isNull,
        );
      },
    );

    test('Docker unreachable → 503 upstream_unavailable', () async {
      final down = containersHub();
      addTearDown(down.close);
      down.fakes.on(
        ServiceId.docker,
        'GET',
        '$_v/containers/json',
        (_) => throw const SocketException('refused'),
      );
      final r = await down.get('/api/v1/containers');
      expect(r.status, 503);
      expect(r.errorCode, 'upstream_unavailable');
      expect(r.body, isNot(contains('socket-proxy-hub.test')));
    });

    test('Docker not configured → 503 service_not_configured', () async {
      final off = containersHub(unconfigured: {ServiceId.docker});
      addTearDown(off.close);
      final r = await off.get('/api/v1/containers');
      expect(r.status, 503);
      expect(r.errorCode, 'service_not_configured');
    });
  });

  group('GET /containers/{name}', () {
    late TestHub hub;
    setUp(() {
      hub = containersHub();
      hub.fakeDocker();
    });
    tearDown(() => hub.close());

    test(
      'maps inspect without Env, Cmd, HostConfig or mount sources',
      () async {
        final r = await hub.get('/api/v1/containers/sonarr', as: TestAs.member);
        expect(r.status, 200, reason: r.body);
        final d = ContainerDetail.fromJson(r.map);
        expect(d.name, 'sonarr');
        expect(d.restartCount, 0);
        expect(d.restartPolicy, 'unless-stopped');
        expect(d.networkMode, 'yams_network');
        expect(d.imageId, startsWith('sha256:ae55f56fa15c'));
        expect(d.createdAt, DateTime.parse('2026-10-31T19:20:52.274709Z'));
        expect(
          d.summary.startedAt,
          DateTime.parse('2026-11-08T06:21:17.288940Z'),
        );
        expect(d.finishedAt, DateTime.parse('2026-11-08T06:02:02.343647Z'));
        expect(d.mounts.map((m) => m.toJson()), [
          {'destination': '/config', 'readOnly': false},
          {'destination': '/data', 'readOnly': false},
          {'destination': '/etc/localtime', 'readOnly': true},
        ]);
        expect(d.dependents, ['recyclarr', 'decluttarr', 'bazarr']);
        expect(d.healthLog, isEmpty);
        for (final leak in [
          'PUID',
          'SONARR_CHANNEL',
          '/volume1',
          'Binds',
          'Env',
          'MaskedPaths',
        ]) {
          expect(r.body, isNot(contains(leak)), reason: leak);
        }
        expect(hub.dockerCalls('$_v/containers/sonarr/json'), isNotEmpty);
      },
    );

    test(
      'health log output is admin-only, redacted and cut to 200 chars',
      () async {
        final admin = ContainerDetail.fromJson(
          (await hub.get('/api/v1/containers/decluttarr')).map,
        );
        expect(admin.healthLog, hasLength(2));
        expect(admin.healthLog.first.output, contains('apikey=***'));
        expect(
          admin.healthLog.first.start,
          DateTime.parse('2026-11-08T08:58:00.123456Z'),
        );
        expect(admin.healthLog.last.exitCode, 1);
        expect(admin.healthLog.last.output, hasLength(200));
        expect(admin.restartCount, 3);
        expect(admin.mounts.single.readOnly, isTrue);

        final member = await hub.get(
          '/api/v1/containers/decluttarr',
          as: TestAs.member,
        );
        final d = ContainerDetail.fromJson(member.map);
        expect(d.healthLog.map((h) => h.output), [null, null]);
        expect(d.healthLog.map((h) => h.exitCode), [0, 1]);
        for (final body in [
          member.body,
          (await hub.get('/api/v1/containers/decluttarr')).body,
        ]) {
          expect(body, isNot(contains('SUPERSECRETKEY123')));
          expect(body, isNot(contains('hunter2')));
        }
      },
    );

    test('qbittorrent shows its network as container:gluetun', () async {
      hub.fakes.on(
        ServiceId.docker,
        'GET',
        '$_v/containers/qbittorrent/json',
        (_) => FakeResponse.json({
          'Created': '2026-11-08T08:00:00Z',
          'State': {
            'Status': 'running',
            'Running': true,
            'StartedAt': '2026-11-08T08:00:00Z',
          },
          'HostConfig': {
            'NetworkMode': 'container:1b55eec72010d6b642b5dd6fb9dd7d7c66da3eb56941c8a82e0d92b22d5c4208',
          },
        }),
      );
      final d = ContainerDetail.fromJson(
        (await hub.get('/api/v1/containers/qbittorrent')).map,
      );
      expect(d.networkMode, 'container:gluetun');
      expect(d.dependsOn, ['gluetun']);
    });
  });

  group('exact-name resolution (API.md §11.6)', () {
    late TestHub hub;
    setUp(() async {
      hub = containersHub();
      hub.fakeDocker();
      await hub.passSelfTest();
    });
    tearDown(() => hub.close());

    test(
      'an id prefix of a locked container → 404 and no Docker write',
      () async {
        final id = idOf('yams-hub');
        for (final ref in [id.substring(0, 12), id]) {
          final r = await hub.post(
            '/api/v1/containers/$ref/actions',
            body: {'action': 'restart', 'confirm': true},
          );
          expect(r.status, 404, reason: ref);
          expect(r.errorCode, 'not_found');
        }
        expect(
          hub.fakes
              .callsTo(ServiceId.docker)
              .where((c) => c.method == 'POST' && c.path.contains('/restart')),
          isEmpty,
        );
      },
    );

    test('`..`, `.` and ids are 404 on every {name} route', () async {
      for (final path in [
        '/api/v1/containers/..',
        '/api/v1/containers/.',
        '/api/v1/containers/../logs',
        '/api/v1/containers/${idOf('sonarr')}',
        '/api/v1/containers/${idOf('sonarr').substring(0, 12)}/logs',
        '/api/v1/containers/Sonarr',
        '/api/v1/containers/sonar',
      ]) {
        final r = await hub.get(path);
        expect(r.status, 404, reason: path);
        expect(r.errorCode, 'not_found', reason: path);
      }
      final r = await hub.post(
        '/api/v1/containers/../actions',
        body: {'action': 'restart'},
      );
      expect(r.status, 404);
    });

    test(
      'a miss refreshes the list once (a container created since)',
      () async {
        final r1 = await hub.get('/api/v1/containers/sonarr');
        expect(r1.status, 200);
        final before = hub.dockerCalls('$_v/containers/json').length;
        final missing = await hub.get('/api/v1/containers/newcomer');
        expect(missing.status, 404);
        expect(hub.dockerCalls('$_v/containers/json').length, before + 1);
      },
    );
  });

  group('GET /containers/{name}/logs', () {
    late TestHub hub;
    setUp(() {
      hub = containersHub();
      hub.fakeDocker();
    });
    tearDown(() => hub.close());

    test(
      'decodes the multiplexed fixture body, newest last, redacted',
      () async {
        final f = readMap(
          fixture('system/docker_container_logs_decluttarr.json'),
        )!;
        final secret = multiplexed([
          (
            2,
            '2026-11-08T08:58:00.000000000Z GET http://sonarr:8989/api?apikey=TOPSECRET1\n',
          ),
        ]);
        hub.fakes.on(
          ServiceId.docker,
          'GET',
          '$_v/containers/decluttarr/logs',
          (_) => FakeResponse.bytes([
            ...base64.decode(readString(f['body_base64'])!),
            ...secret,
          ]),
        );
        final r = await hub.get('/api/v1/containers/decluttarr/logs?tail=200');
        expect(r.status, 200, reason: r.body);
        final logs = LogResponse.fromJson(r.map);
        final expected = readList(f['expected_frames'], (m) => m);
        expect(logs.lines, hasLength(expected.length + 1));
        expect(logs.truncated, isFalse);
        expect(logs.lines.first.stream, ContainerLogStream.stderr);
        expect(
          logs.lines.first.at,
          DateTime.parse('2026-11-08T08:17:23.426244Z'),
        );
        expect(
          logs.lines.first.text,
          startsWith('INFO    | Termination signal'),
        );
        expect(logs.lines.last.text, contains('apikey=***'));
        expect(r.body, isNot(contains('TOPSECRET1')));
        final call = hub.dockerCalls('$_v/containers/decluttarr/logs').single;
        expect(call.query['stdout'], ['1']);
        expect(call.query['stderr'], ['1']);
        expect(call.query['timestamps'], ['1']);
        expect(call.query['tail'], ['200']);
      },
    );

    test('since, stream and tail are passed and filtered', () async {
      hub.fakes.on(
        ServiceId.docker,
        'GET',
        '$_v/containers/sonarr/logs',
        (_) => FakeResponse.bytes(
          multiplexed([
            (1, '2026-11-08T08:00:00.000001Z old\n'),
            (1, '2026-11-08T08:00:01Z new\n'),
          ]),
        ),
      );
      final r = await hub.get(
        '/api/v1/containers/sonarr/logs?tail=2&stream=stdout&since=2026-11-08T08:00:00.000001Z',
      );
      expect(r.status, 200, reason: r.body);
      final logs = LogResponse.fromJson(r.map);
      expect(logs.lines.map((l) => l.text), ['new']);
      expect(logs.truncated, isTrue);
      final call = hub.dockerCalls('$_v/containers/sonarr/logs').single;
      expect(call.query['stderr'], ['0']);
      expect(call.query['since'], ['1794124800.000001']);
      expect(call.query['tail'], ['2']);
    });

    test('rejects bad parameters', () async {
      for (final q in [
        'tail=0',
        'tail=2001',
        'stream=both',
        'since=yesterday',
      ]) {
        final r = await hub.get('/api/v1/containers/sonarr/logs?$q');
        expect(r.status, 400, reason: q);
      }
    });

    test('proxy 403 → 503 "Logs need ALLOW_LOGS=1"', () async {
      hub.fakes.on(
        ServiceId.docker,
        'GET',
        '$_v/containers/sonarr/logs',
        (_) => FakeResponse.text(
          '<html><body><h1>403 Forbidden</h1>Request forbidden by administrative rules.</body></html>',
          status: 403,
          contentType: 'text/html',
        ),
      );
      final r = await hub.get('/api/v1/containers/sonarr/logs');
      expect(r.status, 503);
      expect(r.errorCode, 'service_not_configured');
      expect(
        readMap(r.map['error'])!['message'],
        contains('Logs need ALLOW_LOGS=1'),
      );
    });

    test('members get 403', () async {
      final r = await hub.get(
        '/api/v1/containers/sonarr/logs',
        as: TestAs.member,
      );
      expect(r.status, 403);
    });
  });

  group('POST /containers/{name}/actions', () {
    late TestHub hub;
    setUp(() {
      hub = containersHub();
      hub.fakeDocker();
    });
    tearDown(() => hub.close());

    void fakeAction(String name, String action, {int status = 204}) =>
        hub.fakes.on(
          ServiceId.docker,
          'POST',
          '$_v/containers/$name/$action',
          (_) => FakeResponse(status),
        );

    test('actions are disabled until the proxy self-test passes', () async {
      fakeAction('sonarr', 'restart');
      final r = await hub.post(
        '/api/v1/containers/sonarr/actions',
        body: {'action': 'restart'},
      );
      expect(r.status, 503);
      expect(r.errorCode, 'service_not_configured');
      expect(hub.dockerCalls('$_v/containers/sonarr/restart'), isEmpty);
    });

    test('a failed self-test (proxy allows writes) disables actions', () async {
      await hub.ready;
      hub.fakes.on(
        ServiceId.docker,
        'POST',
        '$_v/containers/create',
        (_) => FakeResponse.json({'message': 'invalid'}, status: 400),
      );
      expect(await hub.hub.health.dockerProxy.run(), ProxySelfTestState.failed);
      final r = await hub.post(
        '/api/v1/containers/sonarr/actions',
        body: {'action': 'restart'},
      );
      expect(r.status, 503);
      expect(readMap(r.map['error'])!['message'], contains('not restricted'));
    });

    test(
      'restart runs as a job against the canonical name with t=30',
      () async {
        await hub.passSelfTest();
        fakeAction('sonarr', 'restart');
        final r = await hub.post(
          '/api/v1/containers/sonarr/actions',
          body: {'action': 'restart'},
        );
        expect(r.status, 202, reason: r.body);
        final job = Job.fromJson(readMap(r.map['job'])!);
        expect(job.kind, 'containers.restart');
        expect(job.target, 'sonarr');
        final done = await hub.waitJob(job.id);
        expect(
          done.status,
          JobStatus.succeeded,
          reason: '${done.error?.message}',
        );
        expect(done.steps.single.label, 'Restart sonarr');
        expect(done.result, {'state': 'running', 'health': 'none'});
        final call = hub.dockerCalls('$_v/containers/sonarr/restart').single;
        expect(call.query['t'], ['30']);
      },
    );

    test('start has no t; 304 (already running) counts as success', () async {
      await hub.passSelfTest();
      fakeAction('sonarr', 'start', status: 304);
      final r = await hub.post(
        '/api/v1/containers/sonarr/actions',
        body: {'action': 'start'},
      );
      expect(r.status, 202);
      final done = await hub.waitJob(Job.fromJson(readMap(r.map['job'])!).id);
      expect(done.status, JobStatus.succeeded);
      expect(
        hub.dockerCalls('$_v/containers/sonarr/start').single.query,
        isEmpty,
      );
    });

    test(
      'every stop and confirm-list container needs confirm=true (428)',
      () async {
        await hub.passSelfTest();
        fakeAction('sonarr', 'stop');
        fakeAction('qbittorrent', 'restart');
        final stop = await hub.post(
          '/api/v1/containers/sonarr/actions',
          body: {'action': 'stop'},
        );
        expect(stop.status, 428);
        expect(stop.errorCode, 'confirmation_required');
        expect(
          readMap(readMap(stop.map['error'])!['details'])!['impact'],
          contains('Stops sonarr'),
        );
        final confirmList = await hub.post(
          '/api/v1/containers/qbittorrent/actions',
          body: {'action': 'restart'},
        );
        expect(confirmList.status, 428);
        expect(
          hub.fakes
              .callsTo(ServiceId.docker)
              .where((c) => c.method == 'POST' && c.path.endsWith('/stop')),
          isEmpty,
        );
        final ok = await hub.post(
          '/api/v1/containers/sonarr/actions?confirm=true',
          body: {'action': 'stop'},
        );
        expect(ok.status, 202);
      },
    );

    test('stopping gluetun warns that qBittorrent loses network', () async {
      await hub.passSelfTest();
      final r = await hub.post(
        '/api/v1/containers/gluetun/actions',
        body: {'action': 'stop'},
      );
      expect(r.status, 428);
      expect(
        readMap(readMap(r.map['error'])!['details'])!['impact'],
        contains('qBittorrent loses network'),
      );
    });

    test('locked containers → 403 policy_denied', () async {
      await hub.passSelfTest();
      final r = await hub.post(
        '/api/v1/containers/yams-hub/actions',
        body: {'action': 'restart', 'confirm': true},
      );
      expect(r.status, 403);
      expect(r.errorCode, 'policy_denied');
    });

    test(
      'gluetun restart waits for healthy, then restarts qbittorrent',
      () async {
        await hub.passSelfTest();
        fakeAction('gluetun', 'restart');
        fakeAction('qbittorrent', 'restart');
        var inspects = 0;
        hub.fakes.on(ServiceId.docker, 'GET', '$_v/containers/gluetun/json', (
          _,
        ) {
          inspects++;
          return FakeResponse.json({
            'State': {
              'Status': 'running',
              'Running': true,
              'Health': {'Status': inspects < 3 ? 'starting' : 'healthy'},
            },
          });
        });
        final r = await hub.post(
          '/api/v1/containers/gluetun/actions',
          body: {'action': 'restart', 'confirm': true},
        );
        expect(r.status, 202, reason: r.body);
        final done = await hub.waitJob(Job.fromJson(readMap(r.map['job'])!).id);
        expect(
          done.status,
          JobStatus.succeeded,
          reason: '${done.error?.message}',
        );
        expect(done.steps.map((s) => s.label), [
          'Restart gluetun',
          'Wait for gluetun to become healthy',
          'Restart qbittorrent',
        ]);
        expect(done.result, {'state': 'running', 'health': 'healthy'});
        final order = [
          for (final c in hub.fakes.callsTo(ServiceId.docker))
            if (c.method == 'POST' && c.path.endsWith('/restart')) c.path,
        ];
        expect(order, [
          '$_v/containers/gluetun/restart',
          '$_v/containers/qbittorrent/restart',
        ]);
      },
    );

    test(
      'gluetun never healthy → the job fails and qbittorrent is left alone',
      () async {
        await hub.passSelfTest();
        fakeAction('gluetun', 'restart');
        hub.fakes.on(
          ServiceId.docker,
          'GET',
          '$_v/containers/gluetun/json',
          (_) => FakeResponse.json({
            'State': {
              'Status': 'running',
              'Health': {'Status': 'unhealthy'},
            },
          }),
        );
        final r = await hub.post(
          '/api/v1/containers/gluetun/actions',
          body: {'action': 'restart', 'confirm': true},
        );
        final done = await hub.waitJob(Job.fromJson(readMap(r.map['job'])!).id);
        expect(done.status, JobStatus.failed);
        expect(done.error!.code, 'upstream_timeout');
        expect(hub.dockerCalls('$_v/containers/qbittorrent/restart'), isEmpty);
      },
    );

    test('a Docker error fails the job with the mapped error', () async {
      await hub.passSelfTest();
      hub.fakes.on(
        ServiceId.docker,
        'POST',
        '$_v/containers/sonarr/restart',
        (_) => FakeResponse.json({
          'message': 'cannot restart: driver failed',
        }, status: 500),
      );
      final r = await hub.post(
        '/api/v1/containers/sonarr/actions',
        body: {'action': 'restart'},
      );
      final done = await hub.waitJob(Job.fromJson(readMap(r.map['job'])!).id);
      expect(done.status, JobStatus.failed);
      expect(done.error!.code, 'upstream_error');
      expect(done.error!.message, contains('driver failed'));
    });

    test('bad bodies and member callers are refused', () async {
      await hub.passSelfTest();
      final bad = await hub.post(
        '/api/v1/containers/sonarr/actions',
        body: {'action': 'kill'},
      );
      expect(bad.status, 400);
      final member = await hub.post(
        '/api/v1/containers/sonarr/actions',
        body: {'action': 'restart'},
        as: TestAs.member,
      );
      expect(member.status, 403);
    });

    test('the action is audited', () async {
      await hub.passSelfTest();
      fakeAction('sonarr', 'restart');
      final r = await hub.post(
        '/api/v1/containers/sonarr/actions',
        body: {'action': 'restart'},
      );
      await hub.waitJob(Job.fromJson(readMap(r.map['job'])!).id);
      await hub.hub.audit.flush();
      final audit = await hub.get('/api/v1/admin/audit?action=containers.');
      expect(audit.status, 200);
      final actions = [
        for (final e in readList(audit.map['items'], (m) => m)) e['action'],
      ];
      expect(
        actions,
        containsAll(['containers.actions', 'containers.restart']),
      );
    });
  });

  group('GET /containers/events', () {
    test('the stream is kept open, reconnects with since= and is buffered', () async {
      final hub = containersHub(start: true);
      addTearDown(hub.close);
      final first = StreamController<List<int>>();
      var opens = 0;
      final sinces = <List<String>?>[];
      hub.fakes.on(ServiceId.docker, 'GET', '$_v/events', (req) {
        opens++;
        sinces.add(req.query['since']);
        expect(jsonDecode(req.query['filters']!.single), {
          'type': ['container'],
          'event': [
            'start',
            'stop',
            'die',
            'kill',
            'restart',
            'oom',
            'health_status',
            'create',
            'destroy',
          ],
        });
        if (opens == 1) return FakeResponse.chunked(first.stream);
        return FakeResponse.chunked(const Stream.empty());
      });
      await hub.ready;
      // The module started before the fake was registered: wait for a retry.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (opens == 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      String line(String action, String name, int t, {String? exit}) =>
          '${jsonEncode({
            'Type': 'container',
            'Action': action,
            'Actor': {
              'ID': 'id-$name',
              'Attributes': {'name': name, 'exitCode': ?exit},
            },
            'time': t,
            'timeNano': t * 1000000000,
          })}\n';
      first
        ..add(utf8.encode(line('die', 'sonarr', 1794124800, exit: '0')))
        ..add(utf8.encode(line('start', 'sonarr', 1794124801)))
        ..add(
          utf8.encode(
            '${line('health_status: healthy', 'decluttarr', 1794124802)}not json\n',
          ),
        );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await first.close();
      while (opens < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(opens, greaterThanOrEqualTo(2));
      expect(sinces.last, ['1794124802']);

      final r = await hub.get('/api/v1/containers/events', as: TestAs.member);
      expect(r.status, 200);
      final events = ItemList.fromJson(r.map, ContainerEvent.fromJson).items;
      expect(events.map((e) => (e.name, e.action)), [
        ('decluttarr', ContainerEventAction.health),
        ('sonarr', ContainerEventAction.start),
        ('sonarr', ContainerEventAction.die),
      ]);
      expect(events.first.health, 'healthy');
      expect(events.last.exitCode, 0);
      final filtered = await hub.get(
        '/api/v1/containers/events?name=sonarr&limit=1',
      );
      expect(
        ItemList.fromJson(
          filtered.map,
          ContainerEvent.fromJson,
        ).items.single.action,
        ContainerEventAction.start,
      );
      expect(
        (await hub.get('/api/v1/containers/events?limit=201')).status,
        400,
      );
    });
  });

  group('updates', () {
    late TestHub hub;
    setUp(() {
      hub = containersHub();
      hub.fakeDocker();
      hub.fakes.on(
        ServiceId.watchtower,
        'GET',
        '/v1/metrics',
        (_) =>
            FakeResponse.text(fixtureText('system/watchtower_v1_metrics.txt')),
      );
      hub.fakes.on(
        ServiceId.watchtower,
        'GET',
        '/v1/status',
        (_) => FakeResponse(204),
      );
    });
    tearDown(() => hub.close());

    void enableCheck() {
      hub.fakes.on(
        ServiceId.watchtower,
        'GET',
        '/v1/containers/details',
        (_) => FakeResponse.json({'containers': <Object?>[], 'count': 0}),
      );
      hub.fakes.on(
        ServiceId.watchtower,
        'POST',
        '/v1/check',
        (_) =>
            FakeResponse.json(dataJson('watchtower_v1_check.synthetic.json')),
      );
    }

    void enableUpdater() {
      hub.fakes.on(
        ServiceId.updater,
        'GET',
        '/services',
        (_) => FakeResponse.json({
          'services': [
            'sonarr',
            'homepage',
            'gluetun',
            'yams-hub',
            'qbittorrent',
          ],
        }),
      );
    }

    test('lastScan is present even when the check endpoint is off', () async {
      final r = await hub.get('/api/v1/updates', as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      final u = UpdatesResponse.fromJson(r.map);
      expect(u.available, isFalse);
      expect(u.updaterAvailable, isFalse);
      expect(u.checkedAt, isNull);
      expect(u.lastScan!.toJson(), {
        'scanned': 0,
        'updated': 0,
        'failed': 0,
        'skipped': 0,
        'restarted': 0,
        'scansTotal': 0,
      });
      expect(u.items, hasLength(10));
      final qbit = u.items.firstWhere((i) => i.name == 'qbittorrent');
      expect(qbit.pinned, isTrue);
      expect(qbit.updateAvailable, isNull);
      expect(
        u.items.firstWhere((i) => i.name == 'homepage').autoUpdate,
        isTrue,
      );
      expect(u.items.every((i) => !i.canUpdate), isTrue);
      // Never /v1/check from a read.
      expect(
        hub.fakes
            .callsTo(ServiceId.watchtower)
            .where((c) => c.path == '/v1/check'),
        isEmpty,
      );
    });

    test('the scan time comes from /v1/status after the first scan', () async {
      hub.fakes.on(
        ServiceId.watchtower,
        'GET',
        '/v1/status',
        (_) => FakeResponse.json({
          'summary': {'scanned': 21},
          'timestamp': '2026-11-09T07:54:04Z',
          'api_version': 'v1',
        }),
      );
      final u = UpdatesResponse.fromJson(
        (await hub.get('/api/v1/updates')).map,
      );
      expect(u.lastScan!.at, DateTime.utc(2026, 11, 9, 7, 54, 4));
    });

    test(
      'POST /updates/check with the endpoint off → 503 with instructions',
      () async {
        final r = await hub.post(
          '/api/v1/updates/check',
          body: <String, Object?>{},
        );
        expect(r.status, 503);
        expect(r.errorCode, 'service_not_configured');
        expect(
          readMap(r.map['error'])!['message'],
          contains(
            'WATCHTOWER_HTTP_API_ENDPOINTS=metrics,check,containers,history',
          ),
        );
        expect(
          hub.fakes
              .callsTo(ServiceId.watchtower)
              .where((c) => c.path == '/v1/check'),
          isEmpty,
        );
      },
    );

    test(
      'a check job stores results (updates.json) and is rate limited',
      () async {
        enableCheck();
        enableUpdater();
        final r = await hub.post(
          '/api/v1/updates/check',
          body: <String, Object?>{},
        );
        expect(r.status, 202, reason: r.body);
        final job = Job.fromJson(readMap(r.map['job'])!);
        expect(job.kind, 'updates.check');
        final done = await hub.waitJob(job.id);
        expect(
          done.status,
          JobStatus.succeeded,
          reason: '${done.error?.message}',
        );
        expect(done.result, {'checked': 3, 'updatesAvailable': 1, 'failed': 1});
        final call = hub.fakes
            .callsTo(ServiceId.watchtower)
            .singleWhere((c) => c.path == '/v1/check');
        expect(call.method, 'POST');
        expect(call.query['timeout'], ['2m']);
        expect(call.query.containsKey('container'), isFalse);

        final u = UpdatesResponse.fromJson(
          (await hub.get('/api/v1/updates')).map,
        );
        expect(u.available, isTrue);
        expect(u.updaterAvailable, isTrue);
        expect(u.checkedAt, hub.clock.now());
        expect(u.items.first.name, 'sonarr');
        final sonarr = u.items.first;
        expect(sonarr.updateAvailable, isTrue);
        expect(sonarr.latestDigest, 'sha256:new0001');
        expect(sonarr.currentVersion, '4.0.20.3014-ls2');
        expect(sonarr.canUpdate, isTrue);
        expect(
          u.items.firstWhere((i) => i.name == 'yams-hub').canUpdate,
          isFalse,
        );
        final qbit = u.items.firstWhere((i) => i.name == 'qbittorrent');
        expect(qbit.error, contains('token=***'));
        expect(qbit.error, isNot(contains('ABCDEF0123')));

        // The badge appears on the container list too.
        final list = ContainerList.fromJson(
          (await hub.get('/api/v1/containers')).map,
        );
        final badge = list.items.firstWhere((c) => c.name == 'sonarr').update!;
        expect(badge.available, isTrue);

        final file = File(p.join(hub.config.dataDir, 'updates.json'));
        expect(file.existsSync(), isTrue);
        expect(file.readAsStringSync(), contains('sha256:new0001'));

        final again = await hub.post(
          '/api/v1/updates/check',
          body: <String, Object?>{},
        );
        expect(again.status, 429);
        expect(again.errorCode, 'rate_limited');
        expect(again.headers['retry-after'], isNotNull);
        hub.clock.advance(const Duration(minutes: 5, seconds: 1));
        final later = await hub.post(
          '/api/v1/updates/check',
          body: <String, Object?>{},
        );
        expect(later.status, 202);
        await hub.waitJob(Job.fromJson(readMap(later.map['job'])!).id);
      },
    );

    test(
      'a targeted check passes container= and is not rate limited',
      () async {
        enableCheck();
        final r = await hub.post(
          '/api/v1/updates/check',
          body: {
            'containers': ['sonarr', 'homepage'],
          },
        );
        expect(r.status, 202);
        await hub.waitJob(Job.fromJson(readMap(r.map['job'])!).id);
        final call = hub.fakes
            .callsTo(ServiceId.watchtower)
            .singleWhere((c) => c.path == '/v1/check');
        expect(call.query['container'], ['homepage,sonarr']);
        final bad = await hub.post(
          '/api/v1/updates/check',
          body: {
            'containers': ['../etc'],
          },
        );
        expect(bad.status, 400);
      },
    );

    test('check results survive a restart (store)', () async {
      enableCheck();
      final r = await hub.post(
        '/api/v1/updates/check',
        body: <String, Object?>{},
      );
      await hub.waitJob(Job.fromJson(readMap(r.map['job'])!).id);
      await hub.hub.stores.closeAll();
      final store = UpdateStoreProbe.read(hub.config.dataDir);
      expect(store['lastFullCheckAt'], instantToJson(hub.clock.now()));
      expect(readList(store['results'], (m) => m), hasLength(3));
    });

    test('POST /updates/{service}: allow-list, locked, confirm', () async {
      enableUpdater();
      final unknown = await hub.post('/api/v1/updates/jellyfin?confirm=true');
      expect(unknown.status, 404);
      final locked = await hub.post('/api/v1/updates/yams-hub?confirm=true');
      expect(locked.status, 403);
      expect(locked.errorCode, 'policy_denied');
      final noConfirm = await hub.post('/api/v1/updates/sonarr');
      expect(noConfirm.status, 428);
      expect(
        hub.fakes.callsTo(ServiceId.updater).where((c) => c.method == 'POST'),
        isEmpty,
      );
      final member = await hub.post(
        '/api/v1/updates/sonarr?confirm=true',
        as: TestAs.member,
      );
      expect(member.status, 403);
    });

    test('a container name maps to its allow-listed compose service', () async {
      enableUpdater();
      final list = dockerList();
      final sonarr = list.firstWhere(
        (e) => readStringList(e['Names']).first == '/sonarr',
      );
      list.add({
        ...sonarr,
        'Id': 'f' * 64,
        'Names': ['/tv-main'],
        'Labels': {
          ...readMap(sonarr['Labels'])!,
          'com.docker.compose.service': 'sonarr',
        },
      });
      hub.fakeDocker(list: list);
      hub.fakes.on(
        ServiceId.updater,
        'POST',
        '/update/sonarr',
        (_) => FakeResponse.json({'jobId': 'u_x'}, status: 202),
      );
      hub.fakes.on(
        ServiceId.updater,
        'GET',
        '/jobs/u_x',
        (_) => FakeResponse.json({'id': 'u_x', 'state': 'succeeded'}),
      );
      final r = await hub.post('/api/v1/updates/tv-main?confirm=true');
      expect(r.status, 202, reason: r.body);
      final job = Job.fromJson(readMap(r.map['job'])!);
      expect(job.target, 'sonarr');
      await hub.waitJob(job.id);
      expect(
        hub.fakes
            .callsTo(ServiceId.updater)
            .where((c) => c.method == 'POST')
            .map((c) => c.path),
        ['/update/sonarr'],
      );
      // A name whose service is not allow-listed stays 404.
      final other = await hub.post('/api/v1/updates/decluttarr?confirm=true');
      expect(other.status, 404);
    });

    test(
      'an update mirrors the updater job (steps, redacted log) and re-checks',
      () async {
        enableUpdater();
        enableCheck();
        hub.fakes.on(ServiceId.updater, 'POST', '/update/sonarr', (req) {
          expect(req.json(), {'service': 'sonarr'});
          expect(req.headers['authorization'], startsWith('Bearer '));
          return FakeResponse.json({'jobId': 'u_job1'}, status: 202);
        });
        var polls = 0;
        hub.fakes.on(ServiceId.updater, 'GET', '/jobs/u_job1', (_) {
          polls++;
          return FakeResponse.json(
            dataJson(
              polls < 2
                  ? 'updater_job_running.synthetic.json'
                  : 'updater_job_succeeded.synthetic.json',
            ),
          );
        });
        final r = await hub.post(
          '/api/v1/updates/sonarr',
          body: {'confirm': true},
        );
        expect(r.status, 202, reason: r.body);
        final job = Job.fromJson(readMap(r.map['job'])!);
        expect(job.kind, 'updates.apply');
        expect(job.target, 'sonarr');
        final done = await hub.waitJob(job.id);
        expect(
          done.status,
          JobStatus.succeeded,
          reason: '${done.error?.message}',
        );
        expect(done.steps.map((s) => s.label), [
          'Ask the updater to update sonarr',
          'compose pull sonarr',
          'compose up -d --no-deps sonarr',
          'docker image prune -f',
          'Check sonarr for updates',
        ]);
        expect(done.log, contains('Container sonarr Recreated'));
        expect(
          done.log.where((l) => l.startsWith('Pulling sonarr')),
          hasLength(1),
        );
        expect(done.log.join('\n'), isNot(contains('SECRETTOKEN42')));
        final check = hub.fakes
            .callsTo(ServiceId.watchtower)
            .singleWhere((c) => c.path == '/v1/check');
        expect(check.query['container'], ['sonarr']);
      },
    );

    test('a failed updater job fails the gateway job', () async {
      enableUpdater();
      hub.fakes.on(
        ServiceId.updater,
        'POST',
        '/update/sonarr',
        (_) => FakeResponse.json({'jobId': 'u_bad'}, status: 202),
      );
      hub.fakes.on(
        ServiceId.updater,
        'GET',
        '/jobs/u_bad',
        (_) => FakeResponse.json({
          'id': 'u_bad',
          'state': 'failed',
          'steps': [
            {'cmd': 'docker compose pull -- sonarr', 'exitCode': 1},
          ],
          'log': ['pull access denied'],
        }),
      );
      final r = await hub.post('/api/v1/updates/sonarr?confirm=true');
      final done = await hub.waitJob(Job.fromJson(readMap(r.map['job'])!).id);
      expect(done.status, JobStatus.failed);
      expect(done.error!.code, 'upstream_error');
      expect(done.log, contains('pull access denied'));
    });

    test('updater busy (409) fails with job_running', () async {
      enableUpdater();
      hub.fakes.on(
        ServiceId.updater,
        'POST',
        '/update/sonarr',
        (_) => FakeResponse.json({'error': 'busy'}, status: 409),
      );
      final r = await hub.post('/api/v1/updates/sonarr?confirm=true');
      final done = await hub.waitJob(Job.fromJson(readMap(r.map['job'])!).id);
      expect(done.error!.code, 'job_running');
    });

    test('without the updater → 503', () async {
      final off = containersHub(unconfigured: {ServiceId.updater});
      addTearDown(off.close);
      final r = await off.post('/api/v1/updates/sonarr?confirm=true');
      expect(r.status, 503);
      expect(r.errorCode, 'service_not_configured');
      final sync = await off.post(
        '/api/v1/maintenance/recyclarr/sync?confirm=true',
      );
      expect(sync.status, 503);
    });
  });

  group('maintenance', () {
    late TestHub hub;
    setUp(() {
      hub = containersHub();
      hub.fakeDocker();
    });
    tearDown(() => hub.close());

    test('GET /maintenance/decluttarr parses 24 h of stderr logs', () async {
      final f = readMap(
        fixture('system/docker_container_logs_decluttarr.json'),
      )!;
      hub.fakes.on(
        ServiceId.docker,
        'GET',
        '$_v/containers/decluttarr/logs',
        (_) => FakeResponse.bytes(base64.decode(readString(f['body_base64'])!)),
      );
      final r = await hub.get(
        '/api/v1/maintenance/decluttarr',
        as: TestAs.member,
      );
      expect(r.status, 200, reason: r.body);
      final s = DecluttarrStatus.fromJson(r.map);
      expect(s.container.state, ContainerState.running);
      expect(s.container.health, ContainerHealth.healthy);
      expect(s.last24h.runs, 5);
      expect(s.lastRunAt, DateTime.parse('2026-11-08T08:57:27.361334Z'));
      expect(s.intervalMinutes, 10);
      expect(s.last24h.removed, isEmpty);
      final call = hub.dockerCalls('$_v/containers/decluttarr/logs').single;
      expect(call.query['since'], [
        ((hub.clock
                    .now()
                    .subtract(const Duration(hours: 24))
                    .millisecondsSinceEpoch) /
                1000)
            .toStringAsFixed(6),
      ]);
      expect(call.query.containsKey('tail'), isFalse);
      // Cached 60 s.
      await hub.get('/api/v1/maintenance/decluttarr');
      expect(hub.dockerCalls('$_v/containers/decluttarr/logs'), hasLength(1));
    });

    test('decluttarr logs denied → 503 ALLOW_LOGS', () async {
      hub.fakes.on(
        ServiceId.docker,
        'GET',
        '$_v/containers/decluttarr/logs',
        (_) => FakeResponse.text(
          '<html>403</html>',
          status: 403,
          contentType: 'text/html',
        ),
      );
      final r = await hub.get('/api/v1/maintenance/decluttarr');
      expect(r.status, 503);
      expect(readMap(r.map['error'])!['message'], contains('ALLOW_LOGS=1'));
    });

    test('GET /maintenance/recyclarr reads the newest debug log', () async {
      await hub.ready;
      final cli = Directory(p.join(hub.config.recyclarrLogDir, 'cli'))
        ..createSync(recursive: true);
      File(p.join(cli.path, 'recyclarr_2026-11-01_02-00-00.debug.log'))
          .writeAsStringSync('[02:00:01 ERR] old run failed\n');
      File(
        p.join(cli.path, 'recyclarr_2026-11-08_07-45-43.debug.log'),
      ).writeAsStringSync(
        '[07:45:43 DBG] noise\n${fixtureText('system/recyclarr_cli_debug_log_infolines.txt')}',
      );
      File(p.join(cli.path, 'recyclarr_2026-11-08_07-45-43.verbose.log'))
          .writeAsStringSync('[07:45:43 ERR] not this file\n');
      hub.fakes.on(
        ServiceId.docker,
        'GET',
        '$_v/containers/recyclarr/json',
        (_) => FakeResponse.json({
          'State': {'Status': 'running'},
          'Config': {
            'Env': ['CRON_SCHEDULE=0 4 * * 0', 'SECRET_KEY=abc'],
          },
        }),
      );
      hub.fakes.on(
        ServiceId.updater,
        'GET',
        '/services',
        (_) => FakeResponse.json({
          'services': ['recyclarr'],
        }),
      );
      final r = await hub.get(
        '/api/v1/maintenance/recyclarr',
        as: TestAs.member,
      );
      expect(r.status, 200, reason: r.body);
      final s = RecyclarrStatus.fromJson(r.map);
      expect(s.schedule, '0 4 * * 0');
      // Sunday 2026-11-08 11:00 SAST → Sunday 2026-11-15 04:00 SAST.
      expect(s.nextRunAt, DateTime.utc(2026, 11, 15, 2));
      expect(s.container.state, ContainerState.running);
      expect(s.lastRun!.startedAt, DateTime.utc(2026, 11, 8, 7, 45, 43));
      expect(s.lastRun!.ok, isTrue);
      expect(s.lastRun!.instances.map((i) => i.name), [
        'hd-bluray-web',
        'web-1080p',
      ]);
      expect(s.canSyncNow, isTrue);
      expect(r.body, isNot(contains('SECRET_KEY')));
    });

    test('recyclarr without logs or Docker still answers', () async {
      final down = containersHub();
      addTearDown(down.close);
      down.fakes.on(
        ServiceId.docker,
        'GET',
        '$_v/containers/json',
        (_) => throw const SocketException('refused'),
      );
      final r = await down.get('/api/v1/maintenance/recyclarr');
      expect(r.status, 200, reason: r.body);
      final s = RecyclarrStatus.fromJson(r.map);
      expect(s.lastRun, isNull);
      expect(s.container.state, ContainerState.unknown);
      expect(s.schedule, '0 4 * * 0');
      expect(s.canSyncNow, isFalse);
    });

    test('POST /maintenance/recyclarr/sync runs the updater command', () async {
      final noConfirm = await hub.post('/api/v1/maintenance/recyclarr/sync');
      expect(noConfirm.status, 428);
      hub.fakes.on(
        ServiceId.updater,
        'POST',
        '/exec/recyclarr-sync',
        (_) => FakeResponse.json({'jobId': 'u_sync'}, status: 202),
      );
      hub.fakes.on(
        ServiceId.updater,
        'GET',
        '/jobs/u_sync',
        (_) => FakeResponse.json({
          'id': 'u_sync',
          'state': 'succeeded',
          'steps': [
            {'cmd': 'docker exec recyclarr recyclarr sync', 'exitCode': 0},
          ],
          'log': ['[INF] Completed'],
        }),
      );
      final r = await hub.post(
        '/api/v1/maintenance/recyclarr/sync',
        body: {'confirm': true},
      );
      expect(r.status, 202, reason: r.body);
      final done = await hub.waitJob(Job.fromJson(readMap(r.map['job'])!).id);
      expect(
        done.status,
        JobStatus.succeeded,
        reason: '${done.error?.message}',
      );
      expect(done.kind, 'maintenance.recyclarr.sync');
      expect(done.steps.map((s) => s.label), [
        'Run recyclarr sync',
        'docker exec recyclarr recyclarr sync',
      ]);
      expect(
        hub.fakes
            .callsTo(ServiceId.updater)
            .where((c) => c.path == '/exec/recyclarr-sync'),
        hasLength(1),
      );
      final member = await hub.post(
        '/api/v1/maintenance/recyclarr/sync?confirm=true',
        as: TestAs.member,
      );
      expect(member.status, 403);
    });
  });

  group('dashboard card', () {
    test('counts, alerts and the raw keys running/total', () async {
      final hub = containersHub();
      addTearDown(hub.close);
      hub.fakeDocker();
      hub.fakes.on(
        ServiceId.watchtower,
        'GET',
        '/v1/metrics',
        (_) =>
            FakeResponse.text(fixtureText('system/watchtower_v1_metrics.txt')),
      );
      final f = readMap(
        fixture('system/docker_container_logs_decluttarr.json'),
      )!;
      hub.fakes.on(
        ServiceId.docker,
        'GET',
        '$_v/containers/decluttarr/logs',
        (_) => FakeResponse.bytes(base64.decode(readString(f['body_base64'])!)),
      );
      hub.fakes.on(
        ServiceId.watchtower,
        'GET',
        '/v1/containers/details',
        (_) => FakeResponse.json({'containers': <Object?>[]}),
      );
      hub.fakes.on(
        ServiceId.watchtower,
        'POST',
        '/v1/check',
        (_) =>
            FakeResponse.json(dataJson('watchtower_v1_check.synthetic.json')),
      );
      final check = await hub.post(
        '/api/v1/updates/check',
        body: <String, Object?>{},
      );
      await hub.waitJob(Job.fromJson(readMap(check.map['job'])!).id);

      final r = await hub.get(
        '/api/v1/dashboard?cards=containers',
        as: TestAs.member,
      );
      expect(r.status, 200, reason: r.body);
      final section = Section.fromJson(
        readMap(readMap(r.map['cards'])!['containers'])!,
      );
      expect(
        section.status,
        SectionState.ok,
        reason: '${section.error?.message}',
      );
      final raw = section.data!;
      expect(raw['running'], 9);
      expect(raw['total'], 10);
      final card = section.decode(ContainersCard.fromJson)!;
      expect(card.unhealthy, ['uptime-kuma']);
      expect(card.stopped, ['portainer']);
      expect(card.updatesAvailable, 1);
      expect(card.lastScan!.scansTotal, 0);
      expect(
        card.decluttarr!.lastRunAt,
        DateTime.parse('2026-11-08T08:57:27.361334Z'),
      );
      expect(card.decluttarr!.removed24h, 0);
      expect(card.topCpu, isEmpty);
      final alerts = readList(r.map['alerts'], Alert.fromJson);
      final byId = {for (final a in alerts) a.id: a};
      expect(
        byId['container.unhealthy.uptime-kuma']!.severity,
        AlertSeverity.error,
      );
      expect(
        byId['container.unhealthy.uptime-kuma']!.route,
        '/containers/uptime-kuma',
      );
      expect(
        byId['container.stopped.portainer']!.severity,
        AlertSeverity.warning,
      );
      expect(byId['updates.available']!.title, '1 container update available');
      expect(byId['updates.available']!.route, '/containers/updates');
    });

    test('Docker down → error section', () async {
      final hub = containersHub();
      addTearDown(hub.close);
      hub.fakes.on(
        ServiceId.docker,
        'GET',
        '$_v/containers/json',
        (_) => throw const SocketException('refused'),
      );
      final r = await hub.get('/api/v1/dashboard?cards=containers');
      final section = Section.fromJson(
        readMap(readMap(r.map['cards'])!['containers'])!,
      );
      expect(section.status, SectionState.error);
      expect(section.error!.code, 'upstream_unavailable');
    });
  });
}

/// Reads `$DATA/updates.json` as written by the store.
abstract final class UpdateStoreProbe {
  static JsonMap read(String dataDir) =>
      jsonDecode(File(p.join(dataDir, 'updates.json')).readAsStringSync())
          as JsonMap;
}
