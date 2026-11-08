import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../../support/test_hub.dart';
import 'activity_support.dart';

const _sonarr = ServiceId.sonarr;
const _radarr = ServiceId.radarr;

JsonMap _command(int id, String name) => {
  'id': id,
  'name': name,
  'commandName': name,
  'status': 'queued',
  'result': 'unknown',
  'queued': '2026-11-08T09:00:00Z',
  'trigger': 'manual',
};

void main() {
  late TestHub hub;

  setUp(() => hub = activityHub());
  tearDown(() => hub.close());

  group('GET /activity/queue', () {
    test('merges torrents with their *arr records', () async {
      final r = await hub.get('/api/v1/activity/queue?filter=all');
      expect(r.status, 200, reason: r.body);
      final q = QueueResponse.fromJson(r.map);
      expect(q.sonarr.isOk && q.radarr.isOk && q.qbittorrent.isOk, isTrue);
      // 5 torrents + the Sonarr record without a torrent.
      expect(q.items, hasLength(6));

      final pack = q.items.firstWhere((i) => i.key == sonarrHash);
      expect(pack.state, QueueItemState.importPending);
      expect(pack.needsAttention, isTrue);
      expect(pack.attention, QueueAttention.importPending);
      expect(pack.title, 'That Time I Got Reincarnated as a Slime');
      expect(pack.subtitle, 'Sonarr · S04E01–E02');
      expect(pack.torrent!.hash, sonarrHash);
      final entry = pack.arr.single;
      expect(entry.queueIds, [123456, 123457]);
      expect(entry.canManualImport, isTrue);
      expect(entry.links.single.app, ExternalApp.sonarr);
      expect(entry.messages.single, startsWith('No files found'));
      // Attention first.
      expect(q.items.first.key, sonarrHash);

      final orphan = q.items.firstWhere((i) => i.torrent == null);
      expect(orphan.key, 'sonarr:${'a' * 40}');
      expect(orphan.state, QueueItemState.delayed);
      expect(orphan.etaSeconds, 93600);
      expect(orphan.sizeLeftBytes, 1496206957);
      expect(orphan.arr.single.isUpgrade, isTrue);

      final movie = q.items.firstWhere((i) => i.key == radarrHash);
      expect(movie.arr.single.service, ArrService.radarr);
      expect(movie.arr.single.movieId, 9);
      expect(movie.subtitle, 'Radarr');

      expect(q.summary.attention, 1);
      expect(q.summary.seeding, 4);
      expect(q.summary.upBps, 935671);

      final sonarrCall = hub.fakes
          .callsTo(_sonarr)
          .firstWhere((c) => c.path == '/api/v3/queue');
      expect(sonarrCall.query, {
        'page': ['1'],
        'pageSize': ['200'],
        'includeSeries': ['true'],
        'includeEpisode': ['true'],
      });
      final radarrCall = hub.fakes
          .callsTo(_radarr)
          .firstWhere((c) => c.path == '/api/v3/queue');
      expect(radarrCall.query['includeMovie'], ['true']);
    });

    test('members get no *arr links or import actions', () async {
      final r = await hub.get(
        '/api/v1/activity/queue?filter=attention',
        as: TestAs.member,
      );
      final q = QueueResponse.fromJson(r.map);
      final entry = q.items.single.arr.single;
      expect(entry.canManualImport, isFalse);
      expect(entry.links, isEmpty);
    });

    test('filters', () async {
      Future<List<String>> keys(String filter) async => [
        for (final i in QueueResponse.fromJson(
          (await hub.get('/api/v1/activity/queue?filter=$filter')).map,
        ).items)
          i.key,
      ];
      // Active: everything the *arrs track (the idle seeds are hidden).
      expect(
        await keys('active'),
        unorderedEquals([sonarrHash, radarrHash, 'sonarr:${'a' * 40}']),
      );
      expect(await keys('attention'), [sonarrHash]);
      expect(await keys('downloading'), ['sonarr:${'a' * 40}']);
      expect(await keys('seeding'), hasLength(4));
      final bad = await hub.get('/api/v1/activity/queue?filter=paused');
      expect(bad.status, 400);
    });

    test('one failing source does not fail the response', () async {
      hub.fakes.on(
        _radarr,
        'GET',
        '/api/v3/queue',
        (_) => throw http.ClientException('refused'),
      );
      final r = await hub.get('/api/v1/activity/queue?filter=all');
      expect(r.status, 200);
      final q = QueueResponse.fromJson(r.map);
      expect(q.radarr.status, SectionState.error);
      expect(q.radarr.error!.code, 'upstream_unavailable');
      expect(q.sonarr.isOk, isTrue);
      expect(q.items.firstWhere((i) => i.key == radarrHash).arr, isEmpty);
    });

    test('an unconfigured *arr is disabled', () async {
      final h = activityHub(unconfigured: {ServiceId.radarr});
      addTearDown(h.close);
      final q = QueueResponse.fromJson(
        (await h.get('/api/v1/activity/queue')).map,
      );
      expect(q.radarr.status, SectionState.disabled);
    });

    test('qBittorrent down still lists the *arr records', () async {
      hub.fakes.on(
        ServiceId.qbittorrent,
        'GET',
        '/api/v2/sync/maindata',
        (_) => throw http.ClientException('refused'),
      );
      final q = QueueResponse.fromJson(
        (await hub.get('/api/v1/activity/queue?filter=all')).map,
      );
      expect(q.qbittorrent.status, SectionState.error);
      expect(q.items, hasLength(3));
      expect(q.items.every((i) => i.torrent == null), isTrue);
      expect(q.items.first.attention, QueueAttention.importPending);
    });
  });

  group('queue actions', () {
    test('remove needs confirm, then bulk-deletes per service', () async {
      hub.fakes.on(
        _sonarr,
        'DELETE',
        '/api/v3/queue/bulk',
        (_) => FakeResponse(200),
      );
      final body = {
        'items': [
          {
            'service': 'sonarr',
            'queueIds': [123456, 123457, 999],
          },
        ],
        'blocklist': true,
        'searchAgain': true,
      };
      var r = await hub.post('/api/v1/activity/queue/remove', body: body);
      expect(r.status, 428);
      expect(
        readMap(readMap(r.map['error'])?['details'])?['impact'],
        'Removes 3 queue items and deletes the torrent; the release is '
        'blocklisted and Sonarr searches again',
      );
      expect(
        called(hub.fakes, _sonarr, '/api/v3/queue/bulk', method: 'DELETE'),
        isFalse,
      );

      r = await hub.post(
        '/api/v1/activity/queue/remove',
        body: {...body, 'confirm': true},
      );
      expect(r.status, 200, reason: r.body);
      expect(QueueRemoveResult.fromJson(r.map).removed, 2);
      expect(QueueRemoveResult.fromJson(r.map).alreadyGone, 1);
      final call = hub.fakes
          .callsTo(_sonarr)
          .lastWhere((c) => c.path == '/api/v3/queue/bulk');
      expect(call.method, 'DELETE');
      expect(call.query, {
        'removeFromClient': ['true'],
        'blocklist': ['true'],
        'skipRedownload': ['false'],
      });
      expect(call.body, '{"ids":[123456,123457]}');
    });

    test('ids beyond a full queue page are still removed', () async {
      hub.fakes
        ..on(
          _sonarr,
          'GET',
          '/api/v3/queue',
          (_) => FakeResponse.json({
            'page': 1,
            'pageSize': 200,
            'totalRecords': 250,
            'records': [
              for (var i = 1; i <= 200; i++)
                {'id': i, 'downloadId': 'A' * 40, 'title': 'Pack'},
            ],
          }),
        )
        ..on(_sonarr, 'DELETE', '/api/v3/queue/bulk', (_) => FakeResponse(200));
      final r = await hub.post(
        '/api/v1/activity/queue/remove?confirm=true',
        body: {
          'items': [
            {
              'service': 'sonarr',
              'queueIds': [5, 240],
            },
          ],
        },
      );
      expect(r.status, 200, reason: r.body);
      expect(QueueRemoveResult.fromJson(r.map).removed, 2);
      expect(QueueRemoveResult.fromJson(r.map).alreadyGone, 0);
      expect(
        hub.fakes
            .callsTo(_sonarr)
            .lastWhere((c) => c.path == '/api/v3/queue/bulk')
            .body,
        '{"ids":[5,240]}',
      );
    });

    test('a 404 counts as already gone; searchAgain needs blocklist', () async {
      hub.fakes.on(
        _radarr,
        'DELETE',
        '/api/v3/queue/bulk',
        (_) => FakeResponse.json({'message': 'gone'}, status: 404),
      );
      var r = await hub.post(
        '/api/v1/activity/queue/remove?confirm=true',
        body: {
          'items': [
            {
              'service': 'radarr',
              'queueIds': [9],
            },
          ],
          'removeFromClient': false,
        },
      );
      expect(r.status, 200, reason: r.body);
      expect(QueueRemoveResult.fromJson(r.map).alreadyGone, 1);
      expect(
        hub.fakes
            .callsTo(_radarr)
            .lastWhere((c) => c.path == '/api/v3/queue/bulk')
            .query['skipRedownload'],
        ['true'],
      );
      r = await hub.post(
        '/api/v1/activity/queue/remove?confirm=true',
        body: {
          'items': [
            {
              'service': 'radarr',
              'queueIds': [9],
            },
          ],
          'searchAgain': true,
        },
      );
      expect(r.status, 422);
    });

    test('grab and refresh', () async {
      hub.fakes
        ..on(
          _sonarr,
          'POST',
          '/api/v3/queue/grab/bulk',
          (_) => FakeResponse(200),
        )
        ..on(
          _sonarr,
          'POST',
          '/api/v3/command',
          (_) => FakeResponse.json(
            _command(11, 'RefreshMonitoredDownloads'),
            status: 201,
          ),
        )
        ..on(
          _radarr,
          'POST',
          '/api/v3/command',
          (_) => FakeResponse.json(
            _command(12, 'RefreshMonitoredDownloads'),
            status: 201,
          ),
        );
      var r = await hub.post(
        '/api/v1/activity/queue/grab',
        body: {
          'service': 'sonarr',
          'queueIds': [200],
        },
      );
      expect(r.status, 200, reason: r.body);
      expect(
        hub.fakes
            .callsTo(_sonarr)
            .lastWhere((c) => c.path == '/api/v3/queue/grab/bulk')
            .body,
        '{"ids":[200]}',
      );

      r = await hub.post('/api/v1/activity/queue/refresh', body: {});
      expect(r.status, 202, reason: r.body);
      final commands = [
        for (final c in r.map['commands'] as List)
          CommandRef.fromJson(readMap(c)!),
      ];
      expect(commands.map((c) => c.service), [
        ServiceId.sonarr,
        ServiceId.radarr,
      ]);
      expect(commands.first.id, 11);
      expect(
        hub.fakes
            .callsTo(_sonarr)
            .lastWhere((c) => c.path == '/api/v3/command')
            .body,
        '{"name":"RefreshMonitoredDownloads"}',
      );

      r = await hub.post(
        '/api/v1/activity/queue/refresh',
        body: {'service': 'radarr'},
      );
      expect((r.map['commands'] as List), hasLength(1));
    });

    test('members are refused', () async {
      for (final path in ['remove', 'grab', 'refresh', 'import']) {
        final r = await hub.post(
          '/api/v1/activity/queue/$path',
          as: TestAs.member,
          body: {'confirm': true},
        );
        expect(r.status, 403, reason: path);
      }
      final r = await hub.get(
        '/api/v1/activity/queue/sonarr/123456/import',
        as: TestAs.member,
      );
      expect(r.status, 403);
    });
  });

  group('manual import', () {
    setUp(() {
      hub.fakes.on(
        _sonarr,
        'GET',
        '/api/v3/manualimport',
        (_) => syntheticResponse('sonarr_manualimport.synthetic.json'),
      );
    });

    test('candidates keep paths behind fileId tokens', () async {
      final r = await hub.get('/api/v1/activity/queue/sonarr/123456/import');
      expect(r.status, 200, reason: r.body);
      final c = ManualImportCandidates.fromJson(r.map);
      expect(c.service, ArrService.sonarr);
      expect(c.queueId, 123456);
      expect(c.downloadId, '0985D9EFDF7508DB837E629AE8F40EE8B56F4D71');
      expect(c.items, hasLength(2));
      final ep = c.items.first;
      expect(ep.fileId, startsWith('mi_'));
      expect(ep.importable, isTrue);
      expect(ep.episodes.single.label, 'S04E01 (073)');
      expect(ep.quality.name, 'WEBDL-1080p');
      expect(ep.languages, ['Japanese']);
      expect(ep.customFormatScore, 200);
      final extra = c.items.last;
      expect(extra.importable, isFalse);
      expect(
        extra.rejections.single.type,
        ManualImportFileRejectionType.permanent,
      );
      // Absolute paths and folder names never leave the gateway.
      expect(r.body, isNot(contains('/data/downloads')));
      expect(r.body, isNot(contains('folderName')));

      final call = hub.fakes
          .callsTo(_sonarr)
          .firstWhere((c) => c.path == '/api/v3/manualimport');
      expect(call.query, {
        'downloadId': ['0985D9EFDF7508DB837E629AE8F40EE8B56F4D71'],
        'seriesId': ['54'],
        'filterExistingFiles': ['true'],
      });
    });

    test('import sends the candidate back with the raw quality', () async {
      hub.fakes.on(
        _sonarr,
        'POST',
        '/api/v3/command',
        (_) => FakeResponse.json(_command(77, 'ManualImport'), status: 201),
      );
      final c = ManualImportCandidates.fromJson(
        (await hub.get('/api/v1/activity/queue/sonarr/123456/import')).map,
      );
      final r = await hub.post(
        '/api/v1/activity/queue/import',
        body: {
          'service': 'sonarr',
          'queueId': 123456,
          'files': [
            {'fileId': c.items.first.fileId},
            {
              'fileId': c.items.last.fileId,
              'seriesId': 54,
              'episodeIds': [5581],
            },
          ],
        },
      );
      expect(r.status, 202, reason: r.body);
      final ref = CommandRef.fromJson(readMap(r.map['command'])!);
      expect(ref.id, 77);
      expect(ref.service, ServiceId.sonarr);

      final sent = readMap(
        jsonDecode(
          hub.fakes
              .callsTo(_sonarr)
              .lastWhere((c) => c.path == '/api/v3/command')
              .body,
        ),
      )!;
      expect(sent['name'], 'ManualImport');
      expect(sent['importMode'], 'auto');
      final files = [for (final f in sent['files'] as List) readMap(f)!];
      expect(files.first['path'], startsWith('/data/downloads/torrents/'));
      expect(files.first['seriesId'], 54);
      expect(files.first['episodeIds'], [5580]);
      expect(files.first['releaseType'], 'seasonPack');
      expect(files.first['indexerFlags'], 1);
      expect(
        files.first['quality'],
        readMap(
          (synthetic('sonarr_manualimport.synthetic.json')! as List).first,
        )!['quality'],
      );
      expect(files.first['languages'], [
        {'id': 8, 'name': 'Japanese'},
      ]);
      expect(
        files.first['downloadId'],
        '0985D9EFDF7508DB837E629AE8F40EE8B56F4D71',
      );
      expect(files.last['episodeIds'], [5581]);
      expect(files.last['releaseType'], 'singleEpisode');
    });

    test('expired or foreign tokens are 404; unmatched files 422', () async {
      var r = await hub.post(
        '/api/v1/activity/queue/import',
        body: {
          'service': 'sonarr',
          'queueId': 123456,
          'files': [
            {'fileId': 'mi_nope'},
          ],
        },
      );
      expect(r.status, 404);
      expect(r.body, contains('Import candidates expired, reload'));

      final c = ManualImportCandidates.fromJson(
        (await hub.get('/api/v1/activity/queue/sonarr/123456/import')).map,
      );
      r = await hub.post(
        '/api/v1/activity/queue/import',
        body: {
          'service': 'sonarr',
          'queueId': 123456,
          'files': [
            {'fileId': c.items.last.fileId},
          ],
        },
      );
      expect(r.status, 422);

      // Another queue item cannot reuse the tokens.
      r = await hub.post(
        '/api/v1/activity/queue/import',
        body: {
          'service': 'sonarr',
          'queueId': 200,
          'files': [
            {'fileId': c.items.first.fileId},
          ],
        },
      );
      expect(r.status, 404);

      // Tokens expire after 30 minutes.
      hub.clock.advance(const Duration(minutes: 31));
      r = await hub.post(
        '/api/v1/activity/queue/import',
        body: {
          'service': 'sonarr',
          'queueId': 123456,
          'files': [
            {'fileId': c.items.first.fileId},
          ],
        },
      );
      expect(r.status, 404);
    });

    test('404 when the queue record is gone', () async {
      hub.fakes.on(
        _sonarr,
        'GET',
        '/api/v3/queue/424242',
        (_) => FakeResponse.json({'title': 'Not Found'}, status: 404),
      );
      final r = await hub.get('/api/v1/activity/queue/sonarr/424242/import');
      expect(r.status, 404);
      expect(r.errorCode, 'not_found');
    });
  });

  group('GET /activity/history', () {
    setUp(() {
      hub.fakes
        ..onFixture(
          _sonarr,
          'GET',
          '/api/v3/history',
          'arr/sonarr_history.json',
        )
        ..onFixture(
          _radarr,
          'GET',
          '/api/v3/history',
          'arr/radarr_history.json',
        );
    });

    test('merges both services newest first', () async {
      final r = await hub.get('/api/v1/activity/history', as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      final page = CursorPage.fromJson(r.map, ArrHistoryItem.fromJson);
      expect(page.items, hasLength(8));
      expect(page.nextCursor, isNull);
      final dates = [for (final i in page.items) i.date];
      expect(
        dates,
        orderedEquals(<DateTime>[...dates]..sort((a, b) => b.compareTo(a))),
      );
      expect(page.items.map((i) => i.service).toSet(), {
        ArrService.sonarr,
        ArrService.radarr,
      });
      expect(r.body, isNot(contains('apikey')));
      final call = hub.fakes
          .callsTo(_sonarr)
          .firstWhere((c) => c.path == '/api/v3/history');
      expect(call.query, {
        'page': ['1'],
        'pageSize': ['50'],
        'sortKey': ['date'],
        'sortDirection': ['descending'],
        'includeSeries': ['true'],
        'includeEpisode': ['true'],
      });
    });

    test('types become per-service eventType integers', () async {
      final r = await hub.get(
        '/api/v1/activity/history?types=imported,deleted&service=radarr',
      );
      expect(r.status, 200);
      final call = hub.fakes
          .callsTo(_radarr)
          .firstWhere((c) => c.path == '/api/v3/history');
      expect(call.query['eventType'], ['3', '7', '6']);
      expect(call.query['includeMovie'], ['true']);
      expect(
        hub.fakes.callsTo(_sonarr).where((c) => c.path == '/api/v3/history'),
        isEmpty,
      );
    });

    test('cursor paging and validation', () async {
      final first = CursorPage.fromJson(
        (await hub.get('/api/v1/activity/history?limit=3')).map,
        ArrHistoryItem.fromJson,
      );
      expect(first.items, hasLength(3));
      expect(first.nextCursor, isNotNull);
      final second = CursorPage.fromJson(
        (await hub.get(
          '/api/v1/activity/history?limit=10&cursor=${first.nextCursor}',
        )).map,
        ArrHistoryItem.fromJson,
      );
      expect(second.items, hasLength(5));
      expect({
        ...first.items.map((i) => i.id),
        ...second.items.map((i) => i.id),
      }, hasLength(8));
      for (final q in [
        'types=renamedd',
        'limit=101',
        'cursor=garbage',
        'service=lidarr',
      ]) {
        final r = await hub.get('/api/v1/activity/history?$q');
        expect(r.status, 400, reason: q);
      }
    });
  });

  group('dashboard card', () {
    test('counts, top items, VPN and alerts', () async {
      hub.fakes.on(
        ServiceId.gluetun,
        'GET',
        '/v1/openvpn/portforwarded',
        (_) => gluetunResponse({'port': 40000}),
      );
      final r = await hub.get('/api/v1/dashboard?cards=activity');
      expect(r.status, 200, reason: r.body);
      final section = Section.fromJson(
        readMap(readMap(r.map['cards'])!['activity'])!,
      );
      expect(section.status, SectionState.ok, reason: r.body);
      // The raw key the app's badge reads.
      expect(readMap(section.data!['counts'])!['attention'], 1);
      final card = section.decode(ActivityCard.fromJson)!;
      expect(card.counts.seeding, 4);
      expect(card.transfer.altSpeedEnabled, isTrue);
      expect(card.top.first.key, sonarrHash);
      expect(card.top.length, lessThanOrEqualTo(3));
      expect(card.vpn!.status, VpnConnectionState.degraded);

      final alerts = [
        for (final a in r.map['alerts'] as List) Alert.fromJson(readMap(a)!),
      ];
      final ids = alerts.map((a) => a.id).toSet();
      expect(ids, containsAll(['vpn.port', 'queue.import.$sonarrHash']));
      final importAlert = alerts.firstWhere(
        (a) => a.id.startsWith('queue.import.'),
      );
      expect(importAlert.severity, AlertSeverity.warning);
      expect(importAlert.route, '/activity?tab=queue&import=$sonarrHash');
      expect(
        importAlert.title,
        'Manual import needed: That Time I Got Reincarnated as a Slime',
      );
      expect(importAlert.source, ServiceId.sonarr);
    });

    test('vpn.down and qbittorrent.auth', () async {
      hub.fakes
        ..on(
          ServiceId.gluetun,
          'GET',
          '/v1/publicip/ip',
          (_) => gluetunResponse({'public_ip': ''}),
        )
        ..on(
          ServiceId.qbittorrent,
          'POST',
          '/api/v2/auth/login',
          (_) => FakeResponse.text('Unauthorized', status: 401),
        );
      final r = await hub.get('/api/v1/dashboard?cards=activity');
      final ids = {for (final a in r.map['alerts'] as List) readMap(a)!['id']};
      expect(ids, containsAll(['vpn.down', 'qbittorrent.auth']));
      // The *arr queues still feed the card.
      final section = Section.fromJson(
        readMap(readMap(r.map['cards'])!['activity'])!,
      );
      expect(section.status, SectionState.ok);
      expect(section.decode(ActivityCard.fromJson)!.counts.attention, 1);
    });

    test('everything down is an error card', () async {
      final h = activityHub(
        unconfigured: {
          ServiceId.qbittorrent,
          ServiceId.sonarr,
          ServiceId.radarr,
        },
      );
      addTearDown(h.close);
      final r = await h.get('/api/v1/dashboard?cards=activity');
      final section = Section.fromJson(
        readMap(readMap(r.map['cards'])!['activity'])!,
      );
      expect(section.status, SectionState.disabled);
    });
  });
}
