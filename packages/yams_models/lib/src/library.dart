/// Library DTOs: Sonarr series and Radarr movies (API.md §7).
///
/// Every public name is an API.md §7 DTO or starts with one (or with
/// `Library`), per the naming rule of ARCHITECTURE §4.
library;

import 'package:meta/meta.dart';

import 'arr_common.dart';
import 'common.dart';
import 'json.dart';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Sonarr series status.
enum LibrarySeriesStatus {
  continuing,
  ended,
  upcoming,
  deleted,
  unknown;

  static LibrarySeriesStatus fromJson(Object? v) =>
      readEnum(v, values, LibrarySeriesStatus.unknown);

  String toJson() => name;
}

/// Sonarr series type: decides how releases are searched and named.
enum LibrarySeriesType {
  standard,
  daily,
  anime,
  unknown;

  static LibrarySeriesType fromJson(Object? v) =>
      readEnum(v, values, LibrarySeriesType.unknown);

  String toJson() => name;
}

/// Whether Sonarr monitors seasons added later.
enum LibraryMonitorNewItems {
  all,
  none,
  unknown;

  static LibraryMonitorNewItems fromJson(Object? v) =>
      readEnum(v, values, LibraryMonitorNewItems.unknown);

  String toJson() => name;
}

/// Which episodes Sonarr monitors when a series is added.
enum LibrarySeriesMonitor {
  all,
  future,
  missing,
  existing,
  firstSeason,
  latestSeason,
  pilot,
  none,
  unknown;

  static LibrarySeriesMonitor fromJson(Object? v) =>
      readEnum(v, values, LibrarySeriesMonitor.unknown);

  String toJson() => name;
}

/// Radarr movie status.
enum LibraryMovieStatus {
  tba,
  announced,
  inCinemas,
  released,
  deleted,
  unknown;

  static LibraryMovieStatus fromJson(Object? v) =>
      readEnum(v, values, LibraryMovieStatus.unknown);

  String toJson() => name;
}

/// When Radarr considers a movie available (and starts searching).
enum LibraryMinimumAvailability {
  tba,
  announced,
  inCinemas,
  released,
  unknown;

  static LibraryMinimumAvailability fromJson(Object? v) =>
      readEnum(v, values, LibraryMinimumAvailability.unknown);

  String toJson() => name;
}

/// What Radarr monitors when a movie is added.
enum LibraryMovieMonitor {
  movieOnly,
  movieAndCollection,
  none,
  unknown;

  static LibraryMovieMonitor fromJson(Object? v) =>
      readEnum(v, values, LibraryMovieMonitor.unknown);

  String toJson() => name;
}

/// Download protocol of a [ReleaseChoice].
enum LibraryReleaseProtocol {
  torrent,
  usenet,
  unknown;

  static LibraryReleaseProtocol fromJson(Object? v) =>
      readEnum(v, values, LibraryReleaseProtocol.unknown);

  String toJson() => name;
}

DateTime? _instant(Object? v) => readInstant(v);

// ---------------------------------------------------------------------------
// Series
// ---------------------------------------------------------------------------

/// One Sonarr series as listed in the library.
@immutable
final class SeriesSummary {
  const SeriesSummary({
    required this.id,
    required this.title,
    required this.sortTitle,
    required this.status,
    required this.seriesType,
    required this.monitored,
    this.year,
    this.isAnime = false,
    this.monitorNewItems = LibraryMonitorNewItems.all,
    this.network,
    this.qualityProfileId = 0,
    this.qualityProfileName,
    this.posterPath,
    this.fanartPath,
    this.nextAiring,
    this.previousAiring,
    this.seasonCount = 0,
    this.episodeCount = 0,
    this.episodeFileCount = 0,
    this.missingCount = 0,
    this.totalEpisodeCount = 0,
    this.sizeOnDiskBytes = 0,
    this.percentComplete = 0,
    this.added,
    this.genres = const [],
    this.tvdbId,
    this.tmdbId,
    this.imdbId,
    this.ratingValue,
    this.ratingVotes,
    this.tags = const [],
  });

  factory SeriesSummary.fromJson(JsonMap j) => SeriesSummary(
    id: req(readInt(j['id']), 'id'),
    title: readString(j['title']) ?? '',
    sortTitle: readString(j['sortTitle']) ?? '',
    year: readInt(j['year']),
    status: LibrarySeriesStatus.fromJson(j['status']),
    seriesType: LibrarySeriesType.fromJson(j['seriesType']),
    isAnime: readBool(j['isAnime']) ?? false,
    monitored: readBool(j['monitored']) ?? false,
    monitorNewItems: LibraryMonitorNewItems.fromJson(j['monitorNewItems']),
    network: readString(j['network']),
    qualityProfileId: readInt(j['qualityProfileId']) ?? 0,
    qualityProfileName: readString(j['qualityProfileName']),
    posterPath: readString(j['posterPath']),
    fanartPath: readString(j['fanartPath']),
    nextAiring: _instant(j['nextAiring']),
    previousAiring: _instant(j['previousAiring']),
    seasonCount: readInt(j['seasonCount']) ?? 0,
    episodeCount: readInt(j['episodeCount']) ?? 0,
    episodeFileCount: readInt(j['episodeFileCount']) ?? 0,
    missingCount: readInt(j['missingCount']) ?? 0,
    totalEpisodeCount: readInt(j['totalEpisodeCount']) ?? 0,
    sizeOnDiskBytes: readInt(j['sizeOnDiskBytes']) ?? 0,
    percentComplete: readDouble(j['percentComplete']) ?? 0,
    added: _instant(j['added']),
    genres: readStringList(j['genres']),
    tvdbId: readInt(j['tvdbId']),
    tmdbId: readInt(j['tmdbId']),
    imdbId: readString(j['imdbId']),
    ratingValue: readDouble(j['ratingValue']),
    ratingVotes: readInt(j['ratingVotes']),
    tags: readStringList(j['tags']),
  );

  final int id;
  final String title;
  final String sortTitle;
  final int? year;
  final LibrarySeriesStatus status;
  final LibrarySeriesType seriesType;

  /// `seriesType == anime` or the genres contain `Anime`.
  final bool isAnime;
  final bool monitored;
  final LibraryMonitorNewItems monitorNewItems;
  final String? network;
  final int qualityProfileId;
  final String? qualityProfileName;
  final String? posterPath;
  final String? fanartPath;
  final DateTime? nextAiring;
  final DateTime? previousAiring;
  final int seasonCount;

  /// Monitored episodes that aired or have a file (progress denominator).
  final int episodeCount;
  final int episodeFileCount;

  /// `episodeCount - episodeFileCount` (never negative).
  final int missingCount;

  /// Every episode, specials and unaired ones included.
  final int totalEpisodeCount;
  final int sizeOnDiskBytes;

  /// 0..100.
  final double percentComplete;
  final DateTime? added;
  final List<String> genres;
  final int? tvdbId;
  final int? tmdbId;
  final String? imdbId;
  final double? ratingValue;
  final int? ratingVotes;

  /// Tag labels (read-only in the hub).
  final List<String> tags;

  JsonMap toJson() => compactJson({
    'id': id,
    'title': title,
    'sortTitle': sortTitle,
    'year': year,
    'status': status.toJson(),
    'seriesType': seriesType.toJson(),
    'isAnime': isAnime,
    'monitored': monitored,
    'monitorNewItems': monitorNewItems.toJson(),
    'network': network,
    'qualityProfileId': qualityProfileId,
    'qualityProfileName': qualityProfileName,
    'posterPath': posterPath,
    'fanartPath': fanartPath,
    'nextAiring': optionalInstantToJson(nextAiring),
    'previousAiring': optionalInstantToJson(previousAiring),
    'seasonCount': seasonCount,
    'episodeCount': episodeCount,
    'episodeFileCount': episodeFileCount,
    'missingCount': missingCount,
    'totalEpisodeCount': totalEpisodeCount,
    'sizeOnDiskBytes': sizeOnDiskBytes,
    'percentComplete': percentComplete,
    'added': optionalInstantToJson(added),
    'genres': genres,
    'tvdbId': tvdbId,
    'tmdbId': tmdbId,
    'imdbId': imdbId,
    'ratingValue': ratingValue,
    'ratingVotes': ratingVotes,
    'tags': tags,
  });

  /// A copy with another monitored state (optimistic toggles in the app).
  SeriesSummary copyWithMonitored(bool value) => SeriesSummary(
    id: id,
    title: title,
    sortTitle: sortTitle,
    year: year,
    status: status,
    seriesType: seriesType,
    isAnime: isAnime,
    monitored: value,
    monitorNewItems: monitorNewItems,
    network: network,
    qualityProfileId: qualityProfileId,
    qualityProfileName: qualityProfileName,
    posterPath: posterPath,
    fanartPath: fanartPath,
    nextAiring: nextAiring,
    previousAiring: previousAiring,
    seasonCount: seasonCount,
    episodeCount: episodeCount,
    episodeFileCount: episodeFileCount,
    missingCount: missingCount,
    totalEpisodeCount: totalEpisodeCount,
    sizeOnDiskBytes: sizeOnDiskBytes,
    percentComplete: percentComplete,
    added: added,
    genres: genres,
    tvdbId: tvdbId,
    tmdbId: tmdbId,
    imdbId: imdbId,
    ratingValue: ratingValue,
    ratingVotes: ratingVotes,
    tags: tags,
  );
}

/// Download state of an episode or movie that is in the *arr queue.
@immutable
final class EpisodeQueueState {
  const EpisodeQueueState({
    required this.status,
    required this.trackedState,
    required this.progress,
    this.etaSeconds,
  });

  factory EpisodeQueueState.fromJson(JsonMap j) => EpisodeQueueState(
    status: readString(j['status']) ?? 'unknown',
    trackedState: readString(j['trackedState']) ?? 'unknown',
    progress: readDouble(j['progress']) ?? 0,
    etaSeconds: readInt(j['etaSeconds']),
  );

  /// Download client state (`downloading`, `paused`, `completed`, ...).
  final String status;

  /// *arr tracking state (`downloading`, `importPending`, `importBlocked`, ...).
  final String trackedState;

  /// 0..1.
  final double progress;
  final int? etaSeconds;

  JsonMap toJson() => compactJson({
    'status': status,
    'trackedState': trackedState,
    'progress': progress,
    'etaSeconds': etaSeconds,
  });
}

/// One Sonarr episode.
@immutable
final class Episode {
  const Episode({
    required this.id,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.label,
    required this.monitored,
    required this.hasFile,
    this.absoluteEpisodeNumber,
    this.title,
    this.overview,
    this.airDate,
    this.airDateUtc,
    this.runtimeMinutes,
    this.finaleType,
    this.lastSearchTime,
    this.file,
    this.queue,
  });

  factory Episode.fromJson(JsonMap j) {
    final season = req(readInt(j['seasonNumber']), 'seasonNumber');
    final number = req(readInt(j['episodeNumber']), 'episodeNumber');
    return Episode(
      id: req(readInt(j['id']), 'id'),
      seasonNumber: season,
      episodeNumber: number,
      absoluteEpisodeNumber: readInt(j['absoluteEpisodeNumber']),
      label: readString(j['label']) ?? ArrEpisodeLabel.format(season, number),
      title: readString(j['title']),
      overview: readString(j['overview']),
      airDate: readString(j['airDate']),
      airDateUtc: _instant(j['airDateUtc']),
      runtimeMinutes: readInt(j['runtimeMinutes']),
      monitored: readBool(j['monitored']) ?? false,
      hasFile: readBool(j['hasFile']) ?? false,
      finaleType: readString(j['finaleType']),
      lastSearchTime: _instant(j['lastSearchTime']),
      file: switch (readMap(j['file'])) {
        final m? => MediaFileInfo.fromJson(m),
        null => null,
      },
      queue: switch (readMap(j['queue'])) {
        final m? => EpisodeQueueState.fromJson(m),
        null => null,
      },
    );
  }

  final int id;
  final int seasonNumber;
  final int episodeNumber;
  final int? absoluteEpisodeNumber;

  /// `S03E01`, or `S03E01 (049)` for anime.
  final String label;
  final String? title;
  final String? overview;

  /// Network-local `YYYY-MM-DD`.
  final String? airDate;
  final DateTime? airDateUtc;
  final int? runtimeMinutes;
  final bool monitored;
  final bool hasFile;

  /// `series`, `season` or `midseason`.
  final String? finaleType;
  final DateTime? lastSearchTime;
  final MediaFileInfo? file;
  final EpisodeQueueState? queue;

  JsonMap toJson() => compactJson({
    'id': id,
    'seasonNumber': seasonNumber,
    'episodeNumber': episodeNumber,
    'absoluteEpisodeNumber': absoluteEpisodeNumber,
    'label': label,
    'title': title,
    'overview': overview,
    'airDate': airDate,
    'airDateUtc': optionalInstantToJson(airDateUtc),
    'runtimeMinutes': runtimeMinutes,
    'monitored': monitored,
    'hasFile': hasFile,
    'finaleType': finaleType,
    'lastSearchTime': optionalInstantToJson(lastSearchTime),
    'file': file?.toJson(),
    'queue': queue?.toJson(),
  });

  /// A copy with another monitored state (optimistic toggles in the app).
  Episode copyWithMonitored(bool value) => Episode(
    id: id,
    seasonNumber: seasonNumber,
    episodeNumber: episodeNumber,
    absoluteEpisodeNumber: absoluteEpisodeNumber,
    label: label,
    title: title,
    overview: overview,
    airDate: airDate,
    airDateUtc: airDateUtc,
    runtimeMinutes: runtimeMinutes,
    monitored: value,
    hasFile: hasFile,
    finaleType: finaleType,
    lastSearchTime: lastSearchTime,
    file: file,
    queue: queue,
  );
}

/// One season of a series.
@immutable
final class SeasonInfo {
  const SeasonInfo({
    required this.seasonNumber,
    required this.monitored,
    this.episodeCount = 0,
    this.episodeFileCount = 0,
    this.totalEpisodeCount = 0,
    this.sizeOnDiskBytes = 0,
    this.nextAiring,
    this.previousAiring,
    this.posterPath,
  });

  factory SeasonInfo.fromJson(JsonMap j) => SeasonInfo(
    seasonNumber: req(readInt(j['seasonNumber']), 'seasonNumber'),
    monitored: readBool(j['monitored']) ?? false,
    episodeCount: readInt(j['episodeCount']) ?? 0,
    episodeFileCount: readInt(j['episodeFileCount']) ?? 0,
    totalEpisodeCount: readInt(j['totalEpisodeCount']) ?? 0,
    sizeOnDiskBytes: readInt(j['sizeOnDiskBytes']) ?? 0,
    nextAiring: _instant(j['nextAiring']),
    previousAiring: _instant(j['previousAiring']),
    posterPath: readString(j['posterPath']),
  );

  /// 0 = specials.
  final int seasonNumber;
  final bool monitored;
  final int episodeCount;
  final int episodeFileCount;
  final int totalEpisodeCount;
  final int sizeOnDiskBytes;
  final DateTime? nextAiring;
  final DateTime? previousAiring;
  final String? posterPath;

  JsonMap toJson() => compactJson({
    'seasonNumber': seasonNumber,
    'monitored': monitored,
    'episodeCount': episodeCount,
    'episodeFileCount': episodeFileCount,
    'totalEpisodeCount': totalEpisodeCount,
    'sizeOnDiskBytes': sizeOnDiskBytes,
    'nextAiring': optionalInstantToJson(nextAiring),
    'previousAiring': optionalInstantToJson(previousAiring),
    'posterPath': posterPath,
  });

  /// A copy with another monitored state (optimistic toggles in the app).
  SeasonInfo copyWithMonitored(bool value) => SeasonInfo(
    seasonNumber: seasonNumber,
    monitored: value,
    episodeCount: episodeCount,
    episodeFileCount: episodeFileCount,
    totalEpisodeCount: totalEpisodeCount,
    sizeOnDiskBytes: sizeOnDiskBytes,
    nextAiring: nextAiring,
    previousAiring: previousAiring,
    posterPath: posterPath,
  );
}

Map<String, String> _stringMap(Object? v) {
  final m = readMap(v);
  if (m == null) return const {};
  return {for (final e in m.entries) e.key: ?readString(e.value)};
}

/// `GET /library/tv/{id}`.
@immutable
final class SeriesDetail {
  const SeriesDetail({
    required this.series,
    this.overview,
    this.airTime,
    this.runtimeMinutes,
    this.certification,
    this.rootFolderPath,
    this.seasonFolder = true,
    this.originalLanguage,
    this.alternateTitles = const [],
    this.bannerPath,
    this.seasons = const [],
    this.episodes = const [],
    this.links = const {},
    this.titleSlug,
  });

  factory SeriesDetail.fromJson(JsonMap j) => SeriesDetail(
    series: SeriesSummary.fromJson(req(readMap(j['series']), 'series')),
    titleSlug: readString(j['titleSlug']),
    overview: readString(j['overview']),
    airTime: readString(j['airTime']),
    runtimeMinutes: readInt(j['runtimeMinutes']),
    certification: readString(j['certification']),
    rootFolderPath: readString(j['rootFolderPath']),
    seasonFolder: readBool(j['seasonFolder']) ?? true,
    originalLanguage: readString(j['originalLanguage']),
    alternateTitles: readStringList(j['alternateTitles']),
    bannerPath: readString(j['bannerPath']),
    seasons: readList(j['seasons'], SeasonInfo.fromJson),
    episodes: readList(j['episodes'], Episode.fromJson),
    links: _stringMap(j['links']),
  );

  final SeriesSummary series;
  final String? overview;

  /// Network-local `HH:mm`.
  final String? airTime;
  final int? runtimeMinutes;
  final String? certification;
  final String? rootFolderPath;
  final bool seasonFolder;
  final String? originalLanguage;
  final List<String> alternateTitles;
  final String? bannerPath;

  /// Ascending, specials (season 0) last.
  final List<SeasonInfo> seasons;

  /// By season, then episode number.
  final List<Episode> episodes;

  /// `tvdb`, `imdb` web links.
  final Map<String, String> links;

  /// Sonarr's URL slug (`/series/<titleSlug>` in the Sonarr web UI).
  final String? titleSlug;

  JsonMap toJson() => compactJson({
    'series': series.toJson(),
    'titleSlug': titleSlug,
    'overview': overview,
    'airTime': airTime,
    'runtimeMinutes': runtimeMinutes,
    'certification': certification,
    'rootFolderPath': rootFolderPath,
    'seasonFolder': seasonFolder,
    'originalLanguage': originalLanguage,
    'alternateTitles': alternateTitles,
    'bannerPath': bannerPath,
    'seasons': [for (final s in seasons) s.toJson()],
    'episodes': [for (final e in episodes) e.toJson()],
    'links': links,
  });

  /// A copy with other parts replaced (optimistic updates in the app).
  SeriesDetail copyWith({
    SeriesSummary? series,
    List<SeasonInfo>? seasons,
    List<Episode>? episodes,
  }) => SeriesDetail(
    series: series ?? this.series,
    overview: overview,
    airTime: airTime,
    runtimeMinutes: runtimeMinutes,
    certification: certification,
    rootFolderPath: rootFolderPath,
    seasonFolder: seasonFolder,
    originalLanguage: originalLanguage,
    alternateTitles: alternateTitles,
    bannerPath: bannerPath,
    seasons: seasons ?? this.seasons,
    episodes: episodes ?? this.episodes,
    links: links,
    titleSlug: titleSlug,
  );
}

// ---------------------------------------------------------------------------
// Movies
// ---------------------------------------------------------------------------

/// One Radarr movie as listed in the library.
@immutable
final class MovieSummary {
  const MovieSummary({
    required this.id,
    required this.title,
    required this.sortTitle,
    required this.status,
    required this.monitored,
    this.year,
    this.hasFile = false,
    this.isAvailable = false,
    this.minimumAvailability = LibraryMinimumAvailability.released,
    this.qualityProfileId = 0,
    this.qualityProfileName,
    this.posterPath,
    this.fanartPath,
    this.inCinemasDate,
    this.digitalReleaseDate,
    this.physicalReleaseDate,
    this.releaseDate,
    this.runtimeMinutes,
    this.sizeOnDiskBytes = 0,
    this.quality,
    this.cutoffNotMet = false,
    this.added,
    this.genres = const [],
    this.tmdbId,
    this.imdbId,
    this.studio,
    this.certification,
    this.ratingImdb,
    this.ratingTmdb,
    this.collection,
    this.tags = const [],
  });

  factory MovieSummary.fromJson(JsonMap j) => MovieSummary(
    id: req(readInt(j['id']), 'id'),
    title: readString(j['title']) ?? '',
    sortTitle: readString(j['sortTitle']) ?? '',
    year: readInt(j['year']),
    status: LibraryMovieStatus.fromJson(j['status']),
    monitored: readBool(j['monitored']) ?? false,
    hasFile: readBool(j['hasFile']) ?? false,
    isAvailable: readBool(j['isAvailable']) ?? false,
    minimumAvailability: LibraryMinimumAvailability.fromJson(
      j['minimumAvailability'],
    ),
    qualityProfileId: readInt(j['qualityProfileId']) ?? 0,
    qualityProfileName: readString(j['qualityProfileName']),
    posterPath: readString(j['posterPath']),
    fanartPath: readString(j['fanartPath']),
    inCinemasDate: readString(j['inCinemasDate']),
    digitalReleaseDate: readString(j['digitalReleaseDate']),
    physicalReleaseDate: readString(j['physicalReleaseDate']),
    releaseDate: readString(j['releaseDate']),
    runtimeMinutes: readInt(j['runtimeMinutes']),
    sizeOnDiskBytes: readInt(j['sizeOnDiskBytes']) ?? 0,
    quality: readString(j['quality']),
    cutoffNotMet: readBool(j['cutoffNotMet']) ?? false,
    added: _instant(j['added']),
    genres: readStringList(j['genres']),
    tmdbId: readInt(j['tmdbId']),
    imdbId: readString(j['imdbId']),
    studio: readString(j['studio']),
    certification: readString(j['certification']),
    ratingImdb: readDouble(j['ratingImdb']),
    ratingTmdb: readDouble(j['ratingTmdb']),
    collection: readString(j['collection']),
    tags: readStringList(j['tags']),
  );

  final int id;
  final String title;
  final String sortTitle;
  final int? year;
  final LibraryMovieStatus status;
  final bool monitored;
  final bool hasFile;

  /// The minimum availability has been reached.
  final bool isAvailable;
  final LibraryMinimumAvailability minimumAvailability;
  final int qualityProfileId;
  final String? qualityProfileName;
  final String? posterPath;
  final String? fanartPath;

  /// Release dates as `YYYY-MM-DD` (never time-zone converted).
  final String? inCinemasDate;
  final String? digitalReleaseDate;
  final String? physicalReleaseDate;

  /// Radarr's "available" date.
  final String? releaseDate;
  final int? runtimeMinutes;
  final int sizeOnDiskBytes;

  /// Quality of the file, e.g. `Bluray-1080p`.
  final String? quality;
  final bool cutoffNotMet;
  final DateTime? added;
  final List<String> genres;
  final int? tmdbId;
  final String? imdbId;
  final String? studio;
  final String? certification;
  final double? ratingImdb;
  final double? ratingTmdb;

  /// Collection title.
  final String? collection;

  /// Tag labels (read-only in the hub).
  final List<String> tags;

  JsonMap toJson() => compactJson({
    'id': id,
    'title': title,
    'sortTitle': sortTitle,
    'year': year,
    'status': status.toJson(),
    'monitored': monitored,
    'hasFile': hasFile,
    'isAvailable': isAvailable,
    'minimumAvailability': minimumAvailability.toJson(),
    'qualityProfileId': qualityProfileId,
    'qualityProfileName': qualityProfileName,
    'posterPath': posterPath,
    'fanartPath': fanartPath,
    'inCinemasDate': inCinemasDate,
    'digitalReleaseDate': digitalReleaseDate,
    'physicalReleaseDate': physicalReleaseDate,
    'releaseDate': releaseDate,
    'runtimeMinutes': runtimeMinutes,
    'sizeOnDiskBytes': sizeOnDiskBytes,
    'quality': quality,
    'cutoffNotMet': cutoffNotMet,
    'added': optionalInstantToJson(added),
    'genres': genres,
    'tmdbId': tmdbId,
    'imdbId': imdbId,
    'studio': studio,
    'certification': certification,
    'ratingImdb': ratingImdb,
    'ratingTmdb': ratingTmdb,
    'collection': collection,
    'tags': tags,
  });

  /// A copy with another monitored state (optimistic toggles in the app).
  MovieSummary copyWithMonitored(bool value) =>
      MovieSummary.fromJson({...toJson(), 'monitored': value});
}

/// `GET /library/movies/{id}`.
@immutable
final class MovieDetail {
  const MovieDetail({
    required this.movie,
    this.overview,
    this.files = const [],
    this.queue,
    this.alternateTitles = const [],
    this.youTubeTrailerId,
    this.links = const {},
  });

  factory MovieDetail.fromJson(JsonMap j) => MovieDetail(
    movie: MovieSummary.fromJson(req(readMap(j['movie']), 'movie')),
    overview: readString(j['overview']),
    files: readList(j['files'], MediaFileInfo.fromJson),
    queue: switch (readMap(j['queue'])) {
      final m? => EpisodeQueueState.fromJson(m),
      null => null,
    },
    alternateTitles: readStringList(j['alternateTitles']),
    youTubeTrailerId: readString(j['youTubeTrailerId']),
    links: _stringMap(j['links']),
  );

  final MovieSummary movie;
  final String? overview;
  final List<MediaFileInfo> files;

  /// Set while the movie is downloading.
  final EpisodeQueueState? queue;
  final List<String> alternateTitles;
  final String? youTubeTrailerId;

  /// `tmdb` and `imdb` web links.
  final Map<String, String> links;

  JsonMap toJson() => compactJson({
    'movie': movie.toJson(),
    'overview': overview,
    'files': [for (final f in files) f.toJson()],
    'queue': queue?.toJson(),
    'alternateTitles': alternateTitles,
    'youTubeTrailerId': youTubeTrailerId,
    'links': links,
  });

  /// A copy with another movie summary (optimistic updates in the app).
  MovieDetail copyWithMovie(MovieSummary movie) => MovieDetail(
    movie: movie,
    overview: overview,
    files: files,
    queue: queue,
    alternateTitles: alternateTitles,
    youTubeTrailerId: youTubeTrailerId,
    links: links,
  );
}

// ---------------------------------------------------------------------------
// Lookup and add
// ---------------------------------------------------------------------------

/// The add-sheet defaults the gateway suggests for a [SeriesLookup].
@immutable
final class SeriesLookupSuggestion {
  const SeriesLookupSuggestion({
    required this.seriesType,
    required this.qualityProfileId,
    required this.rootFolderPath,
  });

  factory SeriesLookupSuggestion.fromJson(JsonMap j) => SeriesLookupSuggestion(
    seriesType: LibrarySeriesType.fromJson(j['seriesType']),
    qualityProfileId: readInt(j['qualityProfileId']) ?? 0,
    rootFolderPath: readString(j['rootFolderPath']) ?? '',
  );

  final LibrarySeriesType seriesType;
  final int qualityProfileId;
  final String rootFolderPath;

  JsonMap toJson() => {
    'seriesType': seriesType.toJson(),
    'qualityProfileId': qualityProfileId,
    'rootFolderPath': rootFolderPath,
  };
}

/// A Sonarr lookup result (`GET /library/tv/lookup`).
@immutable
final class SeriesLookup {
  const SeriesLookup({
    required this.tvdbId,
    required this.title,
    required this.status,
    required this.suggested,
    this.year,
    this.overview,
    this.network,
    this.genres = const [],
    this.runtimeMinutes,
    this.seasonNumbers = const [],
    this.posterPath,
    this.ratingValue,
    this.originalLanguage,
    this.isAnime = false,
    this.inLibrary = false,
    this.libraryId,
  });

  factory SeriesLookup.fromJson(JsonMap j) => SeriesLookup(
    tvdbId: req(readInt(j['tvdbId']), 'tvdbId'),
    title: readString(j['title']) ?? '',
    year: readInt(j['year']),
    overview: readString(j['overview']),
    network: readString(j['network']),
    status: readString(j['status']) ?? 'unknown',
    genres: readStringList(j['genres']),
    runtimeMinutes: readInt(j['runtimeMinutes']),
    seasonNumbers: readIntList(j['seasonNumbers']),
    posterPath: readString(j['posterPath']),
    ratingValue: readDouble(j['ratingValue']),
    originalLanguage: readString(j['originalLanguage']),
    isAnime: readBool(j['isAnime']) ?? false,
    inLibrary: readBool(j['inLibrary']) ?? false,
    libraryId: readInt(j['libraryId']),
    suggested: SeriesLookupSuggestion.fromJson(
      readMap(j['suggested']) ?? const {},
    ),
  );

  final int tvdbId;
  final String title;
  final int? year;
  final String? overview;
  final String? network;
  final String status;
  final List<String> genres;
  final int? runtimeMinutes;
  final List<int> seasonNumbers;
  final String? posterPath;
  final double? ratingValue;
  final String? originalLanguage;
  final bool isAnime;
  final bool inLibrary;

  /// The Sonarr series id when [inLibrary].
  final int? libraryId;
  final SeriesLookupSuggestion suggested;

  JsonMap toJson() => compactJson({
    'tvdbId': tvdbId,
    'title': title,
    'year': year,
    'overview': overview,
    'network': network,
    'status': status,
    'genres': genres,
    'runtimeMinutes': runtimeMinutes,
    'seasonNumbers': seasonNumbers,
    'posterPath': posterPath,
    'ratingValue': ratingValue,
    'originalLanguage': originalLanguage,
    'isAnime': isAnime,
    'inLibrary': inLibrary,
    'libraryId': libraryId,
    'suggested': suggested.toJson(),
  });
}

/// The add-sheet defaults the gateway suggests for a [MovieLookup].
@immutable
final class MovieLookupSuggestion {
  const MovieLookupSuggestion({
    required this.qualityProfileId,
    required this.rootFolderPath,
    this.minimumAvailability = LibraryMinimumAvailability.released,
  });

  factory MovieLookupSuggestion.fromJson(JsonMap j) => MovieLookupSuggestion(
    qualityProfileId: readInt(j['qualityProfileId']) ?? 0,
    rootFolderPath: readString(j['rootFolderPath']) ?? '',
    minimumAvailability: LibraryMinimumAvailability.fromJson(
      j['minimumAvailability'],
    ),
  );

  final int qualityProfileId;
  final String rootFolderPath;
  final LibraryMinimumAvailability minimumAvailability;

  JsonMap toJson() => {
    'qualityProfileId': qualityProfileId,
    'rootFolderPath': rootFolderPath,
    'minimumAvailability': minimumAvailability.toJson(),
  };
}

/// A Radarr lookup result (`GET /library/movies/lookup`).
@immutable
final class MovieLookup {
  const MovieLookup({
    required this.tmdbId,
    required this.title,
    required this.status,
    required this.suggested,
    this.imdbId,
    this.year,
    this.overview,
    this.runtimeMinutes,
    this.genres = const [],
    this.posterPath,
    this.ratingTmdb,
    this.studio,
    this.inLibrary = false,
    this.libraryId,
    this.hasFile = false,
  });

  factory MovieLookup.fromJson(JsonMap j) => MovieLookup(
    tmdbId: req(readInt(j['tmdbId']), 'tmdbId'),
    imdbId: readString(j['imdbId']),
    title: readString(j['title']) ?? '',
    year: readInt(j['year']),
    overview: readString(j['overview']),
    status: readString(j['status']) ?? 'unknown',
    runtimeMinutes: readInt(j['runtimeMinutes']),
    genres: readStringList(j['genres']),
    posterPath: readString(j['posterPath']),
    ratingTmdb: readDouble(j['ratingTmdb']),
    studio: readString(j['studio']),
    inLibrary: readBool(j['inLibrary']) ?? false,
    libraryId: readInt(j['libraryId']),
    hasFile: readBool(j['hasFile']) ?? false,
    suggested: MovieLookupSuggestion.fromJson(
      readMap(j['suggested']) ?? const {},
    ),
  );

  final int tmdbId;
  final String? imdbId;
  final String title;
  final int? year;
  final String? overview;
  final String status;
  final int? runtimeMinutes;
  final List<String> genres;
  final String? posterPath;
  final double? ratingTmdb;

  /// Studio (shown next to the year in the add list).
  final String? studio;
  final bool inLibrary;

  /// The Radarr movie id when [inLibrary].
  final int? libraryId;
  final bool hasFile;
  final MovieLookupSuggestion suggested;

  JsonMap toJson() => compactJson({
    'tmdbId': tmdbId,
    'imdbId': imdbId,
    'title': title,
    'year': year,
    'overview': overview,
    'status': status,
    'runtimeMinutes': runtimeMinutes,
    'genres': genres,
    'posterPath': posterPath,
    'ratingTmdb': ratingTmdb,
    'studio': studio,
    'inLibrary': inLibrary,
    'libraryId': libraryId,
    'hasFile': hasFile,
    'suggested': suggested.toJson(),
  });
}

/// Body of `POST /library/tv`.
@immutable
final class AddSeriesRequest {
  const AddSeriesRequest({
    required this.tvdbId,
    required this.qualityProfileId,
    required this.rootFolderPath,
    required this.seriesType,
    this.seasonFolder = true,
    this.monitor = LibrarySeriesMonitor.all,
    this.monitorNewItems = LibraryMonitorNewItems.all,
    this.searchForMissing = false,
    this.searchForCutoffUnmet = false,
  });

  factory AddSeriesRequest.fromJson(JsonMap j) => AddSeriesRequest(
    tvdbId: req(readInt(j['tvdbId']), 'tvdbId'),
    qualityProfileId: req(readInt(j['qualityProfileId']), 'qualityProfileId'),
    rootFolderPath: req(readString(j['rootFolderPath']), 'rootFolderPath'),
    seriesType: LibrarySeriesType.fromJson(j['seriesType'] ?? 'standard'),
    seasonFolder: readBool(j['seasonFolder']) ?? true,
    monitor: LibrarySeriesMonitor.fromJson(j['monitor'] ?? 'all'),
    monitorNewItems: LibraryMonitorNewItems.fromJson(
      j['monitorNewItems'] ?? 'all',
    ),
    searchForMissing: readBool(j['searchForMissing']) ?? false,
    searchForCutoffUnmet: readBool(j['searchForCutoffUnmet']) ?? false,
  );

  final int tvdbId;
  final int qualityProfileId;
  final String rootFolderPath;
  final LibrarySeriesType seriesType;
  final bool seasonFolder;
  final LibrarySeriesMonitor monitor;
  final LibraryMonitorNewItems monitorNewItems;
  final bool searchForMissing;
  final bool searchForCutoffUnmet;

  JsonMap toJson() => {
    'tvdbId': tvdbId,
    'qualityProfileId': qualityProfileId,
    'rootFolderPath': rootFolderPath,
    'seriesType': seriesType.toJson(),
    'seasonFolder': seasonFolder,
    'monitor': monitor.toJson(),
    'monitorNewItems': monitorNewItems.toJson(),
    'searchForMissing': searchForMissing,
    'searchForCutoffUnmet': searchForCutoffUnmet,
  };
}

/// Body of `POST /library/movies`.
@immutable
final class AddMovieRequest {
  const AddMovieRequest({
    required this.tmdbId,
    required this.qualityProfileId,
    required this.rootFolderPath,
    this.minimumAvailability = LibraryMinimumAvailability.released,
    this.monitor = LibraryMovieMonitor.movieOnly,
    this.searchForMovie = false,
  });

  factory AddMovieRequest.fromJson(JsonMap j) => AddMovieRequest(
    tmdbId: req(readInt(j['tmdbId']), 'tmdbId'),
    qualityProfileId: req(readInt(j['qualityProfileId']), 'qualityProfileId'),
    rootFolderPath: req(readString(j['rootFolderPath']), 'rootFolderPath'),
    minimumAvailability: LibraryMinimumAvailability.fromJson(
      j['minimumAvailability'] ?? 'released',
    ),
    monitor: LibraryMovieMonitor.fromJson(j['monitor'] ?? 'movieOnly'),
    searchForMovie: readBool(j['searchForMovie']) ?? false,
  );

  final int tmdbId;
  final int qualityProfileId;
  final String rootFolderPath;
  final LibraryMinimumAvailability minimumAvailability;
  final LibraryMovieMonitor monitor;
  final bool searchForMovie;

  JsonMap toJson() => {
    'tmdbId': tmdbId,
    'qualityProfileId': qualityProfileId,
    'rootFolderPath': rootFolderPath,
    'minimumAvailability': minimumAvailability.toJson(),
    'monitor': monitor.toJson(),
    'searchForMovie': searchForMovie,
  };
}

// ---------------------------------------------------------------------------
// Wanted
// ---------------------------------------------------------------------------

/// A row of `GET /library/wanted/{missing|cutoff}`.
@immutable
final class WantedItem {
  const WantedItem({
    required this.service,
    required this.id,
    required this.title,
    required this.monitored,
    this.seriesId,
    this.episodeLabel,
    this.episodeTitle,
    this.airDateUtc,
    this.releaseDate,
    this.year,
    this.posterPath,
    this.lastSearchTime,
    this.isAvailable = true,
    this.currentQuality,
    this.cutoffQuality,
  });

  factory WantedItem.fromJson(JsonMap j) => WantedItem(
    service: ArrService.fromJson(j['service']),
    id: req(readInt(j['id']), 'id'),
    seriesId: readInt(j['seriesId']),
    title: readString(j['title']) ?? '',
    episodeLabel: readString(j['episodeLabel']),
    episodeTitle: readString(j['episodeTitle']),
    airDateUtc: _instant(j['airDateUtc']),
    releaseDate: readString(j['releaseDate']),
    year: readInt(j['year']),
    posterPath: readString(j['posterPath']),
    monitored: readBool(j['monitored']) ?? false,
    lastSearchTime: _instant(j['lastSearchTime']),
    isAvailable: readBool(j['isAvailable']) ?? true,
    currentQuality: readString(j['currentQuality']),
    cutoffQuality: readString(j['cutoffQuality']),
  );

  final ArrService service;

  /// Episode id (Sonarr) or movie id (Radarr).
  final int id;
  final int? seriesId;

  /// Series or movie title.
  final String title;
  final String? episodeLabel;
  final String? episodeTitle;
  final DateTime? airDateUtc;

  /// Radarr release date (`YYYY-MM-DD`).
  final String? releaseDate;

  /// Radarr movie year.
  final int? year;
  final String? posterPath;
  final bool monitored;
  final DateTime? lastSearchTime;

  /// Radarr: the movie reached its minimum availability (Sonarr: true).
  final bool isAvailable;
  final String? currentQuality;
  final String? cutoffQuality;

  JsonMap toJson() => compactJson({
    'service': service.toJson(),
    'id': id,
    'seriesId': seriesId,
    'title': title,
    'episodeLabel': episodeLabel,
    'episodeTitle': episodeTitle,
    'airDateUtc': optionalInstantToJson(airDateUtc),
    'releaseDate': releaseDate,
    'year': year,
    'posterPath': posterPath,
    'monitored': monitored,
    'lastSearchTime': optionalInstantToJson(lastSearchTime),
    'isAvailable': isAvailable,
    'currentQuality': currentQuality,
    'cutoffQuality': cutoffQuality,
  });
}

// ---------------------------------------------------------------------------
// Profiles
// ---------------------------------------------------------------------------

/// A quality profile (id and name only; profiles are read-only in the hub).
@immutable
final class LibraryQualityProfile {
  const LibraryQualityProfile({required this.id, required this.name});

  factory LibraryQualityProfile.fromJson(JsonMap j) => LibraryQualityProfile(
    id: req(readInt(j['id']), 'id'),
    name: readString(j['name']) ?? '',
  );

  final int id;
  final String name;

  JsonMap toJson() => {'id': id, 'name': name};
}

/// A root folder with its free space.
@immutable
final class LibraryRootFolder {
  const LibraryRootFolder({
    required this.id,
    required this.path,
    this.freeBytes,
    this.accessible = true,
  });

  factory LibraryRootFolder.fromJson(JsonMap j) => LibraryRootFolder(
    id: req(readInt(j['id']), 'id'),
    path: readString(j['path']) ?? '',
    freeBytes: readInt(j['freeBytes']),
    accessible: readBool(j['accessible']) ?? true,
  );

  final int id;
  final String path;
  final int? freeBytes;
  final bool accessible;

  JsonMap toJson() => compactJson({
    'id': id,
    'path': path,
    'freeBytes': freeBytes,
    'accessible': accessible,
  });
}

/// Add-sheet defaults for Sonarr.
@immutable
final class LibrarySonarrDefaults {
  const LibrarySonarrDefaults({
    required this.standardProfileId,
    required this.animeProfileId,
    this.rootFolderPath,
  });

  factory LibrarySonarrDefaults.fromJson(JsonMap j) => LibrarySonarrDefaults(
    standardProfileId: readInt(j['standardProfileId']) ?? 0,
    animeProfileId: readInt(j['animeProfileId']) ?? 0,
    rootFolderPath: readString(j['rootFolderPath']),
  );

  final int standardProfileId;
  final int animeProfileId;
  final String? rootFolderPath;

  JsonMap toJson() => compactJson({
    'standardProfileId': standardProfileId,
    'animeProfileId': animeProfileId,
    'rootFolderPath': rootFolderPath,
  });
}

/// Add-sheet defaults for Radarr.
@immutable
final class LibraryRadarrDefaults {
  const LibraryRadarrDefaults({
    required this.profileId,
    this.rootFolderPath,
    this.minimumAvailability = LibraryMinimumAvailability.released,
  });

  factory LibraryRadarrDefaults.fromJson(JsonMap j) => LibraryRadarrDefaults(
    profileId: readInt(j['profileId']) ?? 0,
    rootFolderPath: readString(j['rootFolderPath']),
    minimumAvailability: LibraryMinimumAvailability.fromJson(
      j['minimumAvailability'],
    ),
  );

  final int profileId;
  final String? rootFolderPath;
  final LibraryMinimumAvailability minimumAvailability;

  JsonMap toJson() => compactJson({
    'profileId': profileId,
    'rootFolderPath': rootFolderPath,
    'minimumAvailability': minimumAvailability.toJson(),
  });
}

/// The Sonarr part of [LibraryProfiles].
@immutable
final class LibrarySonarrProfiles {
  const LibrarySonarrProfiles({
    required this.qualityProfiles,
    required this.rootFolders,
    required this.defaults,
  });

  factory LibrarySonarrProfiles.fromJson(JsonMap j) => LibrarySonarrProfiles(
    qualityProfiles: readList(
      j['qualityProfiles'],
      LibraryQualityProfile.fromJson,
    ),
    rootFolders: readList(j['rootFolders'], LibraryRootFolder.fromJson),
    defaults: LibrarySonarrDefaults.fromJson(
      readMap(j['defaults']) ?? const {},
    ),
  );

  final List<LibraryQualityProfile> qualityProfiles;
  final List<LibraryRootFolder> rootFolders;
  final LibrarySonarrDefaults defaults;

  JsonMap toJson() => {
    'qualityProfiles': [for (final p in qualityProfiles) p.toJson()],
    'rootFolders': [for (final r in rootFolders) r.toJson()],
    'defaults': defaults.toJson(),
  };
}

/// The Radarr part of [LibraryProfiles].
@immutable
final class LibraryRadarrProfiles {
  const LibraryRadarrProfiles({
    required this.qualityProfiles,
    required this.rootFolders,
    required this.defaults,
  });

  factory LibraryRadarrProfiles.fromJson(JsonMap j) => LibraryRadarrProfiles(
    qualityProfiles: readList(
      j['qualityProfiles'],
      LibraryQualityProfile.fromJson,
    ),
    rootFolders: readList(j['rootFolders'], LibraryRootFolder.fromJson),
    defaults: LibraryRadarrDefaults.fromJson(
      readMap(j['defaults']) ?? const {},
    ),
  );

  final List<LibraryQualityProfile> qualityProfiles;
  final List<LibraryRootFolder> rootFolders;
  final LibraryRadarrDefaults defaults;

  JsonMap toJson() => {
    'qualityProfiles': [for (final p in qualityProfiles) p.toJson()],
    'rootFolders': [for (final r in rootFolders) r.toJson()],
    'defaults': defaults.toJson(),
  };
}

/// `GET /library/profiles`.
@immutable
final class LibraryProfiles {
  const LibraryProfiles({required this.sonarr, required this.radarr});

  factory LibraryProfiles.fromJson(JsonMap j) => LibraryProfiles(
    sonarr: LibrarySonarrProfiles.fromJson(readMap(j['sonarr']) ?? const {}),
    radarr: LibraryRadarrProfiles.fromJson(readMap(j['radarr']) ?? const {}),
  );

  final LibrarySonarrProfiles sonarr;
  final LibraryRadarrProfiles radarr;

  JsonMap toJson() => {'sonarr': sonarr.toJson(), 'radarr': radarr.toJson()};
}

// ---------------------------------------------------------------------------
// Summary and dashboard card
// ---------------------------------------------------------------------------

/// The download queue counters of an [ArrSummary].
@immutable
final class ArrSummaryQueue {
  const ArrSummaryQueue({
    this.total = 0,
    this.errors = false,
    this.warnings = false,
  });

  factory ArrSummaryQueue.fromJson(JsonMap j) => ArrSummaryQueue(
    total: readInt(j['total']) ?? 0,
    errors: readBool(j['errors']) ?? false,
    warnings: readBool(j['warnings']) ?? false,
  );

  final int total;
  final bool errors;
  final bool warnings;

  JsonMap toJson() => {'total': total, 'errors': errors, 'warnings': warnings};
}

/// Header numbers for one *arr.
@immutable
final class ArrSummary {
  const ArrSummary({
    required this.configured,
    this.version,
    this.itemCount = 0,
    this.missing = 0,
    this.cutoffUnmet = 0,
    this.sizeOnDiskBytes = 0,
    this.freeBytes,
    this.queue = const ArrSummaryQueue(),
    this.health = const [],
  });

  /// The service has no URL/key in the gateway.
  const ArrSummary.notConfigured()
    : configured = false,
      version = null,
      itemCount = 0,
      missing = 0,
      cutoffUnmet = 0,
      sizeOnDiskBytes = 0,
      freeBytes = null,
      queue = const ArrSummaryQueue(),
      health = const [];

  factory ArrSummary.fromJson(JsonMap j) => ArrSummary(
    configured: readBool(j['configured']) ?? false,
    version: readString(j['version']),
    itemCount: readInt(j['itemCount']) ?? 0,
    missing: readInt(j['missing']) ?? 0,
    cutoffUnmet: readInt(j['cutoffUnmet']) ?? 0,
    sizeOnDiskBytes: readInt(j['sizeOnDiskBytes']) ?? 0,
    freeBytes: readInt(j['freeBytes']),
    queue: ArrSummaryQueue.fromJson(readMap(j['queue']) ?? const {}),
    health: readList(j['health'], HealthMessage.fromJson),
  );

  final bool configured;
  final String? version;

  /// Series (Sonarr) or movies (Radarr).
  final int itemCount;

  /// Missing episodes (Sonarr) or available movies without a file (Radarr).
  final int missing;
  final int cutoffUnmet;
  final int sizeOnDiskBytes;
  final int? freeBytes;
  final ArrSummaryQueue queue;
  final List<HealthMessage> health;

  /// Health messages of type warning or error.
  List<HealthMessage> get problems => [
    for (final h in health)
      if (h.type == HealthMessageType.warning ||
          h.type == HealthMessageType.error)
        h,
  ];

  JsonMap toJson() => compactJson({
    'configured': configured,
    'version': version,
    'itemCount': itemCount,
    'missing': missing,
    'cutoffUnmet': cutoffUnmet,
    'sizeOnDiskBytes': sizeOnDiskBytes,
    'freeBytes': freeBytes,
    'queue': queue.toJson(),
    'health': [for (final h in health) h.toJson()],
  });
}

/// `GET /library/summary`.
@immutable
final class LibrarySummary {
  const LibrarySummary({required this.sonarr, required this.radarr});

  factory LibrarySummary.fromJson(JsonMap j) => LibrarySummary(
    sonarr: ArrSummary.fromJson(readMap(j['sonarr']) ?? const {}),
    radarr: ArrSummary.fromJson(readMap(j['radarr']) ?? const {}),
  );

  final ArrSummary sonarr;
  final ArrSummary radarr;

  JsonMap toJson() => {'sonarr': sonarr.toJson(), 'radarr': radarr.toJson()};
}

/// Dashboard card `library` (API.md §7.11): the same data as
/// [LibrarySummary].
@immutable
final class LibraryCard {
  const LibraryCard({required this.sonarr, required this.radarr});

  factory LibraryCard.fromJson(JsonMap j) => LibraryCard(
    sonarr: ArrSummary.fromJson(readMap(j['sonarr']) ?? const {}),
    radarr: ArrSummary.fromJson(readMap(j['radarr']) ?? const {}),
  );

  factory LibraryCard.fromSummary(LibrarySummary s) =>
      LibraryCard(sonarr: s.sonarr, radarr: s.radarr);

  final ArrSummary sonarr;
  final ArrSummary radarr;

  JsonMap toJson() => {'sonarr': sonarr.toJson(), 'radarr': radarr.toJson()};
}

// ---------------------------------------------------------------------------
// Interactive release search
// ---------------------------------------------------------------------------

/// One release found by an interactive search (API.md §7.8). Download URLs,
/// GUIDs, magnets and info hashes are never included: [releaseId] is a
/// gateway token valid for 30 minutes.
@immutable
final class ReleaseChoice {
  const ReleaseChoice({
    required this.releaseId,
    required this.service,
    required this.title,
    required this.indexer,
    required this.indexerId,
    required this.quality,
    this.customFormats = const [],
    this.customFormatScore = 0,
    this.sizeBytes = 0,
    this.ageHours,
    this.publishDate,
    this.seeders,
    this.leechers,
    this.protocol = LibraryReleaseProtocol.unknown,
    this.languages = const [],
    this.releaseGroup,
    this.fullSeason = false,
    this.episodeLabels = const [],
    this.approved = false,
    this.temporarilyRejected = false,
    this.rejected = false,
    this.rejections = const [],
    this.infoUrl,
  });

  factory ReleaseChoice.fromJson(JsonMap j) => ReleaseChoice(
    releaseId: req(readString(j['releaseId']), 'releaseId'),
    service: ArrService.fromJson(j['service']),
    title: readString(j['title']) ?? '',
    indexer: readString(j['indexer']) ?? '',
    indexerId: readInt(j['indexerId']) ?? 0,
    quality: QualityInfo.fromJson(readMap(j['quality']) ?? const {}),
    customFormats: readStringList(j['customFormats']),
    customFormatScore: readInt(j['customFormatScore']) ?? 0,
    sizeBytes: readInt(j['sizeBytes']) ?? 0,
    ageHours: readInt(j['ageHours']),
    publishDate: _instant(j['publishDate']),
    seeders: readInt(j['seeders']),
    leechers: readInt(j['leechers']),
    protocol: LibraryReleaseProtocol.fromJson(j['protocol']),
    languages: readStringList(j['languages']),
    releaseGroup: readString(j['releaseGroup']),
    fullSeason: readBool(j['fullSeason']) ?? false,
    episodeLabels: readStringList(j['episodeLabels']),
    approved: readBool(j['approved']) ?? false,
    temporarilyRejected: readBool(j['temporarilyRejected']) ?? false,
    rejected: readBool(j['rejected']) ?? false,
    rejections: readStringList(j['rejections']),
    infoUrl: readString(j['infoUrl']),
  );

  /// Gateway token for `POST /library/releases/grab`.
  final String releaseId;
  final ArrService service;
  final String title;
  final String indexer;
  final int indexerId;
  final QualityInfo quality;
  final List<String> customFormats;
  final int customFormatScore;
  final int sizeBytes;
  final int? ageHours;
  final DateTime? publishDate;
  final int? seeders;
  final int? leechers;
  final LibraryReleaseProtocol protocol;
  final List<String> languages;
  final String? releaseGroup;

  /// A season pack.
  final bool fullSeason;

  /// Episodes in the release (`S03E01 (049)` for anime).
  final List<String> episodeLabels;
  final bool approved;
  final bool temporarilyRejected;
  final bool rejected;

  /// Why the *arr would not grab it automatically.
  final List<String> rejections;
  final String? infoUrl;

  JsonMap toJson() => compactJson({
    'releaseId': releaseId,
    'service': service.toJson(),
    'title': title,
    'indexer': indexer,
    'indexerId': indexerId,
    'quality': quality.toJson(),
    'customFormats': customFormats,
    'customFormatScore': customFormatScore,
    'sizeBytes': sizeBytes,
    'ageHours': ageHours,
    'publishDate': optionalInstantToJson(publishDate),
    'seeders': seeders,
    'leechers': leechers,
    'protocol': protocol.toJson(),
    'languages': languages,
    'releaseGroup': releaseGroup,
    'fullSeason': fullSeason,
    'episodeLabels': episodeLabels,
    'approved': approved,
    'temporarilyRejected': temporarilyRejected,
    'rejected': rejected,
    'rejections': rejections,
    'infoUrl': infoUrl,
  });
}

/// The result of a release search.
@immutable
final class ReleaseChoiceList {
  const ReleaseChoiceList({required this.items, this.tookMs = 0});

  factory ReleaseChoiceList.fromJson(JsonMap j) => ReleaseChoiceList(
    items: readList(j['items'], ReleaseChoice.fromJson),
    tookMs: readInt(j['tookMs']) ?? 0,
  );

  /// Approved first, then in upstream order.
  final List<ReleaseChoice> items;
  final int tookMs;

  JsonMap toJson() => {
    'items': [for (final i in items) i.toJson()],
    'tookMs': tookMs,
  };
}

/// Answer of `POST /library/releases/grab`.
@immutable
final class ReleaseChoiceGrabResult {
  const ReleaseChoiceGrabResult({required this.ok, required this.title});

  factory ReleaseChoiceGrabResult.fromJson(JsonMap j) =>
      ReleaseChoiceGrabResult(
        ok: readBool(j['ok']) ?? false,
        title: readString(j['title']) ?? '',
      );

  final bool ok;
  final String title;

  JsonMap toJson() => {'ok': ok, 'title': title};
}

/// Answer of the command routes: `{"command": CommandRef}`.
@immutable
final class LibraryCommandResponse {
  const LibraryCommandResponse(this.command);

  factory LibraryCommandResponse.fromJson(JsonMap j) => LibraryCommandResponse(
    CommandRef.fromJson(req(readMap(j['command']), 'command')),
  );

  final CommandRef command;

  JsonMap toJson() => {'command': command.toJson()};
}
