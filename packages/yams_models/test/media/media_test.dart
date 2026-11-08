import 'package:test/test.dart';
import 'package:yams_models/yams_models.dart';

import '../core/round_trip.dart';

const _serverId = '79315eab3c4c401f8391d5c26210b6d7';

JsonMap _jfLink(String id) => {
  'app': 'jellyfin',
  'path': '/web/#/details?id=$id&serverId=$_serverId',
};

final _session = <String, Object?>{
  'id': 'eb96632f72ed3854021c5466f350a158',
  'userName': 'Zenith Greyrat',
  'userId': '8bed8d8cccf249548eb6a39fd6a7e54b',
  'client': 'Jellyfin Android TV',
  'deviceName': 'Xiaomi TV Box',
  'itemId': 'd078a144bb4719f0e6babd8d90ba0b11',
  'itemType': 'episode',
  'title': 'A Spark. To Pierce the Dark.',
  'seriesName': 'Desperate Housewives',
  'seasonNumber': 5,
  'episodeNumber': 18,
  'runtimeSeconds': 2583,
  'positionSeconds': 165,
  'progress': 0.064,
  'paused': false,
  'playMethod': 'transcode',
  'transcode': {
    'videoCodec': 'h264',
    'audioCodec': 'aac',
    'container': 'ts',
    'hwAccel': 'qsv',
    'reasons': ['VideoCodecNotSupported', 'SomeFutureReason'],
    'bitrate': 8000000,
    'completionPercent': 12.5,
    'videoDirect': false,
    'audioDirect': true,
    'width': 1920,
    'height': 1080,
  },
  'imagePath': '/api/v1/img/jellyfin/d078a144bb4719f0e6babd8d90ba0b11/Primary?tag=dbb58187fd3e6443369f536fb7a75908',
  'backdropPath':
      '/api/v1/img/jellyfin/9efa4240a1af422beff21712c58c218d/Backdrop?index=0',
  'userImagePath': '/api/v1/img/jellyfin-user/8bed8d8cccf249548eb6a39fd6a7e54b',
  'remoteAddress': '192.168.10.160',
  'jellyfin': _jfLink('d078a144bb4719f0e6babd8d90ba0b11'),
  'canControl': true,
};

final _item = <String, Object?>{
  'id': '71fb0b620791c8c3ea2ad7ba6ca6e787',
  'type': 'series',
  'title': 'That Time I Got Reincarnated as a Slime',
  'subtitle': '48 new episodes',
  'year': 2018,
  'imagePath': '/api/v1/img/jellyfin/71fb0b620791c8c3ea2ad7ba6ca6e787/Primary',
  'addedAt': '2026-11-06T23:35:57.261Z',
  'newEpisodeCount': 48,
  'progress': 0.25,
  'jellyfin': _jfLink('71fb0b620791c8c3ea2ad7ba6ca6e787'),
};

JsonMap _absLink(String path) => {'app': 'audiobookshelf', 'path': path};

JsonMap _series(int id) => {
  'id': id,
  'name': 'Ascendance of a Bookworm',
  'libraryId': 1,
  'libraryName': 'Books',
  'coverPath': '/api/v1/img/kavita/series/$id',
  'pages': 320,
  'pagesRead': 80,
  'format': 'epub',
  'link': {'app': 'kavita', 'path': '/library/1/series/$id'},
};

void main() {
  group('now playing', () {
    test('NowPlayingSession round trip and helpers', () {
      final s = expectRoundTrip(
        _session,
        NowPlayingSession.fromJson,
        (s) => s.toJson(),
      );
      expect(s.itemType, NowPlayingItemType.episode);
      expect(s.episodeCode, 'S05E18');
      expect(s.isTranscoding, isTrue);
      expect(s.transcode!.reasons, contains('SomeFutureReason'));
      expect(s.jellyfin!.app, ExternalApp.jellyfin);
    });

    test('minimal session omits optional fields', () {
      final minimal = <String, Object?>{
        'id': 'a' * 32,
        'userName': '',
        'client': 'Jellyfin Web',
        'deviceName': 'Safari',
        'itemId': 'b' * 32,
        'itemType': 'movie',
        'title': 'Dune',
        'positionSeconds': 0,
        'progress': 0.0,
        'paused': true,
        'playMethod': 'directPlay',
        'canControl': false,
      };
      final s = expectRoundTrip(
        minimal,
        NowPlayingSession.fromJson,
        (s) => s.toJson(),
      );
      expect(s.episodeCode, isNull);
      expect(s.remoteAddress, isNull);
    });

    test('unknown enum strings map to unknown', () {
      final s = NowPlayingSession.fromJson({
        ..._session,
        'itemType': 'trailer',
        'playMethod': 'teleport',
      });
      expect(s.itemType, NowPlayingItemType.unknown);
      expect(s.playMethod, MediaPlayMethod.unknown);
    });

    test('NowPlaying round trip', () {
      final np = expectRoundTrip(
        {
          'sessions': [_session],
          'transcoding': 1,
          'hwAccel': 'qsv',
        },
        NowPlaying.fromJson,
        (n) => n.toJson(),
      );
      expect(np.sessions.single.id, _session['id']);
    });

    test('MediaSessionMessage round trip', () {
      expectRoundTrip(
        {'text': 'Server restarting', 'header': 'YAMS Hub', 'timeoutMs': 10000},
        MediaSessionMessage.fromJson,
        (m) => m.toJson(),
      );
      expect(MediaPlaybackCommand.fromJson('stop'), MediaPlaybackCommand.stop);
      expect(
        MediaPlaybackCommand.fromJson('rewind'),
        MediaPlaybackCommand.unknown,
      );
    });
  });

  group('Jellyfin overview', () {
    test('round trip', () {
      final o = expectRoundTrip(
        {
          'server': {'name': 'Zenith', 'version': '12.4.0', 'hwAccel': 'qsv'},
          'counts': {
            'movies': 179,
            'series': 54,
            'episodes': 1694,
            'songs': 0,
            'albums': 0,
            'books': 2,
          },
          'libraries': [
            {
              'id': 'a656b907eb3a73532e40e44b968d0225',
              'name': 'Shows',
              'type': 'tvshows',
              'sizeBytes': 2775587676767,
              'files': 1695,
              'itemCount': 54,
              'refreshing': false,
            },
            {
              'id': '7e64e319657a9516ec78490da03edccb',
              'name': 'Music',
              'type': 'music',
              'refreshing': true,
            },
          ],
          'recentlyAdded': [_item],
          'continueWatching': [
            {
              'id': 'dd63a9d25cc63db2481640b2db34c937',
              'type': 'episode',
              'title': 'Clevatess',
              'subtitle': 'S01E06 · Insect Controlling Wizard',
              'progress': 0.49,
            },
          ],
          'nextUp': <Object?>[],
        },
        JellyfinOverview.fromJson,
        (o) => o.toJson(),
      );
      expect(o.libraries.first.type, JellyfinLibraryType.tvshows);
      expect(o.libraries.last.refreshing, isTrue);
      expect(o.recentlyAdded.single.type, MediaItemType.series);
      expect(
        o.recentlyAdded.single.addedAt,
        DateTime.utc(2026, 11, 6, 23, 35, 57, 261),
      );
    });

    test('server is required', () {
      expect(
        () => JellyfinOverview.fromJson({'counts': <String, Object?>{}}),
        throwsFormatException,
      );
    });
  });

  group('watch stats', () {
    test('WatchStats round trip', () {
      final sample = <String, Object?>{
        'days': 30,
        'libraries': [
          {'id': 'f137a2dd21bbc1b99aa5c0f6bf02a805', 'name': 'Movies'},
        ],
        'viewsOverTime': [
          {
            'date': '2026-11-01',
            'plays': {'f137a2dd21bbc1b99aa5c0f6bf02a805': 2},
            'durationSeconds': {'f137a2dd21bbc1b99aa5c0f6bf02a805': 5400},
          },
        ],
        'byWeekday': [
          {'day': 'monday', 'plays': 3},
        ],
        'byHour': [
          {'hour': 21, 'plays': 2},
        ],
        'playMethods': [
          {'method': 'directPlay', 'count': 1},
        ],
        'topMovies': [
          {
            'id': '4fcea1b4d58b05010e29c1cea2be02d4',
            'name': 'Dune: Part Two',
            'plays': 2,
            'durationSeconds': 9960,
            'imagePath':
                '/api/v1/img/jellyfin/4fcea1b4d58b05010e29c1cea2be02d4/Primary',
          },
        ],
        'topSeries': <Object?>[],
        'popularSeries': [
          {
            'id': '9efa4240a1af422beff21712c58c218d',
            'name': 'Desperate Housewives',
            'uniqueViewers': 1,
          },
        ],
        'topUsers': [
          {
            'userId': '8bed8d8cccf249548eb6a39fd6a7e54b',
            'name': 'Zenith Greyrat',
            'plays': 1,
          },
        ],
        'topClients': [
          {'client': 'Jellyfin Android TV', 'plays': 1},
        ],
        'topLibraries': [
          {
            'id': 'a656b907eb3a73532e40e44b968d0225',
            'name': 'Shows',
            'plays': 1,
          },
        ],
        'totals': {'plays': 2, 'durationSeconds': 5400},
        'partial': true,
      };
      final s = expectRoundTrip(sample, WatchStats.fromJson, (s) => s.toJson());
      expect(s.partial, isTrue);
      expect(s.isEmpty, isFalse);
      expect(s.viewsOverTime.single.totalPlays, 2);
      expect(s.byWeekday.single.day, WatchWeekday.monday);
      expect(WatchStats.periods, [7, 30, 90, 365]);
    });

    test('partial is omitted when false', () {
      final s = WatchStats.fromJson({'days': 7});
      expect(s.toJson().containsKey('partial'), isFalse);
      expect(s.isEmpty, isTrue);
    });

    test('WatchUser and PlaybackRecord round trip', () {
      expectRoundTrip(
        {
          'userId': '8bed8d8cccf249548eb6a39fd6a7e54b',
          'name': 'Zenith Greyrat',
          'totalPlays': 1,
          'totalWatchSeconds': 1559,
          'lastSeenAt': '2026-11-08T08:54:48Z',
          'lastWatched': 'Desperate Housewives - The Story of Lucy and Jessie',
          'lastClient': 'Jellyfin Android TV - Xiaomi TV Box',
          'avatarPath': '/api/v1/img/jellyfin-user/8bed8d8cccf249548eb6a39fd6a7e54b?tag=3c0b29d9ed1bdf303020adb869978510',
        },
        WatchUser.fromJson,
        (u) => u.toJson(),
      );
      final r = expectRoundTrip(
        {
          'id': '2921119b-db06-4c50-9299-df580643ecc6',
          'userName': 'Zenith Greyrat',
          'title': 'The Story of Lucy and Jessie',
          'seriesName': 'Desperate Housewives',
          'client': 'Jellyfin Android TV',
          'device': 'Xiaomi TV Box',
          'playMethod': 'directPlay',
          'durationSeconds': 1559,
          'at': '2026-11-08T08:53:19.346Z',
          'imagePath':
              '/api/v1/img/jellyfin/cde3668a5433ba3171ff466f1693e2f3/Primary',
        },
        PlaybackRecord.fromJson,
        (r) => r.toJson(),
      );
      expect(r.at, DateTime.utc(2026, 11, 8, 8, 53, 19, 346));
      final page = PagedList<PlaybackRecord>.fromJson({
        'items': [r.toJson()],
        'page': 1,
        'pageSize': 25,
        'total': 1,
        'hasMore': false,
      }, PlaybackRecord.fromJson);
      expect(page.items.single.title, r.title);
    });
  });

  group('audiobooks', () {
    test('AudiobooksOverview round trip', () {
      final o = expectRoundTrip(
        {
          'version': '2.37.2',
          'libraries': [
            {
              'id': '5bbbf8b6-d60d-4ffa-837e-aaecb77d2995',
              'name': 'Audiobooks',
              'mediaType': 'book',
              'items': 247,
              'authors': 83,
              'durationSeconds': 7392921,
              'sizeBytes': 116852142646,
            },
          ],
          'continueListening': [
            {
              'id': '2b3a26fa-c8ab-4553-bd96-34a74440485e',
              'title': 'Lonely Castle in the Mirror',
              'author': 'Sarah Skaer',
              'narrator': 'Mizuki Tsujimura',
              'coverPath': '/api/v1/img/abs/2b3a26fa-c8ab-4553-bd96-34a74440485e?w=500&v=1794126276784',
              'progress': 0.25,
              'currentTimeSeconds': 7,
              'durationSeconds': 45112,
              'lastUpdateAt': '2026-11-08T09:28:56.949Z',
              'link': _absLink('/item/2b3a26fa-c8ab-4553-bd96-34a74440485e'),
            },
          ],
          'recentlyAdded': [
            {
              'id': 'b039a17e-a22e-4da0-83c5-27a518ccb44d',
              'title': 'Konosuba, Vol. 01',
              'coverPath':
                  '/api/v1/img/abs/b039a17e-a22e-4da0-83c5-27a518ccb44d',
              'addedAt': '2026-11-08T09:06:11.485Z',
              'durationSeconds': 16049,
              'link': _absLink('/item/b039a17e-a22e-4da0-83c5-27a518ccb44d'),
            },
          ],
          'listening': {
            'todaySeconds': 16,
            'totalSeconds': 16,
            'last7Days': [
              {'date': '2026-11-07', 'seconds': 0},
              {'date': '2026-11-08', 'seconds': 16},
            ],
          },
          'library': _absLink('/library/5bbbf8b6-d60d-4ffa-837e-aaecb77d2995'),
        },
        AudiobooksOverview.fromJson,
        (o) => o.toJson(),
      );
      expect(o.totalItems, 247);
      expect(o.continueListening.single.remainingSeconds, 45105);
      expect(o.recentlyAdded.single.author, isNull);
    });

    test('link is required', () {
      expect(
        () => AudiobooksOverview.fromJson(const {}),
        throwsFormatException,
      );
    });
  });

  group('books', () {
    test('BooksOverview round trip', () {
      final o = expectRoundTrip(
        {
          'auth': 'ok',
          'version': '0.9.1.4',
          'libraries': [
            {'id': 1, 'name': 'Books', 'type': 'book'},
          ],
          'stats': {
            'series': 2,
            'volumes': 3,
            'chapters': 3,
            'files': 3,
            'sizeBytes': 10485760,
          },
          'recentlyAdded': [_series(7)],
          'onDeck': [_series(8)],
          'library': {'app': 'kavita', 'path': '/library/1'},
        },
        BooksOverview.fromJson,
        (o) => o.toJson(),
      );
      expect(o.recentlyAdded.single.progress, 0.25);
      expect(o.onDeck.single.format, BookSeriesFormat.epub);
    });

    test('missing key overview omits stats and keeps the hint', () {
      final o = expectRoundTrip(
        {
          'auth': 'missingKey',
          'libraries': <Object?>[],
          'recentlyAdded': <Object?>[],
          'onDeck': <Object?>[],
          'hint': 'Kavita found no series.',
          'library': {'app': 'kavita', 'path': '/'},
        },
        BooksOverview.fromJson,
        (o) => o.toJson(),
      );
      expect(o.auth, BooksAuth.missingKey);
      expect(o.stats, isNull);
      expect(BooksAuth.fromJson('expired'), BooksAuth.unknown);
      expect(
        BooksLibraryType.fromJson('lightNovel'),
        BooksLibraryType.lightNovel,
      );
    });
  });

  group('shelfmark', () {
    test('ShelfmarkStatus round trip', () {
      final s = expectRoundTrip(
        {
          'status': 'degraded',
          'coordinator': 'stopped',
          'queue': {'active': 2, 'queued': 1, 'awaitingPickup': 0},
          'requests': {
            'pending': 1,
            'delivered': 4,
            'failed': 1,
            'cancelled': 0,
            'rejected': 0,
          },
          'added': {
            'ebook7d': 3,
            'ebook30d': 5,
            'audiobook7d': 2,
            'audiobook30d': 2,
            'total7d': 5,
            'total30d': 7,
          },
          'failed7d': 1,
          'generatedAt': '2026-11-08T09:51:34.709Z',
          'web': {'app': 'shelfmark', 'path': '/'},
        },
        ShelfmarkStatus.fromJson,
        (s) => s.toJson(),
      );
      expect(s.coordinator, ShelfmarkCoordinator.stopped);
      expect(s.queue.total, 3);
      expect(s.isEmpty, isFalse);
    });

    test('all zero counters are empty', () {
      final s = ShelfmarkStatus.fromJson({
        'status': 'ok',
        'coordinator': 'running',
        'web': {'app': 'shelfmark', 'path': '/'},
      });
      expect(s.isEmpty, isTrue);
      expect(s.toJson()['queue'], {
        'active': 0,
        'queued': 0,
        'awaitingPickup': 0,
      });
    });
  });

  group('launcher and card', () {
    test('MediaApp round trip', () {
      final a = expectRoundTrip(
        {
          'app': 'shelfmark',
          'name': 'Shelfmark',
          'status': 'up',
          'headline': '2 downloading · 1 queued · 5 added this week',
          'web': {'app': 'shelfmark', 'path': '/'},
          'route': '/media/shelfmark',
        },
        MediaApp.fromJson,
        (a) => a.toJson(),
      );
      expect(a.app.externalApp, ExternalApp.shelfmark);
      expect(MediaAppKind.unknown.externalApp, ExternalApp.unknown);
      final list = ItemList<MediaApp>.fromJson({
        'items': [a.toJson()],
      }, MediaApp.fromJson);
      expect(list.items.single.route, '/media/shelfmark');
    });

    test('MediaCard round trip', () {
      final c = expectRoundTrip(
        {
          'nowPlaying': [_session],
          'transcoding': 1,
          'counts': {'movies': 179, 'series': 54, 'episodes': 1694},
          'audiobooks': {'items': 247, 'inProgress': 1},
          'books': {'series': 0, 'auth': 'missingKey'},
          'shelfmark': {'active': 2, 'queued': 1, 'failed7d': 0},
          'recentlyAdded': [_item],
        },
        MediaCard.fromJson,
        (c) => c.toJson(),
      );
      expect(c.books!.auth, BooksAuth.missingKey);
    });

    test('a card with only now playing', () {
      final c = expectRoundTrip(
        {
          'nowPlaying': <Object?>[],
          'transcoding': 0,
          'recentlyAdded': <Object?>[],
        },
        MediaCard.fromJson,
        (c) => c.toJson(),
      );
      expect(c.counts, isNull);
      expect(c.shelfmark, isNull);
    });
  });
}
