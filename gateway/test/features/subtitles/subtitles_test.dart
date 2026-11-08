import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../support/test_hub.dart';

const _bazarr = ServiceId.bazarr;

/// A sample from this slice's `fixtures/` (`*.synthetic.json`, shaped like
/// integrations/downloads.md §4).
Object? _synthetic(String name) {
  for (final base in const [
    'test/features/subtitles/fixtures',
    'gateway/test/features/subtitles/fixtures',
  ]) {
    final f = File('$base/$name');
    if (f.existsSync()) return jsonDecode(f.readAsStringSync());
  }
  throw StateError('synthetic fixture $name not found');
}

/// Registers the five calls behind `GET /subtitles/summary` with the
/// captured fixtures.
void _summaryFixtures(FakeUpstreams f) {
  f
    ..onFixture(_bazarr, 'GET', '/api/badges', 'downloads/bazarr_badges.json')
    ..onFixture(
      _bazarr,
      'GET',
      '/api/providers',
      'downloads/bazarr_providers.json',
    )
    ..onFixture(
      _bazarr,
      'GET',
      '/api/system/health',
      'downloads/bazarr_system_health.json',
    )
    ..onFixture(
      _bazarr,
      'GET',
      '/api/system/status',
      'downloads/bazarr_system_status.json',
    )
    ..onFixture(
      _bazarr,
      'GET',
      '/api/system/tasks',
      'downloads/bazarr_system_tasks.json',
    );
}

/// Records Bazarr writes and answers 204 like Bazarr 1.6.
void _acceptWrites(FakeUpstreams f) {
  for (final method in const ['PATCH', 'POST']) {
    f.on(_bazarr, method, RegExp('.*'), (_) => FakeResponse(204));
  }
}

List<RecordedCall> _calls(TestHub hub, String method, String path) => [
  for (final c in hub.fakes.callsTo(_bazarr))
    if (c.method == method && c.path == path) c,
];

void main() {
  late TestHub hub;

  setUp(() => hub = TestHub());
  tearDown(() => hub.close());

  group('GET /subtitles/summary', () {
    test('maps badges, providers, health, status and tasks', () async {
      _summaryFixtures(hub.fakes);
      final r = await hub.get('/api/v1/subtitles/summary', as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      final s = SubtitlesSummary.fromJson(r.map);
      expect(s.missingEpisodes, 111);
      expect(s.missingMovies, 3);
      // The badge says 1, but every provider is Good (API.md §12.5).
      expect(s.throttledProviders, 0);
      expect(s.providers, hasLength(5));
      expect(s.providers.first.name, 'animesubinfo');
      expect(s.providers.first.ok, isTrue);
      expect(s.providers.first.retry, isNull, reason: '"-" means no retry');
      expect(s.signalr.sonarr, SubtitleSignalrState.live);
      expect(s.signalr.radarr, SubtitleSignalrState.live);
      expect(s.health, isEmpty);
      expect(s.version, '1.6.2');
      expect(s.tasks, hasLength(5));
      expect(s.tasks.first.id, 'update_release');
      expect(s.tasks.first.interval, 'every 3 hours');
      expect(s.tasks.first.nextRun, 'in 20 minutes');
      expect(s.tasks.first.running, isFalse);
      expect(r.map['signalr'], {'sonarr': 'live', 'radarr': 'live'});

      // Every call carries the Bazarr key header.
      for (final c in hub.fakes.callsTo(_bazarr)) {
        expect(c.headers['x-api-key'], '***');
      }
      // Cached for 60 s.
      final before = hub.fakes.callsTo(_bazarr).length;
      expect(before, 5);
      await hub.get('/api/v1/subtitles/summary');
      expect(hub.fakes.callsTo(_bazarr), hasLength(before));
      hub.clock.advance(const Duration(seconds: 61));
      await hub.get('/api/v1/subtitles/summary');
      expect(hub.fakes.callsTo(_bazarr), hasLength(before * 2));
    });

    test('throttled providers, health issues and SignalR down', () async {
      _summaryFixtures(hub.fakes);
      hub.fakes
        ..on(
          _bazarr,
          'GET',
          '/api/badges',
          (_) => FakeResponse.json(
            _synthetic('bazarr_badges_signalr_down.synthetic.json'),
          ),
        )
        ..on(
          _bazarr,
          'GET',
          '/api/providers',
          (_) => FakeResponse.json(
            _synthetic('bazarr_providers_throttled.synthetic.json'),
          ),
        )
        ..on(
          _bazarr,
          'GET',
          '/api/system/health',
          (_) => FakeResponse.json(
            _synthetic('bazarr_system_health_issue.synthetic.json'),
          ),
        );
      final r = await hub.get('/api/v1/subtitles/summary');
      expect(r.status, 200, reason: r.body);
      final s = SubtitlesSummary.fromJson(r.map);
      expect(s.throttledProviders, 1);
      final throttled = s.providers.singleWhere((p) => !p.ok);
      expect(throttled.name, 'tvsubtitles');
      expect(throttled.status, 'TooManyRequests');
      expect(throttled.retry, 'in 2 hours');
      expect(s.signalr.sonarr, SubtitleSignalrState.down);
      expect(s.health.single.object, 'Sonarr');
    });

    test('a failing status call only drops the version', () async {
      _summaryFixtures(hub.fakes);
      hub.fakes.on(
        _bazarr,
        'GET',
        '/api/system/status',
        (_) => FakeResponse.json({'message': 'boom'}, status: 500),
      );
      final r = await hub.get('/api/v1/subtitles/summary');
      expect(r.status, 200, reason: r.body);
      expect(r.map.containsKey('version'), isFalse);
      expect(r.map['missingEpisodes'], 111);
    });

    test('a rejected key is upstream_auth_failed', () async {
      _summaryFixtures(hub.fakes);
      hub.fakes.onFixture(
        _bazarr,
        'GET',
        '/api/badges',
        'downloads/bazarr_error_401.json',
        status: 401,
      );
      final r = await hub.get('/api/v1/subtitles/summary');
      expect(r.status, 502);
      expect(r.errorCode, 'upstream_auth_failed');
      expect(r.body, isNot(contains('test-bazarr-key')));
    });

    test('serves the cached summary when Bazarr goes away', () async {
      _summaryFixtures(hub.fakes);
      expect((await hub.get('/api/v1/subtitles/summary')).status, 200);
      hub.fakes.on(
        _bazarr,
        'GET',
        '/api/badges',
        (_) => FakeResponse.json({'message': 'down'}, status: 503),
      );
      hub.clock.advance(const Duration(seconds: 90));
      final r = await hub.get('/api/v1/subtitles/summary');
      expect(r.status, 200);
      expect(r.map['missingEpisodes'], 111);
    });
  });

  group('dashboard card', () {
    test('SubtitlesCard with the raw missingEpisodes key', () async {
      _summaryFixtures(hub.fakes);
      final r = await hub.get(
        '/api/v1/dashboard?cards=subtitles',
        as: TestAs.member,
      );
      expect(r.status, 200, reason: r.body);
      final section = readMap(readMap(r.map['cards'])!['subtitles'])!;
      expect(section['status'], 'ok');
      expect(section['data'], {
        'missingEpisodes': 111,
        'missingMovies': 3,
        'throttledProviders': 0,
        'signalrDown': false,
      });
      expect(r.map['alerts'], isEmpty);
    });

    test('alerts for SignalR down and each health issue', () async {
      _summaryFixtures(hub.fakes);
      hub.fakes
        ..on(
          _bazarr,
          'GET',
          '/api/badges',
          (_) => FakeResponse.json(
            _synthetic('bazarr_badges_signalr_down.synthetic.json'),
          ),
        )
        ..on(
          _bazarr,
          'GET',
          '/api/system/health',
          (_) => FakeResponse.json(
            _synthetic('bazarr_system_health_issue.synthetic.json'),
          ),
        );
      final r = await hub.get('/api/v1/dashboard?cards=subtitles');
      final card = SubtitlesCard.fromJson(
        readMap(readMap(readMap(r.map['cards'])!['subtitles'])!['data'])!,
      );
      expect(card.signalrDown, isTrue);
      expect(card.missingEpisodes, 2);
      final alerts = readList(r.map['alerts'], Alert.fromJson);
      final byId = {for (final a in alerts) a.id: a};
      expect(byId.keys, containsAll(['bazarr.signalr', 'bazarr.health.0']));
      final signalr = byId['bazarr.signalr']!;
      expect(signalr.severity, AlertSeverity.warning);
      expect(signalr.source, ServiceId.bazarr);
      expect(signalr.title, 'Bazarr lost its live link to Sonarr');
      expect(signalr.route, '/subtitles');
      final health = byId['bazarr.health.0']!;
      expect(health.severity, AlertSeverity.warning);
      expect(health.title, contains('Unable to connect to Sonarr'));
      expect(health.feature, 'subtitles');
    });

    test('disabled when Bazarr is not configured', () async {
      final h = TestHub(unconfigured: {_bazarr});
      addTearDown(h.close);
      final r = await h.get('/api/v1/dashboard?cards=subtitles');
      final section = readMap(readMap(r.map['cards'])!['subtitles'])!;
      expect(section['status'], 'disabled');
      final summary = await h.get('/api/v1/subtitles/summary');
      expect(summary.status, 503);
      expect(summary.errorCode, 'service_not_configured');
    });
  });

  group('GET /subtitles/wanted', () {
    test('episodes: paging, labels and Sonarr posters', () async {
      hub.fakes.onFixture(
        _bazarr,
        'GET',
        '/api/episodes/wanted',
        'downloads/bazarr_episodes_wanted.json',
      );
      final r = await hub.get(
        '/api/v1/subtitles/wanted?type=episodes&page=2&pageSize=5',
        as: TestAs.member,
      );
      expect(r.status, 200, reason: r.body);
      final call = _calls(hub, 'GET', '/api/episodes/wanted').single;
      expect(call.query, {
        'start': ['5'],
        'length': ['5'],
      });
      final page = PagedList.fromJson(r.map, WantedSubtitle.fromJson);
      expect(page.page, 2);
      expect(page.pageSize, 5);
      expect(page.total, 111);
      expect(page.hasMore, isTrue);
      final first = page.items.first;
      expect(first.type, SubtitleMediaType.episode);
      expect(first.title, 'Gachiakuta');
      expect(first.episodeLabel, 'S01E11');
      expect(first.episodeTitle, "Amo's Hospitality");
      expect(first.seriesId, 164);
      expect(first.episodeId, 7941);
      expect(first.seriesType, 'anime');
      expect(
        first.missing.single,
        const SubtitleLanguage(code: 'en', name: 'English'),
      );
      expect(
        first.posterPath,
        hub.ctx.images.arr(ArrService.sonarr, 164, 'poster', size: 250),
      );
      expect(first.posterPath, startsWith('/api/v1/img/arr/sonarr/164/poster'));
      expect(page.items[3].episodeLabel, 'S02E23');
    });

    test('movies: Radarr ids and posters, no episode fields', () async {
      hub.fakes.onFixture(
        _bazarr,
        'GET',
        '/api/movies/wanted',
        'downloads/bazarr_movies_wanted.json',
      );
      final r = await hub.get('/api/v1/subtitles/wanted?type=movies');
      expect(r.status, 200, reason: r.body);
      final call = _calls(hub, 'GET', '/api/movies/wanted').single;
      expect(call.query, {
        'start': ['0'],
        'length': ['25'],
      });
      final page = PagedList.fromJson(r.map, WantedSubtitle.fromJson);
      expect(page.total, 3);
      expect(page.hasMore, isFalse);
      final hotel = page.items.first;
      expect(hotel.type, SubtitleMediaType.movie);
      expect(hotel.title, 'Hotel');
      expect(hotel.movieId, 190);
      expect(hotel.posterPath, startsWith('/api/v1/img/arr/radarr/190/poster'));
      final json = readList(r.map['items'], (m) => m).first;
      expect(json.containsKey('episodeLabel'), isFalse);
      expect(json.containsKey('seriesId'), isFalse);
    });

    test('caches 30 s per page', () async {
      hub.fakes.onFixture(
        _bazarr,
        'GET',
        '/api/movies/wanted',
        'downloads/bazarr_movies_wanted.json',
      );
      await hub.get('/api/v1/subtitles/wanted?type=movies');
      await hub.get('/api/v1/subtitles/wanted?type=movies');
      expect(_calls(hub, 'GET', '/api/movies/wanted'), hasLength(1));
      await hub.get('/api/v1/subtitles/wanted?type=movies&page=2');
      expect(_calls(hub, 'GET', '/api/movies/wanted'), hasLength(2));
      hub.clock.advance(const Duration(seconds: 31));
      await hub.get('/api/v1/subtitles/wanted?type=movies');
      expect(_calls(hub, 'GET', '/api/movies/wanted'), hasLength(3));
    });

    test('pageSize is capped at 100 and length is always sent', () async {
      hub.fakes.onFixture(
        _bazarr,
        'GET',
        '/api/episodes/wanted',
        'downloads/bazarr_episodes_wanted.json',
      );
      final r = await hub.get(
        '/api/v1/subtitles/wanted?type=episodes&pageSize=500',
      );
      expect(r.status, 200);
      expect(r.map['pageSize'], 100);
      expect(_calls(hub, 'GET', '/api/episodes/wanted').single.query, {
        'start': ['0'],
        'length': ['100'],
      });
    });

    test('type is required and validated', () async {
      for (final q in ['', '?type=series', '?type=episodes&page=0']) {
        final r = await hub.get('/api/v1/subtitles/wanted$q');
        expect(r.status, 400, reason: q);
        expect(r.errorCode, 'bad_request');
      }
      expect(hub.fakes.callsTo(_bazarr), isEmpty);
    });

    test('an upstream 404 is not a hub not_found', () async {
      hub.fakes.on(
        _bazarr,
        'GET',
        '/api/episodes/wanted',
        (_) => FakeResponse.json({'message': 'nope'}, status: 404),
      );
      final r = await hub.get('/api/v1/subtitles/wanted?type=episodes');
      expect(r.status, 502);
      expect(r.errorCode, 'upstream_error');
    });

    test('a validation error from Bazarr', () async {
      hub.fakes.onFixture(
        _bazarr,
        'GET',
        '/api/episodes/wanted',
        'downloads/bazarr_error_400.json',
        status: 400,
      );
      final r = await hub.get('/api/v1/subtitles/wanted?type=episodes');
      expect(r.status, 422);
      expect(r.errorCode, 'validation_failed');
    });
  });

  group('GET /subtitles/history', () {
    test('episodes: action, language, score and UTC time', () async {
      hub.fakes.onFixture(
        _bazarr,
        'GET',
        '/api/episodes/history',
        'downloads/bazarr_episodes_history.json',
      );
      final r = await hub.get(
        '/api/v1/subtitles/history?type=episodes&pageSize=5',
        as: TestAs.member,
      );
      expect(r.status, 200, reason: r.body);
      expect(_calls(hub, 'GET', '/api/episodes/history').single.query, {
        'start': ['0'],
        'length': ['5'],
      });
      final page = PagedList.fromJson(r.map, SubtitleHistoryItem.fromJson);
      expect(page.total, 2226);
      expect(page.hasMore, isTrue);
      final h = page.items.first;
      expect(h.type, SubtitleMediaType.episode);
      expect(h.title, 'That Time I Got Reincarnated as a Slime');
      expect(h.episodeLabel, 'S03E17');
      expect(h.action, SubtitleHistoryAction.downloaded);
      expect(h.language?.code, 'en');
      expect(h.provider, 'embeddedsubtitles');
      expect(h.score, '100.0%');
      expect(h.description, startsWith('English subtitles downloaded'));
      expect(h.at, DateTime.utc(2026, 11, 8, 7, 53, 14));
      expect(
        readList(r.map['items'], (m) => m).first['at'],
        '2026-11-08T07:53:14Z',
      );
      // Paths and Bazarr internals never leave the gateway.
      expect(r.body, isNot(contains('/data/tvshows')));
      expect(r.body, isNot(contains('subs_id')));
    });

    test('movies', () async {
      hub.fakes.onFixture(
        _bazarr,
        'GET',
        '/api/movies/history',
        'downloads/bazarr_movies_history.json',
      );
      final r = await hub.get('/api/v1/subtitles/history?type=movies');
      expect(r.status, 200, reason: r.body);
      final page = PagedList.fromJson(r.map, SubtitleHistoryItem.fromJson);
      expect(page.total, 435);
      final h = page.items.first;
      expect(h.type, SubtitleMediaType.movie);
      expect(h.title, 'Dune: Part Two');
      expect(h.episodeLabel, isNull);
      expect(h.at, DateTime.utc(2026, 11, 6, 9, 26, 8));
      expect(r.body, isNot(contains('/data/movies')));
    });

    test('type defaults to episodes and is validated', () async {
      hub.fakes.onFixture(
        _bazarr,
        'GET',
        '/api/episodes/history',
        'downloads/bazarr_episodes_history.json',
      );
      final r = await hub.get('/api/v1/subtitles/history');
      expect(r.status, 200, reason: r.body);
      expect(_calls(hub, 'GET', '/api/episodes/history').single.query, {
        'start': ['0'],
        'length': ['25'],
      });
      final bad = await hub.get('/api/v1/subtitles/history?type=series');
      expect(bad.status, 400);
      expect(bad.errorCode, 'bad_request');
    });
  });

  group('GET /subtitles/jobs', () {
    test('defaults to running and maps progress', () async {
      hub.fakes.on(
        _bazarr,
        'GET',
        '/api/system/jobs',
        (_) => FakeResponse.json(
          _synthetic('bazarr_system_jobs_running.synthetic.json'),
        ),
      );
      final r = await hub.get('/api/v1/subtitles/jobs', as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      expect(_calls(hub, 'GET', '/api/system/jobs').single.query, {
        'status': ['running'],
      });
      final jobs = ItemList.fromJson(r.map, SubtitleJob.fromJson).items;
      expect(jobs, hasLength(2));
      expect(jobs.first.id, 31);
      expect(jobs.first.status, 'running');
      expect(jobs.first.progress, 0.25);
      expect(jobs.first.message, "Amo's Hospitality");
      expect(jobs.first.lastRunAt, DateTime.utc(2026, 11, 8, 8, 59, 58, 120));
      expect(jobs.last.progress, isNull, reason: 'not a progress job');
      expect(jobs.last.message, isNull);
      expect(jobs.last.lastRunAt, isNull);

      // Never cached: the app polls it every 3 s.
      await hub.get('/api/v1/subtitles/jobs');
      expect(_calls(hub, 'GET', '/api/system/jobs'), hasLength(2));
    });

    test('completed jobs from the capture', () async {
      hub.fakes.onFixture(
        _bazarr,
        'GET',
        '/api/system/jobs',
        'downloads/bazarr_system_jobs.json',
      );
      final r = await hub.get('/api/v1/subtitles/jobs?status=completed');
      expect(r.status, 200);
      expect(_calls(hub, 'GET', '/api/system/jobs').single.query, {
        'status': ['completed'],
      });
      final jobs = ItemList.fromJson(r.map, SubtitleJob.fromJson).items;
      expect(jobs, hasLength(5));
      expect(jobs.first.isActive, isFalse);
      expect(jobs.first.progress, isNull);
      expect(jobs.first.message, '1 subtitle(s) downloaded');
    });

    test('rejects unknown statuses', () async {
      final r = await hub.get('/api/v1/subtitles/jobs?status=stuck');
      expect(r.status, 400);
      expect(hub.fakes.callsTo(_bazarr), isEmpty);
    });
  });

  group('POST /subtitles/search', () {
    test('episode: PATCH with the parameters in the query string', () async {
      _acceptWrites(hub.fakes);
      final r = await hub.post(
        '/api/v1/subtitles/search',
        body: const SubtitleSearchRequest(
          type: SubtitleMediaType.episode,
          seriesId: 164,
          episodeId: 7941,
          language: 'en',
          hi: true,
        ).toJson(),
      );
      expect(r.status, 202, reason: r.body);
      expect(r.map, {'queued': true});
      final call = _calls(hub, 'PATCH', '/api/episodes/subtitles').single;
      expect(call.query, {
        'seriesid': ['164'],
        'episodeid': ['7941'],
        'language': ['en'],
        'forced': ['false'],
        'hi': ['true'],
      });
      expect(call.body, isEmpty);
    });

    test('movie: PATCH /api/movies/subtitles with radarrid', () async {
      _acceptWrites(hub.fakes);
      final r = await hub.post(
        '/api/v1/subtitles/search',
        body: {
          'type': 'movie',
          'movieId': 190,
          'language': 'en',
          'forced': true,
          'hi': false,
        },
      );
      expect(r.status, 202, reason: r.body);
      expect(_calls(hub, 'PATCH', '/api/movies/subtitles').single.query, {
        'radarrid': ['190'],
        'language': ['en'],
        'forced': ['true'],
        'hi': ['false'],
      });
    });

    test('invalidates the wanted lists', () async {
      _acceptWrites(hub.fakes);
      hub.fakes.onFixture(
        _bazarr,
        'GET',
        '/api/movies/wanted',
        'downloads/bazarr_movies_wanted.json',
      );
      await hub.get('/api/v1/subtitles/wanted?type=movies');
      await hub.post(
        '/api/v1/subtitles/search',
        body: {'type': 'movie', 'movieId': 190, 'language': 'en'},
      );
      await hub.get('/api/v1/subtitles/wanted?type=movies');
      expect(_calls(hub, 'GET', '/api/movies/wanted'), hasLength(2));
    });

    test('validation', () async {
      _acceptWrites(hub.fakes);
      final missing = await hub.post(
        '/api/v1/subtitles/search',
        body: {'type': 'episode', 'seriesId': 164, 'language': 'en'},
      );
      expect(missing.status, 422);
      expect(missing.errorCode, 'validation_failed');
      final fields = readList(
        readMap(missing.map['error'])!['fields'],
        ApiFieldError.fromJson,
      );
      expect(fields.map((f) => f.field), ['episodeId']);

      final badLanguage = await hub.post(
        '/api/v1/subtitles/search',
        body: {'type': 'movie', 'movieId': 1, 'language': 'en&x=1'},
      );
      expect(badLanguage.status, 422);

      final badFlag = await hub.post(
        '/api/v1/subtitles/search',
        body: {'type': 'movie', 'movieId': 1, 'language': 'en', 'hi': 'maybe'},
      );
      expect(badFlag.status, 422);

      final badType = await hub.post(
        '/api/v1/subtitles/search',
        body: {'type': 'series', 'seriesId': 1, 'language': 'en'},
      );
      expect(badType.status, 400);

      final notJson = await hub.post('/api/v1/subtitles/search', body: 'nope');
      expect(notJson.status, 400);
      expect(hub.fakes.callsTo(_bazarr), isEmpty);
    });

    test('members are refused', () async {
      final r = await hub.post(
        '/api/v1/subtitles/search',
        as: TestAs.member,
        body: {'type': 'movie', 'movieId': 190, 'language': 'en'},
      );
      expect(r.status, 403);
      expect(hub.fakes.callsTo(_bazarr), isEmpty);
    });

    test('is audited', () async {
      _acceptWrites(hub.fakes);
      await hub.post(
        '/api/v1/subtitles/search',
        body: {'type': 'movie', 'movieId': 190, 'language': 'en'},
      );
      await hub.hub.audit.flush();
      final entries = await hub.hub.audit.query();
      expect(entries.items.map((e) => e.action), contains('subtitles.search'));
    });
  });

  group('POST /subtitles/search-item', () {
    test('series and movie', () async {
      _acceptWrites(hub.fakes);
      final series = await hub.post(
        '/api/v1/subtitles/search-item',
        body: {'type': 'series', 'id': 164},
      );
      expect(series.status, 202, reason: series.body);
      expect(series.map, {'queued': true});
      expect(_calls(hub, 'PATCH', '/api/series').single.query, {
        'seriesid': ['164'],
        'action': ['search-missing'],
      });
      final movie = await hub.post(
        '/api/v1/subtitles/search-item',
        body: {'type': 'movie', 'id': 190},
      );
      expect(movie.status, 202);
      expect(_calls(hub, 'PATCH', '/api/movies').single.query, {
        'radarrid': ['190'],
        'action': ['search-missing'],
      });
    });

    test('a path mapping problem surfaces Bazarr\'s message', () async {
      hub.fakes.on(
        _bazarr,
        'PATCH',
        '/api/series',
        (_) => FakeResponse.json({
          'message': 'Series directory not found. Path mapping issue?',
        }, status: 500),
      );
      final r = await hub.post(
        '/api/v1/subtitles/search-item',
        body: {'type': 'series', 'id': 164},
      );
      expect(r.status, 502);
      expect(r.errorCode, 'upstream_error');
      expect(r.body, contains('Path mapping issue'));
    });

    test('validation', () async {
      expect(
        (await hub.post(
          '/api/v1/subtitles/search-item',
          body: {'type': 'episode', 'id': 1},
        )).status,
        400,
      );
      expect(
        (await hub.post(
          '/api/v1/subtitles/search-item',
          body: {'type': 'movie'},
        )).status,
        422,
      );
      expect(hub.fakes.callsTo(_bazarr), isEmpty);
    });
  });

  group('POST /subtitles/search-all', () {
    test('requires confirm=true and names the impact', () async {
      _summaryFixtures(hub.fakes);
      _acceptWrites(hub.fakes);
      await hub.get('/api/v1/subtitles/summary');
      final r = await hub.post(
        '/api/v1/subtitles/search-all',
        body: {'type': 'episodes'},
      );
      expect(r.status, 428);
      expect(r.errorCode, 'confirmation_required');
      final impact = readString(
        readMap(readMap(r.map['error'])!['details'])!['impact'],
      );
      expect(impact, contains('111 episodes'));
      expect(_calls(hub, 'POST', '/api/system/tasks'), isEmpty);
    });

    test('runs the wanted search task', () async {
      _acceptWrites(hub.fakes);
      final episodes = await hub.post(
        '/api/v1/subtitles/search-all',
        body: {'type': 'episodes', 'confirm': true},
      );
      expect(episodes.status, 202, reason: episodes.body);
      expect(episodes.map, {'queued': true});
      final movies = await hub.post(
        '/api/v1/subtitles/search-all?confirm=true',
        body: {'type': 'movies'},
      );
      expect(movies.status, 202);
      expect(
        [
          for (final c in _calls(hub, 'POST', '/api/system/tasks'))
            c.query['taskid']!.single,
        ],
        [
          'wanted_search_missing_subtitles_series',
          'wanted_search_missing_subtitles_movies',
        ],
      );
    });

    test('rejects unknown types before asking for confirmation', () async {
      final r = await hub.post(
        '/api/v1/subtitles/search-all',
        body: {'type': 'books', 'confirm': true},
      );
      expect(r.status, 400);
    });
  });

  test('POST /subtitles/providers/reset', () async {
    _acceptWrites(hub.fakes);
    final r = await hub.post('/api/v1/subtitles/providers/reset');
    expect(r.status, 204, reason: r.body);
    expect(_calls(hub, 'POST', '/api/providers').single.query, {
      'action': ['reset'],
    });
    final member = await hub.post(
      '/api/v1/subtitles/providers/reset',
      as: TestAs.member,
    );
    expect(member.status, 403);
  });

  group('POST /subtitles/tasks/{taskId}/run', () {
    test('runs a task from the cached list', () async {
      _summaryFixtures(hub.fakes);
      _acceptWrites(hub.fakes);
      await hub.get('/api/v1/subtitles/summary');
      expect(_calls(hub, 'GET', '/api/system/tasks'), hasLength(1));
      final r = await hub.post('/api/v1/subtitles/tasks/update_series/run');
      expect(r.status, 202, reason: r.body);
      expect(r.map, {'queued': true});
      expect(_calls(hub, 'POST', '/api/system/tasks').single.query, {
        'taskid': ['update_series'],
      });
      // Validated against the cached list, which the run then invalidates.
      expect(_calls(hub, 'GET', '/api/system/tasks'), hasLength(1));
      await hub.post('/api/v1/subtitles/tasks/update_movies/run');
      expect(_calls(hub, 'GET', '/api/system/tasks'), hasLength(2));
      expect(_calls(hub, 'POST', '/api/system/tasks'), hasLength(2));
    });

    test('unknown task ids are 404 and never sent to Bazarr', () async {
      _summaryFixtures(hub.fakes);
      _acceptWrites(hub.fakes);
      final r = await hub.post('/api/v1/subtitles/tasks/rm_rf/run');
      expect(r.status, 404);
      expect(r.errorCode, 'not_found');
      expect(_calls(hub, 'POST', '/api/system/tasks'), isEmpty);
    });

    test('ids outside the pattern do not match the route', () async {
      final r = await hub.post('/api/v1/subtitles/tasks/a.b/run');
      expect(r.status, 404);
      expect(hub.fakes.callsTo(_bazarr), isEmpty);
    });
  });
}
