import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/features/media/jellyfin_service.dart';

import '../../support/test_hub.dart';
import 'media_fakes.dart';

void main() {
  late TestHub hub;

  setUp(() {
    hub = TestHub();
    hub.fakes.fakeJellyfin();
    hub.fakes.fakeJellystat();
  });
  tearDown(() => hub.close());

  group('GET /media/now-playing', () {
    test('maps the playing session and drops idle ones', () async {
      final r = await hub.get('/api/v1/media/now-playing');
      expect(r.status, 200, reason: r.body);
      final np = NowPlaying.fromJson(r.map);
      expect(np.sessions, hasLength(1));
      expect(np.transcoding, 0);
      expect(np.hwAccel, 'qsv');
      final s = np.sessions.single;
      expect(s.id, 'eb96632f72ed3854021c5466f350a158');
      expect(s.userName, 'Zenith Greyrat');
      expect(s.itemType, NowPlayingItemType.episode);
      expect(s.title, 'A Spark. To Pierce the Dark.');
      expect(s.seriesName, 'Desperate Housewives');
      expect(s.episodeCode, 'S05E18');
      expect(s.year, isNull);
      expect(s.runtimeSeconds, 2583);
      expect(s.positionSeconds, 165);
      expect(s.progress, closeTo(0.064, 0.001));
      expect(s.paused, isFalse);
      expect(s.playMethod, MediaPlayMethod.directPlay);
      expect(s.transcode, isNull);
      expect(s.remoteAddress, '192.168.10.160');
      expect(s.canControl, isTrue);
      expect(
        s.imagePath,
        startsWith(
          '/api/v1/img/jellyfin/d078a144bb4719f0e6babd8d90ba0b11/Primary',
        ),
      );
      expect(s.imagePath, contains('tag=dbb58187fd3e6443369f536fb7a75908'));
      expect(s.backdropPath, contains('9efa4240a1af422beff21712c58c218d'));
      expect(s.userImagePath, contains('/img/jellyfin-user/'));
      expect(s.jellyfin!.app, ExternalApp.jellyfin);
      expect(
        s.jellyfin!.path,
        '/web/#/details?id=d078a144bb4719f0e6babd8d90ba0b11'
        '&serverId=$jellyfinServerId',
      );

      final call = hub.fakes
          .callsTo(ServiceId.jellyfin)
          .firstWhere((c) => c.path == '/Sessions');
      expect(call.query['activeWithinSeconds'], ['960']);
    });

    test('members get no client address and no controls', () async {
      final r = await hub.get('/api/v1/media/now-playing', as: TestAs.member);
      expect(r.status, 200);
      final s = NowPlaying.fromJson(r.map).sessions.single;
      expect(s.remoteAddress, isNull);
      expect(s.canControl, isFalse);
      expect(r.body, isNot(contains('192.168.10.160')));
    });

    test('transcodes, pseudo sessions and unknown reasons', () async {
      hub.fakes.fakeJellyfin(mixedSessions: true);
      final r = await hub.get('/api/v1/media/now-playing');
      final np = NowPlaying.fromJson(r.map);
      // Homepage's API-key session and the idle web session are dropped.
      expect(np.sessions.map((s) => s.client), ['Jellyfin Web', 'Finamp']);
      expect(np.transcoding, 1);
      final movie = np.sessions.first;
      expect(movie.id, 'aa11bb22cc33dd44ee55ff6677889900');
      expect(movie.itemId, '4fcea1b4d58b05010e29c1cea2be02d4');
      expect(movie.itemType, NowPlayingItemType.movie);
      expect(movie.year, 2024);
      expect(movie.playMethod, MediaPlayMethod.transcode);
      expect(movie.transcode!.hwAccel, 'qsv');
      expect(movie.transcode!.reasons, [
        'VideoCodecNotSupported',
        'BrandNewReason',
      ]);
      expect(movie.transcode!.bitrate, 8000000);
      expect(movie.transcode!.width, 1920);
      expect(movie.progress, closeTo(36 / 99.6, 0.0001));
      expect(movie.backdropPath, contains('/Backdrop'));
      final song = np.sessions.last;
      expect(song.itemType, NowPlayingItemType.audio);
      expect(song.paused, isTrue);
      expect(song.playMethod, MediaPlayMethod.directStream);
      expect(song.imagePath, isNull);
      expect(song.canControl, isFalse, reason: 'SupportsMediaControl false');
    });

    test('an audio-only transcode is reported as direct stream', () async {
      await hub.ready;
      final images = hub.ctx.images;
      final s = mapSession(
        {
          'Id': 'a' * 32,
          'Client': 'Jellyfin Web',
          'PlayState': {'PlayMethod': 'Transcode', 'PositionTicks': 0},
          'TranscodingInfo': {
            'IsVideoDirect': true,
            'IsAudioDirect': false,
            'HardwareAccelerationType': 'none',
            'TranscodeReasons': 'AudioCodecNotSupported',
          },
          'NowPlayingItem': {'Id': 'b' * 32, 'Type': 'Movie', 'Name': 'X'},
        },
        images: images,
        isAdmin: true,
      )!;
      expect(s.playMethod, MediaPlayMethod.directStream);
      expect(s.transcode!.hwAccel, isNull);
      expect(s.transcode!.reasons, ['AudioCodecNotSupported']);
      expect(s.jellyfin, isNull);
    });

    test('Jellyfin down is 503', () async {
      hub.fakes.on(
        ServiceId.jellyfin,
        'GET',
        '/Sessions',
        (_) => throw const SocketException('refused'),
      );
      final r = await hub.get('/api/v1/media/now-playing');
      expect(r.status, 503);
      expect(r.errorCode, 'upstream_unavailable');
    });

    test('a rejected key is 502 upstream_auth_failed', () async {
      hub.fakes.on(
        ServiceId.jellyfin,
        'GET',
        '/Sessions',
        (_) => FakeResponse(401),
      );
      final r = await hub.get('/api/v1/media/now-playing');
      expect(r.status, 502);
      expect(r.errorCode, 'upstream_auth_failed');
    });
  });

  group('session commands', () {
    const sid = 'eb96632f72ed3854021c5466f350a158';

    test('pause, unpause and stop reach Jellyfin', () async {
      for (final (cmd, verb) in [
        ('pause', 'Pause'),
        ('unpause', 'Unpause'),
        ('stop', 'Stop'),
      ]) {
        final r = await hub.post(
          '/api/v1/media/sessions/$sid/playback',
          body: {'command': cmd},
        );
        expect(r.status, 204, reason: r.body);
        expect(hub.fakes.calls.last.path, '/Sessions/$sid/Playing/$verb');
        expect(hub.fakes.calls.last.method, 'POST');
      }
      final audit = await hub.get(
        '/api/v1/admin/audit?action=media.sessions.playback',
      );
      expect(readList(audit.map['items'], (m) => m), hasLength(3));
    });

    test('upper-case session ids are normalised', () async {
      final r = await hub.post(
        '/api/v1/media/sessions/${sid.toUpperCase()}/playback',
        body: {'command': 'pause'},
      );
      expect(r.status, 204);
      expect(hub.fakes.calls.last.path, '/Sessions/$sid/Playing/Pause');
    });

    test('an unknown command is 400 and calls nothing', () async {
      hub.fakes.clearCalls();
      final r = await hub.post(
        '/api/v1/media/sessions/$sid/playback',
        body: {'command': 'rewind'},
      );
      expect(r.status, 400);
      expect(hub.fakes.callsTo(ServiceId.jellyfin), isEmpty);
    });

    test('members are forbidden', () async {
      hub.fakes.clearCalls();
      final r = await hub.post(
        '/api/v1/media/sessions/$sid/playback',
        body: {'command': 'stop'},
        as: TestAs.member,
      );
      expect(r.status, 403);
      expect(hub.fakes.callsTo(ServiceId.jellyfin), isEmpty);
    });

    test('a session that ended is 404', () async {
      hub.fakes.on(
        ServiceId.jellyfin,
        'POST',
        '/Sessions/$sid/Playing/Stop',
        (_) => FakeResponse(404),
      );
      final r = await hub.post(
        '/api/v1/media/sessions/$sid/playback',
        body: {'command': 'stop'},
      );
      expect(r.status, 404);
      expect(r.errorCode, 'not_found');
    });

    test('message sends Header, Text and TimeoutMs', () async {
      final r = await hub.post(
        '/api/v1/media/sessions/$sid/message',
        body: {'text': '  Server restarting in 5 min  '},
      );
      expect(r.status, 204, reason: r.body);
      final call = hub.fakes.calls.last;
      expect(call.path, '/Sessions/$sid/Message');
      expect(jsonDecode(call.body), {
        'Header': 'YAMS Hub',
        'Text': 'Server restarting in 5 min',
        'TimeoutMs': 10000,
      });
    });

    test('message validation is 422 with fields', () async {
      final r = await hub.post(
        '/api/v1/media/sessions/$sid/message',
        body: {'text': '', 'timeoutMs': 5},
      );
      expect(r.status, 422);
      final fields = readList(
        readMap(r.map['error'])!['fields'],
        (m) => m['field'],
      );
      expect(fields, containsAll(['text', 'timeoutMs']));
      final long = await hub.post(
        '/api/v1/media/sessions/$sid/message',
        body: {'text': 'x' * 201, 'header': 'Admin'},
      );
      expect(long.status, 422);
    });
  });

  group('GET /media/jellyfin', () {
    test('overview for a linked member', () async {
      final r = await hub.get('/api/v1/media/jellyfin', as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      final o = JellyfinOverview.fromJson(r.map);
      expect(o.server.name, 'Zenith');
      expect(o.server.version, '12.4.0');
      expect(o.server.hwAccel, 'qsv');
      expect(o.counts.movies, 179);
      expect(o.counts.series, 54);
      expect(o.counts.episodes, 1694);
      expect(o.counts.books, 2);

      expect(o.libraries.map((l) => l.name), [
        'Movies',
        'Shows',
        'Music',
        'Books',
      ]);
      final shows = o.libraries[1];
      expect(shows.type, JellyfinLibraryType.tvshows);
      expect(shows.sizeBytes, 2775587676767);
      expect(shows.files, 1695);
      expect(shows.itemCount, 54);
      expect(shows.refreshing, isFalse);
      expect(o.libraries[2].sizeBytes, isNull);

      // /Items/Latest per movies/tvshows library as the admin user,
      // interleaved in Jellyfin's own order (a grouped Season's own
      // DateCreated can be months old even when its episodes are new).
      final latest = hub.fakes
          .callsTo(ServiceId.jellyfin)
          .where((c) => c.path == '/Items/Latest')
          .toList();
      expect(latest.map((c) => c.query['parentId']!.single).toSet(), {
        moviesLibraryId,
        showsLibraryId,
      });
      expect(latest.first.query['userId'], [jellyfinAdminId]);
      expect(o.recentlyAdded, isNotEmpty);
      expect(o.recentlyAdded.length, lessThanOrEqualTo(16));
      expect(o.recentlyAdded.take(4).map((i) => i.title), [
        'Dune: Part Two',
        'That Time I Got Reincarnated as a Slime',
        'Dune',
        'The Apothecary Diaries',
      ]);
      // Re:ZERO's season row (created in February, new episodes now) is kept.
      expect(
        o.recentlyAdded.map((i) => i.title),
        contains('Re:ZERO -Starting Life in Another World-'),
      );
      final slime = o.recentlyAdded.firstWhere(
        (i) => i.title == 'That Time I Got Reincarnated as a Slime',
      );
      expect(slime.type, MediaItemType.series);
      expect(slime.newEpisodeCount, 48);
      final season = o.recentlyAdded.firstWhere(
        (i) => i.type == MediaItemType.season,
      );
      expect(season.title, 'The Ramparts of Ice');
      expect(season.subtitle, 'Season 2');

      // Rows for the member's linked Jellyfin user.
      final resume = hub.fakes
          .callsTo(ServiceId.jellyfin)
          .firstWhere((c) => c.path == '/UserItems/Resume');
      expect(resume.query['userId'], [testMemberJellyfinId]);
      expect(o.continueWatching, hasLength(3));
      final first = o.continueWatching.first;
      expect(first.title, 'Clevatess');
      expect(first.subtitle, 'S01E06 · Insect Controlling Wizard');
      expect(first.progress, closeTo(0.4914, 0.0001));
      expect(first.imagePath, contains('8333708745b725b410b5fc52678cdd5d'));
      expect(o.nextUp.single.subtitle, "S05E19 · Now That I'm Here");
      expect(o.nextUp.single.jellyfin!.path, contains(jellyfinServerId));
    });

    test('an unlinked admin gets empty personal rows', () async {
      final r = await hub.get('/api/v1/media/jellyfin');
      final o = JellyfinOverview.fromJson(r.map);
      expect(o.continueWatching, isEmpty);
      expect(o.nextUp, isEmpty);
      expect(
        hub.fakes.callsTo(ServiceId.jellyfin).map((c) => c.path),
        isNot(contains('/UserItems/Resume')),
      );
    });

    test('falls back to /Items when the latest rows fail', () async {
      hub.fakes.on(
        ServiceId.jellyfin,
        'GET',
        '/Items/Latest',
        (_) => FakeResponse(500),
      );
      final r = await hub.get('/api/v1/media/jellyfin');
      expect(r.status, 200);
      final o = JellyfinOverview.fromJson(r.map);
      final call = hub.fakes
          .callsTo(ServiceId.jellyfin)
          .firstWhere((c) => c.path == '/Items');
      expect(call.query['includeItemTypes'], ['Movie,Episode']);
      expect(call.query['sortBy'], ['DateCreated']);
      expect(o.recentlyAdded.first.type, MediaItemType.episode);
      expect(
        o.recentlyAdded.first.title,
        'That Time I Got Reincarnated as a Slime',
      );
      expect(o.recentlyAdded.first.subtitle, 'S04E01 · New Days');
    });

    test('Jellystat failures do not break the overview', () async {
      hub.fakes.on(
        ServiceId.jellystat,
        'GET',
        '/stats/getLibraryMetadata',
        (_) => FakeResponse.text('Days needs to be a number.', status: 503),
      );
      final r = await hub.get('/api/v1/media/jellyfin');
      expect(r.status, 200);
      final o = JellyfinOverview.fromJson(r.map);
      expect(o.libraries.every((l) => l.sizeBytes == null), isTrue);
    });

    test('a missing upstream route is a 502, not a 404', () async {
      hub.fakes.on(
        ServiceId.jellyfin,
        'GET',
        '/Items/Counts',
        (_) => FakeResponse(404),
      );
      final r = await hub.get('/api/v1/media/jellyfin');
      expect(r.status, 502);
      expect(r.errorCode, 'upstream_error');
    });
  });

  group('POST /media/jellyfin/library/refresh', () {
    test('queues a scan', () async {
      final r = await hub.post('/api/v1/media/jellyfin/library/refresh');
      expect(r.status, 202);
      expect(r.map, {'queued': true});
      expect(hub.fakes.calls.last.path, '/Library/Refresh');
      expect(hub.fakes.calls.last.method, 'POST');
    });

    test('members are forbidden', () async {
      final r = await hub.post(
        '/api/v1/media/jellyfin/library/refresh',
        as: TestAs.member,
      );
      expect(r.status, 403);
    });
  });

  test('Jellyfin not configured is 503 service_not_configured', () async {
    final h = TestHub(unconfigured: {ServiceId.jellyfin});
    addTearDown(h.close);
    final r = await h.get('/api/v1/media/now-playing');
    expect(r.status, 503);
    expect(r.errorCode, 'service_not_configured');
  });

  test('interleave keeps every element and each list order', () {
    expect(
      interleave([
        [1, 2, 3],
        [10],
        [20, 21],
      ]),
      [1, 10, 20, 2, 21, 3],
    );
    expect(interleave(<List<int>>[]), isEmpty);
  });
}
