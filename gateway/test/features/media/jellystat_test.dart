import 'dart:convert';

import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/core/auth/records.dart';
import 'package:yams_hub_gateway/src/features/media/jellystat_service.dart';

import '../../support/test_hub.dart';
import 'media_fakes.dart';

/// Jellystat routes the hub must never call (integrations/seerr.md §3.3).
final _forbiddenJellystat = RegExp(
  r'^/(api/keys|api/getconfig|sync/|backup/|api/stopTask|api/setconfig|proxy/)',
);

void main() {
  late TestHub hub;

  setUp(() {
    hub = TestHub();
    hub.fakes.fakeJellystat();
  });
  tearDown(() async {
    for (final c in hub.fakes.callsTo(ServiceId.jellystat)) {
      expect(_forbiddenJellystat.hasMatch(c.path), isFalse, reason: '$c');
    }
    await hub.close();
  });

  group('GET /media/stats', () {
    test('assembles the stats from every Jellystat query', () async {
      final r = await hub.get('/api/v1/media/stats?days=7', as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      final s = WatchStats.fromJson(r.map);
      expect(s.days, 7);
      expect(s.partial, isFalse);
      expect(s.libraries.map((l) => l.name), ['Movies', 'Shows']);

      // Library names become ids, dates are ISO, minutes become seconds.
      expect(s.viewsOverTime.map((p) => p.date), ['2026-11-07', '2026-11-08']);
      expect(s.viewsOverTime.first.plays[moviesLibraryId], 2);
      expect(s.viewsOverTime.first.durationSeconds[moviesLibraryId], 166 * 60);
      expect(s.viewsOverTime.last.plays[showsLibraryId], 1);
      expect(s.totals.plays, 3);
      expect(s.totals.durationSeconds, (166 + 26) * 60);

      expect(s.byWeekday, hasLength(7));
      expect(s.byWeekday.first.day, WatchWeekday.monday);
      expect(s.byWeekday.last.day, WatchWeekday.sunday);
      expect(s.byWeekday.last.plays, 1);
      expect(s.byHour, hasLength(24));
      expect(s.byHour.every((h) => h.plays == 0), isTrue);

      expect(s.playMethods.single.method, MediaPlayMethod.directPlay);
      expect(s.playMethods.single.count, 1);
      expect(s.topMovies, isEmpty);
      final top = s.topSeries.single;
      expect(top.name, 'Desperate Housewives');
      expect(top.plays, 1);
      expect(top.durationSeconds, 1559);
      // BlurHash is ignored; the poster comes from Jellyfin.
      expect(
        top.imagePath,
        startsWith(
          '/api/v1/img/jellyfin/9efa4240a1af422beff21712c58c218d/Primary',
        ),
      );
      expect(s.popularSeries.single.uniqueViewers, 1);
      expect(s.topUsers.single.name, 'Zenith Greyrat');
      expect(s.topClients.single.client, 'Jellyfin Android TV');
      expect(s.topLibraries.single.name, 'Shows');

      final calls = hub.fakes.callsTo(ServiceId.jellystat);
      final views = calls.firstWhere(
        (c) => c.path == '/stats/getViewsOverTime',
      );
      expect(views.query['days'], ['7']);
      final posts = calls.where((c) => c.method == 'POST').toList();
      expect(posts, hasLength(7));
      for (final p in posts) {
        expect((jsonDecode(p.body) as Map)['days'], 7, reason: p.path);
      }
      final types = [
        for (final p in posts)
          if (p.path == '/stats/getMostViewedByType')
            (jsonDecode(p.body) as Map)['type'],
      ];
      expect(types, unorderedEquals(['Movie', 'Series']));
      expect(
        jsonDecode(
          posts.firstWhere((p) => p.path == '/stats/getMostPopularByType').body,
        ),
        {'days': 7, 'type': 'Series'},
      );
    });

    test('defaults to 30 days and rejects other periods', () async {
      final r = await hub.get('/api/v1/media/stats');
      expect(WatchStats.fromJson(r.map).days, 30);
      final bad = await hub.get('/api/v1/media/stats?days=14');
      expect(bad.status, 400);
      expect(bad.errorCode, 'bad_request');
    });

    test('a failing query leaves its part empty and marks partial', () async {
      hub.fakes.on(
        ServiceId.jellystat,
        'POST',
        '/stats/getMostUsedClient',
        (_) => FakeResponse.text('Days needs to be a number.', status: 503),
      );
      final r = await hub.get('/api/v1/media/stats');
      expect(r.status, 200);
      final s = WatchStats.fromJson(r.map);
      expect(s.partial, isTrue);
      expect(s.topClients, isEmpty);
      expect(s.topUsers, isNotEmpty);
    });

    test('when every query fails the error is returned', () async {
      hub.fakes.on(
        ServiceId.jellystat,
        '*',
        RegExp('.*'),
        (_) => FakeResponse.json({'message': 'Invalid API key'}, status: 403),
      );
      final r = await hub.get('/api/v1/media/stats');
      expect(r.status, 502);
      expect(r.errorCode, 'upstream_auth_failed');
    });

    test('Jellystat not configured is 503', () async {
      final h = TestHub(unconfigured: {ServiceId.jellystat});
      addTearDown(h.close);
      final r = await h.get('/api/v1/media/stats');
      expect(r.status, 503);
      expect(r.errorCode, 'service_not_configured');
    });
  });

  group('GET /media/stats/users', () {
    test('per-user activity with last seen as an instant', () async {
      final r = await hub.get('/api/v1/media/stats/users', as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      final users = ItemList.fromJson(r.map, WatchUser.fromJson).items;
      expect(users, hasLength(4));
      final zenith = users.first;
      expect(zenith.name, 'Zenith Greyrat');
      expect(zenith.totalPlays, 1);
      expect(zenith.totalWatchSeconds, 1559);
      expect(zenith.lastWatched, contains('Desperate Housewives'));
      expect(zenith.lastClient, 'Jellyfin Android TV - Xiaomi TV Box');
      // LastSeen {minutes: 5, seconds: 11, milliseconds: 432.298}.
      expect(
        zenith.lastSeenAt,
        hub.clock.now().subtract(
          const Duration(minutes: 5, seconds: 11, milliseconds: 432),
        ),
      );
      expect(zenith.avatarPath, contains('/img/jellyfin-user/'));
      final paul = users.firstWhere((u) => u.name == 'Paul Greyrat');
      expect(paul.lastSeenAt, isNull);
      expect(paul.totalWatchSeconds, 0);
    });
  });

  group('GET /media/stats/history', () {
    test('admins see everyone, newest first', () async {
      final r = await hub.get('/api/v1/media/stats/history');
      expect(r.status, 200, reason: r.body);
      final page = PagedList.fromJson(r.map, PlaybackRecord.fromJson);
      expect(page.page, 1);
      expect(page.pageSize, 25);
      expect(page.total, 1);
      expect(page.hasMore, isFalse);
      final rec = page.items.single;
      expect(rec.title, 'The Story of Lucy and Jessie');
      expect(rec.seriesName, 'Desperate Housewives');
      expect(rec.device, 'Xiaomi TV Box');
      expect(rec.playMethod, MediaPlayMethod.directPlay);
      expect(rec.durationSeconds, 1559);
      expect(rec.at, DateTime.utc(2026, 11, 8, 8, 53, 19, 346));
      // The episode image, not the series id in NowPlayingItemId.
      expect(rec.imagePath, contains('cde3668a5433ba3171ff466f1693e2f3'));

      final call = hub.fakes.callsTo(ServiceId.jellystat).last;
      expect(call.path, '/stats/getPlaybackActivity');
      expect(call.query['sort'], ['ActivityDateInserted']);
      expect(call.query['desc'], ['true']);
      expect(call.query['size'], ['25']);
      expect(call.query['page'], ['1']);
      expect(call.query.containsKey('filters'), isFalse);
    });

    test('admins can filter by user (scoped by Jellystat)', () async {
      final r = await hub.get(
        '/api/v1/media/stats/history?userId=8BED8D8C-CCF2-4954-8EB6-A39FD6A7E54B&pageSize=10',
      );
      expect(r.status, 200, reason: r.body);
      final call = hub.fakes.callsTo(ServiceId.jellystat).last;
      expect(call.method, 'POST');
      expect(call.path, '/api/getUserHistory');
      expect(jsonDecode(call.body), {
        'userid': '8bed8d8cccf249548eb6a39fd6a7e54b',
      });
      expect(call.query['size'], ['10']);
      expect(call.query['sort'], ['ActivityDateInserted']);
      expect(call.query.containsKey('filters'), isFalse);
      final page = PagedList.fromJson(r.map, PlaybackRecord.fromJson);
      expect(page.items.single.title, 'The Story of Lucy and Jessie');
      final bad = await hub.get('/api/v1/media/stats/history?userId=nope');
      expect(bad.status, 400);
    });

    test('members are scoped to their own Jellyfin user', () async {
      final r = await hub.get(
        '/api/v1/media/stats/history?userId=4c0628aacef24bdfacd40f946ea33ee7',
        as: TestAs.member,
      );
      expect(r.status, 200);
      final call = hub.fakes.callsTo(ServiceId.jellystat).last;
      expect(call.path, '/api/getUserHistory');
      expect(jsonDecode(call.body), {'userid': testMemberJellyfinId});
    });

    test(
      'rows of other users are dropped even if Jellystat sends them',
      () async {
        final data = jsonDecode(
          jsonEncode(fixture('seerr/jellystat_api_getHistory.json')),
        ) as JsonMap;
        final own = (data['results']! as List).single as JsonMap;
        hub.fakes.on(
          ServiceId.jellystat,
          'POST',
          '/api/getUserHistory',
          (_) => FakeResponse.json({
            ...data,
            'results': [
              {
                ...own,
                'Id': 'someone-else',
                'UserId': '4c0628aacef24bdfacd40f946ea33ee7',
                'UserName': 'Paul Greyrat',
              },
              own,
            ],
          }),
        );
        final r = await hub.get(
          '/api/v1/media/stats/history',
          as: TestAs.member,
        );
        expect(r.status, 200, reason: r.body);
        final page = PagedList.fromJson(r.map, PlaybackRecord.fromJson);
        expect(page.items.map((i) => i.userName), ['Zenith Greyrat']);
        expect(r.body, isNot(contains('Paul Greyrat')));
      },
    );

    test('unlinked members get an empty page without a call', () async {
      await hub.ready;
      final updated = UserRecord(
        id: hub.member.id,
        username: hub.member.username,
        displayName: hub.member.displayName,
        role: Role.member,
        passwordHash: hub.member.passwordHash,
        createdAt: hub.member.createdAt,
        updatedAt: hub.member.updatedAt,
      );
      await hub.hub.auth.users.put(updated);
      hub.fakes.clearCalls();
      final r = await hub.get('/api/v1/media/stats/history', as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      final page = PagedList.fromJson(r.map, PlaybackRecord.fromJson);
      expect(page.items, isEmpty);
      expect(page.total, 0);
      expect(hub.fakes.callsTo(ServiceId.jellystat), isEmpty);
    });

    test('pageSize is capped at 50', () async {
      final r = await hub.get('/api/v1/media/stats/history?pageSize=51');
      expect(r.status, 400);
    });
  });

  group('mapping', () {
    test('Jellystat dates', () {
      expect(parseJellystatDate('Nov 01, 2026'), '2026-11-01');
      expect(parseJellystatDate('Sep 9, 2026'), '2026-09-09');
      expect(parseJellystatDate('2026-11-08T00:00:00Z'), '2026-11-08');
      expect(parseJellystatDate('Monday'), isNull);
      expect(parseJellystatDate(null), isNull);
    });

    test('Postgres intervals', () {
      expect(
        parsePgInterval({'days': 1, 'hours': 2, 'milliseconds': 500.4}),
        const Duration(days: 1, hours: 2, milliseconds: 500),
      );
      expect(parsePgInterval({}), Duration.zero);
      expect(parsePgInterval(null), isNull);
    });
  });
}
