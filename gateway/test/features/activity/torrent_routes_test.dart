import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../../support/test_hub.dart';
import 'activity_support.dart';

const _q = ServiceId.qbittorrent;

void main() {
  late TestHub hub;

  setUp(() => hub = activityHub());
  tearDown(() => hub.close());

  group('GET /torrents', () {
    test('maps the snapshot with transfer, categories and tags', () async {
      final r = await hub.get('/api/v1/torrents');
      expect(r.status, 200, reason: r.body);
      final list = TorrentList.fromJson(r.map);
      expect(list.items, hasLength(5));
      expect(list.stale, isFalse);
      expect(list.categories, ['books', 'lidarr', 'radarr', 'tv-sonarr']);
      expect(list.tags, ['Keep', 'Obsolete']);
      expect(list.transfer.altSpeedEnabled, isTrue);
      expect(list.transfer.limits!.altDlBps, 10240000);
      expect(list.transfer.schedule!.from, '08:00');
      // Default sort: added, newest first.
      final added = [for (final t in list.items) t.addedAt];
      expect(
        added,
        orderedEquals(<DateTime>[...added]..sort((a, b) => b.compareTo(a))),
      );
      // The maindata poller started from rid=0 with the session cookie.
      final sync = hub.fakes
          .callsTo(_q)
          .firstWhere((c) => c.path == '/api/v2/sync/maindata');
      expect(sync.query['rid'], ['0']);
      expect(sync.headers['cookie'], '***');
      // The full preferences object never leaves the gateway.
      expect(r.body, isNot(contains('web_ui_username')));
    });

    test('filters, searches and sorts in the gateway', () async {
      var r = await hub.get('/api/v1/torrents?filter=stopped');
      expect(TorrentList.fromJson(r.map).items.single.hash, plainHash);

      r = await hub.get(
        '/api/v1/torrents?q=apothecary%20diaries%20s03e06%201080p%20nf',
      );
      expect(TorrentList.fromJson(r.map).items.single.hash, sonarrHash);
      r = await hub.get('/api/v1/torrents?q=APOTHECARY');
      expect(TorrentList.fromJson(r.map).items, hasLength(4));

      r = await hub.get('/api/v1/torrents?sort=name&order=asc');
      final names = [
        for (final t in TorrentList.fromJson(r.map).items) t.name.toLowerCase(),
      ];
      expect(names, orderedEquals(<String>[...names]..sort()));

      r = await hub.get('/api/v1/torrents?category=radarr');
      expect(TorrentList.fromJson(r.map).items, isEmpty);
    });

    test('rejects filters qBittorrent would silently ignore', () async {
      for (final q in ['filter=paused', 'filter=resumed', 'sort=nosuch']) {
        final r = await hub.get('/api/v1/torrents?$q');
        expect(r.status, 400, reason: q);
        expect(r.errorCode, 'bad_request');
      }
    });

    test('members can read', () async {
      final r = await hub.get('/api/v1/torrents', as: TestAs.member);
      expect(r.status, 200);
    });

    test('qBittorrent unreachable is 503 and a 500 is 502', () async {
      hub.fakes.on(
        _q,
        'GET',
        '/api/v2/sync/maindata',
        (_) => throw http.ClientException('connection refused'),
      );
      var r = await hub.get('/api/v1/torrents');
      expect(r.status, 503);
      expect(r.errorCode, 'upstream_unavailable');

      final other = activityHub();
      addTearDown(other.close);
      other.fakes.on(
        _q,
        'GET',
        '/api/v2/sync/maindata',
        (_) => FakeResponse.text('boom', status: 500),
      );
      r = await other.get('/api/v1/torrents');
      expect(r.status, 502);
      expect(r.errorCode, 'upstream_error');
    });

    test('rejected credentials surface as upstream_auth_failed', () async {
      hub.fakes.on(
        _q,
        'POST',
        '/api/v2/auth/login',
        (_) => FakeResponse.text('Unauthorized', status: 401),
      );
      final r = await hub.get('/api/v1/torrents');
      expect(r.status, 502);
      expect(r.errorCode, 'upstream_auth_failed');
      expect(hub.ctx.upstreams.qbitSession.credentialsRejected, isTrue);
    });
  });

  group('GET /torrents/{hash}', () {
    setUp(() {
      for (final (path, file) in [
        ('/api/v2/torrents/properties', 'qbittorrent_torrents_properties.json'),
        ('/api/v2/torrents/files', 'qbittorrent_torrents_files.json'),
        ('/api/v2/torrents/trackers', 'qbittorrent_torrents_trackers.json'),
      ]) {
        hub.fakes.onFixture(_q, 'GET', path, 'downloads/$file');
      }
    });

    test('merges properties, files, trackers and the *arr queue', () async {
      final r = await hub.get('/api/v1/torrents/${sonarrHash.toUpperCase()}');
      expect(r.status, 200, reason: r.body);
      final d = TorrentDetail.fromJson(r.map);
      expect(d.summary.hash, sonarrHash);
      expect(d.savePath, '/data/downloads/torrents');
      expect(d.piecesTotal, 33533);
      expect(d.seedsTotal, 315);
      expect(d.avgDlBps, 9119879);
      expect(d.comment, isNull);
      expect(d.shareLimits.mode, ShareLimitsMode.global);
      expect(d.files, hasLength(5));
      expect(d.trackers.map((t) => t.url), [
        'http://nyaa.tracker.wf:7777',
        'udp://open.stealth.si:80',
      ]);
      expect(r.body, isNot(contains('/announce')));
      expect(r.body, isNot(contains('endpoints')));
      expect(d.arr.single.service, ArrService.sonarr);
      expect(d.arr.single.queueIds, [123456, 123457]);
      final props = hub.fakes
          .callsTo(_q)
          .firstWhere((c) => c.path == '/api/v2/torrents/properties');
      expect(props.query['hash'], [sonarrHash]);
    });

    test('404 when qBittorrent no longer has it', () async {
      hub.fakes.on(
        _q,
        'GET',
        '/api/v2/torrents/properties',
        (_) => FakeResponse.text('Not Found', status: 404),
      );
      final r = await hub.get('/api/v1/torrents/$plainHash');
      expect(r.status, 404);
      expect(r.errorCode, 'not_found');
      expect(
        r.map['error'],
        containsPair('message', 'Torrent no longer exists.'),
      );
    });
  });

  group('POST /torrents/actions', () {
    test('stop posts the pipe-joined hashes', () async {
      final r = await hub.post(
        '/api/v1/torrents/actions',
        body: {
          'hashes': [plainHash, sonarrHash.toUpperCase()],
          'action': 'stop',
        },
      );
      expect(r.status, 200, reason: r.body);
      expect(r.map, {'ok': true});
      expect(lastForm(hub.fakes, _q, '/api/v2/torrents/stop'), {
        'hashes': '$plainHash|$sonarrHash',
      });
    });

    test('every action reaches its v5 endpoint', () async {
      const paths = {
        'start': 'start',
        'forceStart': 'setForceStart',
        'recheck': 'recheck',
        'reannounce': 'reannounce',
        'topPriority': 'topPrio',
        'bottomPriority': 'bottomPrio',
        'increasePriority': 'increasePrio',
        'decreasePriority': 'decreasePrio',
      };
      for (final e in paths.entries) {
        final r = await hub.post(
          '/api/v1/torrents/actions',
          body: {
            'hashes': [plainHash],
            'action': e.key,
          },
        );
        expect(r.status, 200, reason: e.key);
        expect(called(hub.fakes, _q, '/api/v2/torrents/${e.value}'), isTrue);
      }
      expect(lastForm(hub.fakes, _q, '/api/v2/torrents/setForceStart'), {
        'hashes': plainHash,
        'value': 'true',
      });
      expect(called(hub.fakes, _q, '/api/v2/torrents/pause'), isFalse);
    });

    test('tags and categories are validated', () async {
      var r = await hub.post(
        '/api/v1/torrents/actions',
        body: {
          'hashes': [plainHash],
          'action': 'addTags',
          'tags': ['Keep'],
        },
      );
      expect(r.status, 200);
      expect(
        lastForm(hub.fakes, _q, '/api/v2/torrents/addTags')['tags'],
        'Keep',
      );

      r = await hub.post(
        '/api/v1/torrents/actions',
        body: {
          'hashes': [plainHash],
          'action': 'setCategory',
          'category': 'nope',
        },
      );
      expect(r.status, 422);
      expect(r.errorCode, 'validation_failed');

      r = await hub.post(
        '/api/v1/torrents/actions',
        body: {
          'hashes': [plainHash],
          'action': 'setCategory',
          'category': '',
        },
      );
      expect(r.status, 200);
      expect(lastForm(hub.fakes, _q, '/api/v2/torrents/setCategory'), {
        'hashes': plainHash,
        'category': '',
      });
    });

    test('bad input', () async {
      for (final body in [
        {'hashes': <String>[], 'action': 'stop'},
        {
          'hashes': ['xyz'],
          'action': 'stop',
        },
      ]) {
        final r = await hub.post('/api/v1/torrents/actions', body: body);
        expect(r.status, 422, reason: '$body');
      }
      final r = await hub.post(
        '/api/v1/torrents/actions',
        body: {
          'hashes': [plainHash],
          'action': 'pause',
        },
      );
      expect(r.status, 400);
    });

    test('delete needs confirm and refuses *arr-managed torrents', () async {
      var r = await hub.post(
        '/api/v1/torrents/actions',
        body: {
          'hashes': [sonarrHash],
          'action': 'delete',
          'deleteFiles': true,
        },
      );
      expect(r.status, 428);
      expect(r.errorCode, 'confirmation_required');
      expect(
        readMap(readMap(r.map['error'])?['details'])?['impact'],
        contains('permanently deletes'),
      );
      expect(called(hub.fakes, _q, '/api/v2/torrents/delete'), isFalse);

      r = await hub.post(
        '/api/v1/torrents/actions',
        body: {
          'hashes': [sonarrHash],
          'action': 'delete',
          'deleteFiles': true,
          'confirm': true,
        },
      );
      expect(r.status, 409);
      expect(r.errorCode, 'managed_by_arr');
      final items = TorrentManagedByArr.listFromDetails(
        readMap(readMap(r.map['error'])?['details']),
      );
      expect(items.single.hash, sonarrHash);
      expect(items.single.service, ArrService.sonarr);
      expect(items.single.queueIds, [123456, 123457]);
      expect(called(hub.fakes, _q, '/api/v2/torrents/delete'), isFalse);

      r = await hub.post(
        '/api/v1/torrents/actions',
        body: {
          'hashes': [sonarrHash],
          'action': 'delete',
          'deleteFiles': true,
          'force': true,
          'confirm': true,
        },
      );
      expect(r.status, 200);
      expect(lastForm(hub.fakes, _q, '/api/v2/torrents/delete'), {
        'hashes': sonarrHash,
        'deleteFiles': 'true',
      });
    });

    test('delete of an untracked torrent keeps files by default', () async {
      final r = await hub.post(
        '/api/v1/torrents/actions?confirm=true',
        body: {
          'hashes': [plainHash],
          'action': 'delete',
        },
      );
      expect(r.status, 200, reason: r.body);
      expect(
        lastForm(hub.fakes, _q, '/api/v2/torrents/delete')['deleteFiles'],
        'false',
      );
    });

    test('members are refused', () async {
      final r = await hub.post(
        '/api/v1/torrents/actions',
        as: TestAs.member,
        body: {
          'hashes': [plainHash],
          'action': 'stop',
        },
      );
      expect(r.status, 403);
      expect(called(hub.fakes, _q, '/api/v2/torrents/stop'), isFalse);
    });

    test('a qBittorrent 409 becomes a conflict with its reason', () async {
      hub.fakes.on(
        _q,
        'POST',
        '/api/v2/torrents/topPrio',
        (_) =>
            FakeResponse.text('Torrent queueing must be enabled', status: 409),
      );
      final r = await hub.post(
        '/api/v1/torrents/actions',
        body: {
          'hashes': [plainHash],
          'action': 'topPriority',
        },
      );
      expect(r.status, 409);
      expect(r.errorCode, 'conflict');
      expect(r.body, contains('queueing'));
    });
  });

  group('POST /torrents/add', () {
    const magnet = 'magnet:?xt=urn:btih:$plainHash&dn=test';

    test('sends a multipart add and creates the manual category', () async {
      final r = await hub.post(
        '/api/v1/torrents/add',
        body: {
          'urls': [magnet, 'https://example.org/file.torrent'],
          'torrentFilesBase64': [base64.encode(utf8.encode('d4:infoe'))],
          'tags': ['Keep'],
          'stopped': true,
        },
      );
      expect(r.status, 201, reason: r.body);
      expect(r.map, {'ok': true});
      expect(lastForm(hub.fakes, _q, '/api/v2/torrents/createCategory'), {
        'category': 'manual',
        'savePath': '',
      });
      final add = hub.fakes
          .callsTo(_q)
          .lastWhere((c) => c.path == '/api/v2/torrents/add');
      expect(add.headers['content-type'], startsWith('multipart/form-data'));
      expect(add.body, contains('name="urls"'));
      expect(add.body, contains('$magnet\nhttps://example.org/file.torrent'));
      expect(
        add.body,
        contains('name="torrents"; filename="upload-1.torrent"'),
      );
      expect(add.body, contains('d4:infoe'));
      expect(add.body, contains('name="category"\r\n\r\nmanual'));
      expect(add.body, contains('name="tags"\r\n\r\nKeep'));
      expect(add.body, contains('name="stopped"\r\n\r\ntrue'));
      // The gateway never fetches http(s) URLs itself.
      expect(hub.fakes.remoteCalls('example.org'), isEmpty);
    });

    test('an existing category is not created again', () async {
      final r = await hub.post(
        '/api/v1/torrents/add',
        body: {
          'urls': [magnet],
          'category': 'books',
        },
      );
      expect(r.status, 201);
      expect(called(hub.fakes, _q, '/api/v2/torrents/createCategory'), isFalse);
    });

    test('validates links, files and categories', () async {
      for (final body in <JsonMap>[
        {},
        {
          'urls': ['ftp://x/y'],
        },
        {
          'urls': ['magnet:?dn=no-hash'],
        },
        {
          'torrentFilesBase64': [base64.encode(utf8.encode('<html>'))],
        },
        {
          'torrentFilesBase64': ['%%%'],
        },
        {
          'urls': [magnet],
          'category': 'does-not-exist',
        },
        {'urls': List.filled(21, magnet)},
      ]) {
        final r = await hub.post('/api/v1/torrents/add', body: body);
        expect(r.status, 422, reason: '$body ${r.body}');
      }
      expect(called(hub.fakes, _q, '/api/v2/torrents/add'), isFalse);
    });

    test('415 from qBittorrent is a 422', () async {
      hub.fakes.on(
        _q,
        'POST',
        '/api/v2/torrents/add',
        (_) => FakeResponse.text('Fails.', status: 415),
      );
      final r = await hub.post(
        '/api/v1/torrents/add',
        body: {
          'urls': [magnet],
        },
      );
      expect(r.status, 422);
      expect(r.body, contains('qBittorrent rejected this torrent'));
    });
  });

  group('PUT /torrents/{hash}/share-limits', () {
    test('global sends -2 for every limit', () async {
      final r = await hub.put(
        '/api/v1/torrents/$plainHash/share-limits',
        body: {'mode': 'global'},
      );
      expect(r.status, 200, reason: r.body);
      final s = ShareLimits.fromJson(r.map);
      expect(s.mode, ShareLimitsMode.global);
      expect(s.effectiveRatio, 1.0);
      expect(lastForm(hub.fakes, _q, '/api/v2/torrents/setShareLimits'), {
        'hashes': plainHash,
        'ratioLimit': '-2',
        'seedingTimeLimit': '-2',
        'inactiveSeedingTimeLimit': '-2',
        'shareLimitAction': 'Default',
        'shareLimitsMode': 'Default',
      });
    });

    test('custom remove actions need confirmation with the impact', () async {
      var r = await hub.put(
        '/api/v1/torrents/$plainHash/share-limits',
        body: {'mode': 'custom', 'ratio': 1.0, 'action': 'removeWithContent'},
      );
      expect(r.status, 428);
      final impact =
          readMap(readMap(r.map['error'])?['details'])?['impact'] as String;
      expect(impact, startsWith('qBittorrent will delete '));
      expect(impact, endsWith('and its files once ratio ≥ 1.0'));
      expect(called(hub.fakes, _q, '/api/v2/torrents/setShareLimits'), isFalse);

      r = await hub.put(
        '/api/v1/torrents/$plainHash/share-limits',
        body: {'mode': 'global', 'action': 'remove'},
      );
      expect(r.status, 428);
      expect(r.body, contains('keeping files'));

      r = await hub.put(
        '/api/v1/torrents/$plainHash/share-limits',
        body: {
          'mode': 'custom',
          'ratio': 2.5,
          'seedingMinutes': 1440,
          'action': 'remove',
          'confirm': true,
        },
      );
      expect(r.status, 200, reason: r.body);
      final s = ShareLimits.fromJson(r.map);
      expect(s.ratio, 2.5);
      expect(s.seedingMinutes, 1440);
      expect(s.action, ShareLimitsAction.remove);
      expect(lastForm(hub.fakes, _q, '/api/v2/torrents/setShareLimits'), {
        'hashes': plainHash,
        'ratioLimit': '2.5',
        'seedingTimeLimit': '1440',
        'inactiveSeedingTimeLimit': '-1',
        'shareLimitAction': 'Remove',
        'shareLimitsMode': 'Default',
      });
    });

    test('stop does not need confirmation; unknown torrents 404', () async {
      var r = await hub.put(
        '/api/v1/torrents/$plainHash/share-limits',
        body: {'mode': 'unlimited', 'action': 'stop'},
      );
      expect(r.status, 200);
      expect(
        lastForm(
          hub.fakes,
          _q,
          '/api/v2/torrents/setShareLimits',
        )['ratioLimit'],
        '-1',
      );
      r = await hub.put(
        '/api/v1/torrents/${'f' * 40}/share-limits',
        body: {'mode': 'global'},
      );
      expect(r.status, 404);
      r = await hub.put(
        '/api/v1/torrents/$plainHash/share-limits',
        body: {'mode': 'custom'},
      );
      expect(r.status, 422);
      r = await hub.put(
        '/api/v1/torrents/$plainHash/share-limits',
        body: {'mode': 'global', 'action': 'explode'},
      );
      expect(r.status, 400);
    });
  });

  test('PUT files/priority maps the priority', () async {
    final r = await hub.put(
      '/api/v1/torrents/$sonarrHash/files/priority',
      body: {
        'indexes': [0, 3],
        'priority': 'max',
      },
    );
    expect(r.status, 200, reason: r.body);
    expect(lastForm(hub.fakes, _q, '/api/v2/torrents/filePrio'), {
      'hash': sonarrHash,
      'id': '0|3',
      'priority': '7',
    });
  });

  group('transfer', () {
    test('GET /transfer', () async {
      final r = await hub.get('/api/v1/transfer', as: TestAs.member);
      expect(r.status, 200);
      final t = TransferState.fromJson(r.map);
      expect(t.upBps, 935671);
      expect(t.schedule!.enabled, isTrue);
    });

    test('alt-speed sets the mode explicitly (never toggles)', () async {
      final r = await hub.put(
        '/api/v1/transfer/alt-speed',
        body: {'enabled': false},
      );
      expect(r.status, 200, reason: r.body);
      expect(TransferState.fromJson(r.map).updatedAt, isNotNull);
      expect(lastForm(hub.fakes, _q, '/api/v2/transfer/setSpeedLimitsMode'), {
        'mode': '0',
      });
      expect(
        called(hub.fakes, _q, '/api/v2/transfer/toggleSpeedLimitsMode'),
        isFalse,
      );
    });

    test('limits and session', () async {
      var r = await hub.put(
        '/api/v1/transfer/limits',
        body: {
          'dlBps': 0,
          'upBps': 1048576,
          'altDlBps': 5120000,
          'altUpBps': 1024000,
        },
      );
      expect(r.status, 200, reason: r.body);
      expect(lastForm(hub.fakes, _q, '/api/v2/transfer/setSpeedLimits'), {
        'up_limit': '1048576',
        'dl_limit': '0',
        'alt_up_limit': '1024000',
        'alt_dl_limit': '5120000',
      });
      r = await hub.put('/api/v1/transfer/limits', body: {'dlBps': -1});
      expect(r.status, anyOf(400, 422));

      r = await hub.put('/api/v1/transfer/session', body: {'paused': true});
      expect(r.status, 200);
      expect(called(hub.fakes, _q, '/api/v2/transfer/pauseSession'), isTrue);
      r = await hub.put('/api/v1/transfer/session', body: {'paused': false});
      expect(called(hub.fakes, _q, '/api/v2/transfer/resumeSession'), isTrue);

      r = await hub.put(
        '/api/v1/transfer/session',
        as: TestAs.member,
        body: {'paused': true},
      );
      expect(r.status, 403);
    });

    test('categories are marked read-only', () async {
      final r = await hub.get('/api/v1/transfer/categories');
      expect(r.status, 200);
      final c = CategoryList.fromJson(r.map);
      expect(c.categories.map((c) => c.name), [
        'books',
        'lidarr',
        'radarr',
        'tv-sonarr',
      ]);
      expect(c.categories.every((c) => c.readOnly), isTrue);
      expect(c.categories.first.savePath, isNull);
      expect(c.tags, ['Keep', 'Obsolete']);
    });
  });

  group('GET /vpn', () {
    test('connected when the forwarded port matches', () async {
      final r = await hub.get('/api/v1/vpn', as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      final v = VpnStatus.fromJson(r.map);
      expect(v.status, VpnConnectionState.connected);
      expect(v.publicIp, '203.0.113.10');
      expect(v.country, 'France');
      expect(v.city, 'Marseille');
      expect(v.forwardedPort, 36681);
      expect(v.listenPort, 36681);
      expect(v.portInSync, isTrue);
      expect(v.qbitConnection, 'connected');
      expect(v.gluetunHealth, VpnGluetunHealth.healthy);
      final docker = hub.fakes
          .callsTo(ServiceId.docker)
          .firstWhere((c) => c.path == '/v1.54/containers/json');
      expect(docker.query['filters'], [
        jsonEncode({
          'name': ['gluetun'],
        }),
      ]);
    });

    test('down while gluetun reconnects (empty public IP)', () async {
      hub.fakes.on(
        ServiceId.gluetun,
        'GET',
        '/v1/publicip/ip',
        (_) => gluetunResponse({'public_ip': '', 'country': ''}),
      );
      final v = VpnStatus.fromJson((await hub.get('/api/v1/vpn')).map);
      expect(v.status, VpnConnectionState.down);
      expect(v.publicIp, isNull);
      expect(v.country, isNull);
    });

    test(
      'degraded without a forwarded port; health unknown without docker',
      () async {
        hub.fakes
          ..on(
            ServiceId.gluetun,
            'GET',
            '/v1/openvpn/portforwarded',
            (_) => gluetunResponse({'port': 0}),
          )
          ..on(
            ServiceId.docker,
            'GET',
            '/v1.54/containers/json',
            (_) => FakeResponse.text('denied', status: 403),
          );
        final v = VpnStatus.fromJson((await hub.get('/api/v1/vpn')).map);
        expect(v.status, VpnConnectionState.degraded);
        expect(v.forwardedPort, isNull);
        expect(v.portInSync, isFalse);
        expect(v.gluetunHealth, VpnGluetunHealth.unknown);
      },
    );

    test('down when gluetun is unreachable', () async {
      hub.fakes.on(
        ServiceId.gluetun,
        '*',
        RegExp('.*'),
        (_) => throw http.ClientException('refused'),
      );
      final v = VpnStatus.fromJson((await hub.get('/api/v1/vpn')).map);
      expect(v.status, VpnConnectionState.down);
    });
  });
}
