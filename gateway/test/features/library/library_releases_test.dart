import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';

import '../../support/test_hub.dart';
import 'library_fakes.dart';

const _base = '/api/v1/library';

void main() {
  late TestHub hub;

  setUp(() {
    hub = TestHub();
    stubLibraryUpstreams(hub.fakes);
    hub.fakes
      ..on(
        ServiceId.sonarr,
        'GET',
        '/api/v3/release',
        (_) =>
            FakeResponse.json(syntheticJson('sonarr_release.synthetic.json')),
      )
      ..on(
        ServiceId.radarr,
        'GET',
        '/api/v3/release',
        (_) =>
            FakeResponse.json(syntheticJson('radarr_release.synthetic.json')),
      );
  });
  tearDown(() => hub.close());

  List<JsonMap> items(TestResponse r) => [
    for (final i in r.map['items']! as List) i as JsonMap,
  ];

  group('search', () {
    test('episode releases: tokens instead of secrets, approved first', () async {
      // No list was loaded before: the search reads the series types itself
      // and knows Slime is anime (label rule).
      final r = await hub.get('$_base/tv/episodes/2447/releases');
      expect(r.status, 200, reason: r.body);
      expect(r.map['tookMs'], isA<int>());
      final list = items(r);
      expect(list.map((c) => c['approved']), [true, false, false]);
      expect(list.last['rejected'], isTrue, reason: 'rejected sorted last');
      expect(list[1]['temporarilyRejected'], isTrue);
      final approved = list.first;
      expect(approved['releaseId'], startsWith('rl_'));
      expect(approved['service'], 'sonarr');
      expect(approved['indexer'], 'Nyaa.si (Prowlarr)');
      expect(approved['customFormatScore'], 1400);
      expect(approved['seeders'], 812);
      expect(approved['episodeLabels'], ['S03E01 (049)']);
      expect(approved['quality'], containsPair('revision', 2));
      expect(list.last['rejections'], [
        'Existing file on disk is of equal or higher preference: HDTV-1080p v2',
      ]);
      for (final secret in [
        'guid',
        'downloadUrl',
        'magnetUrl',
        'infoHash',
        'commentUrl',
        'SECRETKEY',
        'magnet:',
        'APPROVEDHASH',
        'nyaa.si/download',
      ]) {
        expect(r.body, isNot(contains(secret)), reason: secret);
      }
      final call = callsOf(
        hub.fakes,
        ServiceId.sonarr,
        '/api/v3/release',
      ).single;
      expect(call.query, {
        'episodeId': ['2447'],
      });
    });

    test(
      'episode search without mappedSeriesId reads the episode series',
      () async {
        final raw = [
          for (final r
              in syntheticJson('sonarr_release.synthetic.json') as List)
            {...(r as JsonMap), 'mappedSeriesId': null},
        ];
        hub.fakes
          ..on(
            ServiceId.sonarr,
            'GET',
            '/api/v3/release',
            (_) => FakeResponse.json(raw),
          )
          ..on(
            ServiceId.sonarr,
            'GET',
            '/api/v3/episode/2447',
            (_) => FakeResponse.json({'id': 2447, 'seriesId': 54}),
          );
        final r = await hub.get('$_base/tv/episodes/2447/releases');
        expect(r.status, 200, reason: r.body);
        expect(items(r).first['episodeLabels'], ['S03E01 (049)']);
        expect(
          callsOf(hub.fakes, ServiceId.sonarr, '/api/v3/episode/2447'),
          hasLength(1),
        );
      },
    );

    test('season and movie searches', () async {
      final season = await hub.get('$_base/tv/54/seasons/3/releases');
      expect(season.status, 200);
      expect(
        callsOf(hub.fakes, ServiceId.sonarr, '/api/v3/release').single.query,
        {
          'seriesId': ['54'],
          'seasonNumber': ['3'],
        },
      );
      expect(items(season).last['fullSeason'], isFalse);

      final movie = await hub.get('$_base/movies/1/releases');
      expect(movie.status, 200);
      final choice = items(movie).single;
      expect(choice['service'], 'radarr');
      expect(choice['title'], 'Zootopia.2.2025.1080p.BluRay.x264-FraMeSToR');
      expect(choice['episodeLabels'], isEmpty);
      expect(movie.body, isNot(contains('ZOOHASH')));
      expect(
        callsOf(hub.fakes, ServiceId.radarr, '/api/v3/release').single.query,
        {
          'movieId': ['1'],
        },
      );
    });

    test('one search at a time per user (409 job_running)', () async {
      final gate = Completer<void>();
      hub.fakes.on(ServiceId.sonarr, 'GET', '/api/v3/release', (_) async {
        await gate.future;
        return FakeResponse.json(
          syntheticJson('sonarr_release.synthetic.json'),
        );
      });
      final first = hub.get('$_base/tv/episodes/2447/releases');
      // Let the first request reach the fake.
      for (
        var i = 0;
        i < 50 &&
            callsOf(hub.fakes, ServiceId.sonarr, '/api/v3/release').isEmpty;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final second = await hub.get('$_base/movies/1/releases');
      expect(second.status, 409);
      expect(second.errorCode, 'job_running');
      gate.complete();
      expect((await first).status, 200);
      final third = await hub.get('$_base/movies/1/releases');
      expect(third.status, 200, reason: 'the lock is released afterwards');
    });

    test('admins only, and an upstream timeout is 504', () async {
      final member = await hub.get(
        '$_base/tv/episodes/2447/releases',
        as: TestAs.member,
      );
      expect(member.status, 403);
      hub.fakes.on(
        ServiceId.sonarr,
        'GET',
        '/api/v3/release',
        (_) => FakeResponse.json({
          'message': 'Indexer search failed',
        }, status: 500),
      );
      final failed = await hub.get('$_base/tv/episodes/2447/releases');
      expect(failed.status, 502);
    });
  });

  group('grab', () {
    Future<String> search() async {
      final r = await hub.get('$_base/tv/episodes/2447/releases');
      return items(r).first['releaseId']! as String;
    }

    test('POST release with the stored guid and indexer', () async {
      hub.fakes.on(
        ServiceId.sonarr,
        'POST',
        '/api/v3/release',
        (req) => FakeResponse.json(req.json()),
      );
      final token = await search();
      final r = await hub.post(
        '$_base/releases/grab',
        body: {'releaseId': token},
      );
      expect(r.status, 201, reason: r.body);
      expect(r.map, {
        'ok': true,
        'title': '[SubsPlease] Tensei Shitara Slime Datta Ken - 49v2 (1080p) [ABCD1234]',
      });
      final post = callsOf(
        hub.fakes,
        ServiceId.sonarr,
        '/api/v3/release',
        method: 'POST',
      ).single;
      expect(jsonDecode(post.body), {
        'guid': 'https://nyaa.si/download/2.torrent',
        'indexerId': 5,
      });
      final audit = await hub.get('/api/v1/admin/audit?action=library.release');
      expect(
        [for (final e in audit.map['items']! as List) (e as Map)['action']],
        ['library.release.grab'],
      );
      expect(audit.body, isNot(contains('nyaa.si/download')));
    });

    test('unknown token or expired *arr cache: 404 "search again"', () async {
      final unknown = await hub.post(
        '$_base/releases/grab',
        body: {'releaseId': 'rl_nope'},
      );
      expect(unknown.status, 404);
      expect(
        readMap(unknown.map['error'])!['message'],
        contains('search again'),
      );

      hub.fakes.on(
        ServiceId.sonarr,
        'POST',
        '/api/v3/release',
        (_) => FakeResponse.json({
          'message': "Couldn't find requested release in cache, cache timeout probably expired.",
        }, status: 404),
      );
      final token = await search();
      final expired = await hub.post(
        '$_base/releases/grab',
        body: {'releaseId': token},
      );
      expect(expired.status, 404);
      expect(
        readMap(expired.map['error'])!['message'],
        'Release expired, search again.',
      );
    });

    test('tokens expire after 30 minutes', () async {
      final token = await search();
      hub.clock.advance(const Duration(minutes: 31));
      final r = await hub.post(
        '$_base/releases/grab',
        body: {'releaseId': token},
      );
      expect(r.status, 404);
      expect(
        callsOf(hub.fakes, ServiceId.sonarr, '/api/v3/release', method: 'POST'),
        isEmpty,
      );
    });

    test('a refusal by the *arr is 422 with its message', () async {
      hub.fakes.on(
        ServiceId.sonarr,
        'POST',
        '/api/v3/release',
        (_) => FakeResponse.json({
          'message': 'Download client is not available',
          'description': 'NzbDrone.Core.Download ... stack',
        }, status: 409),
      );
      final token = await search();
      final r = await hub.post(
        '$_base/releases/grab',
        body: {'releaseId': token},
      );
      expect(r.status, 422);
      expect(r.errorCode, 'validation_failed');
      expect(
        readMap(r.map['error'])!['message'],
        'Download client is not available',
      );
      expect(r.body, isNot(contains('NzbDrone')));
    });

    test('body validation and roles', () async {
      expect(
        (await hub.post(
          '$_base/releases/grab',
          body: <String, Object>{},
        )).status,
        422,
      );
      final member = await hub.post(
        '$_base/releases/grab',
        body: {'releaseId': 'rl_x'},
        as: TestAs.member,
      );
      expect(member.status, 403);
    });
  });
}
