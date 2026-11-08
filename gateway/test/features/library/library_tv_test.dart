import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../../support/test_hub.dart';
import 'library_fakes.dart';

const _base = '/api/v1/library';

void main() {
  late TestHub hub;

  setUp(() {
    hub = TestHub();
    stubLibraryUpstreams(hub.fakes);
    stubCommands(hub.fakes, ServiceId.sonarr);
  });
  tearDown(() => hub.close());

  List<JsonMap> items(TestResponse r) => [
    for (final i in r.map['items']! as List) i as JsonMap,
  ];

  group('GET /library/tv', () {
    test('slim list for members, tags resolved through /api/v3/tag', () async {
      final series = fixtureCopy('arr/sonarr_series.json')! as List;
      (series[2] as Map)['tags'] = [1, 42];
      hub.fakes.on(
        ServiceId.sonarr,
        'GET',
        '/api/v3/series',
        (_) => FakeResponse.json(series),
      );
      final r = await hub.get('$_base/tv', as: TestAs.member);
      expect(r.status, 200);
      final list = items(r);
      // By sortTitle (Sonarr drops leading articles).
      expect(list.map((s) => s['id']), [25, 2, 140, 61, 54]);
      final slime = list.firstWhere((s) => s['id'] == 54);
      expect(slime['tags'], ['anime']);
      expect(slime['isAnime'], isTrue);
      expect(slime['missingCount'], 48);
      expect(slime['qualityProfileName'], '[Anime] Remux-1080p');
      expect(slime.containsKey('path'), isFalse);
      expect(slime.containsKey('nextAiring'), isFalse);
      expect(
        callsOf(hub.fakes, ServiceId.sonarr, '/api/v3/series'),
        hasLength(1),
      );
      expect(callsOf(hub.fakes, ServiceId.sonarr, '/api/v3/tag'), hasLength(1));

      // Cached for 60 s.
      await hub.get('$_base/tv?filter=anime');
      expect(
        callsOf(hub.fakes, ServiceId.sonarr, '/api/v3/series'),
        hasLength(1),
      );
    });

    test(
      'filters, sorts and diacritics-insensitive q in the gateway',
      () async {
        Future<List<Object?>> ids(String query) async =>
            items(await hub.get('$_base/tv?$query'))
                .map((s) => s['id'])
                .toList();

        expect(await ids('filter=anime'), [25, 140, 54]);
        expect(await ids('filter=missing&sort=missing&order=desc'), [
          54,
          61,
          2,
        ]);
        expect(await ids('filter=upcoming'), [140]);
        expect(await ids('q=FR%C3%8FEREN'), [25]);
        expect(await ids('sort=sizeOnDisk'), [54, 25, 140, 2, 61]);
        final bad = await hub.get('$_base/tv?sort=rating');
        expect(bad.status, 400);
        expect(bad.errorCode, 'bad_request');
      },
    );

    test('an unreachable Sonarr is 503 upstream_unavailable', () async {
      hub.fakes.on(
        ServiceId.sonarr,
        'GET',
        '/api/v3/series',
        (_) => throw http.ClientException('connection refused'),
      );
      final r = await hub.get('$_base/tv');
      expect(r.status, 503);
      expect(r.errorCode, 'upstream_unavailable');
      expect(r.body, isNot(contains('sonarr.test')));
    });

    test('a 500 is 502 upstream_error without the stack trace', () async {
      hub.fakes.on(
        ServiceId.sonarr,
        'GET',
        '/api/v3/series',
        (_) => FakeResponse.json({
          'message': 'Database is locked',
          'description': 'System.Exception at NzbDrone.Core ...',
        }, status: 500),
      );
      final r = await hub.get('$_base/tv');
      expect(r.status, 502);
      expect(r.errorCode, 'upstream_error');
      expect(r.body, isNot(contains('NzbDrone')));
    });
  });

  group('GET /library/tv/{id}', () {
    test('series, episodes and queue in parallel', () async {
      final r = await hub.get('$_base/tv/54', as: TestAs.member);
      expect(r.status, 200);
      final seasons = [
        for (final s in r.map['seasons']! as List) (s as Map)['seasonNumber'],
      ];
      expect(seasons, [1, 2, 3, 4, 0]);
      final episodes = r.map['episodes']! as List;
      final first = episodes.first as Map;
      expect(first['label'], 'S03E01 (049)');
      expect((first['queue'] as Map)['trackedState'], 'importPending');
      expect((r.map['links']! as Map)['tvdb'], contains('352408'));
      expect(r.map['rootFolderPath'], '/data/tvshows');

      final series = callsOf(hub.fakes, ServiceId.sonarr, '/api/v3/series/54');
      expect(series.single.query['includeSeasonImages'], ['true']);
      final eps = callsOf(hub.fakes, ServiceId.sonarr, '/api/v3/episode');
      expect(eps.single.query['seriesId'], ['54']);
      expect(eps.single.query['includeEpisodeFile'], ['true']);
      final queue = callsOf(
        hub.fakes,
        ServiceId.sonarr,
        '/api/v3/queue/details',
      );
      expect(queue.single.query['seriesId'], ['54']);
    });

    test('an unknown series is 404', () async {
      final r = await hub.get('$_base/tv/999999');
      expect(r.status, 404);
      expect(r.errorCode, 'not_found');
      expect(readMap(r.map['error'])!['service'], 'sonarr');
    });

    test('a failing queue read still shows the page', () async {
      hub.fakes.on(
        ServiceId.sonarr,
        'GET',
        '/api/v3/queue/details',
        (_) => FakeResponse.json({'message': 'boom'}, status: 500),
      );
      final r = await hub.get('$_base/tv/54');
      expect(r.status, 200);
      expect((r.map['episodes']! as List).first, isNot(contains('queue')));
    });
  });

  test('GET /library/tv/{id}/history pages and strips secrets', () async {
    hub.fakes.onFixture(
      ServiceId.sonarr,
      'GET',
      '/api/v3/history',
      'arr/sonarr_history_grabbed.json',
    );
    final r = await hub.get('$_base/tv/54/history?page=1&pageSize=200');
    expect(r.status, 200);
    expect(r.map['total'], 2546);
    expect(r.map['pageSize'], 50, reason: 'clamped');
    expect(r.map['hasMore'], isTrue);
    final first = (r.map['items']! as List).first as Map;
    expect(first['type'], 'grabbed');
    expect(first['id'], 'sonarr:13662');
    expect(r.body, isNot(contains('apikey')));
    expect(r.body, isNot(contains('downloadUrl')));
    final call = callsOf(hub.fakes, ServiceId.sonarr, '/api/v3/history').single;
    expect(call.query['seriesIds'], ['54']);
    expect(call.query['includeEpisode'], ['true']);
    expect(call.query['sortKey'], ['date']);
    expect(call.query['sortDirection'], ['descending']);
  });

  group('GET /library/tv/lookup', () {
    test('an empty term is 400 and never reaches Sonarr', () async {
      final r = await hub.get('$_base/tv/lookup?term=%20');
      expect(r.status, 400);
      expect(
        callsOf(hub.fakes, ServiceId.sonarr, '/api/v3/series/lookup'),
        isEmpty,
      );
    });

    test('results with in-library flags and Seerr defaults', () async {
      final r = await hub.get('$_base/tv/lookup?term=frieren');
      expect(r.status, 200);
      final list = items(r);
      expect(list.first['inLibrary'], isTrue);
      expect(list.first['libraryId'], 25);
      expect(list.first['suggested'], {
        'seriesType': 'anime',
        'qualityProfileId': 7,
        'rootFolderPath': '/data/tvshows',
      });
      expect((list[1]['suggested']! as Map)['qualityProfileId'], 9);
      expect(list.last.containsKey('posterPath'), isFalse);
      expect(r.body, isNot(contains('MediaCoverProxy')));
      final call = callsOf(
        hub.fakes,
        ServiceId.sonarr,
        '/api/v3/series/lookup',
      ).single;
      expect(call.query['term'], ['frieren']);
      // Cached per term.
      await hub.get('$_base/tv/lookup?term=Frieren');
      expect(
        callsOf(hub.fakes, ServiceId.sonarr, '/api/v3/series/lookup'),
        hasLength(1),
      );
    });
  });

  group('POST /library/tv', () {
    const body = {
      'tvdbId': 371980,
      'qualityProfileId': 9,
      'rootFolderPath': '/data/tvshows',
      'seriesType': 'standard',
      'monitor': 'firstSeason',
      'searchForMissing': true,
    };

    void lookupNew() {
      final found = fixtureCopy('arr/sonarr_series_lookup_tvdb.json')! as List;
      (found.first as Map)
        ..remove('id')
        ..remove('path');
      hub.fakes.on(
        ServiceId.sonarr,
        'GET',
        '/api/v3/series/lookup',
        (_) => FakeResponse.json(found),
      );
    }

    test('lookup, override, POST series with addOptions', () async {
      lookupNew();
      hub.fakes.on(ServiceId.sonarr, 'POST', '/api/v3/series', (req) {
        final b = req.json()! as Map<String, Object?>;
        return FakeResponse.json({...b, 'id': 300}, status: 201);
      });
      final r = await hub.post('$_base/tv', body: body);
      expect(r.status, 201, reason: r.body);
      expect(r.map['id'], 300);
      expect(r.map['title'], 'Severance');

      final lookup = callsOf(
        hub.fakes,
        ServiceId.sonarr,
        '/api/v3/series/lookup',
      ).single;
      expect(lookup.query['term'], ['tvdb:371980']);
      final post = callsOf(
        hub.fakes,
        ServiceId.sonarr,
        '/api/v3/series',
        method: 'POST',
      ).single;
      final sent = jsonDecode(post.body) as Map<String, Object?>;
      expect(sent['tvdbId'], 371980);
      expect(sent['qualityProfileId'], 9);
      expect(sent['rootFolderPath'], '/data/tvshows');
      expect(sent['seriesType'], 'standard');
      expect(sent['seasonFolder'], isTrue);
      expect(sent['monitored'], isTrue);
      expect(sent['monitorNewItems'], 'all');
      expect(sent.containsKey('path'), isFalse);
      expect(sent['addOptions'], {
        'monitor': 'firstSeason',
        'searchForMissingEpisodes': true,
        'searchForCutoffUnmetEpisodes': false,
        'ignoreEpisodesWithFiles': false,
        'ignoreEpisodesWithoutFiles': false,
      });

      final audit = await hub.get('/api/v1/admin/audit?action=library.tv');
      final actions = [
        for (final e in audit.map['items']! as List) (e as Map)['action'],
      ];
      expect(actions, contains('library.tv.add'));
    });

    test('a lookup result already in the library is 409 with its id', () async {
      hub.fakes.onFixture(
        ServiceId.sonarr,
        'GET',
        '/api/v3/series/lookup',
        'arr/sonarr_series_lookup_tvdb.json',
      );
      final r = await hub.post('$_base/tv', body: body);
      expect(r.status, 409);
      expect(r.errorCode, 'already_exists');
      expect(readMap(r.map['error'])!['details'], {'libraryId': 61});
      expect(
        callsOf(hub.fakes, ServiceId.sonarr, '/api/v3/series', method: 'POST'),
        isEmpty,
      );
    });

    test('Sonarr "already been added" is 409, other validation 422', () async {
      lookupNew();
      hub.fakes.on(
        ServiceId.sonarr,
        'POST',
        '/api/v3/series',
        (_) => FakeResponse.json([
          {
            'propertyName': 'TvdbId',
            'errorMessage': 'This series has already been added',
            'attemptedValue': 371980,
            'severity': 'error',
          },
        ], status: 400),
      );
      hub.fakes.on(
        ServiceId.sonarr,
        'GET',
        '/api/v3/series',
        (req) => FakeResponse.json([
          {'id': 61, 'title': 'Severance', 'tvdbId': 371980},
        ]),
      );
      final dup = await hub.post('$_base/tv', body: body);
      expect(dup.status, 409);
      expect(readMap(dup.map['error'])!['details'], {'libraryId': 61});

      hub.fakes.on(
        ServiceId.sonarr,
        'POST',
        '/api/v3/series',
        (_) => FakeResponse.json([
          {
            'propertyName': 'RootFolderPath',
            'errorMessage': 'Root folder does not exist',
          },
        ], status: 400),
      );
      final bad = await hub.post('$_base/tv', body: body);
      expect(bad.status, 422);
      expect(bad.errorCode, 'validation_failed');
      expect(readMap(bad.map['error'])!['fields'], [
        {'field': 'RootFolderPath', 'message': 'Root folder does not exist'},
      ]);
    });

    test('body validation and roles', () async {
      final missing = await hub.post(
        '$_base/tv',
        body: {'tvdbId': 1, 'seriesType': 'standard'},
      );
      expect(missing.status, 422);
      final badType = await hub.post(
        '$_base/tv',
        body: {...body, 'seriesType': 'weekly'},
      );
      expect(badType.status, 422);
      final member = await hub.post('$_base/tv', body: body, as: TestAs.member);
      expect(member.status, 403);
    });
  });

  group('edits', () {
    test('PATCH series goes through series/editor and re-reads', () async {
      hub.fakes.on(
        ServiceId.sonarr,
        'PUT',
        '/api/v3/series/editor',
        (_) => FakeResponse(202),
      );
      final r = await hub.patch(
        '$_base/tv/54',
        body: {'monitored': false, 'seriesType': 'anime'},
      );
      expect(r.status, 200, reason: r.body);
      expect(r.map['id'], 54);
      final put = callsOf(
        hub.fakes,
        ServiceId.sonarr,
        '/api/v3/series/editor',
      ).single;
      expect(jsonDecode(put.body), {
        'seriesIds': [54],
        'monitored': false,
        'seriesType': 'anime',
      });
      final empty = await hub.patch('$_base/tv/54', body: <String, Object>{});
      expect(empty.status, 422);
    });

    test('PATCH season PUTs the full series with the season flipped', () async {
      hub.fakes.on(
        ServiceId.sonarr,
        'PUT',
        '/api/v3/series/54',
        (req) => FakeResponse.json(req.json(), status: 202),
      );
      final r = await hub.patch(
        '$_base/tv/54/seasons/3',
        body: {'monitored': false},
      );
      expect(r.status, 200, reason: r.body);
      expect(r.map['seasonNumber'], 3);
      expect(r.map['monitored'], isFalse);
      final put = callsOf(
        hub.fakes,
        ServiceId.sonarr,
        '/api/v3/series/54',
        method: 'PUT',
      ).single;
      final sent = jsonDecode(put.body) as Map<String, Object?>;
      expect(sent['path'], isNotEmpty, reason: 'full resource, never partial');
      final seasons = {
        for (final s in sent['seasons']! as List)
          (s as Map)['seasonNumber']: s['monitored'],
      };
      expect(seasons, {0: false, 1: true, 2: true, 3: false, 4: true});

      final unknown = await hub.patch(
        '$_base/tv/54/seasons/9',
        body: {'monitored': true},
      );
      expect(unknown.status, 404);
    });

    test('PATCH episodes uses episode/monitor', () async {
      hub.fakes.on(
        ServiceId.sonarr,
        'PUT',
        '/api/v3/episode/monitor',
        (_) => FakeResponse.json([
          {'id': 2447, 'monitored': true, 'seasonNumber': 3},
        ], status: 202),
      );
      final r = await hub.patch(
        '$_base/tv/episodes',
        body: {
          'episodeIds': [2447],
          'monitored': true,
        },
      );
      expect(r.status, 200);
      expect(r.map['items'], [
        {'id': 2447, 'monitored': true},
      ]);
      final put = callsOf(
        hub.fakes,
        ServiceId.sonarr,
        '/api/v3/episode/monitor',
      ).single;
      expect(jsonDecode(put.body), {
        'episodeIds': [2447],
        'monitored': true,
      });
      final none = await hub.patch(
        '$_base/tv/episodes',
        body: {'episodeIds': <int>[], 'monitored': true},
      );
      expect(none.status, 422);
      final tooMany = await hub.patch(
        '$_base/tv/episodes',
        body: {
          'episodeIds': [for (var i = 1; i <= 501; i++) i],
          'monitored': true,
        },
      );
      expect(tooMany.status, 422);
    });
  });

  group('commands', () {
    test('search scopes map to Sonarr commands; 30 s debounce', () async {
      final season = await hub.post(
        '$_base/tv/54/search',
        body: {'scope': 'season', 'seasonNumber': 3},
      );
      expect(season.status, 202);
      final command = season.map['command']! as Map;
      expect(command['service'], 'sonarr');
      expect(command['name'], 'SeasonSearch');
      expect(command['status'], 'queued');

      final again = await hub.post(
        '$_base/tv/54/search',
        body: {'scope': 'season', 'seasonNumber': 3},
      );
      expect((again.map['command']! as Map)['id'], command['id']);
      expect(
        callsOf(hub.fakes, ServiceId.sonarr, '/api/v3/command'),
        hasLength(1),
      );

      hub.clock.advance(const Duration(seconds: 31));
      final later = await hub.post(
        '$_base/tv/54/search',
        body: {'scope': 'season', 'seasonNumber': 3},
      );
      expect((later.map['command']! as Map)['id'], isNot(command['id']));

      await hub.post('$_base/tv/54/search', body: {'scope': 'missing'});
      await hub.post(
        '$_base/tv/54/search',
        body: {
          'scope': 'episodes',
          'episodeIds': [2447, 2448],
        },
      );
      await hub.post('$_base/tv/54/search', body: {'scope': 'series'});
      await hub.post('$_base/tv/54/refresh');
      final bodies = [
        for (final c in callsOf(hub.fakes, ServiceId.sonarr, '/api/v3/command'))
          jsonDecode(c.body),
      ];
      expect(bodies, [
        {'name': 'SeasonSearch', 'seriesId': 54, 'seasonNumber': 3},
        {'name': 'SeasonSearch', 'seriesId': 54, 'seasonNumber': 3},
        {'name': 'MissingEpisodeSearch', 'seriesId': 54, 'monitored': true},
        {
          'name': 'EpisodeSearch',
          'episodeIds': [2447, 2448],
        },
        {'name': 'SeriesSearch', 'seriesId': 54},
        {
          'name': 'RefreshSeries',
          'seriesIds': [54],
        },
      ]);
      final bad = await hub.post('$_base/tv/54/search', body: {'scope': 'all'});
      expect(bad.status, 422);
    });

    test('GET /library/commands polls command/{id}', () async {
      hub.fakes.on(
        ServiceId.sonarr,
        'GET',
        '/api/v3/command/937782',
        (_) => FakeResponse.json(
          (fixture('arr/sonarr_command.json')! as List).first,
        ),
      );
      final r = await hub.get(
        '/api/v1/library/commands/sonarr/937782',
        as: TestAs.member,
      );
      expect(r.status, 200);
      expect(r.map['command'], containsPair('status', 'completed'));
      expect(r.map['command'], containsPair('result', 'successful'));
      final unknown = await hub.get('/api/v1/library/commands/sonarr/1');
      expect(unknown.status, 404);
    });
  });

  group('DELETE /library/tv/{id}', () {
    test('428 with the impact until confirmed, then DELETE series', () async {
      hub.fakes.on(
        ServiceId.sonarr,
        'DELETE',
        '/api/v3/series/54',
        (_) => FakeResponse(200),
      );
      final keep = await hub.delete('$_base/tv/54');
      expect(keep.status, 428);
      expect(
        readMap(readMap(keep.map['error'])!['details'])!['impact'],
        "Removes 'That Time I Got Reincarnated as a Slime' from Sonarr; "
        'files stay on disk',
      );
      final withFiles = await hub.delete('$_base/tv/54?deleteFiles=true');
      expect(
        readMap(readMap(withFiles.map['error'])!['details'])!['impact'],
        "Removes 'That Time I Got Reincarnated as a Slime' from Sonarr and "
        'permanently deletes 48 files (71.1 GB)',
      );
      expect(
        callsOf(
          hub.fakes,
          ServiceId.sonarr,
          '/api/v3/series/54',
          method: 'DELETE',
        ),
        isEmpty,
      );

      final ok = await hub.delete(
        '$_base/tv/54?deleteFiles=true&addExclusion=true&confirm=true',
      );
      expect(ok.status, 204);
      final call = callsOf(
        hub.fakes,
        ServiceId.sonarr,
        '/api/v3/series/54',
        method: 'DELETE',
      ).single;
      expect(call.query, {
        'deleteFiles': ['true'],
        'addImportListExclusion': ['true'],
      });
    });

    test('deleting files is refused when the policy forbids it', () async {
      final strict = TestHub(
        policyYaml: 'policy:\n  allowArrDeleteFiles: false\n',
      );
      addTearDown(strict.close);
      stubLibraryUpstreams(strict.fakes);
      final r = await strict.delete(
        '$_base/tv/54?deleteFiles=true&confirm=true',
      );
      expect(r.status, 403);
      expect(r.errorCode, 'policy_denied');
      final member = await hub.delete(
        '$_base/tv/54?confirm=true',
        as: TestAs.member,
      );
      expect(member.status, 403);
    });
  });
}
