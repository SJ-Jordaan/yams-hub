/// Gateway-shaped media samples for the app tests (API.md §14).
library;

import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import '../../support/fake_api.dart';

const serverId = '79315eab3c4c401f8391d5c26210b6d7';

ExternalLink jfLink(String id) => ExternalLink(ExternalApp.jellyfin, '/web/#/details?id=$id&serverId=$serverId');

NowPlayingSession episodeSession({bool paused = false, bool canControl = true}) => NowPlayingSession(
  id: 'eb96632f72ed3854021c5466f350a158',
  userName: 'Zenith Greyrat',
  userId: '8bed8d8cccf249548eb6a39fd6a7e54b',
  client: 'Jellyfin Android TV',
  deviceName: 'Xiaomi TV Box',
  itemId: 'd078a144bb4719f0e6babd8d90ba0b11',
  itemType: NowPlayingItemType.episode,
  title: 'A Spark. To Pierce the Dark.',
  seriesName: 'Desperate Housewives',
  seasonNumber: 5,
  episodeNumber: 18,
  runtimeSeconds: 2583,
  positionSeconds: 165,
  progress: 0.064,
  paused: paused,
  playMethod: MediaPlayMethod.directPlay,
  imagePath: '/api/v1/img/jellyfin/d078a144bb4719f0e6babd8d90ba0b11/Primary',
  remoteAddress: canControl ? '192.168.10.160' : null,
  jellyfin: jfLink('d078a144bb4719f0e6babd8d90ba0b11'),
  canControl: canControl,
);

NowPlayingSession transcodingSession() => NowPlayingSession(
  id: 'aa11bb22cc33dd44ee55ff6677889900',
  userName: 'Paul Greyrat',
  client: 'Jellyfin Web',
  deviceName: 'Firefox',
  itemId: '4fcea1b4d58b05010e29c1cea2be02d4',
  itemType: NowPlayingItemType.movie,
  title: 'Dune: Part Two',
  year: 2024,
  runtimeSeconds: 9960,
  positionSeconds: 3600,
  progress: 0.36,
  paused: false,
  playMethod: MediaPlayMethod.transcode,
  transcode: const NowPlayingTranscode(
    videoCodec: 'h264',
    audioCodec: 'aac',
    container: 'ts',
    hwAccel: 'qsv',
    reasons: ['VideoCodecNotSupported'],
    bitrate: 8000000,
    videoDirect: false,
    audioDirect: true,
  ),
  canControl: true,
);

MediaItem item(
  String id,
  String title, {
  MediaItemType type = MediaItemType.movie,
  String? subtitle,
  double? progress,
}) => MediaItem(id: id, type: type, title: title, subtitle: subtitle, progress: progress, jellyfin: jfLink(id));

JellyfinOverview jellyfinOverview({List<MediaItem>? continueWatching}) => JellyfinOverview(
  server: const JellyfinServerSummary(name: 'Zenith', version: '12.4.0', hwAccel: 'qsv'),
  counts: const JellyfinCounts(movies: 179, series: 54, episodes: 1694, books: 2),
  libraries: const [
    JellyfinLibrary(
      id: 'a656b907eb3a73532e40e44b968d0225',
      name: 'Shows',
      type: JellyfinLibraryType.tvshows,
      sizeBytes: 2775587676767,
      files: 1695,
      itemCount: 54,
    ),
    JellyfinLibrary(
      id: 'f137a2dd21bbc1b99aa5c0f6bf02a805',
      name: 'Movies',
      type: JellyfinLibraryType.movies,
      refreshing: true,
    ),
  ],
  recentlyAdded: [item('4fcea1b4d58b05010e29c1cea2be02d4', 'Dune: Part Two')],
  continueWatching:
      continueWatching ??
      [
        item(
          'dd63a9d25cc63db2481640b2db34c937',
          'Clevatess',
          type: MediaItemType.episode,
          subtitle: 'S01E06 · Insect Controlling Wizard',
          progress: 0.49,
        ),
      ],
);

const moviesId = 'f137a2dd21bbc1b99aa5c0f6bf02a805';
const showsId = 'a656b907eb3a73532e40e44b968d0225';

WatchStats watchStats({int days = 30, bool empty = false, bool partial = false}) => WatchStats(
  days: days,
  libraries: const [
    WatchLibrary(id: moviesId, name: 'Movies'),
    WatchLibrary(id: showsId, name: 'Shows'),
  ],
  viewsOverTime: [
    WatchViewsPoint(
      date: '2026-11-07',
      plays: {moviesId: empty ? 0 : 2, showsId: 0},
      durationSeconds: {moviesId: empty ? 0 : 9960},
    ),
    WatchViewsPoint(date: '2026-11-08', plays: {moviesId: 0, showsId: empty ? 0 : 1}),
  ],
  byWeekday: [
    for (final d in WatchWeekday.values.where((d) => d != WatchWeekday.unknown))
      WatchDayPlays(day: d, plays: !empty && d == WatchWeekday.sunday ? 1 : 0),
  ],
  byHour: [for (var h = 0; h < 24; h++) WatchHourPlays(hour: h, plays: !empty && h == 21 ? 3 : 0)],
  playMethods: empty ? const [] : const [WatchPlayMethodCount(method: MediaPlayMethod.directPlay, count: 3)],
  topSeries: empty
      ? const []
      : const [
          WatchTopItem(
            id: '9efa4240a1af422beff21712c58c218d',
            name: 'Desperate Housewives',
            plays: 1,
            durationSeconds: 1559,
          ),
        ],
  topUsers: empty
      ? const []
      : const [WatchTopUser(userId: '8bed8d8cccf249548eb6a39fd6a7e54b', name: 'Zenith Greyrat', plays: 3)],
  topClients: empty ? const [] : const [WatchTopClient(client: 'Jellyfin Android TV', plays: 3)],
  totals: WatchTotals(plays: empty ? 0 : 3, durationSeconds: empty ? 0 : 11520),
  partial: partial,
);

AudiobooksOverview audiobooksOverview() => AudiobooksOverview(
  version: '2.37.2',
  libraries: const [
    AudiobookLibrary(
      id: '5bbbf8b6-d60d-4ffa-837e-aaecb77d2995',
      name: 'Audiobooks',
      mediaType: AudiobookMediaType.book,
      items: 247,
      authors: 83,
      durationSeconds: 7392921,
      sizeBytes: 116852142646,
    ),
  ],
  continueListening: const [
    AudiobookProgressItem(
      id: '2b3a26fa-c8ab-4553-bd96-34a74440485e',
      title: 'Lonely Castle in the Mirror',
      author: 'Sarah Skaer',
      coverPath: '/api/v1/img/abs/2b3a26fa-c8ab-4553-bd96-34a74440485e?w=500',
      progress: 0.25,
      currentTimeSeconds: 11278,
      durationSeconds: 45112,
      link: ExternalLink(ExternalApp.audiobookshelf, '/item/2b3a26fa-c8ab-4553-bd96-34a74440485e'),
    ),
  ],
  recentlyAdded: [
    AudiobookRecentItem(
      id: 'b039a17e-a22e-4da0-83c5-27a518ccb44d',
      title: 'Konosuba, Vol. 01',
      coverPath: '/api/v1/img/abs/b039a17e-a22e-4da0-83c5-27a518ccb44d',
      addedAt: testNow,
      link: const ExternalLink(ExternalApp.audiobookshelf, '/item/b039a17e-a22e-4da0-83c5-27a518ccb44d'),
    ),
  ],
  listening: AudiobookListening(
    todaySeconds: 960,
    totalSeconds: 3600,
    last7Days: [for (var d = 2; d <= 8; d++) AudiobookListeningDay(date: '2026-11-0$d', seconds: d == 8 ? 960 : 0)],
  ),
  library: const ExternalLink(ExternalApp.audiobookshelf, '/library/5bbbf8b6-d60d-4ffa-837e-aaecb77d2995'),
);

BookSeries bookSeries(int id, String name) => BookSeries(
  id: id,
  name: name,
  libraryId: 2,
  libraryName: 'Light Novels',
  coverPath: '/api/v1/img/kavita/series/$id',
  pages: 400,
  pagesRead: 100,
  format: BookSeriesFormat.epub,
  link: ExternalLink(ExternalApp.kavita, '/library/2/series/$id'),
);

BooksOverview booksOverview({BooksAuth auth = BooksAuth.ok, bool noSeries = false}) => BooksOverview(
  auth: auth,
  version: auth == BooksAuth.ok ? '0.9.1.4' : null,
  libraries: auth == BooksAuth.ok
      ? const [BooksLibrary(id: 2, name: 'Light Novels', type: BooksLibraryType.lightNovel)]
      : const [],
  stats: auth == BooksAuth.ok ? BooksStats(series: noSeries ? 0 : 3, volumes: noSeries ? 0 : 12) : null,
  recentlyAdded: auth == BooksAuth.ok && !noSeries ? [bookSeries(3, 'Ascendance of a Bookworm')] : const [],
  onDeck: auth == BooksAuth.ok && !noSeries ? [bookSeries(2, 'Mushoku Tensei')] : const [],
  hint: noSeries
      ? 'Kavita found no series. It needs one folder per series, e.g. books/lightnovels/<Series>/<file>.epub'
      : null,
  library: const ExternalLink(ExternalApp.kavita, '/library/2'),
);

ShelfmarkStatus shelfmarkStatus({bool stopped = false, bool empty = false}) => ShelfmarkStatus(
  status: stopped ? ShelfmarkServiceState.degraded : ShelfmarkServiceState.ok,
  coordinator: stopped ? ShelfmarkCoordinator.stopped : ShelfmarkCoordinator.running,
  queue: empty ? const ShelfmarkQueue() : const ShelfmarkQueue(active: 2, queued: 1, awaitingPickup: 1),
  requests: empty ? const ShelfmarkRequests() : const ShelfmarkRequests(pending: 2, delivered: 6, failed: 1),
  added: empty
      ? const ShelfmarkAdded()
      : const ShelfmarkAdded(ebook7d: 3, ebook30d: 9, audiobook7d: 2, audiobook30d: 4, total7d: 5, total30d: 13),
  failed7d: empty ? 0 : 1,
  generatedAt: testNow,
  web: const ExternalLink(ExternalApp.shelfmark, '/'),
);

List<MediaApp> mediaApps() => const [
  MediaApp(
    app: MediaAppKind.jellyfin,
    name: 'Jellyfin',
    status: MediaAppStatus.up,
    version: '12.4.0',
    headline: '179 movies · 54 shows · 1,694 episodes',
    web: ExternalLink(ExternalApp.jellyfin, '/'),
    route: '/media/jellyfin',
  ),
  MediaApp(
    app: MediaAppKind.audiobookshelf,
    name: 'Audiobookshelf',
    status: MediaAppStatus.up,
    version: '2.37.2',
    headline: '247 audiobooks · 83 authors · 1 in progress',
    web: ExternalLink(ExternalApp.audiobookshelf, '/'),
    route: '/media/audiobooks',
  ),
  MediaApp(
    app: MediaAppKind.kavita,
    name: 'Kavita',
    status: MediaAppStatus.disabled,
    headline: 'Needs an Auth Key',
    web: ExternalLink(ExternalApp.kavita, '/'),
    route: '/media/books',
  ),
  MediaApp(
    app: MediaAppKind.seerr,
    name: 'Seerr',
    status: MediaAppStatus.up,
    version: '3.5.1',
    headline: '0 pending · 3 processing · 1 available',
    web: ExternalLink(ExternalApp.seerr, '/'),
    route: '/requests',
  ),
  MediaApp(
    app: MediaAppKind.shelfmark,
    name: 'Shelfmark',
    status: MediaAppStatus.degraded,
    headline: '2 downloading · 1 queued · 5 added this week',
    web: ExternalLink(ExternalApp.shelfmark, '/'),
    route: '/media/shelfmark',
  ),
];

/// Registers every media endpoint on [api].
void serveMedia(
  FakeApi api, {
  NowPlaying? nowPlaying,
  JellyfinOverview? jellyfin,
  WatchStats Function(int days)? stats,
  AudiobooksOverview? audiobooks,
  BooksOverview? books,
  ShelfmarkStatus? shelfmark,
}) {
  api
    ..getJson(
      '/media/now-playing',
      (nowPlaying ?? NowPlaying(sessions: [episodeSession(), transcodingSession()], transcoding: 1, hwAccel: 'qsv'))
          .toJson(),
    )
    ..getJson('/media/jellyfin', (jellyfin ?? jellyfinOverview()).toJson())
    ..on('GET', '/media/stats', (r) {
      final days = int.tryParse('${r.uri.queryParameters['days']}') ?? 30;
      return FakeResponse((stats ?? (d) => watchStats(days: d))(days).toJson());
    })
    ..getJson('/media/stats/users', {
      'items': [
        const WatchUser(
          userId: '8bed8d8cccf249548eb6a39fd6a7e54b',
          name: 'Zenith Greyrat',
          totalPlays: 1,
          totalWatchSeconds: 1559,
          lastWatched: 'Desperate Housewives - The Story of Lucy and Jessie',
        ).toJson(),
        const WatchUser(userId: '4c0628aacef24bdfacd40f946ea33ee7', name: 'Paul Greyrat').toJson(),
      ],
    })
    ..getJson(
      '/media/stats/history',
      PagedList.of(
        items: [
          PlaybackRecord(
            id: '2921119b-db06-4c50-9299-df580643ecc6',
            userName: 'Zenith Greyrat',
            title: 'The Story of Lucy and Jessie',
            seriesName: 'Desperate Housewives',
            client: 'Jellyfin Android TV',
            device: 'Xiaomi TV Box',
            playMethod: MediaPlayMethod.directPlay,
            durationSeconds: 1559,
            at: testNow,
          ),
        ],
        page: 1,
        pageSize: 25,
        total: 1,
      ).toJson((r) => r.toJson()),
    )
    ..getJson('/media/audiobooks', (audiobooks ?? audiobooksOverview()).toJson())
    ..getJson('/media/books', (books ?? booksOverview()).toJson())
    ..getJson('/media/shelfmark', (shelfmark ?? shelfmarkStatus()).toJson())
    ..getJson('/media/apps', {
      'items': [for (final a in mediaApps()) a.toJson()],
    });
}
