import 'package:test/test.dart';

import '../../support/test_hub.dart';
import 'indexers_test_support.dart';

void main() {
  late TestHub hub;

  setUp(() {
    hub = TestHub();
    fakeProwlarrReads(hub.fakes);
  });
  tearDown(() => hub.close());

  group('GET /indexers', () {
    test('joins indexer, status, tags, health and 30-day stats', () async {
      final r = await hub.get('/api/v1/indexers', as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      final list = IndexerList.fromJson(r.map);

      expect(list.items.map((i) => i.name), [
        '1337x',
        'Bangumi Moe',
        'EZTV',
        'Nyaa.si',
        'showRSS',
        'Uindex',
      ]);
      final uindex = list.items.firstWhere((i) => i.id == 15);
      expect(uindex.status, IndexerStatus.failing);
      expect(uindex.disabledTill, DateTime.utc(2026, 11, 8, 19, 6, 16));
      expect(uindex.failingSince, DateTime.utc(2026, 5, 29, 23, 36, 28));
      expect(uindex.lastFailure, DateTime.utc(2026, 11, 7, 19, 6, 16));
      expect(uindex.usesFlareSolverr, isTrue);
      expect(uindex.tags.single.label, 'flaresolverr');
      expect(uindex.baseUrl, 'https://uindex.org/');

      final x1337 = list.items.firstWhere((i) => i.id == 4);
      expect(x1337.status, IndexerStatus.ok);
      expect(x1337.stats!.queries, 605);
      expect(x1337.stats!.grabs, 8);
      expect(x1337.stats!.avgResponseMs, 501);
      expect(x1337.protocol, 'torrent');
      expect(x1337.privacy, 'public');
      expect(x1337.implementation, 'Cardigann');
      expect(x1337.added, DateTime.utc(2026, 2, 3, 19, 46, 40));

      final bangumi = list.items.firstWhere((i) => i.id == 8);
      expect(bangumi.usesFlareSolverr, isFalse);

      expect(list.health.map((h) => h.source), [
        'AllowedHostsCheck',
        'IndexerLongTermStatusCheck',
      ]);
      expect(list.health.first.service, ServiceId.prowlarr);
      expect(list.statsTo, hub.clock.now());
      expect(
        list.statsFrom,
        hub.clock.now().subtract(const Duration(days: 30)),
      );

      // Prowlarr internals never reach the app.
      expect(r.body, isNot(contains('"fields"')));
      expect(r.body, isNot(contains('capabilities')));
      expect(r.body, isNot(contains('description')));
      expect(r.body, isNot(contains('********')));

      final stats = hub.fakes
          .callsTo(ServiceId.prowlarr)
          .where((c) => c.path == '/api/v1/indexerstats')
          .single;
      expect(stats.query['startDate'], ['2026-10-09T09:00:00Z']);
      expect(stats.query['endDate'], ['2026-11-08T09:00:00Z']);
      expect(stats.headers['x-api-key'], '***');
    });

    test('a disabled indexer is disabled even while backing off', () async {
      final indexers = indexersWithUindex()
          .map(
            (i) => {
              ...readMap(i)!,
              if (readMap(i)!['id'] == 15) 'enable': false,
            },
          )
          .toList();
      hub.fakes.on(
        ServiceId.prowlarr,
        'GET',
        '/api/v1/indexer',
        (_) => FakeResponse.json(indexers),
      );
      final list = IndexerList.fromJson(
        (await hub.get('/api/v1/indexers')).map,
      );
      expect(
        list.items.firstWhere((i) => i.id == 15).status,
        IndexerStatus.disabled,
      );
    });

    test('back-off in the past counts as ok', () async {
      hub.clock.set(DateTime.utc(2026, 11, 8, 20));
      final list = IndexerList.fromJson(
        (await hub.get('/api/v1/indexers')).map,
      );
      expect(list.items.firstWhere((i) => i.id == 15).status, IndexerStatus.ok);
    });

    test('is cached for 60 s and stats for 10 min', () async {
      await hub.get('/api/v1/indexers');
      await hub.get('/api/v1/indexers');
      int count(String path) => hub.fakes
          .callsTo(ServiceId.prowlarr)
          .where((c) => c.path == path)
          .length;
      expect(count('/api/v1/indexer'), 1);
      hub.clock.advance(const Duration(seconds: 61));
      await hub.get('/api/v1/indexers');
      expect(count('/api/v1/indexer'), 2);
      expect(count('/api/v1/indexerstats'), 1);
      hub.clock.advance(const Duration(minutes: 10));
      await hub.get('/api/v1/indexers');
      expect(count('/api/v1/indexerstats'), 2);
    });

    test('stats and health are best effort', () async {
      hub.fakes
        ..on(
          ServiceId.prowlarr,
          'GET',
          '/api/v1/indexerstats',
          (_) => FakeResponse.json({'message': 'boom'}, status: 500),
        )
        ..on(
          ServiceId.prowlarr,
          'GET',
          '/api/v1/health',
          (_) => FakeResponse.json({'message': 'boom'}, status: 500),
        );
      final r = await hub.get('/api/v1/indexers');
      expect(r.status, 200);
      final list = IndexerList.fromJson(r.map);
      expect(list.items, hasLength(6));
      expect(list.items.every((i) => i.stats == null), isTrue);
      expect(list.health, isEmpty);
    });

    test('unconfigured Prowlarr is 503 service_not_configured', () async {
      final down = TestHub(unconfigured: {ServiceId.prowlarr});
      addTearDown(down.close);
      final r = await down.get('/api/v1/indexers');
      expect(r.status, 503);
      expect(r.errorCode, 'service_not_configured');
    });

    test('a 404 from the list endpoint is not reported as not_found', () async {
      hub.fakes.on(
        ServiceId.prowlarr,
        'GET',
        '/api/v1/indexer',
        (_) => FakeResponse.json({'message': 'gone'}, status: 404),
      );
      final r = await hub.get('/api/v1/indexers');
      expect(r.status, 502);
      expect(r.errorCode, 'upstream_error');
    });
  });

  group('GET /indexers/{id}', () {
    test('adds description and top-level categories', () async {
      final r = await hub.get('/api/v1/indexers/4', as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      final i = Indexer.fromJson(r.map);
      expect(i.name, '1337x');
      expect(
        i.description,
        '1337x is a Public torrent site that offers verified torrent downloads',
      );
      expect(i.categories, contains('TV'));
      expect(i.categories, isNot(contains('TV/HD')));
      expect(i.stats!.grabs, 8);
      expect(r.body, isNot(contains('"fields"')));
      expect(r.body, isNot(contains('subCategories')));
      expect(
        hub.fakes.callsTo(ServiceId.prowlarr).map((c) => c.path),
        contains('/api/v1/indexer/4'),
      );
    });

    test('unknown indexer is 404 not_found without the stack trace', () async {
      final r = await hub.get('/api/v1/indexers/999999');
      expect(r.status, 404);
      expect(r.errorCode, 'not_found');
      expect(r.body, isNot(contains('at Prowlarr')));
    });
  });

  group('GET /indexers/history', () {
    test('maps records and joins indexer names', () async {
      hub.fakes.onFixture(
        ServiceId.prowlarr,
        'GET',
        '/api/v1/history',
        'downloads/prowlarr_history.json',
      );
      final r = await hub.get(
        '/api/v1/indexers/history?page=2&pageSize=5',
        as: TestAs.member,
      );
      expect(r.status, 200, reason: r.body);
      final page = PagedList.fromJson(r.map, IndexerHistoryItem.fromJson);
      expect(page.total, 33088);
      expect(page.page, 2);
      expect(page.hasMore, isTrue);
      final first = page.items.first;
      expect(first.id, 491570);
      expect(first.indexerName, '1337x');
      expect(first.type, IndexerHistoryType.rss);
      expect(first.successful, isTrue);
      expect(first.source, 'Sonarr');
      expect(first.results, 20);
      expect(first.elapsedMs, 993);
      expect(first.query, isNull);
      expect(first.categories, '5000,5040,5030,5070');
      expect(r.body, isNot(contains('"url"')));
      expect(r.body, isNot(contains('1337x.to/cat')));

      final call = hub.fakes
          .callsTo(ServiceId.prowlarr)
          .lastWhere((c) => c.path == '/api/v1/history');
      expect(call.query, {
        'page': ['2'],
        'pageSize': ['5'],
        'sortKey': ['date'],
        'sortDirection': ['descending'],
      });
    });

    test('passes filters and clamps pageSize', () async {
      hub.fakes.onFixture(
        ServiceId.prowlarr,
        'GET',
        '/api/v1/history',
        'downloads/prowlarr_history_failed.json',
      );
      final r = await hub.get(
        '/api/v1/indexers/history?type=grabbed&successful=false&indexerId=15&pageSize=100000',
      );
      expect(r.status, 200, reason: r.body);
      final page = PagedList.fromJson(r.map, IndexerHistoryItem.fromJson);
      expect(page.pageSize, 100);
      expect(page.items, isNotEmpty);
      expect(page.items.every((i) => !i.successful), isTrue);
      final call = hub.fakes
          .callsTo(ServiceId.prowlarr)
          .lastWhere((c) => c.path == '/api/v1/history');
      expect(call.query['pageSize'], ['100']);
      expect(call.query['eventType'], ['1']);
      expect(call.query['successful'], ['false']);
      expect(call.query['indexerIds'], ['15']);
    });

    test('maps every type filter to the Prowlarr integer', () async {
      hub.fakes.onFixture(
        ServiceId.prowlarr,
        'GET',
        '/api/v1/history',
        'downloads/prowlarr_history.json',
      );
      for (final (type, n) in [('query', '2'), ('rss', '3'), ('auth', '4')]) {
        await hub.get('/api/v1/indexers/history?type=$type');
        final call = hub.fakes
            .callsTo(ServiceId.prowlarr)
            .lastWhere((c) => c.path == '/api/v1/history');
        expect(call.query['eventType'], [n], reason: type);
      }
    });

    test('rejects unknown filters', () async {
      expect(
        (await hub.get('/api/v1/indexers/history?type=infoQuery')).status,
        400,
      );
      expect(
        (await hub.get('/api/v1/indexers/history?successful=maybe')).status,
        400,
      );
      expect(
        (await hub.get('/api/v1/indexers/history?indexerId=x')).status,
        400,
      );
    });
  });

  test(
    'GET /indexers/categories maps the Newznab tree and caches 24 h',
    () async {
      hub.fakes.onFixture(
        ServiceId.prowlarr,
        'GET',
        '/api/v1/indexer/categories',
        'downloads/prowlarr_indexer_categories.json',
      );
      final r = await hub.get('/api/v1/indexers/categories', as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      final list = ItemList.fromJson(r.map, IndexerCategory.fromJson);
      expect(list.items.first.id, 1000);
      expect(list.items.first.name, 'Console');
      expect(list.items.first.subCategories.first.name, 'Console/NDS');
      final movies = list.items.firstWhere((c) => c.id == 2000);
      expect(movies.subCategories.map((s) => s.id), contains(2040));

      hub.clock.advance(const Duration(hours: 23));
      await hub.get('/api/v1/indexers/categories');
      expect(
        hub.fakes
            .callsTo(ServiceId.prowlarr)
            .where((c) => c.path == '/api/v1/indexer/categories'),
        hasLength(1),
      );
    },
  );

  group('dashboard card', () {
    test('counts, failing list, 24 h stats and alerts', () async {
      final r = await hub.get('/api/v1/dashboard?cards=indexers');
      expect(r.status, 200, reason: r.body);
      final dash = DashboardResponse.fromJson(r.map);
      final section = dash.cards[DashboardCardKeys.indexers]!;
      expect(section.status, SectionState.ok, reason: r.body);
      // Raw-key contract (API.md §4): `failing` is an array.
      expect(section.data!['failing'], isA<List<Object?>>());
      final card = section.decode(IndexersCard.fromJson)!;
      expect(card.total, 6);
      expect(card.enabled, 6);
      expect(card.failing.single.id, 15);
      expect(card.failing.single.name, 'Uindex');
      expect(
        card.failing.single.disabledTill,
        DateTime.utc(2026, 11, 8, 19, 6, 16),
      );
      final stats = fixture('downloads/prowlarr_indexerstats.json')! as Map;
      final rows = (stats['indexers'] as List).cast<Map<String, Object?>>();
      expect(
        card.grabs24h,
        rows.fold<int>(0, (s, x) => s + (x['numberOfGrabs']! as int)),
      );
      expect(
        card.queries24h,
        rows.fold<int>(0, (s, x) => s + (x['numberOfQueries']! as int)),
      );
      final statsCall = hub.fakes
          .callsTo(ServiceId.prowlarr)
          .lastWhere((c) => c.path == '/api/v1/indexerstats');
      expect(statsCall.query['startDate'], ['2026-11-07T09:00:00Z']);

      final byId = {for (final a in dash.alerts) a.id: a};
      final failing = byId['prowlarr.indexer.15']!;
      expect(failing.severity, AlertSeverity.warning);
      expect(failing.source, ServiceId.prowlarr);
      expect(failing.feature, 'indexers');
      // 19:06Z in the hub's default +02:00 zone.
      expect(failing.title, 'Indexer Uindex failing, retry at 21:06');
      expect(failing.route, '/indexers');
      expect(failing.since, DateTime.utc(2026, 5, 29, 23, 36, 28));

      final hosts = byId['prowlarr.health.AllowedHostsCheck']!;
      expect(hosts.severity, AlertSeverity.info);
      expect(hosts.dismissible, isTrue);
      expect(hosts.route, '/indexers');
      // Covered by the per-indexer alert.
      expect(
        byId.containsKey('prowlarr.health.IndexerLongTermStatusCheck'),
        isFalse,
      );
    });

    test('omits 24 h numbers when stats fail', () async {
      hub.fakes.on(
        ServiceId.prowlarr,
        'GET',
        '/api/v1/indexerstats',
        (_) => FakeResponse.json({'message': 'boom'}, status: 500),
      );
      final r = await hub.get('/api/v1/dashboard?cards=indexers');
      final card = DashboardResponse.fromJson(r.map).cards['indexers']!
          .decode(IndexersCard.fromJson)!;
      expect(card.grabs24h, isNull);
      expect(card.queries24h, isNull);
      expect(card.total, 6);
    });

    test('is disabled when Prowlarr is not configured', () async {
      final off = TestHub(unconfigured: {ServiceId.prowlarr});
      addTearDown(off.close);
      final r = await off.get('/api/v1/dashboard?cards=indexers');
      final section = DashboardResponse.fromJson(r.map).cards['indexers']!;
      expect(section.status, SectionState.disabled);
    });

    test('serves stale data after a failed refresh', () async {
      await hub.get('/api/v1/dashboard?cards=indexers');
      hub.fakes.on(
        ServiceId.prowlarr,
        'GET',
        '/api/v1/indexer',
        (_) => FakeResponse.json({'message': 'down'}, status: 500),
      );
      hub.clock.advance(const Duration(seconds: 61));
      final r = await hub.get('/api/v1/dashboard?cards=indexers');
      final section = DashboardResponse.fromJson(r.map).cards['indexers']!;
      expect(section.status, SectionState.ok);
      expect(section.stale, isTrue);
      expect(section.error?.code, 'upstream_error');
    });
  });
}
