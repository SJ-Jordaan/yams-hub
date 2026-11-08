import 'dart:io';

import 'package:test/test.dart';

import '../../support/test_hub.dart';
import 'requests_test_support.dart';

void main() {
  late TestHub hub;

  setUp(() {
    hub = TestHub();
    seerrBasics(hub.fakes);
  });
  tearDown(() => hub.close());

  group('GET /discover/{slider}', () {
    test('trending: strict raw query, as admin, TitleCards', () async {
      final queries = recordQueries(
        hub.fakes,
        'GET',
        '/api/v1/discover/trending',
        (_) => FakeResponse.fixture('seerr/seerr_discover_trending.json'),
      );
      final r = await hub.get(
        '/api/v1/discover/trending?mediaType=movie&timeWindow=week',
        as: TestAs.member,
      );
      expect(r.status, 200, reason: r.body);
      expect(queries.single, 'page=1&mediaType=movie&timeWindow=week');
      final call = seerrCalls(hub.fakes, '/api/v1/discover/trending').single;
      expect(call.headers.containsKey('x-api-user'), isFalse);
      final page = TitlePage.fromJson(r.map);
      expect(page.totalPages, 500);
      expect(page.items.first.title, 'The Odyssey');
      expect(page.items.first.availability, Availability.processing);
      expect(page.items.first.posterPath, startsWith('/api/v1/img/tmdb/w342/'));
    });

    test('popular-movies passes genre; the cache is shared', () async {
      final queries = recordQueries(
        hub.fakes,
        'GET',
        '/api/v1/discover/movies',
        (_) => FakeResponse.fixture('seerr/seerr_discover_movies.json'),
      );
      final a = await hub.get(
        '/api/v1/discover/popular-movies?genre=28&page=2',
      );
      final b = await hub.get(
        '/api/v1/discover/popular-movies?genre=28&page=2',
        as: TestAs.member,
      );
      expect(a.status, 200);
      expect(b.json, a.json);
      expect(queries, ['page=2&genre=28']);
      expect(
        TitlePage.fromJson(a.map).items
            .every((c) => c.mediaType == MediaType.movie),
        isTrue,
      );
    });

    test('unknown slider and bad parameters are 400', () async {
      expect((await hub.get('/api/v1/discover/top-rated')).status, 400);
      expect((await hub.get('/api/v1/discover/trending?page=501')).status, 400);
      expect(
        (await hub.get('/api/v1/discover/trending?timeWindow=month')).status,
        400,
      );
      expect(hub.fakes.callsTo(ServiceId.seerr), isEmpty);
    });

    test('an unreachable Seerr is 503 upstream_unavailable', () async {
      hub.fakes.on(
        ServiceId.seerr,
        'GET',
        '/api/v1/discover/tv/upcoming',
        (_) => throw const SocketException('connection refused'),
      );
      final r = await hub.get('/api/v1/discover/upcoming-tv');
      expect(r.status, 503);
      expect(r.errorCode, 'upstream_unavailable');
    });

    test('a rejected key is 502 upstream_auth_failed', () async {
      hub.fakes.onFixture(
        ServiceId.seerr,
        'GET',
        '/api/v1/discover/tv',
        'seerr/seerr_error_403_bad_key.json',
        status: 403,
      );
      final r = await hub.get('/api/v1/discover/popular-tv');
      expect(r.status, 502);
      expect(r.errorCode, 'upstream_auth_failed');
    });
  });

  group('GET /discover/watchlist (per user)', () {
    test('admin and member each get their own Seerr watchlist', () async {
      hub.fakes
        ..onFixture(
          ServiceId.seerr,
          'GET',
          '/api/v1/user/1/watchlist',
          'seerr/seerr_discover_watchlist.json',
        )
        ..on(
          ServiceId.seerr,
          'GET',
          '/api/v1/user/2/watchlist',
          (_) => FakeResponse.json({
            'page': 1,
            'totalPages': 0,
            'totalResults': 0,
            'results': <Object?>[],
          }),
        )
        ..on(
          ServiceId.seerr,
          'GET',
          '/api/v1/tv/260463',
          (_) => FakeResponse.json({
            'id': 260463,
            'name': 'Daemons of the Shadow Realm',
            'firstAirDate': '2025-07-05',
            'posterPath': '/daemons.jpg',
          }),
        );
      final admin = await hub.get('/api/v1/discover/watchlist');
      expect(admin.status, 200, reason: admin.body);
      final page = TitlePage.fromJson(admin.map);
      expect(page.items.single.tmdbId, 260463);
      expect(page.items.single.title, 'Daemons of the Shadow Realm');
      expect(page.items.single.year, 2025);
      expect(page.items.single.posterPath, '/api/v1/img/tmdb/w342/daemons.jpg');
      expect(page.items.single.availability, Availability.partial);

      final member = await hub.get(
        '/api/v1/discover/watchlist',
        as: TestAs.member,
      );
      expect(member.status, 200);
      expect(TitlePage.fromJson(member.map).items, isEmpty);

      // Each call ran as the Seerr admin (no X-API-User) against its own user.
      final adminCall = seerrCalls(
        hub.fakes,
        '/api/v1/user/1/watchlist',
      ).single;
      final memberCall = seerrCalls(
        hub.fakes,
        '/api/v1/user/2/watchlist',
      ).single;
      expect(adminCall.query['page'], ['1']);
      expect(adminCall.headers.containsKey('x-api-user'), isFalse);
      expect(memberCall.headers.containsKey('x-api-user'), isFalse);

      // Cached per Seerr user.
      await hub.get('/api/v1/discover/watchlist');
      await hub.get('/api/v1/discover/watchlist', as: TestAs.member);
      expect(seerrCalls(hub.fakes, '/api/v1/user/1/watchlist'), hasLength(1));
      expect(seerrCalls(hub.fakes, '/api/v1/user/2/watchlist'), hasLength(1));
    });

    test('unlinked members get an empty page, not 403', () async {
      final h = TestHub();
      seerrBasics(h.fakes, memberLinked: false);
      try {
        final r = await h.get('/api/v1/discover/watchlist', as: TestAs.member);
        expect(r.status, 200);
        expect(r.map, {
          'page': 1,
          'totalPages': 0,
          'totalResults': 0,
          'items': <Object?>[],
        });
        expect(
          h.fakes
              .callsTo(ServiceId.seerr)
              .where((c) => c.path.endsWith('/watchlist')),
          isEmpty,
        );
      } finally {
        await h.close();
      }
    });
  });

  group('GET /search', () {
    test('encodes the query strictly and drops persons', () async {
      final queries = recordQueries(
        hub.fakes,
        'GET',
        '/api/v1/search',
        (_) => FakeResponse.fixture('seerr/seerr_search_tmdb_id.json'),
      );
      final r = await hub.get(
        '/api/v1/search?q=${Uri.encodeQueryComponent("grey's (2005)!")}',
        as: TestAs.member,
      );
      expect(r.status, 200, reason: r.body);
      expect(queries.single, 'query=grey%27s%20%282005%29%21&page=1');
      final page = TitlePage.fromJson(r.map);
      expect(page.items.map((c) => c.mediaType), [
        MediaType.movie,
        MediaType.tv,
      ]);
    });

    test('q is required and at most 100 characters', () async {
      expect((await hub.get('/api/v1/search')).status, 400);
      expect((await hub.get('/api/v1/search?q=%20%20')).status, 400);
      expect((await hub.get('/api/v1/search?q=${'a' * 101}')).status, 400);
    });
  });

  test('GET /discover/genres', () async {
    hub.fakes.onFixture(
      ServiceId.seerr,
      'GET',
      '/api/v1/genres/movie',
      'seerr/seerr_genres_movie.json',
    );
    final r = await hub.get('/api/v1/discover/genres?mediaType=movie');
    expect(r.status, 200);
    final list = ItemList.fromJson(r.map, Genre.fromJson);
    expect(list.items.first.name, 'Action');
    expect(
      (await hub.get('/api/v1/discover/genres?mediaType=music')).status,
      400,
    );
  });

  group('GET /titles', () {
    test(
      'movie: slim DTO with media, Jellyfin link and no Seerr URLs',
      () async {
        final r = await hub.get('/api/v1/titles/movie/818', as: TestAs.member);
        expect(r.status, 200, reason: r.body);
        final m = MovieTitle.fromJson(r.map);
        expect(m.title, 'Austin Powers in Goldmember');
        expect(m.media!.availability, Availability.available);
        expect(m.media!.libraryId, isNotNull);
        expect(m.media!.jellyfin!.app, ExternalApp.jellyfin);
        expect(
          m.media!.jellyfin!.path,
          contains('serverId=79315eab3c4c401f8391d5c26210b6d7'),
        );
        expect(m.request.reason, RequestEligibilityReason.available);
        expect(r.body, isNot(contains('mediaUrl')));
        expect(r.body, isNot(contains('serviceUrl')));
        expect(r.body, isNot(contains('redacted@example.com')));
        expect(r.body, isNot(contains('192.168.10.183')));
        // Details are fetched as the Seerr admin (shared cache).
        final call = seerrCalls(hub.fakes, '/api/v1/movie/818').single;
        expect(call.headers.containsKey('x-api-user'), isFalse);
      },
    );

    test('unknown TMDB id: Seerr 500 → 404 not_found', () async {
      final r = await hub.get('/api/v1/titles/movie/999999999');
      expect(r.status, 404);
      expect(r.errorCode, 'not_found');
    });

    test('tv: season picker data; unlinked members see notLinked', () async {
      final linked = await hub.get(
        '/api/v1/titles/tv/10545',
        as: TestAs.member,
      );
      expect(linked.status, 200, reason: linked.body);
      final t = TvTitle.fromJson(linked.map);
      expect(t.seasons.map((s) => s.seasonNumber), [1, 2, 3, 4, 5, 6, 7]);
      expect(t.request.canRequest, isTrue);
      expect(t.request.requestableSeasons, [4, 5, 6, 7]);
      expect(t.media!.requests.single.status, RequestStatus.completed);

      final h = TestHub();
      seerrBasics(h.fakes, memberLinked: false);
      try {
        final r = await h.get('/api/v1/titles/tv/10545', as: TestAs.member);
        final u = TvTitle.fromJson(r.map);
        expect(u.request.canRequest, isFalse);
        expect(u.request.reason, RequestEligibilityReason.notLinked);
        expect(u.request.requestableSeasons, [4, 5, 6, 7]);
      } finally {
        await h.close();
      }
    });

    test('ratings: movie and tv; missing ratings are empty', () async {
      hub.fakes
        ..onFixture(
          ServiceId.seerr,
          'GET',
          '/api/v1/movie/818/ratingscombined',
          'seerr/seerr_movie_ratingscombined.json',
        )
        ..onFixture(
          ServiceId.seerr,
          'GET',
          '/api/v1/tv/10545/ratings',
          'seerr/seerr_tv_ratings.json',
        )
        ..on(
          ServiceId.seerr,
          'GET',
          '/api/v1/movie/603/ratingscombined',
          (_) => FakeResponse.json({
            'message': 'Unable to retrieve movie ratings.',
          }, status: 500),
        );
      final movie = Ratings.fromJson(
        (await hub.get('/api/v1/titles/movie/818/ratings')).map,
      );
      expect(movie.imdb!.score, 6.3);
      final tv = Ratings.fromJson(
        (await hub.get('/api/v1/titles/tv/10545/ratings')).map,
      );
      expect(tv.rottenTomatoes!.criticsScore, 68);
      final none = await hub.get('/api/v1/titles/movie/603/ratings');
      expect(none.status, 200);
      expect(none.map, isEmpty);
    });

    test('recommendations and similar are TitlePages', () async {
      hub.fakes
        ..onFixture(
          ServiceId.seerr,
          'GET',
          '/api/v1/movie/818/recommendations',
          'seerr/seerr_movie_recommendations.json',
        )
        ..onFixture(
          ServiceId.seerr,
          'GET',
          '/api/v1/movie/818/similar',
          'seerr/seerr_movie_similar.json',
        );
      final rec = await hub.get(
        '/api/v1/titles/movie/818/recommendations?page=1',
      );
      expect(rec.status, 200);
      expect(TitlePage.fromJson(rec.map).items, isNotEmpty);
      final sim = await hub.get('/api/v1/titles/movie/818/similar');
      expect(sim.status, 200);
      expect(
        TitlePage.fromJson(sim.map).items.first.mediaType,
        MediaType.movie,
      );
    });

    test('season episodes; an unknown season is 404', () async {
      hub.fakes
        ..onFixture(
          ServiceId.seerr,
          'GET',
          '/api/v1/tv/10545/season/1',
          'seerr/seerr_tv_season.json',
        )
        ..on(
          ServiceId.seerr,
          'GET',
          '/api/v1/tv/10545/season/99',
          (_) => FakeResponse.json({
            'message': 'Unable to retrieve season.',
          }, status: 500),
        );
      final r = await hub.get('/api/v1/titles/tv/10545/seasons/1');
      expect(r.status, 200);
      expect(
        SeasonEpisodes.fromJson(r.map).episodes.first.name,
        'Strange Love',
      );
      expect((await hub.get('/api/v1/titles/tv/10545/seasons/99')).status, 404);
    });
  });

  test('Seerr not configured: 503 service_not_configured', () async {
    final h = TestHub(unconfigured: {ServiceId.seerr});
    try {
      for (final path in [
        '/api/v1/discover/trending',
        '/api/v1/discover/watchlist',
        '/api/v1/search?q=dune',
        '/api/v1/titles/movie/818',
        '/api/v1/requests',
        '/api/v1/issues',
      ]) {
        final r = await h.get(path, as: TestAs.member);
        expect(r.status, 503, reason: path);
        expect(r.errorCode, 'service_not_configured', reason: path);
      }
    } finally {
      await h.close();
    }
  });
}
