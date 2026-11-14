// PRIVATE_PROWLARR_TAG: indexers carrying the tag are ignored everywhere
// (lists, stats, history, search, dashboard, Discord alert).
import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/features/indexers/indexer_alert.dart';
import 'package:yams_hub_gateway/src/features/indexers/prowlarr_mapping.dart';
import 'package:yams_hub_gateway/src/features/indexers/prowlarr_repository.dart';

import '../../support/test_hub.dart';
import 'indexers_test_support.dart';

const _p = ServiceId.prowlarr;

/// Uindex (15, failing) and Nyaa.si (5, the most grabs) carry the tag.
void _fakePrivate(FakeUpstreams f) {
  fakeProwlarrReads(f);
  final indexers = [
    for (final i in indexersWithUindex())
      switch (readMap(i)!) {
        final m when m['id'] == 15 || m['id'] == 5 => {
          ...m,
          'tags': [1, 2],
        },
        final m => m,
      },
  ];
  f
    ..on(_p, 'GET', '/api/v1/indexer', (_) => FakeResponse.json(indexers))
    ..on(
      _p,
      'GET',
      '/api/v1/tag',
      (_) => FakeResponse.json([
        {'label': 'flaresolverr', 'id': 1},
        {'label': 'Private', 'id': 2},
      ]),
    )
    ..on(_p, 'GET', '/api/v1/history', (_) {
      JsonMap rec(int id, int indexer) => {
        'id': id,
        'indexerId': indexer,
        'date': '2026-11-08T06:30:00Z',
        'successful': true,
        'eventType': 'indexerQuery',
        'data': {'query': 'q$indexer'},
      };
      return FakeResponse.json({
        'page': 1,
        'pageSize': 25,
        'totalRecords': 2,
        'records': [rec(1, 4), rec(2, 5)],
      });
    })
    ..on(
      _p,
      'GET',
      '/api/v1/search',
      (_) => FakeResponse.json([
        for (final id in [4, 5])
          {
            'guid': 'g$id',
            'indexerId': id,
            'title': 'Release $id',
            'size': 1,
            'protocol': 'torrent',
            'magnetUrl': 'magnet:?xt=urn:btih:${'$id' * 40}'.substring(0, 60),
          },
      ]),
    );
}

void main() {
  late TestHub hub;

  setUp(() {
    hub = TestHub(env: const {'PRIVATE_PROWLARR_TAG': 'private'});
    _fakePrivate(hub.fakes);
  });
  tearDown(() => hub.close());

  test('GET /indexers leaves out private indexers', () async {
    final r = await hub.get('/api/v1/indexers');
    expect(r.status, 200, reason: r.body);
    final list = IndexerList.fromJson(r.map);
    expect(list.items.map((i) => i.id), isNot(contains(15)));
    expect(list.items.map((i) => i.id), isNot(contains(5)));
    expect(list.items, hasLength(4));
    // The health message naming Uindex is dropped as well.
    expect(r.body, isNot(contains('Uindex')));
    expect(r.body, isNot(contains('Nyaa')));
  });

  test('per-indexer routes answer 404', () async {
    expect((await hub.get('/api/v1/indexers/5')).status, 404);
    expect((await hub.post('/api/v1/indexers/15/test')).status, 404);
    final bulk = await hub.patch(
      '/api/v1/indexers',
      body: {
        'ids': [4, 5],
        'enabled': false,
      },
    );
    expect(bulk.status, 404);
    expect(hub.fakes.callsTo(_p).where((c) => c.method == 'PUT'), isEmpty);
    expect((await hub.get('/api/v1/indexers/4')).status, 200);
  });

  test('history asks for public indexers only and drops the rest', () async {
    final r = await hub.get('/api/v1/indexers/history');
    expect(r.status, 200, reason: r.body);
    final items = readList(r.map['items'], (m) => m);
    expect(items.map((i) => i['indexerId']), [4]);
    final call = hub.fakes
        .callsTo(_p)
        .firstWhere((c) => c.path == '/api/v1/history');
    expect(call.query['indexerIds'], containsAll(['3', '4', '8', '11']));
    expect(call.query['indexerIds'], isNot(contains('5')));
    expect(call.query['indexerIds'], isNot(contains('15')));
    expect((await hub.get('/api/v1/indexers/history?indexerId=5')).status, 404);
  });

  test('search skips private indexers and their results', () async {
    final r = await hub.get('/api/v1/indexers/search?q=example');
    expect(r.status, 200, reason: r.body);
    final items = ReleaseList.fromJson(r.map).items;
    expect(items.map((i) => i.title), ['Release 4']);
    final call = hub.fakes
        .callsTo(_p)
        .firstWhere((c) => c.path == '/api/v1/search');
    expect(call.query['indexerIds'], isNot(contains('5')));
    expect(call.query['indexerIds'], contains('4'));
    final named = await hub.get(
      '/api/v1/indexers/search?q=example&indexerIds=5',
    );
    expect(named.status, 404);
  });

  test('the dashboard card ignores private indexers and their stats', () async {
    final r = await hub.get('/api/v1/dashboard?cards=indexers');
    expect(r.status, 200, reason: r.body);
    final card = DashboardResponse.fromJson(r.map)
        .cards[DashboardCardKeys.indexers]!
        .decode(IndexersCard.fromJson)!;
    expect(card.total, 4);
    expect(card.failing, isEmpty);
    // indexerstats fixture: grabs 0 + 3 + 8 + 60 (Nyaa, private) + 0.
    expect(card.grabs24h, 11);
    expect(r.body, isNot(contains('Uindex')));
  });

  test('the Discord alert sample ignores private indexers', () async {
    await hub.ready;
    final sample = await sampleProwlarr(ProwlarrRepository(hub.ctx), hub.clock);
    expect(sample!.enabled, 4);
    expect(sample.failing, isEmpty);
  });

  test('a tag Prowlarr does not have warns admins', () async {
    final typo = TestHub(env: const {'PRIVATE_PROWLARR_TAG': 'privat'});
    addTearDown(typo.close);
    _fakePrivate(typo.fakes);
    final r = await typo.get('/api/v1/dashboard?cards=indexers');
    final alert = DashboardResponse.fromJson(r.map).alerts
        .singleWhere((a) => a.id == 'privacy.prowlarr.tag');
    expect(alert.message, contains('"privat"'));
    final member = await typo.get(
      '/api/v1/dashboard?cards=indexers',
      as: TestAs.member,
    );
    expect(member.body, isNot(contains('privacy.prowlarr')));
    final ok = await hub.get('/api/v1/dashboard?cards=indexers');
    expect(ok.body, isNot(contains('privacy.prowlarr')));
  });

  group('health messages', () {
    ProwlarrSnapshot snap(List<String> messages) => ProwlarrSnapshot(
      indexers: [
        {
          'id': 1,
          'name': 'EZ',
          'tags': [2],
        },
        {'id': 2, 'name': 'EZTV', 'tags': <int>[]},
      ],
      statuses: const {},
      tags: const {2: 'private'},
      health: [
        for (final m in messages)
          HealthMessage(
            service: ServiceId.prowlarr,
            source: 'IndexerStatusCheck',
            type: HealthMessageType.warning,
            message: m,
          ),
      ],
    );

    test('only messages naming a private indexer as a whole word go', () {
      final out = withoutPrivateIndexers(
        snap([
          'Indexers unavailable due to failures: EZTV',
          'Indexers unavailable due to failures: ez, Nyaa',
          'Indexers unavailable due to failures: EZ',
          'Indexer EZ-mirror is slow',
        ]),
        'Private',
      );
      expect(out.health.map((h) => h.message), [
        'Indexers unavailable due to failures: EZTV',
      ]);
      expect(out.hiddenIds, {1});
    });

    test('a tag Prowlarr does not have hides nothing and says so', () {
      final out = withoutPrivateIndexers(snap(['x']), 'other');
      expect(out.privateTagMissing, isTrue);
      expect(out.indexers, hasLength(2));
      expect(
        withoutPrivateIndexers(snap(['x']), null).privateTagMissing,
        false,
      );
    });
  });

  test('without the setting the tagged indexers are shown', () async {
    final plain = TestHub();
    addTearDown(plain.close);
    _fakePrivate(plain.fakes);
    final list = IndexerList.fromJson(
      (await plain.get('/api/v1/indexers')).map,
    );
    expect(list.items, hasLength(6));
    await plain.get('/api/v1/indexers/history');
    final call = plain.fakes
        .callsTo(_p)
        .firstWhere((c) => c.path == '/api/v1/history');
    expect(call.query.containsKey('indexerIds'), isFalse);
    final sample = await sampleProwlarr(
      ProwlarrRepository(plain.ctx),
      plain.clock,
    );
    expect(sample!.enabled, 6);
    expect(sample.failing, ['Uindex']);
  });
}
