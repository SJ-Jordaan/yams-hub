import 'dart:convert';

import 'package:test/test.dart';

import '../../support/test_hub.dart';
import 'library_fakes.dart';

const _base = '/api/v1/library/movies';

void main() {
  late TestHub hub;

  setUp(() {
    hub = TestHub();
    stubLibraryUpstreams(hub.fakes);
    stubCommands(hub.fakes, ServiceId.radarr);
  });
  tearDown(() => hub.close());

  List<JsonMap> items(TestResponse r) => [
    for (final i in r.map['items']! as List) i as JsonMap,
  ];

  test(
    'GET /library/movies: slim list, Radarr filters in the gateway',
    () async {
      final r = await hub.get(_base, as: TestAs.member);
      expect(r.status, 200);
      final zoo = items(r).firstWhere((m) => m['id'] == 1);
      expect(zoo['hasFile'], isTrue);
      expect(zoo['releaseDate'], '2026-01-26');
      expect(zoo['quality'], 'WEBRip-1080p');
      expect(zoo['qualityProfileName'], 'HD Bluray + WEB');
      expect(zoo.containsKey('alternateTitles'), isFalse);
      expect(zoo.containsKey('keywords'), isFalse);
      expect(r.body, isNot(contains('/data/movies')));

      Future<List<Object?>> ids(String query) async =>
          items(await hub.get('$_base?$query')).map((m) => m['id']).toList();
      expect(await ids('filter=missing'), [227]);
      expect(await ids('filter=unreleased'), [204, 246]);
      expect(await ids('filter=available'), [8, 1]);
      expect(await ids('filter=cutoffUnmet'), isNotEmpty);
      expect(await ids('sort=year&order=desc&filter=available'), [1, 8]);
      expect((await hub.get('$_base?filter=wanted')).status, 400);
      expect(
        callsOf(hub.fakes, ServiceId.radarr, '/api/v3/movie'),
        hasLength(1),
      );
    },
  );

  test('GET /library/movies/{id}: files and queue state', () async {
    hub.fakes.on(
      ServiceId.radarr,
      'GET',
      '/api/v3/queue/details',
      (_) => FakeResponse.json(
        syntheticJson('radarr_queue_details.synthetic.json'),
      ),
    );
    final r = await hub.get('$_base/1');
    expect(r.status, 200);
    expect((r.map['movie']! as Map)['title'], 'Zootopia 2');
    final file = (r.map['files']! as List).single as Map;
    expect(file['id'], 947);
    expect(file.containsKey('path'), isFalse);
    expect((r.map['queue']! as Map)['progress'], 0.75);
    expect((r.map['links']! as Map)['imdb'], contains('tt26443597'));
    final files = callsOf(hub.fakes, ServiceId.radarr, '/api/v3/moviefile');
    expect(files.single.query['movieId'], ['1']);

    final missing = await hub.get('$_base/424242');
    expect(missing.status, 404);
  });

  test('GET /library/movies/{id}/history', () async {
    final r = await hub.get('$_base/9/history');
    expect(r.status, 200);
    expect(r.map['total'], 940);
    final first = (r.map['items']! as List).first as Map;
    expect(first['service'], 'radarr');
    expect(first['type'], 'imported');
    final call = callsOf(hub.fakes, ServiceId.radarr, '/api/v3/history').single;
    expect(call.query['movieIds'], ['9']);
    expect(call.query['includeMovie'], ['false']);
  });

  test('GET /library/movies/lookup', () async {
    expect((await hub.get('$_base/lookup')).status, 400);
    final r = await hub.get('$_base/lookup?term=dune');
    expect(r.status, 200);
    final list = items(r);
    expect(list.first['inLibrary'], isTrue);
    expect(list.first['libraryId'], 8);
    expect(list.first['hasFile'], isTrue);
    expect(list.first['suggested'], {
      'qualityProfileId': 7,
      'rootFolderPath': '/data/movies',
      'minimumAvailability': 'released',
    });
    expect(list[2]['inLibrary'], isFalse);
  });

  group('POST /library/movies', () {
    test('lookup/tmdb, override, POST movie', () async {
      hub.fakes
        ..onFixture(
          ServiceId.radarr,
          'GET',
          '/api/v3/movie/lookup/tmdb',
          'arr/radarr_movie_lookup_tmdb.json',
        )
        ..on(ServiceId.radarr, 'POST', '/api/v3/movie', (req) {
          final b = req.json()! as Map<String, Object?>;
          return FakeResponse.json({...b, 'id': 400}, status: 201);
        });
      final r = await hub.post(
        _base,
        body: {
          'tmdbId': 693134,
          'qualityProfileId': 7,
          'rootFolderPath': '/data/movies',
          'monitor': 'movieOnly',
          'searchForMovie': true,
        },
      );
      expect(r.status, 201, reason: r.body);
      expect(r.map['id'], 400);
      expect(r.map['title'], 'Dune: Part Two');
      final lookup = callsOf(
        hub.fakes,
        ServiceId.radarr,
        '/api/v3/movie/lookup/tmdb',
      ).single;
      expect(lookup.query['tmdbId'], ['693134']);
      final sent = jsonDecode(
        callsOf(
          hub.fakes,
          ServiceId.radarr,
          '/api/v3/movie',
          method: 'POST',
        ).single.body,
      ) as Map<String, Object?>;
      expect(sent['minimumAvailability'], 'released');
      expect(sent['monitored'], isTrue);
      expect(sent['qualityProfileId'], 7);
      expect(sent['rootFolderPath'], '/data/movies');
      expect(sent['addOptions'], {
        'monitor': 'movieOnly',
        'searchForMovie': true,
        'addMethod': 'manual',
      });
    });

    test('monitor none adds unmonitored; duplicates are 409', () async {
      final found = fixtureCopy('arr/radarr_movie_lookup_tmdb.json')! as Map;
      hub.fakes
        ..on(
          ServiceId.radarr,
          'GET',
          '/api/v3/movie/lookup/tmdb',
          (_) => FakeResponse.json(found),
        )
        ..on(
          ServiceId.radarr,
          'POST',
          '/api/v3/movie',
          (_) => FakeResponse.json([
            {
              'propertyName': 'TmdbId',
              'errorMessage': 'This movie has already been added',
            },
          ], status: 400),
        )
        ..on(
          ServiceId.radarr,
          'GET',
          '/api/v3/movie',
          (_) => FakeResponse.json([
            {'id': 9, 'tmdbId': 693134, 'title': 'Dune: Part Two'},
          ]),
        );
      final r = await hub.post(
        _base,
        body: {
          'tmdbId': 693134,
          'qualityProfileId': 7,
          'rootFolderPath': '/data/movies',
          'monitor': 'none',
        },
      );
      expect(r.status, 409);
      expect(r.errorCode, 'already_exists');
      expect(readMap(r.map['error'])!['details'], {'libraryId': 9});
      final sent = jsonDecode(
        callsOf(
          hub.fakes,
          ServiceId.radarr,
          '/api/v3/movie',
          method: 'POST',
        ).single.body,
      ) as Map<String, Object?>;
      expect(sent['monitored'], isFalse);
    });
  });

  test('PATCH movie uses movie/editor', () async {
    hub.fakes.on(
      ServiceId.radarr,
      'PUT',
      '/api/v3/movie/editor',
      (_) => FakeResponse(202),
    );
    final r = await hub.patch(
      '$_base/1',
      body: {'monitored': false, 'minimumAvailability': 'inCinemas'},
    );
    expect(r.status, 200);
    expect(r.map['id'], 1);
    expect(
      jsonDecode(
        callsOf(
          hub.fakes,
          ServiceId.radarr,
          '/api/v3/movie/editor',
        ).single.body,
      ),
      {
        'movieIds': [1],
        'monitored': false,
        'minimumAvailability': 'inCinemas',
      },
    );
    final bad = await hub.patch('$_base/1', body: {'minimumAvailability': 'x'});
    expect(bad.status, 422);
  });

  test('search and refresh commands', () async {
    final s = await hub.post('$_base/1/search');
    expect(s.status, 202);
    expect((s.map['command']! as Map)['service'], 'radarr');
    await hub.post('$_base/1/refresh');
    expect(
      [
        for (final c in callsOf(hub.fakes, ServiceId.radarr, '/api/v3/command'))
          jsonDecode(c.body),
      ],
      [
        {
          'name': 'MoviesSearch',
          'movieIds': [1],
        },
        {
          'name': 'RefreshMovie',
          'movieIds': [1],
        },
      ],
    );
  });

  test('DELETE uses addImportExclusion (Radarr name)', () async {
    hub.fakes.on(
      ServiceId.radarr,
      'DELETE',
      '/api/v3/movie/1',
      (_) => FakeResponse(200),
    );
    final pending = await hub.delete('$_base/1?deleteFiles=true');
    expect(pending.status, 428);
    expect(
      readMap(readMap(pending.map['error'])!['details'])!['impact'],
      "Removes 'Zootopia 2' from Radarr and permanently deletes 1 file "
      '(2.6 GB)',
    );
    final ok = await hub.delete(
      '$_base/1?deleteFiles=true&addExclusion=false&confirm=true',
    );
    expect(ok.status, 204);
    expect(
      callsOf(
        hub.fakes,
        ServiceId.radarr,
        '/api/v3/movie/1',
        method: 'DELETE',
      ).single.query,
      {
        'deleteFiles': ['true'],
        'addImportExclusion': ['false'],
      },
    );
  });
}
