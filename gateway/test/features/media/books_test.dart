import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/features/media/kavita_service.dart';
import 'package:yams_hub_gateway/src/features/media/shelfmark_service.dart';

import '../../support/test_hub.dart';
import 'media_fakes.dart';

void main() {
  group('GET /media/audiobooks', () {
    late TestHub hub;
    setUp(() {
      hub = TestHub();
      hub.fakes.fakeAudiobookshelf();
    });
    tearDown(() => hub.close());

    test('maps libraries, progress, recent items and listening', () async {
      final r = await hub.get('/api/v1/media/audiobooks', as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      // `/api/me` carries the ABS user's token and email: never forwarded.
      expect(r.body, isNot(contains('token')));
      expect(r.body, isNot(contains('email')));
      final o = AudiobooksOverview.fromJson(r.map);
      expect(o.version, '2.37.2');

      final lib = o.libraries.single;
      expect(lib.id, absLibraryId);
      expect(lib.name, 'Audiobooks');
      expect(lib.mediaType, AudiobookMediaType.book);
      expect(lib.items, 247);
      expect(lib.authors, 83);
      expect(lib.durationSeconds, 7392921);
      expect(lib.sizeBytes, 116852142646);

      // items-in-progress lists the book twice; progress joined from /api/me.
      final book = o.continueListening.single;
      expect(book.id, '2b3a26fa-c8ab-4553-bd96-34a74440485e');
      expect(book.title, 'Lonely Castle in the Mirror');
      // Displayed as-is (author/narrator are swapped in this library).
      expect(book.author, 'Sarah Skaer');
      expect(book.narrator, 'Mizuki Tsujimura');
      expect(book.progress, closeTo(0.000164, 0.000001));
      expect(book.currentTimeSeconds, 7);
      expect(book.durationSeconds, 45112);
      expect(
        book.lastUpdateAt,
        DateTime.fromMillisecondsSinceEpoch(1794127736949, isUtc: true),
      );
      expect(book.coverPath, startsWith('/api/v1/img/abs/${book.id}'));
      expect(book.link.app, ExternalApp.audiobookshelf);
      expect(book.link.path, '/item/${book.id}');

      expect(o.recentlyAdded, hasLength(5));
      final first = o.recentlyAdded.first;
      expect(first.title, startsWith('Konosuba'));
      expect(first.author, isNull, reason: 'empty authorName');
      expect(first.durationSeconds, 16049);
      expect(
        first.addedAt,
        DateTime.fromMillisecondsSinceEpoch(1794126371485, isUtc: true),
      );

      // The fake clock is 2026-11-08 09:00 UTC (11:00 SAST).
      expect(o.listening.todaySeconds, 16);
      expect(o.listening.totalSeconds, 16);
      expect(o.listening.last7Days, hasLength(7));
      expect(o.listening.last7Days.first.date, '2026-11-02');
      expect(o.listening.last7Days.last.date, '2026-11-08');
      expect(o.listening.last7Days.last.seconds, 16);
      expect(o.library.path, '/library/$absLibraryId');

      final items = hub.fakes
          .callsTo(ServiceId.audiobookshelf)
          .firstWhere((c) => c.path.endsWith('/items'));
      expect(items.query['sort'], ['addedAt']);
      expect(items.query['desc'], ['1']);
      expect(items.query['minified'], ['1']);
      expect(items.query['limit'], ['12']);
      expect(
        hub.fakes
            .callsTo(ServiceId.audiobookshelf)
            .any((c) => c.path.contains('personalized')),
        isFalse,
      );
    });

    test('a rejected key is 502 upstream_auth_failed', () async {
      hub.fakes.on(
        ServiceId.audiobookshelf,
        'GET',
        '/api/libraries',
        (_) => FakeResponse.text('Unauthorized', status: 401),
      );
      final r = await hub.get('/api/v1/media/audiobooks');
      expect(r.status, 502);
      expect(r.errorCode, 'upstream_auth_failed');
    });

    test('a failing part fails the overview', () async {
      hub.fakes.on(
        ServiceId.audiobookshelf,
        'GET',
        '/api/me',
        (_) => FakeResponse(500),
      );
      final r = await hub.get('/api/v1/media/audiobooks');
      expect(r.status, 502);
      expect(r.errorCode, 'upstream_error');
    });
  });

  group('GET /media/books (Kavita)', () {
    test('with a working Auth Key', () async {
      final hub = TestHub();
      addTearDown(hub.close);
      hub.fakes.fakeKavita();
      final r = await hub.get('/api/v1/media/books', as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      final o = BooksOverview.fromJson(r.map);
      expect(o.auth, BooksAuth.ok);
      expect(o.version, '0.9.1.4');
      expect(o.libraries.map((l) => l.type), [
        BooksLibraryType.book,
        BooksLibraryType.lightNovel,
      ]);
      expect(o.stats!.series, 3);
      expect(o.stats!.volumes, 12);
      expect(o.stats!.sizeBytes, 52428800);
      expect(o.hint, isNull);
      expect(o.recentlyAdded, hasLength(3));
      final bookworm = o.recentlyAdded.first;
      expect(bookworm.name, 'Ascendance of a Bookworm');
      expect(bookworm.format, BookSeriesFormat.epub);
      expect(bookworm.libraryName, 'Light Novels');
      expect(bookworm.coverPath, startsWith('/api/v1/img/kavita/series/3'));
      expect(bookworm.link.path, '/library/2/series/3');
      final mushoku = o.recentlyAdded[1];
      expect(mushoku.name, 'Mushoku Tensei: Jobless Reincarnation');
      expect(mushoku.progress, 0.25);
      final comic = o.recentlyAdded.last;
      expect(comic.format, BookSeriesFormat.archive);
      expect(comic.libraryName, 'Books', reason: 'from the library list');
      expect(o.onDeck.single.id, 2);
      expect(o.library.path, '/library/1');

      final calls = hub.fakes.callsTo(ServiceId.kavita);
      for (final c in calls) {
        expect(c.headers['x-api-key'], '***', reason: '$c');
        expect(c.path, isNot(contains('Account')));
      }
      final recent = calls.firstWhere(
        (c) => c.path == '/api/Series/recently-added-v2',
      );
      expect(recent.method, 'POST');
      expect(recent.query['PageSize'], ['12']);
      expect(recent.query['PageNumber'], ['1']);
      expect(jsonDecode(recent.body), kavitaRecentlyAddedFilter);
      final deck = calls.firstWhere((c) => c.path == '/api/Series/on-deck');
      expect(deck.method, 'POST');
      expect(deck.query['PageSize'], ['12']);
      expect(deck.query['libraryId'], ['0']);
    });

    test('no series: the folder hint', () async {
      final hub = TestHub();
      addTearDown(hub.close);
      hub.fakes.fakeKavita(emptyStats: true);
      final o = BooksOverview.fromJson(
        (await hub.get('/api/v1/media/books')).map,
      );
      expect(o.auth, BooksAuth.ok);
      expect(o.stats!.series, 0);
      expect(o.hint, kavitaNoSeriesHint);
    });

    test('stats need an admin key and are optional', () async {
      final hub = TestHub();
      addTearDown(hub.close);
      hub.fakes.fakeKavita();
      hub.fakes.on(
        ServiceId.kavita,
        'GET',
        '/api/Stats/server/stats',
        (_) => FakeResponse(403),
      );
      final r = await hub.get('/api/v1/media/books');
      expect(r.status, 200);
      final o = BooksOverview.fromJson(r.map);
      expect(o.auth, BooksAuth.ok);
      expect(o.stats, isNull);
    });

    test(
      'an empty KAVITA_API_KEY is missingKey without calling Kavita',
      () async {
        final hub = TestHub(env: {'KAVITA_API_KEY': ''});
        addTearDown(hub.close);
        hub.fakes.fakeKavita();
        final r = await hub.get('/api/v1/media/books');
        expect(r.status, 200, reason: r.body);
        final o = BooksOverview.fromJson(r.map);
        expect(o.auth, BooksAuth.missingKey);
        expect(o.libraries, isEmpty);
        expect(o.recentlyAdded, isEmpty);
        expect(o.stats, isNull);
        expect(hub.fakes.callsTo(ServiceId.kavita), isEmpty);
      },
    );

    test('a rejected key is reported, not thrown', () async {
      final hub = TestHub();
      addTearDown(hub.close);
      hub.fakes.fakeKavita();
      hub.fakes.on(
        ServiceId.kavita,
        'GET',
        '/api/Server/server-info-slim',
        (_) => FakeResponse(401),
      );
      final r = await hub.get('/api/v1/media/books');
      expect(r.status, 200);
      expect(BooksOverview.fromJson(r.map).auth, BooksAuth.rejected);
      expect(hub.fakes.callsTo(ServiceId.kavita).map((c) => c.path), [
        '/api/Server/server-info-slim',
      ]);
    });

    test('no KAVITA_URL is 503 service_not_configured', () async {
      final hub = TestHub(unconfigured: {ServiceId.kavita});
      addTearDown(hub.close);
      final r = await hub.get('/api/v1/media/books');
      expect(r.status, 503);
      expect(r.errorCode, 'service_not_configured');
    });

    test('Kavita down is 503', () async {
      final hub = TestHub();
      addTearDown(hub.close);
      hub.fakes.on(
        ServiceId.kavita,
        '*',
        RegExp('.*'),
        (_) => throw const SocketException('connection refused'),
      );
      final r = await hub.get('/api/v1/media/books');
      expect(r.status, 503);
      expect(r.errorCode, 'upstream_unavailable');
    });
  });

  group('GET /media/shelfmark', () {
    test('healthy with the captured counters', () async {
      final hub = TestHub();
      addTearDown(hub.close);
      hub.fakes.fakeShelfmark();
      final r = await hub.get('/api/v1/media/shelfmark', as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      final s = ShelfmarkStatus.fromJson(r.map);
      expect(s.status, ShelfmarkServiceState.ok);
      expect(s.coordinator, ShelfmarkCoordinator.running);
      expect(s.isEmpty, isTrue);
      expect(s.generatedAt, DateTime.utc(2026, 11, 8, 9, 51, 34, 709, 206));
      expect(s.web.app, ExternalApp.shelfmark);
      expect(s.web.path, '/');
      _expectOnlySafeShelfmarkCalls(hub);
    });

    test('a stopped coordinator (503) is degraded', () async {
      final hub = TestHub();
      addTearDown(hub.close);
      hub.fakes.fakeShelfmark(stopped: true);
      final r = await hub.get('/api/v1/media/shelfmark');
      expect(r.status, 200, reason: r.body);
      final s = ShelfmarkStatus.fromJson(r.map);
      expect(s.status, ShelfmarkServiceState.degraded);
      expect(s.coordinator, ShelfmarkCoordinator.stopped);
      expect(s.queue.active, 2);
      expect(s.queue.queued, 1);
      expect(s.queue.awaitingPickup, 1);
      expect(s.requests.pending, 2);
      expect(s.requests.delivered, 6);
      expect(s.added.ebook7d, 3);
      expect(s.added.audiobook30d, 4);
      expect(s.added.total7d, 5);
      expect(s.failed7d, 1);
      _expectOnlySafeShelfmarkCalls(hub);
    });

    test('unreachable health with stats is degraded', () {
      final s = mapShelfmarkStatus(
        health: null,
        healthStatus: null,
        stats: const {},
      );
      expect(s.status, ShelfmarkServiceState.degraded);
      expect(s.coordinator, ShelfmarkCoordinator.unknown);
      final ws = mapShelfmarkStatus(
        health: const {
          'status': 'ok',
          'coordinator': 'running',
          'degraded': {'websocket': 'down'},
        },
        healthStatus: 200,
        stats: const {},
      );
      expect(ws.status, ShelfmarkServiceState.degraded);
    });

    test('Shelfmark down is 503', () async {
      final hub = TestHub();
      addTearDown(hub.close);
      hub.fakes.on(
        ServiceId.shelfmark,
        'GET',
        RegExp('.*'),
        (_) => throw const SocketException('refused'),
      );
      final r = await hub.get('/api/v1/media/shelfmark');
      expect(r.status, 503);
      _expectOnlySafeShelfmarkCalls(hub);
    });
  });
}

void _expectOnlySafeShelfmarkCalls(TestHub hub) {
  final calls = hub.fakes.callsTo(ServiceId.shelfmark);
  expect(calls, isNotEmpty);
  for (final c in calls) {
    expect(c.method, 'GET', reason: '$c');
    expect(shelfmarkAllowedPaths, contains(c.path), reason: '$c');
  }
}
