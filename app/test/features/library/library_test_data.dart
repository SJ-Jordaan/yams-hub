/// Gateway-shaped library samples for the app tests (image paths are left
/// out so no network image is loaded).
library;

import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';

SeriesSummary buildSeries({
  int id = 54,
  String title = 'That Time I Got Reincarnated as a Slime',
  bool anime = true,
  bool monitored = true,
  int episodes = 96,
  int files = 48,
  LibrarySeriesStatus status = LibrarySeriesStatus.continuing,
  List<String> tags = const [],
  DateTime? nextAiring,
}) => SeriesSummary(
  id: id,
  title: title,
  sortTitle: title.toLowerCase(),
  year: 2018,
  status: status,
  seriesType: anime ? LibrarySeriesType.anime : LibrarySeriesType.standard,
  isAnime: anime,
  monitored: monitored,
  network: 'Nippon TV',
  qualityProfileId: anime ? 7 : 9,
  qualityProfileName: anime ? '[Anime] Remux-1080p' : 'WEB-1080p',
  seasonCount: 2,
  episodeCount: episodes,
  episodeFileCount: files,
  missingCount: episodes - files,
  totalEpisodeCount: episodes + 4,
  sizeOnDiskBytes: files * 1500000000,
  percentComplete: episodes == 0 ? 0 : files / episodes * 100,
  added: DateTime.utc(2026, 2, id % 28 + 1),
  genres: anime ? const ['Anime'] : const ['Drama'],
  tvdbId: 352408,
  imdbId: 'tt9054364',
  tags: tags,
  nextAiring: nextAiring,
);

List<SeriesSummary> buildSeriesList() => [
  buildSeries(),
  buildSeries(id: 2, title: 'A Knight of the Seven Kingdoms', anime: false, episodes: 6, files: 4),
  buildSeries(id: 25, title: "Frieren: Beyond Journey's End", episodes: 38, files: 38),
  buildSeries(id: 61, title: 'Severance', anime: false, episodes: 19, files: 0, status: LibrarySeriesStatus.ended),
];

Episode buildEpisode({
  int id = 2447,
  int season = 3,
  int number = 1,
  int? absolute = 49,
  bool hasFile = true,
  bool monitored = true,
  EpisodeQueueState? queue,
}) => Episode(
  id: id,
  seasonNumber: season,
  episodeNumber: number,
  absoluteEpisodeNumber: absolute,
  label: ArrEpisodeLabel.format(season, number, absoluteEpisodeNumber: absolute, anime: true),
  title: 'Episode $number',
  airDate: '2024-04-05',
  airDateUtc: DateTime.utc(2024, 4, 5, 14),
  monitored: monitored,
  hasFile: hasFile,
  file: hasFile
      ? MediaFileInfo(
          id: id + 10000,
          relativePath: 'Season 03/Slime - S03E0$number.mkv',
          sizeBytes: 1450000000,
          quality: const QualityInfo(name: 'WEBDL-1080p', resolution: 1080),
          customFormats: const ['Anime Web Tier 01'],
          customFormatScore: 1400,
          audioLanguages: const ['jpn'],
          subtitleLanguages: const ['eng'],
        )
      : null,
  queue: queue,
);

SeriesDetail buildSeriesDetail({SeriesSummary? series, List<String> tags = const ['anime', 'kids']}) => SeriesDetail(
  series: series ?? buildSeries(tags: tags),
  overview: 'Rimuru builds a nation.',
  runtimeMinutes: 24,
  certification: 'TV-14',
  rootFolderPath: '/data/tvshows',
  titleSlug: 'that-time-i-got-reincarnated-as-a-slime',
  seasons: const [
    SeasonInfo(seasonNumber: 3, monitored: true, episodeCount: 2, episodeFileCount: 1, totalEpisodeCount: 2),
    SeasonInfo(seasonNumber: 0, monitored: false, episodeCount: 0, episodeFileCount: 0, totalEpisodeCount: 14),
  ],
  episodes: [buildEpisode(), buildEpisode(id: 2448, number: 2, absolute: 50, hasFile: false)],
  links: const {'tvdb': 'https://thetvdb.com/?tab=series&id=352408'},
);

MovieSummary buildMovie({
  int id = 1,
  String title = 'Zootopia 2',
  bool hasFile = true,
  bool available = true,
  bool monitored = true,
}) => MovieSummary(
  id: id,
  title: title,
  sortTitle: title.toLowerCase(),
  year: 2025,
  status: available ? LibraryMovieStatus.released : LibraryMovieStatus.inCinemas,
  monitored: monitored,
  hasFile: hasFile,
  isAvailable: available,
  qualityProfileId: 7,
  qualityProfileName: 'HD Bluray + WEB',
  releaseDate: '2026-01-26',
  inCinemasDate: '2025-11-26',
  runtimeMinutes: 108,
  sizeOnDiskBytes: hasFile ? 2561322154 : 0,
  quality: hasFile ? 'WEBRip-1080p' : null,
  tmdbId: 1084242 + id,
);

List<MovieSummary> buildMovieList() => [
  buildMovie(),
  buildMovie(id: 227, title: 'Winnie the Pooh: Seasons of Giving', hasFile: false),
  buildMovie(id: 246, title: 'The Odyssey', hasFile: false, available: false),
];

ArrSummary buildArrSummary({int items = 4, int missing = 892, bool queueErrors = false}) => ArrSummary(
  configured: true,
  version: '4.0.20.3014',
  itemCount: items,
  missing: missing,
  cutoffUnmet: 994,
  sizeOnDiskBytes: 2780000000000,
  freeBytes: 4048915103744,
  queue: ArrSummaryQueue(total: queueErrors ? 2 : 0, errors: queueErrors),
  health: const [
    HealthMessage(
      service: ServiceId.sonarr,
      source: 'AllowedHostsCheck',
      type: HealthMessageType.warning,
      message: 'Allowed Hosts is not configured',
      wikiUrl: 'https://wiki.servarr.com/sonarr/system',
    ),
  ],
);

LibrarySummary buildLibrarySummary() =>
    LibrarySummary(sonarr: buildArrSummary(), radarr: buildArrSummary(items: 3, missing: 1));

LibraryProfiles buildProfiles() => const LibraryProfiles(
  sonarr: LibrarySonarrProfiles(
    qualityProfiles: [
      LibraryQualityProfile(id: 7, name: '[Anime] Remux-1080p'),
      LibraryQualityProfile(id: 9, name: 'WEB-1080p'),
    ],
    rootFolders: [LibraryRootFolder(id: 1, path: '/data/tvshows', freeBytes: 4048915103744)],
    defaults: LibrarySonarrDefaults(standardProfileId: 9, animeProfileId: 7, rootFolderPath: '/data/tvshows'),
  ),
  radarr: LibraryRadarrProfiles(
    qualityProfiles: [LibraryQualityProfile(id: 7, name: 'HD Bluray + WEB')],
    rootFolders: [LibraryRootFolder(id: 1, path: '/data/movies', freeBytes: 4048914001920)],
    defaults: LibraryRadarrDefaults(profileId: 7, rootFolderPath: '/data/movies'),
  ),
);

ReleaseChoice buildRelease({
  String id = 'rl_ok',
  String title = '[SubsPlease] Slime - 49 (1080p)',
  bool approved = true,
  bool rejected = false,
  List<String> rejections = const [],
  int score = 1400,
  int size = 1500000000,
  int? seeders = 812,
  int? age = 30,
}) => ReleaseChoice(
  releaseId: id,
  service: ArrService.sonarr,
  title: title,
  indexer: 'Nyaa.si (Prowlarr)',
  indexerId: 5,
  quality: const QualityInfo(name: 'WEBDL-1080p'),
  customFormatScore: score,
  sizeBytes: size,
  ageHours: age,
  seeders: seeders,
  leechers: 4,
  protocol: LibraryReleaseProtocol.torrent,
  languages: const ['Japanese'],
  episodeLabels: const ['S03E01 (049)'],
  approved: approved,
  rejected: rejected,
  rejections: rejections,
);

JsonMap buildCommandJson({int id = 5000, String name = 'SeriesSearch', String status = 'queued'}) => {
  'command': CommandRef(
    service: ServiceId.sonarr,
    id: id,
    name: name,
    status: CommandStatus.fromJson(status),
    result: status == 'completed' ? CommandResult.successful : CommandResult.unknown,
  ).toJson(),
};

/// The core fakes plus the library reads every screen needs.
FakeApi buildLibraryFakeApi({Role role = Role.admin, bool allowDeleteFiles = true, bool allowGlobalSearch = false}) {
  final api = buildCoreFakeApi(role: role)
    ..getJson('/server', {
      ...buildServerConfig().toJson(),
      'policy': {'allowGlobalSearch': allowGlobalSearch, 'allowArrDeleteFiles': allowDeleteFiles},
    })
    ..getJson('/library/summary', buildLibrarySummary().toJson())
    ..getJson('/library/profiles', buildProfiles().toJson())
    ..getJson('/library/tv', {
      'items': [for (final s in buildSeriesList()) s.toJson()],
    })
    ..getJson('/library/movies', {
      'items': [for (final m in buildMovieList()) m.toJson()],
    })
    ..getJson('/library/tv/54', buildSeriesDetail().toJson())
    ..getJson(
      '/library/tv/54/history',
      PagedList<ArrHistoryItem>.of(
        items: [
          ArrHistoryItem(
            id: 'sonarr:1',
            service: ArrService.sonarr,
            type: ArrHistoryType.imported,
            date: testNow,
            sourceTitle: '[SubsPlease] Slime - 49 (1080p)',
            quality: const QualityInfo(name: 'WEBDL-1080p'),
          ),
        ],
        page: 1,
        pageSize: 5,
        total: 1,
      ).toJson((i) => i.toJson()),
    );
  return api;
}
