import 'dart:convert';

import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/features/containers/container_events.dart';
import 'package:yams_hub_gateway/src/features/containers/container_mapper.dart';
import 'package:yams_hub_gateway/src/features/containers/container_stats.dart';
import 'package:yams_hub_gateway/src/features/containers/decluttarr_parser.dart';
import 'package:yams_hub_gateway/src/features/containers/docker_entry.dart';
import 'package:yams_hub_gateway/src/features/containers/docker_logs.dart';
import 'package:yams_hub_gateway/src/features/containers/recyclarr_parser.dart';
import 'package:yams_hub_gateway/src/features/containers/watchtower.dart';

import 'containers_support.dart';

DockerContainerEntry _entry(String name) => DockerContainerEntry.fromJson(
  dockerList().firstWhere((e) => readStringList(e['Names']).first == '/$name'),
)!;

void main() {
  group('DockerContainerEntry (fixture docker_containers_json.json)', () {
    test('maps names, labels, health and status text', () {
      final homepage = _entry('homepage');
      expect(homepage.service, 'homepage');
      expect(homepage.health, ContainerHealth.healthy);
      expect(homepage.statusText, 'Up 25 minutes');
      expect(homepage.autoUpdate, isTrue);
      expect(homepage.pinned, isFalse);
      expect(homepage.uptimeFromStatus, const Duration(minutes: 25));

      final sonarr = _entry('sonarr');
      expect(sonarr.health, ContainerHealth.none);
      expect(sonarr.autoUpdate, isFalse);
      expect(sonarr.imageTag, 'latest');
      expect(sonarr.pinned, isFalse);

      final qbit = _entry('qbittorrent');
      expect(qbit.pinned, isTrue);
      expect(qbit.imageTag, '5.3.0');
      expect(qbit.imageVersion, '5.3.0_v2.1.2-ls486');
      expect(
        qbit.networkContainerId,
        '1b55eec72010d6b642b5dd6fb9dd7d7c66da3eb56941c8a82e0d92b22d5c4208',
      );
      expect(qbit.firstComposeDependency, 'gluetun');
    });

    test('de-duplicates IPv4/IPv6 ports and drops unpublished ones', () {
      final gluetun = _entry('gluetun');
      expect(gluetun.ports, hasLength(1));
      expect(gluetun.ports.single.public, 8081);
    });

    test('parses exit codes and Docker human durations', () {
      final portainer = _entry('portainer');
      expect(portainer.state, ContainerState.exited);
      expect(portainer.exitCodeFromStatus, 137);
      expect(portainer.exitedAgo, const Duration(hours: 3));
      expect(
        parseDockerHumanDuration('About an hour'),
        const Duration(hours: 1),
      );
      expect(parseDockerHumanDuration('Less than a second'), Duration.zero);
      expect(parseDockerHumanDuration('2 weeks'), const Duration(days: 14));
      expect(parseDockerHumanDuration('soon'), isNull);
    });

    test('an image without a tag or with a registry port is latest', () {
      DockerContainerEntry withImage(String image) =>
          DockerContainerEntry.fromJson({
            'Names': ['/x'],
            'Image': image,
          })!;
      expect(withImage('nickfedor/watchtower').pinned, isFalse);
      expect(withImage('registry:5000/app').pinned, isFalse);
      expect(withImage('registry:5000/app:1.2').pinned, isTrue);
      expect(withImage('ghcr.io/x/y@sha256:abc').pinned, isFalse);
    });

    test('falls back to the (healthy) suffix without a Health object', () {
      final e = DockerContainerEntry.fromJson({
        'Names': ['/old'],
        'Status': 'Up 2 seconds (health: starting)',
        'State': 'running',
      })!;
      expect(e.health, ContainerHealth.starting);
      expect(e.statusText, 'Up 2 seconds');
    });
  });

  group('mapping', () {
    test('qbittorrent shares gluetun\'s network and hides its counters', () {
      final list = [
        for (final e in dockerList()) DockerContainerEntry.fromJson(e)!,
      ];
      final stats = ContainerStatsStore();
      final qbit = list.firstWhere((e) => e.name == 'qbittorrent');
      final read = DateTime.utc(2026, 11, 8, 9);
      stats
        ..add(
          qbit.id,
          ContainerStatsSample(
            read: read,
            cpuTotal: 0,
            systemCpu: 1000,
            onlineCpus: 4,
            memUsed: 10,
            memLimit: 100,
            netRx: 0,
            netTx: 0,
          ),
        )
        ..add(
          qbit.id,
          ContainerStatsSample(
            read: read.add(const Duration(seconds: 10)),
            cpuTotal: 10,
            systemCpu: 2000,
            onlineCpus: 4,
            memUsed: 20,
            memLimit: 100,
            netRx: 1000,
            netTx: 500,
          ),
        );
      final c = ContainerMappingContext(
        policy: const ContainerPolicy(),
        now: DateTime.utc(2026, 11, 8, 9),
        byId: {for (final e in list) e.id: e},
        stats: stats,
      );
      final s = mapContainerSummary(qbit, c);
      expect(s.sharesNetworkWith, 'gluetun');
      expect(s.cpuPercent, 4.0);
      expect(s.memBytes, 20);
      expect(s.netRxBps, isNull);
      expect(s.netTxBps, isNull);
      expect(s.protection, ContainerProtection.confirm);
      expect(s.group, 'downloads');
      expect(s.links.single.app, ExternalApp.qbittorrent);
    });

    test('service names map to external apps', () {
      expect(externalAppForService('uptime-kuma'), ExternalApp.uptimeKuma);
      expect(externalAppForService('jellyfin'), ExternalApp.jellyfin);
      expect(externalAppForService('jellystat-db'), isNull);
      expect(externalAppForService('gluetun'), isNull);
    });

    test('dependency hints come from the static map', () {
      expect(containerDependents['gluetun'], ['qbittorrent']);
      expect(containerDependsOn('bazarr'), ['sonarr', 'radarr']);
      expect(containerDependsOn('homepage'), ['socket-proxy']);
    });
  });

  group('stats formulas (fixture docker_container_stats.json)', () {
    test('cpu 3.04 % and memory 231,051,264 B for sonarr', () {
      final body = readMap(fixture('system/docker_container_stats.json'))!;
      final prev = ContainerStatsSample.previousFromJson(body)!;
      final now = ContainerStatsSample.fromJson(body)!;
      final f = now.since(prev);
      expect(f.cpuPercent, 3.04);
      expect(f.memBytes, 231051264);
      expect(f.memPercent, 2.87);
      expect(f.pids, now.pids);
    });

    test('one-shot samples have no precpu: the store waits for two', () {
      final body = readMap(
        fixture('system/docker_container_stats_oneshot.json'),
      )!;
      expect(ContainerStatsSample.previousFromJson(body), isNull);
      final s = ContainerStatsSample.fromJson(body)!;
      final store = ContainerStatsStore()..add('a', s);
      expect(store.of('a'), isNull);
      expect(store.sampledAt, isNull);
    });

    test('a stopped container (zeros) yields no sample', () {
      expect(
        ContainerStatsSample.fromJson({
          'cpu_stats': {
            'cpu_usage': {'total_usage': 0},
            'system_cpu_usage': 0,
          },
        }),
        isNull,
      );
    });
  });

  group('log decoding (fixtures docker_container_logs_*.json)', () {
    for (final name in ['decluttarr', 'recyclarr']) {
      test('$name frames match the expected decoding', () {
        final f = readMap(fixture('system/docker_container_logs_$name.json'))!;
        final body = base64.decode(readString(f['body_base64'])!);
        final lines = decodeDockerLogs(body, tty: false);
        final expected = readList(f['expected_frames'], (m) => m);
        expect(lines, hasLength(expected.length));
        for (var i = 0; i < expected.length; i++) {
          final raw = readString(expected[i]['line'])!;
          final (at, text) = splitDockerTimestamp(raw);
          expect(lines[i].stream.name, expected[i]['stream'], reason: '$i');
          expect(lines[i].text, text, reason: '$i');
          expect(lines[i].at, at, reason: '$i');
        }
        expect(lines.first.at, isNotNull);
      });
    }

    test('lines split across frames are joined per stream', () {
      final body = multiplexed([
        (1, '2026-11-08T08:00:00.000000001Z hel'),
        (2, '2026-11-08T08:00:01Z err line\n'),
        (1, 'lo\n2026-11-08T08:00:02Z second'),
      ]);
      final lines = decodeDockerLogs(body, tty: false);
      expect(
        [for (final l in lines) (l.stream, l.text)],
        [
          (ContainerLogStream.stderr, 'err line'),
          (ContainerLogStream.stdout, 'hello'),
          (ContainerLogStream.stdout, 'second'),
        ],
      );
      expect(lines[1].at, DateTime.utc(2026, 11, 8, 8));
    });

    test('tty bodies are raw text', () {
      final lines = decodeDockerLogs(
        utf8.encode('2026-11-08T08:00:00Z plain\r\nno stamp\n'),
        tty: true,
      );
      expect(lines.map((l) => l.text), ['plain', 'no stamp']);
      expect(lines.last.at, isNull);
      expect(lines.every((l) => l.stream == ContainerLogStream.stdout), isTrue);
    });
  });

  group('events', () {
    test('parses health_status, die and ignores exec noise (fixture)', () {
      final f = readMap(fixture('system/docker_events.json'))!;
      for (final e in readList(f['events'], (m) => m)) {
        expect(parseDockerEvent(e), isNull, reason: '${e['Action']}');
      }
      final health = parseDockerEvent({
        'Type': 'container',
        'Action': 'health_status: unhealthy',
        'Actor': {
          'ID': 'abc',
          'Attributes': {'name': 'jellystat'},
        },
        'time': 1794128000,
        'timeNano': 1794128000123456789,
      })!;
      expect(health.event.action, ContainerEventAction.health);
      expect(health.event.health, 'unhealthy');
      expect(health.containerId, 'abc');
      final die = parseDockerEvent({
        'Type': 'container',
        'Action': 'die',
        'Actor': {
          'ID': 'abc',
          'Attributes': {'name': 'sonarr', 'exitCode': '137'},
        },
        'time': 1794128001,
      })!;
      expect(die.event.exitCode, 137);
      expect(die.event.at, DateTime.utc(2026, 11, 8, 8, 53, 21));
    });

    test('the ring buffer drops replays and keeps the newest 1000', () {
      final b = ContainerEventBuffer(capacity: 3);
      DockerEventRecord r(int n, String name) => DockerEventRecord(
        ContainerEvent(
          at: DateTime.fromMicrosecondsSinceEpoch(n * 1000000, isUtc: true),
          name: name,
          action: ContainerEventAction.start,
        ),
        n * 1000000000,
        name,
      );
      expect(b.add(r(1, 'a')), isTrue);
      expect(b.add(r(1, 'a')), isFalse);
      b
        ..add(r(2, 'b'))
        ..add(r(3, 'a'))
        ..add(r(4, 'a'));
      expect(b.length, 3);
      expect(b.latest().map((e) => e.name), ['a', 'a', 'b']);
      expect(b.latest(name: 'a', limit: 1).single.at.second, 4);
    });
  });

  test('Watchtower metrics (fixture watchtower_v1_metrics.txt)', () {
    final scan = parseWatchtowerMetrics(
      fixtureText('system/watchtower_v1_metrics.txt'),
    );
    expect(scan.toJson(), {
      'scanned': 0,
      'updated': 0,
      'failed': 0,
      'skipped': 0,
      'restarted': 0,
      'scansTotal': 0,
    });
    final busy = parseWatchtowerMetrics(
      'watchtower_containers_scanned 21\nwatchtower_containers_updated 2\n'
      'watchtower_scans_total 1.2e+01\n# HELP x\nwatchtower_containers_failed{a="b"} 1\n',
      at: DateTime.utc(2026, 11, 8),
    );
    expect(busy.scanned, 21);
    expect(busy.updated, 2);
    expect(busy.scansTotal, 12);
    expect(busy.failed, 1);
    expect(busy.at, DateTime.utc(2026, 11, 8));
  });

  group('decluttarr', () {
    const container = MaintenanceContainerState(
      state: ContainerState.running,
      health: ContainerHealth.healthy,
    );

    test('the captured log has five runs and clean queues', () {
      final f = readMap(
        fixture('system/docker_container_logs_decluttarr.json'),
      )!;
      final lines = decodeDockerLogs(
        base64.decode(readString(f['body_base64'])!),
        tty: false,
      );
      final s = parseDecluttarrLog(
        lines,
        container: container,
        redact: redactSecrets,
      );
      expect(s.last24h.runs, 5);
      expect(s.lastRunAt, DateTime.parse('2026-11-08T08:57:27.361334Z'));
      expect(s.intervalMinutes, 10);
      expect(s.nextRunAt, DateTime.parse('2026-11-08T09:07:27.361334Z'));
      expect(s.testMode, isFalse);
      expect(s.last24h.removed, isEmpty);
      expect(s.last24h.strikes, isEmpty);
      expect(s.warnings, isEmpty);
      expect(s.errors, isEmpty);
    });

    test('removals, strikes (tuple job names), searches, warnings, errors', () {
      final lines = [
        for (final l in const LineSplitter().convert(
          dataText('decluttarr_activity.synthetic.txt'),
        ))
          () {
            final (at, text) = splitDockerTimestamp(l);
            return DockerLogLine(
              stream: ContainerLogStream.stderr,
              text: text,
              at: at,
            );
          }(),
      ];
      final s = parseDecluttarrLog(
        lines,
        container: container,
        redact: redactSecrets,
      );
      expect(s.last24h.runs, 3);
      expect(s.last24h.strikes.map((x) => (x.job, x.count, x.max)), [
        ('remove_stalled', 3, 3),
        ('remove_stalled', 1, 3),
      ]);
      expect(s.last24h.removed.map((x) => (x.job, x.kind, x.title)), [
        (
          'remove_failed_imports',
          DecluttarrRemovalKind.removal,
          'Other.Movie.2024.2160p',
        ),
        (
          'remove_stalled',
          DecluttarrRemovalKind.queueRemoval,
          'Some.Show.S01E01.1080p.WEB',
        ),
      ]);
      expect(s.last24h.searches, 2);
      expect(s.last24h.obsoleteTagged, 1);
      expect(s.warnings.single.text, contains('qBittorrent is disconnected'));
      expect(s.errors.single.text, contains('apikey=***'));
      expect(s.errors.single.text, isNot(contains('LEAKEDKEY99')));
      expect(cleanDecluttarrJobName("('remove_stalled',)"), 'remove_stalled');
    });

    test('the test-mode banner after the last start sets testMode', () {
      DockerLogLine l(String text) => DockerLogLine(
        stream: ContainerLogStream.stderr,
        text: text,
        at: DateTime.utc(2026, 11, 8, 8),
      );
      final on = parseDecluttarrLog(
        [
          l('INFO    | Application Started!'),
          l('WARNING | !!! TEST MODE IS ACTIVE !!!'),
        ],
        container: container,
        redact: redactSecrets,
      );
      expect(on.testMode, isTrue);
      final off = parseDecluttarrLog(
        [
          l('WARNING | TEST MODE IS ACTIVE'),
          l('INFO    | Application Started!'),
        ],
        container: container,
        redact: redactSecrets,
      );
      expect(off.testMode, isFalse);
    });
  });

  group('recyclarr', () {
    test(
      'the captured run (fixture recyclarr_cli_debug_log_infolines.txt)',
      () {
        final run = parseRecyclarrLog(
          const LineSplitter().convert(
            fixtureText('system/recyclarr_cli_debug_log_infolines.txt'),
          ),
          startedAt: recyclarrRunStart(
            'recyclarr_2026-11-08_07-45-43.debug.log',
          )!,
          redact: redactSecrets,
        );
        expect(run.startedAt, DateTime.utc(2026, 11, 8, 7, 45, 43));
        expect(run.ok, isTrue);
        expect(run.instances.map((i) => i.toJson()), [
          {
            'name': 'hd-bluray-web',
            'type': 'radarr',
            'customFormatsCreated': 41,
            'customFormatsUpdated': 0,
            'customFormatsSkipped': 0,
            'profilesSynced': 1,
            'qualitySizesSynced': true,
            'completedAt': '2026-11-08T07:46:06Z',
          },
          {
            'name': 'web-1080p',
            'type': 'sonarr',
            'customFormatsCreated': 30,
            'customFormatsUpdated': 2,
            'customFormatsSkipped': 5,
            'profilesSynced': 1,
            'qualitySizesSynced': true,
            'completedAt': '2026-11-08T07:46:15Z',
          },
        ]);
        expect(
          run.warnings.single,
          startsWith('web-1080p: 7 custom format(s)'),
        );
        expect(run.errors, isEmpty);
      },
    );

    test('an ERR line or a missing "Completed at" fails the run', () {
      final failed = parseRecyclarrLog(
        [
          '[07:45:48 INF] web-1080p: Processing Sonarr server web-1080p',
          '[07:45:49 ERR] web-1080p: HTTP 401 for http://sonarr:8989/api/v3?apikey=abc',
        ],
        startedAt: DateTime.utc(2026, 11, 8),
        redact: redactSecrets,
      );
      expect(failed.ok, isFalse);
      expect(failed.instances.single.completed, isFalse);
      expect(failed.errors.single, contains('apikey=***'));
      expect(
        parseRecyclarrLog(
          const [],
          startedAt: DateTime.utc(2026),
          redact: redactSecrets,
        ).ok,
        isFalse,
      );
    });

    test('cron: next Sunday 04:00 SAST', () {
      final cron = CronSchedule.tryParse('0 4 * * 0')!;
      const sast = Duration(hours: 2);
      // Sunday 2026-11-08 11:00 SAST → next Sunday.
      expect(
        cron.nextAfter(DateTime.utc(2026, 11, 8, 9), sast),
        DateTime.utc(2026, 11, 15, 2),
      );
      // Saturday 23:00 SAST → the next morning.
      expect(
        cron.nextAfter(DateTime.utc(2026, 11, 14, 21), sast),
        DateTime.utc(2026, 11, 15, 2),
      );
      expect(
        CronSchedule.tryParse('*/15 * * * *')!
            .nextAfter(DateTime.utc(2026, 11, 8, 9, 7), Duration.zero),
        DateTime.utc(2026, 11, 8, 9, 15),
      );
      expect(CronSchedule.tryParse('0 4 * *'), isNull);
      expect(CronSchedule.tryParse('61 4 * * 0'), isNull);
      expect(CronSchedule.tryParse('@weekly'), isNull);
    });
  });

  test('UpdateCheckResult redacts errors and survives the store format', () {
    final body = readMap(dataJson('watchtower_v1_check.synthetic.json'))!;
    final results = [
      for (final c in readList(body['containers'], (m) => m))
        UpdateCheckResult.fromWatchtower(
          c,
          DateTime.utc(2026, 11, 8),
          redactSecrets,
        )!,
    ];
    expect(results.first.updateAvailable, isTrue);
    expect(results.first.latestDigest, 'sha256:new0001');
    final failed = results.last;
    expect(failed.updateAvailable, isNull);
    expect(failed.error, contains('token=***'));
    expect(failed.latestDigest, isNull);
    final back = UpdateCheckResult.fromStore(
      jsonDecode(jsonEncode(failed.toJson())) as JsonMap,
    )!;
    expect(back.toJson(), failed.toJson());
  });
}
