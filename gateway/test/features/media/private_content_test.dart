// PRIVATE_JELLYFIN_LIBRARIES / PRIVATE_JELLYFIN_USERS: the hub never shows a
// private library, its items or a private user (admins included).
import 'dart:convert';

import 'package:test/test.dart';

import '../../support/test_hub.dart';
import 'media_fakes.dart';

const _adultLib = 'ad0000000000000000000000000000a1';
const _adultMovie = 'ad0000000000000000000000000000b1';

/// A movie of the fixtures that the tests file under the private library.
const _privatePaulMovie = '4fcea1b4d58b05010e29c1cea2be02d4';

/// A resume-row episode (no `Path` in the answer) of a private series.
const _privateResume = 'dd63a9d25cc63db2481640b2db34c937';
const _privateSeries = '8333708745b725b410b5fc52678cdd5d';

const _rudeus = '902b544b7a194203b4aebfa75d4baa68';

final _jpeg = [0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(64, 7)];

List<Object?> _fixtureList(String name) =>
    jsonDecode(utf8.decode(fixtureBytes(name))) as List<Object?>;

/// The fixture libraries plus "Adult" at `/data/adult`.
List<Object?> _folders() => [
  ..._fixtureList('seerr/jellyfin_library_virtualfolders.json'),
  {
    'Name': 'Adult',
    'Locations': ['/data/adult'],
    'CollectionType': 'movies',
    'ItemId': _adultLib,
  },
];

JsonMap _adultItem(String id, {String name = 'Secret'}) => {
  'Id': id,
  'Name': name,
  'Type': 'Movie',
  'Path': '/data/adult/$name.mp4',
  'ImageTags': {'Primary': 't'},
};

void _fakePrivateJellyfin(FakeUpstreams f) {
  const s = ServiceId.jellyfin;
  f.on(
    s,
    'GET',
    '/Library/VirtualFolders',
    (_) => FakeResponse.json(_folders()),
  );
  f.on(s, 'GET', '/Items', (r) {
    final q = r.uri.queryParameters;
    if (q['parentId'] == _adultLib && q['limit'] == '0') {
      final n = switch (q['includeItemTypes']) {
        'Movie' => 5,
        'Episode' => 99999, // more than the server total: clamps at 0
        _ => 0,
      };
      return FakeResponse.json({'Items': [], 'TotalRecordCount': n});
    }
    if (q['ids'] case final ids?) {
      return FakeResponse.json({
        'Items': [
          for (final id in ids.split(','))
            switch (id) {
              _adultMovie || _privatePaulMovie => _adultItem(id),
              _privateSeries => {
                'Id': id,
                'Type': 'Series',
                'Path': '/data/adult/Series',
              },
              _privateResume => {
                'Id': id,
                'Type': 'Episode',
                'SeriesId': _privateSeries,
              },
              _ => {'Id': id, 'Type': 'Movie', 'Path': '/data/movies/$id'},
            },
        ],
      });
    }
    // The global recently-added fallback.
    final body = jsonDecode(
      utf8.decode(fixtureBytes('seerr/jellyfin_items_recently_added.json')),
    ) as Map<String, Object?>;
    return FakeResponse.json({
      ...body,
      'Items': [_adultItem(_adultMovie), ...(body['Items']! as List)],
    });
  });
}

void main() {
  late TestHub hub;

  setUp(() {
    hub = TestHub(
      env: const {
        'PRIVATE_JELLYFIN_LIBRARIES': ' adult ,Nope',
        'PRIVATE_JELLYFIN_USERS': 'RUDEUS greyrat',
      },
    );
    hub.fakes.fakeJellyfin();
    hub.fakes.fakeJellystat();
    _fakePrivateJellyfin(hub.fakes);
  });
  tearDown(() => hub.close());

  group('GET /media/jellyfin', () {
    test('drops the private library and subtracts its counts', () async {
      final r = await hub.get('/api/v1/media/jellyfin');
      expect(r.status, 200, reason: r.body);
      final o = JellyfinOverview.fromJson(r.map);
      expect(o.libraries.map((l) => l.name), [
        'Movies',
        'Shows',
        'Music',
        'Books',
      ]);
      expect(o.counts.movies, 179 - 5);
      expect(o.counts.series, 54);
      expect(o.counts.episodes, 0);
      // Movies is still the only public movies library.
      expect(o.libraries.firstWhere((l) => l.name == 'Movies').itemCount, 174);
      expect(r.body, isNot(contains(_adultLib)));
      final latest = hub.fakes
          .callsTo(ServiceId.jellyfin)
          .where((c) => c.path == '/Items/Latest');
      expect(latest, isNotEmpty);
      expect(latest.any((c) => c.query['parentId']!.first == _adultLib), false);
    });

    test('a private item in a public library row is dropped', () async {
      hub.fakes.on(ServiceId.jellyfin, 'GET', '/Items/Latest', (r) {
        return FakeResponse.json([
          _adultItem(_adultMovie),
          {
            'Id': 'f00000000000000000000000000000f1',
            'Name': 'Public',
            'Type': 'Movie',
            'Path': '/data/movies/Public.mkv',
          },
        ]);
      });
      final r = await hub.get('/api/v1/media/jellyfin');
      final o = JellyfinOverview.fromJson(r.map);
      expect(o.recentlyAdded.map((i) => i.id), isNot(contains(_adultMovie)));
      expect(o.recentlyAdded, isNotEmpty);
      final latest = hub.fakes
          .callsTo(ServiceId.jellyfin)
          .firstWhere((c) => c.path == '/Items/Latest');
      expect(latest.query['fields'], ['DateCreated,Path']);
    });

    test('the global fallback after a failing per-library call', () async {
      hub.fakes.on(
        ServiceId.jellyfin,
        'GET',
        '/Items/Latest',
        (_) => FakeResponse(500),
      );
      final r = await hub.get('/api/v1/media/jellyfin');
      expect(r.status, 200, reason: r.body);
      final o = JellyfinOverview.fromJson(r.map);
      expect(o.recentlyAdded, hasLength(5)); // the fixture's five
      expect(r.body, isNot(contains(_adultMovie)));
      expect(r.body, isNot(contains('Secret')));
    });

    test('continue watching drops an episode of a private series', () async {
      final r = await hub.get('/api/v1/media/jellyfin', as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      final o = JellyfinOverview.fromJson(r.map);
      final ids = o.continueWatching.map((i) => i.id).toList();
      expect(ids, isNot(contains(_privateResume)));
      expect(ids, hasLength(2));
      expect(o.nextUp, hasLength(1));
    });
  });

  group('GET /media/now-playing', () {
    test('a public session stays (decided by its path)', () async {
      final r = await hub.get('/api/v1/media/now-playing');
      expect(NowPlaying.fromJson(r.map).sessions, hasLength(1));
      expect(
        hub.fakes.callsTo(ServiceId.jellyfin).where((c) => c.path == '/Items'),
        isEmpty,
      );
    });

    test('private users and private items are dropped', () async {
      hub.fakes.fakeJellyfin(mixedSessions: true);
      _fakePrivateJellyfin(hub.fakes);
      final r = await hub.get('/api/v1/media/now-playing');
      final np = NowPlaying.fromJson(r.map);
      expect(np.sessions, isEmpty);
      expect(r.body, isNot(contains('Rudeus')));
    });

    test('controls of a hidden session answer 404', () async {
      hub.fakes.fakeJellyfin(mixedSessions: true);
      _fakePrivateJellyfin(hub.fakes);
      final raw = jsonDecode(
        utf8.decode(syntheticBytes('jellyfin_sessions_mixed.synthetic.json')),
      ) as List<Object?>;
      final rudeus = raw
          .map(readMap)
          .firstWhere((s) => s!['UserName'] == 'Rudeus Greyrat')!;
      final id = (rudeus['Id']! as String).toLowerCase();
      final r = await hub.post(
        '/api/v1/media/sessions/$id/playback',
        body: {'command': 'pause'},
      );
      expect(r.status, 404, reason: r.body);
      expect(
        hub.fakes.callsTo(ServiceId.jellyfin).where((c) => c.method == 'POST'),
        isEmpty,
      );
    });
  });

  group('images', () {
    test('a private item image is 404 and never fetched', () async {
      final r = await hub.get('/api/v1/img/jellyfin/$_adultMovie/Primary');
      expect(r.status, 404);
      expect(
        hub.fakes
            .callsTo(ServiceId.jellyfin)
            .where((c) => c.path.contains('/Images/')),
        isEmpty,
      );
    });

    test('a private library image is 404', () async {
      final r = await hub.get('/api/v1/img/jellyfin/$_adultLib/Primary');
      expect(r.status, 404);
    });

    test('a public item image is served', () async {
      const id = 'f00000000000000000000000000000f1';
      hub.fakes.on(
        ServiceId.jellyfin,
        'GET',
        '/Items/$id/Images/Primary',
        (_) => FakeResponse.bytes(_jpeg),
      );
      final r = await hub.get('/api/v1/img/jellyfin/$id/Primary');
      expect(r.status, 200, reason: r.body);
    });

    test('a private user avatar is 404', () async {
      final r = await hub.get('/api/v1/img/jellyfin-user/$_rudeus');
      expect(r.status, 404);
      hub.fakes.on(
        ServiceId.jellyfin,
        'GET',
        '/Users/4c0628aacef24bdfacd40f946ea33ee7/Images/Primary',
        (_) => FakeResponse.bytes(_jpeg),
      );
      final ok = await hub.get(
        '/api/v1/img/jellyfin-user/4c0628aacef24bdfacd40f946ea33ee7',
      );
      expect(ok.status, 200);
    });
  });

  test('admin Jellyfin users list leaves out private users', () async {
    final r = await hub.get('/api/v1/admin/jellyfin-users');
    expect(r.status, 200, reason: r.body);
    expect(r.body, isNot(contains('Rudeus')));
    expect(r.body, contains('Zenith Greyrat'));
    final imp = await hub.post(
      '/api/v1/admin/jellyfin-users/$_rudeus/import-to-seerr',
    );
    expect(imp.status, 404, reason: imp.body);
  });

  group('Jellystat', () {
    test('stats drop private libraries, items and users', () async {
      const js = ServiceId.jellystat;
      hub.fakes
        ..on(js, 'GET', '/stats/getViewsOverTime', (_) {
          return FakeResponse.json({
            'libraries': [
              {'Id': moviesLibraryId, 'Name': 'Movies'},
              {'Id': _adultLib, 'Name': 'Adult'},
            ],
            'stats': [
              {
                'Key': 'Nov 08, 2026',
                'Movies': {'count': 1, 'duration': 10},
                'Adult': {'count': 7, 'duration': 70},
              },
            ],
          });
        })
        ..on(js, 'POST', '/stats/getMostViewedByType', (_) {
          return FakeResponse.json([
            {'Id': _adultMovie, 'Name': 'Secret', 'Plays': 9},
            {
              'Id': 'f00000000000000000000000000000f1',
              'Name': 'Ok',
              'Plays': 1,
            },
          ]);
        })
        ..on(js, 'POST', '/stats/getMostActiveUsers', (_) {
          return FakeResponse.json([
            {'UserId': _rudeus, 'Name': 'Rudeus Greyrat', 'Plays': 9},
            {
              'UserId': testMemberJellyfinId,
              'Name': 'Zenith Greyrat',
              'Plays': 1,
            },
          ]);
        })
        ..on(js, 'POST', '/stats/getMostViewedLibraries', (_) {
          return FakeResponse.json([
            {'Id': _adultLib, 'Name': 'Adult', 'Plays': 7},
            {'Id': moviesLibraryId, 'Name': 'Movies', 'Plays': 1},
          ]);
        });
      final r = await hub.get('/api/v1/media/stats?days=30');
      expect(r.status, 200, reason: r.body);
      final s = WatchStats.fromJson(r.map);
      expect(s.libraries.map((l) => l.name), ['Movies']);
      expect(s.totals.plays, 1);
      expect(s.viewsOverTime.single.plays.keys, [moviesLibraryId]);
      expect(s.topMovies.map((i) => i.name), ['Ok']);
      expect(s.topUsers.map((u) => u.name), ['Zenith Greyrat']);
      expect(s.topLibraries.map((l) => l.name), ['Movies']);
      expect(r.body, isNot(contains('Secret')));
      expect(r.body, isNot(contains('Adult')));
      expect(r.body, isNot(contains('Rudeus')));
    });

    test('users drop private users and private last-watched items', () async {
      hub.fakes.on(ServiceId.jellystat, 'GET', '/stats/getAllUserActivity', (
        _,
      ) {
        final rows = _fixtureList('seerr/jellystat_getAllUserActivity.json');
        return FakeResponse.json([
          for (final row in rows)
            if (readMap(row)!['UserName'] == 'Zenith Greyrat')
              {
                ...readMap(row)!,
                'NowPlayingItemId': _adultMovie,
                'LastWatched': 'Secret',
              }
            else
              row,
        ]);
      });
      final r = await hub.get('/api/v1/media/stats/users');
      expect(r.status, 200, reason: r.body);
      expect(r.body, isNot(contains('Rudeus')));
      expect(r.body, isNot(contains('Secret')));
      expect(r.body, contains('Zenith Greyrat'));
    });

    test('history drops private users and private items', () async {
      hub.fakes.on(ServiceId.jellystat, 'GET', '/stats/getPlaybackActivity', (
        _,
      ) {
        JsonMap row(String id, String user, String item, String name) => {
          'Id': id,
          'UserId': user == 'Rudeus Greyrat' ? _rudeus : testMemberJellyfinId,
          'UserName': user,
          'NowPlayingItemId': item,
          'NowPlayingItemName': name,
          'ActivityDateInserted': '2026-11-08T08:53:19.346Z',
          'PlayMethod': 'DirectPlay',
          'PlaybackDuration': 10,
        };
        return FakeResponse.json({
          'pages': 1,
          'results': [
            row('1', 'Zenith Greyrat', _adultMovie, 'Secret'),
            row('2', 'Rudeus Greyrat', 'f00000000000000000000000000000f1', 'X'),
            row(
              '3',
              'Zenith Greyrat',
              'f00000000000000000000000000000f1',
              'Ok',
            ),
          ],
        });
      });
      final r = await hub.get('/api/v1/media/stats/history');
      expect(r.status, 200, reason: r.body);
      final items = readList(r.map['items'], (m) => m);
      expect(items.map((i) => i['title']), ['Ok']);
    });
  });

  group('a private user renamed in Jellystat is matched by id', () {
    test('users, history and top users', () async {
      const js = ServiceId.jellystat;
      hub.fakes
        ..on(js, 'GET', '/stats/getAllUserActivity', (_) {
          return FakeResponse.json([
            {'UserId': _rudeus, 'UserName': 'Rudy', 'TotalPlays': 3},
            {
              'UserId': testMemberJellyfinId,
              'UserName': 'Zenith Greyrat',
              'TotalPlays': 1,
            },
          ]);
        })
        ..on(js, 'GET', '/stats/getPlaybackActivity', (_) {
          return FakeResponse.json({
            'pages': 1,
            'results': [
              for (final (id, user) in [
                (_rudeus, 'Rudy'),
                (testMemberJellyfinId, 'Zenith Greyrat'),
              ])
                {
                  'Id': user,
                  'UserId': id,
                  'UserName': user,
                  'NowPlayingItemId': 'f00000000000000000000000000000f1',
                  'NowPlayingItemName': 'Ok',
                  'ActivityDateInserted': '2026-11-08T08:53:19.346Z',
                },
            ],
          });
        })
        ..on(js, 'POST', '/stats/getMostActiveUsers', (_) {
          return FakeResponse.json([
            {'UserId': _rudeus, 'Name': 'Rudy', 'Plays': 9},
          ]);
        });
      final users = await hub.get('/api/v1/media/stats/users');
      expect(users.status, 200, reason: users.body);
      expect(users.body, isNot(contains('Rudy')));
      expect(users.body, contains('Zenith Greyrat'));
      final history = await hub.get('/api/v1/media/stats/history');
      expect(history.body, isNot(contains('Rudy')));
      expect(history.body, contains('Zenith Greyrat'));
      final stats = await hub.get('/api/v1/media/stats?days=30');
      expect(stats.status, 200, reason: stats.body);
      expect(WatchStats.fromJson(stats.map).topUsers, isEmpty);
    });
  });

  group('names that match nothing', () {
    TestHub withLibraries(String names) {
      final h = TestHub(env: {'PRIVATE_JELLYFIN_LIBRARIES': names});
      addTearDown(h.close);
      h.fakes.fakeJellyfin();
      h.fakes.fakeJellystat();
      _fakePrivateJellyfin(h.fakes);
      return h;
    }

    test('an unknown library name warns admins on the dashboard', () async {
      final typo = withLibraries('Adlt');
      final admin = DashboardResponse.fromJson(
        (await typo.get('/api/v1/dashboard?cards=media')).map,
      );
      final alert = admin.alerts.singleWhere(
        (a) => a.id == 'privacy.jellyfin.libraries',
      );
      expect(alert.title, contains('PRIVATE_JELLYFIN_LIBRARIES'));
      expect(alert.message, contains('"adlt"'));
      final member = await typo.get(
        '/api/v1/dashboard?cards=media',
        as: TestAs.member,
      );
      expect(member.body, isNot(contains('privacy.jellyfin')));
      expect(member.body, isNot(contains('adlt')));
    });

    test('only the unmatched names are reported', () async {
      final r = await hub.get('/api/v1/dashboard?cards=media');
      final alerts = DashboardResponse.fromJson(r.map).alerts;
      // setUp's list is " adult ,Nope": only "nope" matches nothing.
      expect(
        alerts.singleWhere((a) => a.id == 'privacy.jellyfin.libraries').message,
        allOf(contains('"nope"'), isNot(contains('adult'))),
      );
      final ok = await withLibraries('Adult')
          .get('/api/v1/dashboard?cards=media');
      expect(ok.body, isNot(contains('privacy.jellyfin')));
    });
  });

  test(
    'without settings nothing is hidden and no extra call is made',
    () async {
      final plain = TestHub();
      addTearDown(plain.close);
      plain.fakes.fakeJellyfin(mixedSessions: true);
      plain.fakes.fakeJellystat();
      plain.fakes.on(
        ServiceId.jellyfin,
        'GET',
        '/Library/VirtualFolders',
        (_) => FakeResponse.json(_folders()),
      );
      final o = JellyfinOverview.fromJson(
        (await plain.get('/api/v1/media/jellyfin')).map,
      );
      expect(o.libraries.map((l) => l.name), contains('Adult'));
      expect(o.counts.movies, 179);
      final np = NowPlaying.fromJson(
        (await plain.get('/api/v1/media/now-playing')).map,
      );
      expect(np.sessions.map((s) => s.userName), contains('Rudeus Greyrat'));
      final users = await plain.get('/api/v1/admin/jellyfin-users');
      expect(users.body, contains('Rudeus'));
      final jf = plain.fakes.callsTo(ServiceId.jellyfin);
      expect(jf.where((c) => c.query.containsKey('ids')), isEmpty);
      expect(jf.where((c) => c.query['limit']?.first == '0'), isEmpty);
      final latest = jf.firstWhere((c) => c.path == '/Items/Latest');
      expect(latest.query['fields'], ['DateCreated']);
    },
  );
}
