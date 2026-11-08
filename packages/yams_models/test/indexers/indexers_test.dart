import 'package:test/test.dart';
import 'package:yams_models/yams_models.dart';

import '../core/round_trip.dart';

/// Gateway-shaped samples (API.md §10), consistent with the Prowlarr
/// fixtures in `fixtures/downloads/prowlarr_*.json`.
final _stats = <String, Object?>{
  'queries': 605,
  'grabs': 8,
  'rssQueries': 11108,
  'authQueries': 0,
  'failedQueries': 2,
  'failedGrabs': 0,
  'failedRssQueries': 3,
  'avgResponseMs': 501,
};

final _failingIndexer = <String, Object?>{
  'id': 15,
  'name': 'Uindex',
  'enabled': true,
  'priority': 25,
  'protocol': 'torrent',
  'privacy': 'public',
  'tags': [
    {'id': 1, 'label': 'flaresolverr'},
  ],
  'usesFlareSolverr': true,
  'status': 'failing',
  'disabledTill': '2026-11-08T19:06:16Z',
  'failingSince': '2026-05-29T23:36:28Z',
  'lastFailure': '2026-11-07T19:06:16Z',
  'supportsRss': true,
  'supportsSearch': true,
  'baseUrl': 'https://uindex.org/',
  'implementation': 'Cardigann',
  'language': 'en-US',
  'added': '2026-02-03T19:46:40Z',
  'stats': _stats,
};

final _okIndexer = <String, Object?>{
  'id': 8,
  'name': 'Bangumi Moe',
  'enabled': false,
  'priority': 10,
  'protocol': 'torrent',
  'privacy': 'public',
  'tags': <Object?>[],
  'usesFlareSolverr': false,
  'status': 'disabled',
  'supportsRss': true,
  'supportsSearch': false,
};

void main() {
  group('enums', () {
    test('unknown values map to unknown', () {
      expect(IndexerStatus.fromJson('weird'), IndexerStatus.unknown);
      expect(IndexerHistoryType.fromJson('weird'), IndexerHistoryType.unknown);
      expect(ReleaseSearchType.fromJson(null), ReleaseSearchType.unknown);
    });

    test('history types map Prowlarr names and ints', () {
      expect(
        IndexerHistoryType.fromUpstream('releaseGrabbed'),
        IndexerHistoryType.grabbed,
      );
      expect(
        IndexerHistoryType.fromUpstream('indexerRss'),
        IndexerHistoryType.rss,
      );
      expect(
        IndexerHistoryType.fromUpstream('indexerInfoQuery'),
        IndexerHistoryType.infoQuery,
      );
      expect(IndexerHistoryType.fromUpstream(2), IndexerHistoryType.query);
      expect(
        IndexerHistoryType.fromUpstream('somethingNew'),
        IndexerHistoryType.unknown,
      );
      expect(IndexerHistoryType.auth.upstreamEventType, 4);
      expect(IndexerHistoryType.filterable, hasLength(4));
    });
  });

  group('Indexer', () {
    test('round trips a failing indexer with stats', () {
      final i = expectRoundTrip(
        _failingIndexer,
        Indexer.fromJson,
        (x) => x.toJson(),
      );
      expect(i.isFailing, isTrue);
      expect(i.tags.single.label, 'flaresolverr');
      expect(i.disabledTill, DateTime.utc(2026, 11, 8, 19, 6, 16));
      expect(i.stats!.grabs, 8);
      expect(i.categories, isNull);
    });

    test('round trips a minimal disabled indexer', () {
      final i = expectRoundTrip(
        _okIndexer,
        Indexer.fromJson,
        (x) => x.toJson(),
      );
      expect(i.status, IndexerStatus.disabled);
      expect(i.stats, isNull);
    });

    test('round trips the detail fields', () {
      final i = expectRoundTrip(
        {
          ..._okIndexer,
          'description': 'A public anime tracker',
          'categories': ['TV', 'Anime/Anime'],
        },
        Indexer.fromJson,
        (x) => x.toJson(),
      );
      expect(i.categories, ['TV', 'Anime/Anime']);
    });

    test('withEnabled derives the status', () {
      final failing = Indexer.fromJson(_failingIndexer);
      final now = DateTime.utc(2026, 11, 8, 9);
      expect(failing.withEnabled(false).status, IndexerStatus.disabled);
      expect(
        failing.withEnabled(false).withEnabled(true, now: now).status,
        IndexerStatus.failing,
      );
      expect(
        failing.withEnabled(true, now: DateTime.utc(2026, 11, 9)).status,
        IndexerStatus.ok,
      );
      expect(failing.withPriority(3).priority, 3);
    });

    test('stats failure rate', () {
      final s = IndexerStats.fromJson(_stats);
      expect(s.totalQueries, 11713);
      expect(s.failureRate, closeTo(5 / 11713, 1e-9));
      expect(const IndexerStats().failureRate, 0);
    });
  });

  test('IndexerList round trips with health', () {
    final list = expectRoundTrip(
      {
        'items': [_failingIndexer, _okIndexer],
        'health': [
          {
            'service': 'prowlarr',
            'source': 'IndexerLongTermStatusCheck',
            'type': 'warning',
            'message': 'Indexers unavailable due to failures for more than 6 hours: Uindex',
            'wikiUrl': 'https://wiki.servarr.com/prowlarr/system#indexers-are-unavailable-due-to-failures',
          },
        ],
        'statsFrom': '2026-10-09T09:00:00Z',
        'statsTo': '2026-11-08T09:00:00Z',
      },
      IndexerList.fromJson,
      (x) => x.toJson(),
    );
    expect(list.items, hasLength(2));
    expect(list.health.single.type, HealthMessageType.warning);
    expect(list.withItems(const []).statsTo, list.statsTo);
  });

  test('IndexerBulkUpdate round trips', () {
    expectRoundTrip(
      {
        'ids': [4, 5],
        'enabled': false,
      },
      IndexerBulkUpdate.fromJson,
      (x) => x.toJson(),
    );
    expectRoundTrip(
      {
        'ids': [4],
        'priority': 10,
      },
      IndexerBulkUpdate.fromJson,
      (x) => x.toJson(),
    );
  });

  test('IndexerTestResult round trips and decodes job results', () {
    expectRoundTrip(
      {
        'id': 15,
        'valid': false,
        'failures': ['Unable to connect to indexer'],
      },
      IndexerTestResult.fromJson,
      (x) => x.toJson(),
    );
    final items = IndexerTestResult.listFromJobResult({
      'items': [
        {'id': 4, 'valid': true, 'failures': <Object?>[]},
        {
          'id': 15,
          'valid': false,
          'failures': ['Timeout'],
        },
      ],
    });
    expect(items.map((r) => r.valid), [true, false]);
    expect(IndexerTestResult.listFromJobResult(null), isEmpty);
  });

  test('IndexerHistoryItem round trips query and grab rows', () {
    expectRoundTrip(
      {
        'id': 491570,
        'indexerId': 4,
        'indexerName': '1337x',
        'date': '2026-11-08T08:43:18Z',
        'successful': true,
        'type': 'rss',
        'source': 'Sonarr',
        'host': 'sonarr',
        'queryType': 'tvsearch',
        'categories': '5000,5040,5030,5070',
        'results': 20,
        'elapsedMs': 993,
      },
      IndexerHistoryItem.fromJson,
      (x) => x.toJson(),
    );
    final grab = expectRoundTrip(
      {
        'id': 491100,
        'indexerId': 5,
        'indexerName': 'Nyaa.si',
        'date': '2026-11-08T07:00:00Z',
        'successful': false,
        'type': 'grabbed',
        'source': 'Sonarr',
        'grabTitle': '[SubsPlease] Show - 01 (1080p)',
      },
      IndexerHistoryItem.fromJson,
      (x) => x.toJson(),
    );
    expect(grab.type, IndexerHistoryType.grabbed);
  });

  test('IndexerCategory round trips', () {
    final c = expectRoundTrip(
      {
        'id': 2000,
        'name': 'Movies',
        'subCategories': [
          {'id': 2010, 'name': 'Movies/Foreign'},
          {'id': 2040, 'name': 'Movies/HD'},
        ],
      },
      IndexerCategory.fromJson,
      (x) => x.toJson(),
    );
    expect(c.subCategories.last.id, 2040);
    final list = ItemList.fromJson({
      'items': [c.toJson()],
    }, IndexerCategory.fromJson);
    expect(list.items.single.name, 'Movies');
  });

  group('releases', () {
    final release = <String, Object?>{
      'releaseId': 'rel_0123456789abcdef01234567',
      'indexerId': 5,
      'indexer': 'Nyaa.si',
      'title': '[SubsPlease] Show - 01 (1080p) [ABCDEF12].mkv',
      'sizeBytes': 1453267968,
      'publishDate': '2026-11-07T18:01:02Z',
      'ageHours': 14,
      'seeders': 812,
      'leechers': 40,
      'grabs': 3000,
      'categories': ['TV', 'Anime/Anime'],
      'infoUrl': 'https://nyaa.si/view/1234567',
      'protocol': 'torrent',
      'hasMagnet': true,
      'imdbId': 'tt0944947',
      'tmdbId': 1399,
      'tvdbId': 121361,
    };

    test('Release round trips full and minimal', () {
      final r = expectRoundTrip(release, Release.fromJson, (x) => x.toJson());
      expect(r.hasMagnet, isTrue);
      expectRoundTrip(
        {
          'releaseId': 'rel_x',
          'indexerId': 4,
          'indexer': '1337x',
          'title': 'Book',
          'sizeBytes': 1024,
          'categories': <Object?>[],
          'protocol': 'torrent',
          'hasMagnet': false,
        },
        Release.fromJson,
        (x) => x.toJson(),
      );
    });

    test('ReleaseList never carries download URLs', () {
      final list = expectRoundTrip(
        {
          'items': [release],
          'tookMs': 5321,
        },
        ReleaseList.fromJson,
        (x) => x.toJson(),
      );
      expect(list.items.single.toJson().containsKey('downloadUrl'), isFalse);
    });

    test('ReleaseGrabRequest defaults to the manual category', () {
      final r = ReleaseGrabRequest.fromJson({'releaseId': 'rel_x'});
      expect(r.category, 'manual');
      expect(r.tags, isNull);
      expectRoundTrip(
        {
          'releaseId': 'rel_x',
          'category': 'books',
          'tags': ['manual-grab'],
        },
        ReleaseGrabRequest.fromJson,
        (x) => x.toJson(),
      );
    });
  });

  test('IndexersCard round trips and keeps the raw failing array', () {
    final sample = <String, Object?>{
      'total': 10,
      'enabled': 9,
      'failing': [
        {'id': 15, 'name': 'Uindex', 'disabledTill': '2026-11-08T19:06:16Z'},
      ],
      'grabs24h': 12,
      'queries24h': 340,
    };
    final card = expectRoundTrip(
      sample,
      IndexersCard.fromJson,
      (x) => x.toJson(),
    );
    expect(card.failing.single.name, 'Uindex');
    expect(card.toJson()['failing'], isA<List<Object?>>());
    final minimal = expectRoundTrip(
      {'total': 0, 'enabled': 0, 'failing': <Object?>[]},
      IndexersCard.fromJson,
      (x) => x.toJson(),
    );
    expect(minimal.grabs24h, isNull);
  });
}
