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
    stubCommands(hub.fakes, ServiceId.sonarr);
    stubCommands(hub.fakes, ServiceId.radarr, firstId: 9000);
  });
  tearDown(() => hub.close());

  group('GET /library/wanted', () {
    test('sonarr missing: upstream paging, sort keys, labels', () async {
      final r = await hub.get(
        '$_base/wanted/missing?service=sonarr&page=2&pageSize=10',
        as: TestAs.member,
      );
      expect(r.status, 200);
      expect(r.map['total'], 892);
      expect(r.map['page'], 2);
      expect(r.map['hasMore'], isTrue);
      final first = (r.map['items']! as List).first as Map;
      expect(first['service'], 'sonarr');
      expect(first['id'], 7110);
      expect(first['title'], "It's Always Sunny in Philadelphia");
      expect(first['episodeLabel'], 'S18E08');
      expect(first.containsKey('cutoffQuality'), isFalse);
      final call = callsOf(
        hub.fakes,
        ServiceId.sonarr,
        '/api/v3/wanted/missing',
      ).single;
      expect(call.query, {
        'page': ['2'],
        'pageSize': ['10'],
        'monitored': ['true'],
        'includeSeries': ['true'],
        'sortKey': ['episodes.airDateUtc'],
        'sortDirection': ['descending'],
      });
    });

    test('sonarr cutoff: episode files and profile cutoff names', () async {
      final r = await hub.get(
        '$_base/wanted/cutoff?service=sonarr&sort=title&order=asc',
      );
      expect(r.status, 200);
      final first = (r.map['items']! as List).first as Map;
      expect(first['cutoffQuality'], 'Bluray-1080p');
      expect(
        first['episodeLabel'],
        'S03E06',
        reason: 'standard type: no absolute',
      );
      final call = callsOf(
        hub.fakes,
        ServiceId.sonarr,
        '/api/v3/wanted/cutoff',
      ).single;
      expect(call.query['includeEpisodeFile'], ['true']);
      expect(call.query['sortKey'], ['series.sortTitle']);
      expect(call.query['sortDirection'], ['ascending']);
    });

    test(
      'radarr cutoff reads the current quality from moviefile/{id}',
      () async {
        final r = await hub.get('$_base/wanted/cutoff?service=radarr');
        expect(r.status, 200);
        final rows = [for (final i in r.map['items']! as List) i as Map];
        expect(rows.first['currentQuality'], 'WEBRip-1080p');
        expect(rows.first['cutoffQuality'], 'Bluray-1080p');
        final files = [
          for (final c in hub.fakes.callsTo(ServiceId.radarr))
            if (c.path.startsWith('/api/v3/moviefile/')) c.path,
        ];
        expect(files.toSet(), {
          '/api/v3/moviefile/947',
          '/api/v3/moviefile/946',
          '/api/v3/moviefile/972',
        });
        final call = callsOf(
          hub.fakes,
          ServiceId.radarr,
          '/api/v3/wanted/cutoff',
        ).single;
        expect(call.query['sortKey'], ['movieMetadata.sortTitle']);
        expect(call.query.containsKey('includeSeries'), isFalse);
      },
    );

    test('validation of service and sort', () async {
      expect((await hub.get('$_base/wanted/missing')).status, 400);
      expect(
        (await hub.get('$_base/wanted/missing?service=prowlarr')).status,
        400,
      );
      expect(
        (await hub.get('$_base/wanted/missing?service=radarr&sort=airDate'))
            .status,
        400,
      );
    });
  });

  group('wanted searches', () {
    test('search selected rows', () async {
      final r = await hub.post(
        '$_base/wanted/search',
        body: {
          'service': 'radarr',
          'ids': [227, 226],
        },
      );
      expect(r.status, 202);
      expect((r.map['command']! as Map)['name'], 'MoviesSearch');
      expect(
        jsonDecode(
          callsOf(hub.fakes, ServiceId.radarr, '/api/v3/command').single.body,
        ),
        {
          'name': 'MoviesSearch',
          'movieIds': [227, 226],
        },
      );
      final tooMany = await hub.post(
        '$_base/wanted/search',
        body: {
          'service': 'sonarr',
          'ids': [for (var i = 1; i <= 51; i++) i],
        },
      );
      expect(tooMany.status, 422);
      final member = await hub.post(
        '$_base/wanted/search',
        body: {
          'service': 'sonarr',
          'ids': [1],
        },
        as: TestAs.member,
      );
      expect(member.status, 403);
    });

    test('search-all is refused by the default policy', () async {
      final r = await hub.post(
        '$_base/wanted/search-all',
        body: {'service': 'sonarr', 'kind': 'missing', 'confirm': true},
      );
      expect(r.status, 403);
      expect(r.errorCode, 'policy_denied');
      expect(callsOf(hub.fakes, ServiceId.sonarr, '/api/v3/command'), isEmpty);
    });

    test(
      'search-all with the policy: 428 impact, then the global command',
      () async {
        final open = TestHub(
          policyYaml: 'policy:\n  allowGlobalSearch: true\n',
        );
        addTearDown(open.close);
        stubLibraryUpstreams(open.fakes);
        stubCommands(open.fakes, ServiceId.sonarr);
        stubCommands(open.fakes, ServiceId.radarr);
        final pending = await open.post(
          '$_base/wanted/search-all',
          body: {'service': 'sonarr', 'kind': 'missing'},
        );
        expect(pending.status, 428);
        expect(
          readMap(readMap(pending.map['error'])!['details'])!['impact'],
          'Searches indexers for 892 episodes',
        );
        expect(
          callsOf(open.fakes, ServiceId.sonarr, '/api/v3/command'),
          isEmpty,
        );
        final ok = await open.post(
          '$_base/wanted/search-all',
          body: {'service': 'sonarr', 'kind': 'cutoff', 'confirm': true},
        );
        expect(ok.status, 202);
        await open.post(
          '$_base/wanted/search-all',
          body: {'service': 'radarr', 'kind': 'missing', 'confirm': true},
        );
        expect(
          jsonDecode(
            callsOf(
              open.fakes,
              ServiceId.sonarr,
              '/api/v3/command',
            ).single.body,
          ),
          {'name': 'CutoffUnmetEpisodeSearch', 'monitored': true},
        );
        expect(
          jsonDecode(
            callsOf(
              open.fakes,
              ServiceId.radarr,
              '/api/v3/command',
            ).single.body,
          ),
          {'name': 'MissingMoviesSearch'},
        );
      },
    );
  });

  group('GET /library/profiles', () {
    test('profiles, root folders and Seerr defaults', () async {
      final r = await hub.get('$_base/profiles', as: TestAs.member);
      expect(r.status, 200);
      final sonarr = r.map['sonarr']! as Map;
      expect(
        [for (final p in sonarr['qualityProfiles'] as List) (p as Map)['id']],
        [1, 7, 9],
      );
      expect((sonarr['qualityProfiles'] as List).first, {
        'id': 1,
        'name': 'Any',
      });
      expect(sonarr['rootFolders'], [
        {
          'id': 1,
          'path': '/data/tvshows',
          'freeBytes': 4048915103744,
          'accessible': true,
        },
      ]);
      expect(sonarr['defaults'], {
        'standardProfileId': 9,
        'animeProfileId': 7,
        'rootFolderPath': '/data/tvshows',
      });
      expect((r.map['radarr']! as Map)['defaults'], {
        'profileId': 7,
        'rootFolderPath': '/data/movies',
        'minimumAvailability': 'released',
      });
      expect(r.body, isNot(contains('formatItems')));
    });

    test('without Seerr the fallback defaults and first root folder', () async {
      final noSeerr = TestHub(unconfigured: {ServiceId.seerr});
      addTearDown(noSeerr.close);
      stubLibraryUpstreams(noSeerr.fakes);
      final r = await noSeerr.get('$_base/profiles');
      expect(r.status, 200);
      expect((r.map['sonarr']! as Map)['defaults'], {
        'standardProfileId': 9,
        'animeProfileId': 7,
        'rootFolderPath': '/data/tvshows',
      });
      expect(noSeerr.fakes.callsTo(ServiceId.seerr), isEmpty);
    });
  });

  group('summary and dashboard card', () {
    test('GET /library/summary counts', () async {
      final r = await hub.get('$_base/summary', as: TestAs.member);
      expect(r.status, 200);
      final sonarr = r.map['sonarr']! as Map;
      expect(sonarr['configured'], isTrue);
      expect(sonarr['version'], startsWith('4.'));
      expect(sonarr['itemCount'], 5);
      expect(sonarr['missing'], 892);
      expect(sonarr['cutoffUnmet'], 994);
      expect(sonarr['freeBytes'], 4048915103744);
      expect(sonarr['queue'], {'total': 0, 'errors': false, 'warnings': false});
      expect((sonarr['health'] as List), hasLength(2));
      expect(((sonarr['health'] as List).first as Map)['service'], 'sonarr');
      final radarr = r.map['radarr']! as Map;
      expect(radarr['itemCount'], 5);
      expect(radarr['missing'], 1, reason: 'monitored, no file, available');
      expect(radarr['cutoffUnmet'], 139);
      final missingCall = callsOf(
        hub.fakes,
        ServiceId.sonarr,
        '/api/v3/wanted/missing',
      ).single;
      expect(missingCall.query['pageSize'], ['0']);
      expect(
        callsOf(hub.fakes, ServiceId.radarr, '/api/v3/wanted/missing'),
        isEmpty,
        reason: 'Radarr missing comes from the cached list',
      );
      expect(
        callsOf(hub.fakes, ServiceId.sonarr, '/api/v3/diskspace'),
        isEmpty,
      );
    });

    test('one unreachable *arr keeps the other half', () async {
      hub.fakes.on(
        ServiceId.radarr,
        'GET',
        '/api/v3/system/status',
        (_) => FakeResponse.json({'message': 'down'}, status: 503),
      );
      final r = await hub.get('$_base/summary');
      expect(r.status, 200);
      expect((r.map['sonarr']! as Map)['itemCount'], 5);
      final health = (r.map['radarr']! as Map)['health'] as List;
      expect((health.single as Map)['type'], 'error');
      expect((health.single as Map)['source'], 'HubConnection');
    });

    test(
      'dashboard card with alerts (indexer checks left to indexers)',
      () async {
        hub.fakes.on(
          ServiceId.radarr,
          'GET',
          '/api/v3/queue/status',
          (_) => FakeResponse.json({
            'totalCount': 3,
            'count': 3,
            'errors': true,
            'warnings': false,
          }),
        );
        final r = await hub.get('/api/v1/dashboard?cards=library');
        expect(r.status, 200);
        final card = (r.map['cards']! as Map)['library'] as Map;
        expect(card['status'], 'ok');
        final data = card['data'] as Map;
        expect((data['sonarr'] as Map)['missing'], 892);
        expect((data['radarr'] as Map)['queue'], {
          'total': 3,
          'errors': true,
          'warnings': false,
        });
        final alerts = {
          for (final a in r.map['alerts']! as List) (a as Map)['id']: a,
        };
        expect(alerts.keys, {
          'sonarr.health.AllowedHostsCheck',
          'radarr.health.AllowedHostsCheck',
          'radarr.queue.errors',
        });
        final hosts = alerts['sonarr.health.AllowedHostsCheck']!;
        expect(hosts['severity'], 'info');
        expect(hosts['dismissible'], isTrue);
        expect(hosts['route'], '/library');
        expect(
          hosts['title'],
          'Sonarr: Allowed Hosts is not configured, Sonarr will accept requests for any hostname or IP address',
        );
        final queue = alerts['radarr.queue.errors']!;
        expect(queue['severity'], 'warning');
        expect(queue['route'], '/activity');
      },
    );

    test('without Sonarr and Radarr the card is disabled', () async {
      final none = TestHub(unconfigured: {ServiceId.sonarr, ServiceId.radarr});
      addTearDown(none.close);
      final r = await none.get('/api/v1/dashboard?cards=library');
      final card = (r.map['cards']! as Map)['library'] as Map;
      expect(card['status'], 'disabled');
      final summary = await none.get('$_base/summary');
      expect(summary.status, 503);
      expect(summary.errorCode, 'service_not_configured');
    });
  });
}
