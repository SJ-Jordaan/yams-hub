import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/test_hub.dart';

const _calendar = '/api/v3/calendar';
const _queue = '/api/v3/queue';

/// A synthetic sample from `test/features/calendar/data/` (arr.md §9
/// schema; the captured queues were empty).
Object? _synthetic(String name) {
  for (final base in [
    'test/features/calendar/data',
    'gateway/test/features/calendar/data',
  ]) {
    final f = File(p.join(base, name));
    if (f.existsSync()) return jsonDecode(f.readAsStringSync());
  }
  throw StateError('synthetic sample $name not found');
}

/// Registers the captured calendars and the synthetic queues.
void _serveDefaults(FakeUpstreams fakes) {
  fakes
    ..onFixture(ServiceId.sonarr, 'GET', _calendar, 'arr/sonarr_calendar.json')
    ..onFixture(ServiceId.radarr, 'GET', _calendar, 'arr/radarr_calendar.json')
    ..on(
      ServiceId.sonarr,
      'GET',
      _queue,
      (_) => FakeResponse.json(_synthetic('sonarr_queue.synthetic.json')),
    )
    ..on(
      ServiceId.radarr,
      'GET',
      _queue,
      (_) => FakeResponse.json(_synthetic('radarr_queue.synthetic.json')),
    );
}

List<RecordedCall> _calls(TestHub hub, ServiceId s, String path) => [
  for (final c in hub.fakes.callsTo(s))
    if (c.path == path) c,
];

String? _q(RecordedCall c, String key) => c.query[key]?.single;

List<JsonMap> _items(TestResponse r) => [
  for (final i in r.map['items'] as List) i as JsonMap,
];

JsonMap _episode(
  int id,
  String airDateUtc, {
  int seriesId = 159,
  String title = 'Ep',
  bool monitored = true,
}) => {
  'id': id,
  'seriesId': seriesId,
  'seasonNumber': 1,
  'episodeNumber': id % 100,
  'title': title,
  'airDate': airDateUtc.substring(0, 10),
  'airDateUtc': airDateUtc,
  'hasFile': false,
  'monitored': monitored,
  'series': {
    'title': 'Series $seriesId',
    'seriesType': 'standard',
    'monitored': true,
    'network': 'Net',
    'images': [],
  },
};

void main() {
  group('GET /calendar', () {
    late TestHub hub;
    setUp(() {
      hub = TestHub();
      _serveDefaults(hub.fakes);
    });
    tearDown(() => hub.close());

    test(
      'merges Sonarr and Radarr with local-day bounds and queue flags',
      () async {
        final r = await hub.get(
          '/api/v1/calendar?start=2026-11-07&end=2026-11-21',
          as: TestAs.member,
        );
        expect(r.status, 200, reason: r.body);

        final sonarr = _calls(hub, ServiceId.sonarr, _calendar).single;
        // 00:00 local (+02:00) → 22:00Z the day before; 23:59:59 local → 21:59:59Z.
        expect(_q(sonarr, 'start'), '2026-11-06T22:00:00Z');
        expect(_q(sonarr, 'end'), '2026-11-21T21:59:59Z');
        expect(_q(sonarr, 'unmonitored'), 'false');
        expect(_q(sonarr, 'includeSeries'), 'true');
        final radarr = _calls(hub, ServiceId.radarr, _calendar).single;
        // Radarr release dates are midnight-UTC dates: bounds on the UTC date.
        expect(_q(radarr, 'start'), '2026-11-07T00:00:00Z');
        expect(_q(radarr, 'end'), '2026-11-21T23:59:59Z');
        expect(_q(radarr, 'unmonitored'), 'false');
        expect(radarr.query.containsKey('includeSeries'), isFalse);
        for (final s in [ServiceId.sonarr, ServiceId.radarr]) {
          final q = _calls(hub, s, _queue).single;
          expect(_q(q, 'page'), '1');
          expect(_q(q, 'pageSize'), '200');
        }

        final body = r.map;
        expect(body['start'], '2026-11-07');
        expect(body['end'], '2026-11-21');
        expect(body['sources'], {
          'sonarr': {'status': 'ok'},
          'radarr': {'status': 'ok'},
        });
        final items = _items(r);
        // Episodes of 5 and 6 Nov and every Radarr date outside the window are dropped.
        expect(items.map((i) => i['id']), [
          'episode:7958',
          'episode:7669',
          'movie:246:digital',
          'movie:246:physical',
        ]);

        final ramparts = items[0];
        expect(ramparts, containsPair('kind', 'episode'));
        expect(ramparts['airDateUtc'], '2026-11-12T14:45:00Z');
        expect(ramparts['date'], '2026-11-12');
        expect(ramparts['title'], 'The Ramparts of Ice');
        // Anime series: absolute number in the label.
        expect(ramparts['subtitle'], 'S02E07 (021) · TBA');
        expect(ramparts['seriesId'], 140);
        expect(ramparts['episodeId'], 7958);
        expect(ramparts['seasonNumber'], 2);
        expect(ramparts['episodeNumber'], 7);
        expect(ramparts['absoluteEpisodeNumber'], 21);
        expect(ramparts['network'], 'TBS (JP)');
        expect(ramparts['hasFile'], false);
        expect(ramparts['monitored'], true);
        expect(
          ramparts['downloading'],
          true,
          reason: 'episodeId 7958 is in the Sonarr queue',
        );
        expect(
          ramparts['posterPath'],
          startsWith('/api/v1/img/arr/sonarr/140/poster?size=250'),
        );
        expect(ramparts.containsKey('releaseType'), isFalse);

        final apothecary = items[1];
        expect(
          apothecary['subtitle'],
          'S03E07 · The Bet',
          reason: 'standard series: no absolute number',
        );
        expect(apothecary['network'], 'Nippon TV');
        expect(apothecary['downloading'], false);

        final digital = items[2];
        expect(digital, {
          'id': 'movie:246:digital',
          'kind': 'movie',
          'date': '2026-11-17',
          'title': 'The Odyssey',
          'subtitle': 'Digital release',
          'movieId': 246,
          'releaseType': 'digital',
          'hasFile': false,
          'monitored': true,
          'downloading': true,
          'posterPath': digital['posterPath'],
        });
        expect(
          digital['posterPath'],
          startsWith('/api/v1/img/arr/radarr/246/poster?size=250'),
        );
        expect(items[3]['releaseType'], 'physical');
        expect(items[3]['subtitle'], 'Physical release');

        // The response decodes with the shared model.
        final decoded = CalendarResponse.fromJson(r.map);
        expect(decoded.items, hasLength(4));
        expect(decoded.sources.anyFailed, isFalse);
      },
    );

    test(
      'caches the window 5 min and re-applies the 5 s queue flags',
      () async {
        await hub.get('/api/v1/calendar?start=2026-11-07&end=2026-11-21');
        hub.clock.advance(const Duration(seconds: 6));
        hub.fakes.on(
          ServiceId.sonarr,
          'GET',
          _queue,
          (_) => FakeResponse.json({
            'page': 1,
            'pageSize': 200,
            'totalRecords': 0,
            'records': <Object?>[],
          }),
        );
        final r = await hub.get(
          '/api/v1/calendar?start=2026-11-07&end=2026-11-21',
        );
        expect(r.status, 200);
        expect(
          _calls(hub, ServiceId.sonarr, _calendar),
          hasLength(1),
          reason: 'window cached',
        );
        expect(
          _calls(hub, ServiceId.sonarr, _queue),
          hasLength(2),
          reason: 'queue refetched after 5 s',
        );
        expect(_items(r).first['downloading'], false);

        // Within 5 s the queue is not asked again.
        await hub.get('/api/v1/calendar?start=2026-11-07&end=2026-11-21');
        expect(_calls(hub, ServiceId.sonarr, _queue), hasLength(2));

        hub.clock.advance(const Duration(minutes: 5));
        await hub.get('/api/v1/calendar?start=2026-11-07&end=2026-11-21');
        expect(
          _calls(hub, ServiceId.sonarr, _calendar),
          hasLength(2),
          reason: 'window expired after 5 min',
        );
      },
    );

    test('queue failures are ignored', () async {
      hub.fakes
        ..on(
          ServiceId.sonarr,
          'GET',
          _queue,
          (_) => FakeResponse.json({'message': 'boom'}, status: 500),
        )
        ..on(
          ServiceId.radarr,
          'GET',
          _queue,
          (_) => FakeResponse.text('<html>bad gateway</html>', status: 502),
        );
      final r = await hub.get(
        '/api/v1/calendar?start=2026-11-07&end=2026-11-21',
      );
      expect(r.status, 200);
      expect(_items(r), hasLength(4));
      expect(_items(r).every((i) => i['downloading'] == false), isTrue);
      expect(r.map['sources'], {
        'sonarr': {'status': 'ok'},
        'radarr': {'status': 'ok'},
      });
    });

    test(
      'the queue is not fetched when a source has nothing in the window',
      () async {
        hub.fakes.on(
          ServiceId.radarr,
          'GET',
          _calendar,
          (_) => FakeResponse.json(<Object?>[]),
        );
        final r = await hub.get(
          '/api/v1/calendar?start=2026-11-07&end=2026-11-21',
        );
        expect(r.status, 200);
        expect(_calls(hub, ServiceId.radarr, _queue), isEmpty);
        expect(_calls(hub, ServiceId.sonarr, _queue), hasLength(1));
      },
    );

    test(
      'one failing source is reported in sources, the other still shows',
      () async {
        hub.fakes.on(
          ServiceId.radarr,
          'GET',
          _calendar,
          (_) => FakeResponse.json({
            'message': 'database is locked',
            'description': 'at Radarr.Core...',
          }, status: 500),
        );
        final r = await hub.get(
          '/api/v1/calendar?start=2026-11-07&end=2026-11-21',
        );
        expect(r.status, 200);
        expect(_items(r).map((i) => i['kind']).toSet(), {'episode'});
        final sources = r.map['sources'] as JsonMap;
        expect(sources['sonarr'], {'status': 'ok'});
        final radarr = sources['radarr'] as JsonMap;
        expect(radarr['status'], 'error');
        final error = radarr['error'] as JsonMap;
        expect(error['code'], 'upstream_error');
        expect(error['service'], 'radarr');
        expect(error['message'], contains('database is locked'));
        expect(
          r.body,
          isNot(contains('Radarr.Core')),
          reason: 'description never leaves the gateway',
        );
      },
    );

    test('an upstream 404 is not reported as not_found', () async {
      hub.fakes.on(
        ServiceId.sonarr,
        'GET',
        _calendar,
        (_) => FakeResponse.json({'title': 'Not Found'}, status: 404),
      );
      final r = await hub.get(
        '/api/v1/calendar?start=2026-11-07&end=2026-11-21&types=episode',
      );
      expect(r.status, 502);
      expect(r.errorCode, 'upstream_error');
    });

    test('both sources failing is an error response', () async {
      hub.fakes
        ..on(
          ServiceId.sonarr,
          'GET',
          _calendar,
          (_) => throw const SocketException('refused'),
        )
        ..on(
          ServiceId.radarr,
          'GET',
          _calendar,
          (_) => FakeResponse.json({'message': 'x'}, status: 500),
        );
      final r = await hub.get(
        '/api/v1/calendar?start=2026-11-07&end=2026-11-21',
      );
      expect(r.status, 503, reason: r.body);
      expect(r.errorCode, 'upstream_unavailable');
      expect((r.map['error'] as JsonMap)['service'], 'sonarr');
    });

    test('a non-array calendar body is upstream_bad_response', () async {
      hub.fakes.on(
        ServiceId.radarr,
        'GET',
        _calendar,
        (_) => FakeResponse.json({'records': <Object?>[]}),
      );
      final r = await hub.get(
        '/api/v1/calendar?start=2026-11-07&end=2026-11-21&types=movie',
      );
      expect(r.status, 502);
      expect(r.errorCode, 'upstream_bad_response');
    });

    test(
      'serves the cached window with an error when a refresh fails',
      () async {
        await hub.get('/api/v1/calendar?start=2026-11-07&end=2026-11-21');
        hub.clock.advance(const Duration(minutes: 6));
        hub.fakes.on(
          ServiceId.sonarr,
          'GET',
          _calendar,
          (_) => FakeResponse.json({'message': 'x'}, status: 500),
        );
        final r = await hub.get(
          '/api/v1/calendar?start=2026-11-07&end=2026-11-21',
        );
        expect(r.status, 200);
        expect(_items(r).where((i) => i['kind'] == 'episode'), hasLength(2));
        final sonarr = (r.map['sources'] as JsonMap)['sonarr'] as JsonMap;
        expect(sonarr['status'], 'ok');
        expect((sonarr['error'] as JsonMap)['code'], 'upstream_error');
      },
    );

    test('types limits the sources that are called', () async {
      final r = await hub.get(
        '/api/v1/calendar?start=2026-11-07&end=2026-11-21&types=movie',
      );
      expect(r.status, 200);
      expect(hub.fakes.callsTo(ServiceId.sonarr), isEmpty);
      expect(r.map['sources'], {
        'radarr': {'status': 'ok'},
      });
      expect(_items(r).map((i) => i['kind']).toSet(), {'movie'});

      final both = await hub.get(
        '/api/v1/calendar?start=2026-11-07&end=2026-11-21&types=episode,movie',
      );
      expect(_items(both), hasLength(4));
    });

    test(
      'unmonitored=true is passed on and unmonitored episodes are kept',
      () async {
        hub.fakes.onFixture(
          ServiceId.sonarr,
          'GET',
          _calendar,
          'arr/sonarr_calendar_no_series.json',
        );
        final r = await hub.get(
          '/api/v1/calendar?start=2026-11-01&end=2026-11-14&unmonitored=true&types=episode',
        );
        expect(r.status, 200);
        final call = _calls(hub, ServiceId.sonarr, _calendar).single;
        expect(_q(call, 'unmonitored'), 'true');
        final items = _items(r);
        expect(items.first['id'], 'episode:7957');
        expect(items.first['monitored'], false);
        // Without the embedded series the item still renders.
        expect(items.first['title'], 'Unknown series');
        expect(items.first.containsKey('posterPath'), isFalse);
        expect(items.first.containsKey('network'), isFalse);
      },
    );

    test(
      'episodes are dated in local time and sorted by date, time, title',
      () async {
        hub.fakes
          ..on(
            ServiceId.sonarr,
            'GET',
            _calendar,
            (_) => FakeResponse.json([
              // 22:30Z is 00:30 on the 13th in +02:00.
              _episode(101, '2026-11-12T22:30:00Z', seriesId: 2),
              _episode(102, '2026-11-13T18:00:00Z', seriesId: 3),
              _episode(103, '2026-11-13T18:00:00Z', seriesId: 1),
              // Outside the window once converted (00:30 on the 15th local).
              _episode(104, '2026-11-14T22:30:00Z'),
            ]),
          )
          ..on(
            ServiceId.radarr,
            'GET',
            _calendar,
            (_) => FakeResponse.json([
              {
                'id': 9,
                'title': 'Cinema Movie',
                'inCinemas': '2026-11-13T00:00:00Z',
                'digitalRelease': '0001-01-01T00:00:00Z',
                'hasFile': true,
                'monitored': false,
                'images': [
                  {
                    'coverType': 'poster',
                    'url': '/MediaCover/9/poster.jpg?h=ee00d06d64cb9c44727a',
                    'remoteUrl': 'https://image.tmdb.org/t/p/original/abc.jpg',
                  },
                ],
              },
            ]),
          );
        final r = await hub.get(
          '/api/v1/calendar?start=2026-11-13&end=2026-11-14',
        );
        expect(r.status, 200);
        final items = _items(r);
        expect(items.map((i) => i['id']), [
          'movie:9:cinema',
          'episode:101',
          'episode:103',
          'episode:102',
        ]);
        expect(items[1]['date'], '2026-11-13');
        expect(items[0]['subtitle'], 'In cinemas');
        expect(items[0]['hasFile'], true);
        expect(items[0]['monitored'], false);
        expect(items[0]['posterPath'], contains('v=ee00d06d64cb9c44727a'));
      },
    );

    test('rejects invalid windows and parameters', () async {
      Future<void> bad(String query) async {
        final r = await hub.get('/api/v1/calendar?$query');
        expect(r.status, 400, reason: query);
        expect(r.errorCode, 'bad_request', reason: query);
      }

      await bad('end=2026-11-21');
      await bad('start=2026-11-07');
      await bad('start=2026-11-07T00:00:00Z&end=2026-11-21');
      await bad('start=2026-02-30&end=2026-03-02');
      await bad('start=2026-11-21&end=2026-11-07');
      await bad('start=2026-11-01&end=2027-01-03'); // 63 days
      await bad('start=2026-11-07&end=2026-11-21&types=episode,concert');
      await bad('start=2026-11-07&end=2026-11-21&unmonitored=maybe');
      expect(hub.fakes.calls, isEmpty);

      final ok = await hub.get(
        '/api/v1/calendar?start=2026-11-01&end=2027-01-02',
      ); // 62 days
      expect(ok.status, 200);
    });

    test('requires authentication', () async {
      final r = await hub.get(
        '/api/v1/calendar?start=2026-11-07&end=2026-11-21',
        as: TestAs.anonymous,
      );
      expect(r.status, 401);
    });
  });

  group('GET /calendar with Radarr not configured', () {
    late TestHub hub;
    setUp(() {
      hub = TestHub(unconfigured: {ServiceId.radarr});
      _serveDefaults(hub.fakes);
    });
    tearDown(() => hub.close());

    test('reports radarr as disabled', () async {
      final r = await hub.get(
        '/api/v1/calendar?start=2026-11-07&end=2026-11-21',
      );
      expect(r.status, 200);
      final radarr = (r.map['sources'] as JsonMap)['radarr'] as JsonMap;
      expect(radarr['status'], 'disabled');
      expect((radarr['error'] as JsonMap)['code'], 'service_not_configured');
      expect(_items(r), hasLength(2));
    });

    test('a movie-only request fails with service_not_configured', () async {
      final r = await hub.get(
        '/api/v1/calendar?start=2026-11-07&end=2026-11-21&types=movie',
      );
      expect(r.status, 503);
      expect(r.errorCode, 'service_not_configured');
    });
  });

  group('YAMS_HUB_TZ_OFFSET', () {
    test('negative offsets move the Sonarr bounds forward', () async {
      final hub = TestHub(env: {'YAMS_HUB_TZ_OFFSET': '-05:00'});
      addTearDown(hub.close);
      _serveDefaults(hub.fakes);
      final r = await hub.get(
        '/api/v1/calendar?start=2026-11-07&end=2026-11-07',
      );
      expect(r.status, 200);
      final call = _calls(hub, ServiceId.sonarr, _calendar).single;
      expect(_q(call, 'start'), '2026-11-07T05:00:00Z');
      expect(_q(call, 'end'), '2026-11-08T04:59:59Z');
    });
  });

  group('dashboard card', () {
    late TestHub hub;
    setUp(() {
      hub = TestHub();
      _serveDefaults(hub.fakes);
    });
    tearDown(() => hub.close());

    Future<Section> card() async {
      final r = await hub.get(
        '/api/v1/dashboard?cards=calendar',
        as: TestAs.member,
      );
      expect(r.status, 200, reason: r.body);
      return DashboardResponse.fromJson(r.map)
          .card(DashboardCardKeys.calendar)!;
    }

    test(
      'covers today .. today+6 and keeps the raw countNext7Days key',
      () async {
        // FakeClock: 2026-11-08T09:00Z = 11:00 local.
        final s = await card();
        expect(s.status, SectionState.ok, reason: '${s.error}');
        final sonarr = _calls(hub, ServiceId.sonarr, _calendar).single;
        expect(_q(sonarr, 'start'), '2026-11-07T22:00:00Z');
        expect(_q(sonarr, 'end'), '2026-11-14T21:59:59Z');
        expect(_q(sonarr, 'unmonitored'), 'false');
        expect(s.data!['countNext7Days'], 2);
        final c = s.decode(CalendarCard.fromJson)!;
        expect(c.items.map((i) => i.id), ['episode:7958', 'episode:7669']);
        expect(c.items.first.downloading, isTrue);
        expect(
          hub.fakes.callsTo(ServiceId.radarr).where((c) => c.path == _queue),
          isEmpty,
        );
      },
    );

    test('caps the items at 8 but counts the whole week', () async {
      hub.fakes.on(
        ServiceId.sonarr,
        'GET',
        _calendar,
        (_) => FakeResponse.json([
          for (var i = 0; i < 11; i++)
            _episode(
              200 + i,
              DateTime.utc(
                2026,
                11,
                8,
                12,
              ).add(Duration(hours: 12 * i)).toIso8601String(),
            ),
        ]),
      );
      final s = await card();
      final c = s.decode(CalendarCard.fromJson)!;
      expect(c.items, hasLength(8));
      expect(c.countNext7Days, 11);
      expect(c.items.first.id, 'episode:200');
    });

    test('is an error card when both sources fail', () async {
      hub.fakes
        ..on(
          ServiceId.sonarr,
          'GET',
          _calendar,
          (_) => FakeResponse.json({'message': 'x'}, status: 500),
        )
        ..on(
          ServiceId.radarr,
          'GET',
          _calendar,
          (_) => FakeResponse.json({'message': 'x'}, status: 500),
        );
      final s = await card();
      expect(s.status, SectionState.error);
      expect(s.error!.code, 'upstream_error');
    });

    test('reports a failed source without hiding the other', () async {
      hub.fakes.on(
        ServiceId.radarr,
        'GET',
        _calendar,
        (_) => FakeResponse.json({'message': 'x'}, status: 500),
      );
      final s = await card();
      expect(s.status, SectionState.ok);
      expect(s.stale, isFalse);
      expect(s.error!.service, ServiceId.radarr);
      expect(s.data!['countNext7Days'], 2);
    });

    test('an unconfigured source is not reported as a failure', () async {
      final only = TestHub(unconfigured: {ServiceId.radarr});
      addTearDown(only.close);
      _serveDefaults(only.fakes);
      final r = await only.get(
        '/api/v1/dashboard?cards=calendar',
        as: TestAs.member,
      );
      final s = DashboardResponse.fromJson(r.map)
          .card(DashboardCardKeys.calendar)!;
      expect(s.status, SectionState.ok);
      expect(s.error, isNull);
      expect(s.data!['countNext7Days'], 2);
    });

    test('is stale when served from cache after a failed refresh', () async {
      await card();
      hub.clock.advance(const Duration(minutes: 6));
      hub.fakes.on(
        ServiceId.sonarr,
        'GET',
        _calendar,
        (_) => FakeResponse.json({'message': 'x'}, status: 500),
      );
      final s = await card();
      expect(s.status, SectionState.ok);
      expect(s.stale, isTrue);
      expect(s.data!['countNext7Days'], 2);
    });
  });

  test('disabled card when neither *arr is configured', () async {
    final hub = TestHub(unconfigured: {ServiceId.sonarr, ServiceId.radarr});
    addTearDown(hub.close);
    final r = await hub.get('/api/v1/dashboard?cards=calendar');
    final s = DashboardResponse.fromJson(r.map)
        .card(DashboardCardKeys.calendar)!;
    expect(s.status, SectionState.disabled);
  });
}
