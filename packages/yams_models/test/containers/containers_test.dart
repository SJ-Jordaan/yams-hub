import 'package:test/test.dart';
import 'package:yams_models/yams_models.dart';

import '../core/round_trip.dart';

final _summaryJson = <String, Object?>{
  'name': 'sonarr',
  'service': 'sonarr',
  'group': 'automation',
  'image': 'lscr.io/linuxserver/sonarr:latest',
  'imageVersion': '4.0.20.3014-ls2',
  'state': 'running',
  'statusText': 'Up 25 minutes',
  'health': 'none',
  'startedAt': '2026-11-08T06:21:17.288940Z',
  'uptimeSeconds': 9522,
  'cpuPercent': 3.04,
  'memBytes': 231051264,
  'memPercent': 2.87,
  'netRxBps': 1200,
  'netTxBps': 800,
  'autoUpdate': false,
  'pinned': false,
  'update': {'available': true, 'checkedAt': '2026-11-08T07:00:00Z'},
  'protection': 'none',
  'ports': [
    {'public': 8989, 'private': 8989, 'protocol': 'tcp'},
  ],
  'links': [
    {'app': 'sonarr', 'path': '/'},
  ],
};

final _qbitJson = <String, Object?>{
  'name': 'qbittorrent',
  'service': 'qbittorrent',
  'group': 'downloads',
  'image': 'lscr.io/linuxserver/qbittorrent:5.3.0',
  'state': 'exited',
  'statusText': 'Exited (137) 2 hours ago',
  'health': 'none',
  'sharesNetworkWith': 'gluetun',
  'autoUpdate': false,
  'pinned': true,
  'protection': 'confirm',
  'ports': <Object?>[],
  'links': <Object?>[],
};

void main() {
  group('enums', () {
    test('parse unknown values to unknown and round trip by name', () {
      final parsers = <String, (Enum Function(Object?), List<Enum>)>{
        'ContainerState': (ContainerState.fromJson, ContainerState.values),
        'ContainerHealth': (ContainerHealth.fromJson, ContainerHealth.values),
        'ContainerProtection': (
          ContainerProtection.fromJson,
          ContainerProtection.values,
        ),
        'ContainerEventAction': (
          ContainerEventAction.fromJson,
          ContainerEventAction.values,
        ),
        'ContainerLogStream': (
          ContainerLogStream.fromJson,
          ContainerLogStream.values,
        ),
        'ContainerAction': (ContainerAction.fromJson, ContainerAction.values),
        'DecluttarrRemovalKind': (
          DecluttarrRemovalKind.fromJson,
          DecluttarrRemovalKind.values,
        ),
        'RecyclarrInstanceType': (
          RecyclarrInstanceType.fromJson,
          RecyclarrInstanceType.values,
        ),
      };
      parsers.forEach((name, p) {
        final (parse, values) = p;
        for (final bad in <Object?>['__nope__', '', null, 3, true]) {
          expect(parse(bad).name, 'unknown', reason: '$name($bad)');
        }
        for (final v in values) {
          expect(parse(v.name), v, reason: '$name.${v.name}');
        }
      });
    });
  });

  group('ContainerSummary', () {
    test('round trips a full sample', () {
      final s = expectRoundTrip(
        _summaryJson,
        ContainerSummary.fromJson,
        (s) => s.toJson(),
      );
      expect(s.isRunning, isTrue);
      expect(s.updateAvailable, isTrue);
      expect(s.ports.single.public, 8989);
      expect(s.links.single.app, ExternalApp.sonarr);
    });

    test('round trips a minimal stopped sample without stats', () {
      final s = expectRoundTrip(
        _qbitJson,
        ContainerSummary.fromJson,
        (s) => s.toJson(),
      );
      expect(s.cpuPercent, isNull);
      expect(s.netRxBps, isNull);
      expect(s.sharesNetworkWith, 'gluetun');
      expect(s.protection, ContainerProtection.confirm);
      expect(s.updateAvailable, isFalse);
    });

    test('a missing name is a FormatException', () {
      expect(
        () => ContainerSummary.fromJson({'state': 'running'}),
        throwsFormatException,
      );
    });

    test('unknown enum values do not throw', () {
      final s = ContainerSummary.fromJson({
        'name': 'x',
        'state': 'zombie',
        'health': 'meh',
        'protection': 'super',
      });
      expect(s.state, ContainerState.unknown);
      expect(s.health, ContainerHealth.unknown);
      expect(s.protection, ContainerProtection.unknown);
      expect(s.service, 'x');
      expect(s.group, 'other');
    });
  });

  test('ContainerDetail round trips flat (summary fields at the top level)', () {
    final json = <String, Object?>{
      ..._summaryJson,
      'restartCount': 2,
      'finishedAt': '2026-11-08T06:02:02.343647Z',
      'exitCode': 0,
      'oomKilled': false,
      'restartPolicy': 'unless-stopped',
      'imageId': 'sha256:ae55f56fa15c',
      'createdAt': '2026-10-31T19:20:52.274709Z',
      'healthLog': [
        {
          'start': '2026-11-08T07:00:00Z',
          'end': '2026-11-08T07:00:01Z',
          'exitCode': 0,
          'output': 'ok',
        },
        {
          'start': '2026-11-08T07:00:30Z',
          'end': '2026-11-08T07:00:31Z',
          'exitCode': 1,
        },
      ],
      'events': [
        {
          'at': '2026-11-08T06:21:17Z',
          'name': 'sonarr',
          'action': 'start',
        },
        {
          'at': '2026-11-08T06:02:02Z',
          'name': 'sonarr',
          'action': 'die',
          'exitCode': 0,
        },
        {
          'at': '2026-11-08T06:30:00Z',
          'name': 'sonarr',
          'action': 'health',
          'health': 'healthy',
        },
      ],
      'dependents': ['recyclarr', 'decluttarr', 'bazarr'],
      'dependsOn': <Object?>[],
      'mounts': [
        {'destination': '/config', 'readOnly': false},
        {'destination': '/etc/localtime', 'readOnly': true},
      ],
      'networkMode': 'yams_network',
      'pids': 29,
    };
    final d = expectRoundTrip(
      json,
      ContainerDetail.fromJson,
      (d) => d.toJson(),
    );
    expect(d.name, 'sonarr');
    expect(d.summary.cpuPercent, 3.04);
    expect(d.healthLog.last.output, isNull);
    expect(d.events[1].exitCode, 0);
    expect(d.events[2].action, ContainerEventAction.health);
    expect(d.mounts.last.readOnly, isTrue);
  });

  test('ContainerList round trips', () {
    final l = expectRoundTrip(
      {
        'items': [_summaryJson, _qbitJson],
        'engine': {
          'version': '29.4.3',
          'running': 20,
          'stopped': 1,
          'total': 21,
          'images': 114,
        },
        'statsAt': '2026-11-08T09:00:00Z',
      },
      ContainerList.fromJson,
      (l) => l.toJson(),
    );
    expect(l.items, hasLength(2));
    expect(l.engine.images, 114);
  });

  test('LogResponse round trips', () {
    final r = expectRoundTrip(
      {
        'lines': [
          {
            'at': '2026-11-08T08:27:25.804755Z',
            'stream': 'stderr',
            'text': 'INFO    | --------',
          },
          {'stream': 'stdout', 'text': 'raw tty output'},
        ],
        'truncated': true,
      },
      LogResponse.fromJson,
      (r) => r.toJson(),
    );
    expect(r.lines.first.stream, ContainerLogStream.stderr);
    expect(r.lines.last.at, isNull);
  });

  test('ContainerActionRequest round trips', () {
    expectRoundTrip(
      {'action': 'stop', 'confirm': true},
      ContainerActionRequest.fromJson,
      (r) => r.toJson(),
    );
    final r = ContainerActionRequest.fromJson({'action': 'kill'});
    expect(r.action, ContainerAction.unknown);
    expect(r.confirm, isNull);
  });

  group('updates', () {
    test('UpdatesResponse round trips with the last scan', () {
      final u = expectRoundTrip(
        {
          'checkedAt': '2026-11-08T07:00:00Z',
          'checking': false,
          'available': true,
          'items': [
            {
              'name': 'sonarr',
              'image': 'lscr.io/linuxserver/sonarr:latest',
              'updateAvailable': true,
              'pinned': false,
              'currentVersion': '4.0.20.3014-ls2',
              'currentDigest': 'sha256:old',
              'latestDigest': 'sha256:new',
              'autoUpdate': false,
              'canUpdate': true,
            },
            {
              'name': 'qbittorrent',
              'image': 'lscr.io/linuxserver/qbittorrent:5.3.0',
              'pinned': true,
              'error': 'registry timeout',
              'autoUpdate': false,
              'canUpdate': false,
            },
          ],
          'updaterAvailable': true,
          'lastScan': {
            'scanned': 21,
            'updated': 1,
            'failed': 0,
            'skipped': 0,
            'restarted': 0,
            'scansTotal': 3,
            'at': '2026-11-08T07:54:04Z',
          },
        },
        UpdatesResponse.fromJson,
        (u) => u.toJson(),
      );
      expect(u.updatesAvailable, 1);
      expect(u.items.last.updateAvailable, isNull);
      expect(u.lastScan!.scanned, 21);
    });

    test('lastScan stays present when the check endpoint is unavailable', () {
      final u = expectRoundTrip(
        {
          'checking': false,
          'available': false,
          'items': <Object?>[],
          'updaterAvailable': false,
          'lastScan': {
            'scanned': 0,
            'updated': 0,
            'failed': 0,
            'skipped': 0,
            'restarted': 0,
            'scansTotal': 0,
          },
        },
        UpdatesResponse.fromJson,
        (u) => u.toJson(),
      );
      expect(u.available, isFalse);
      expect(u.lastScan!.at, isNull);
    });

    test('UpdateCheckRequest distinguishes "all" from a list', () {
      expect(UpdateCheckRequest.fromJson({}).containers, isNull);
      expectRoundTrip(
        {
          'containers': ['sonarr', 'radarr'],
        },
        UpdateCheckRequest.fromJson,
        (r) => r.toJson(),
      );
    });
  });

  group('maintenance', () {
    test('DecluttarrStatus round trips', () {
      final s = expectRoundTrip(
        {
          'container': {'state': 'running', 'health': 'healthy'},
          'lastRunAt': '2026-11-08T08:57:27.361334Z',
          'intervalMinutes': 10,
          'nextRunAt': '2026-11-08T09:07:27.361334Z',
          'testMode': false,
          'last24h': {
            'runs': 5,
            'removed': [
              {
                'at': '2026-11-08T08:47:27Z',
                'job': 'remove_stalled',
                'title': 'Some.Show.S01E01',
                'kind': 'queueRemoval',
              },
            ],
            'strikes': [
              {
                'at': '2026-11-08T08:37:27Z',
                'job': 'remove_stalled',
                'title': 'Some.Show.S01E01',
                'count': 3,
                'max': 3,
              },
            ],
            'searches': 1,
            'obsoleteTagged': 0,
          },
          'warnings': [
            {
              'at': '2026-11-08T08:17:23Z',
              'text': '>>> qBittorrent is disconnected.',
            },
          ],
          'errors': <Object?>[],
        },
        DecluttarrStatus.fromJson,
        (s) => s.toJson(),
      );
      expect(s.last24h.removed.single.kind, DecluttarrRemovalKind.queueRemoval);
      expect(s.container.health, ContainerHealth.healthy);
    });

    test('RecyclarrStatus round trips with and without a last run', () {
      final s = expectRoundTrip(
        {
          'container': {'state': 'running', 'health': 'none'},
          'schedule': '0 4 * * 0',
          'nextRunAt': '2026-11-15T02:00:00Z',
          'lastRun': {
            'startedAt': '2026-11-08T07:45:43Z',
            'ok': true,
            'instances': [
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
                'qualitySizesSynced': false,
              },
            ],
            'warnings': ['7 custom format(s) already existed'],
            'errors': <Object?>[],
          },
          'canSyncNow': true,
        },
        RecyclarrStatus.fromJson,
        (s) => s.toJson(),
      );
      expect(s.lastRun!.instances.first.completed, isTrue);
      expect(s.lastRun!.instances.last.profilesSynced, isNull);
      final empty = expectRoundTrip(
        {
          'container': {'state': 'exited', 'health': 'none'},
          'schedule': '0 4 * * 0',
          'canSyncNow': false,
        },
        RecyclarrStatus.fromJson,
        (s) => s.toJson(),
      );
      expect(empty.lastRun, isNull);
    });
  });

  test('ContainersCard keeps the raw keys running/total as ints', () {
    final c = expectRoundTrip(
      {
        'total': 21,
        'running': 20,
        'unhealthy': ['jellystat'],
        'stopped': ['portainer'],
        'updatesAvailable': 2,
        'lastScan': {
          'scanned': 21,
          'updated': 0,
          'failed': 0,
          'skipped': 0,
          'restarted': 0,
          'scansTotal': 1,
        },
        'topCpu': [
          {'name': 'jellyfin', 'cpuPercent': 41.5},
          {'name': 'sonarr', 'cpuPercent': 3.04},
        ],
        'decluttarr': {'lastRunAt': '2026-11-08T08:57:27Z', 'removed24h': 0},
      },
      ContainersCard.fromJson,
      (c) => c.toJson(),
    );
    final raw = c.toJson();
    expect(raw['running'], isA<int>());
    expect(raw['total'], isA<int>());
    expect(c.topCpu.first.name, 'jellyfin');
    final minimal = ContainersCard.fromJson({'total': 3, 'running': 3});
    expect(minimal.toJson(), {
      'total': 3,
      'running': 3,
      'unhealthy': <Object?>[],
      'stopped': <Object?>[],
      'updatesAvailable': 0,
      'topCpu': <Object?>[],
    });
  });
}
