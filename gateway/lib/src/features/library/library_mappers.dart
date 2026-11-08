/// Pure mapping from Sonarr/Radarr v3 resources to the library DTOs
/// (API.md §7, integrations/arr.md).
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

/// A JSON array of objects, or a [FormatException] (mapped to
/// `502 upstream_bad_response` by the error handler).
List<JsonMap> arrList(Object? v, [String what = 'response']) {
  if (v is! List) throw FormatException('$what is not a JSON array');
  return [for (final e in v) ?readMap(e)];
}

/// A JSON object, or a [FormatException].
JsonMap arrMap(Object? v, [String what = 'response']) =>
    readMap(v) ?? (throw FormatException('$what is not a JSON object'));

/// A Servarr paging envelope (`page`, `pageSize`, `totalRecords`, `records`).
final class ArrPage {
  ArrPage(JsonMap j)
    : total = readInt(j['totalRecords']) ?? 0,
      records = arrList(j['records'] ?? const [], 'records');

  final int total;
  final List<JsonMap> records;
}

/// The date part of a Radarr release instant (`2026-01-26T00:00:00Z` →
/// `2026-01-26`), without time-zone conversion.
String? arrDatePart(Object? v) {
  final s = readString(v);
  if (s == null || s.length < 10) return null;
  final d = s.substring(0, 10);
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(d)) return null;
  if (d.startsWith('0001-')) return null;
  return d;
}

/// Parses a .NET TimeSpan (`00:41:10`, `1.02:03:04`, `00:00:00.0008733`) to
/// whole seconds.
int? arrTimeSpanSeconds(Object? v) {
  final s = readString(v);
  if (s == null) return null;
  final m = RegExp(r'^(?:(\d+)\.)?(\d{1,2}):(\d{2}):(\d{2})(?:\.(\d+))?$')
      .firstMatch(s.trim());
  if (m == null) return null;
  final days = int.parse(m[1] ?? '0');
  return days * 86400 +
      int.parse(m[2]!) * 3600 +
      int.parse(m[3]!) * 60 +
      int.parse(m[4]!);
}

String? _nonEmpty(Object? v) {
  final s = readString(v)?.trim();
  return s == null || s.isEmpty ? null : s;
}

int? _positive(Object? v) {
  final i = readInt(v);
  return i == null || i <= 0 ? null : i;
}

List<String> _names(Object? v) => [
  for (final e in v is List ? v : const [])
    if (readMap(e) case final m?) ?_nonEmpty(m['name']) else ?_nonEmpty(e),
];

List<String> _slashList(Object? v) {
  final s = readString(v);
  if (s == null) return const [];
  final out = <String>[];
  for (final part in s.split('/')) {
    final p = part.trim();
    if (p.isNotEmpty && !out.contains(p)) out.add(p);
  }
  return out;
}

/// The `lastWrite` (Sonarr) or `h` (Radarr) version token of an *arr image
/// `url` such as `/MediaCover/54/poster.jpg?lastWrite=639058149420070772`.
String? arrImageVersion(String? url) {
  if (url == null) return null;
  final q = Uri.tryParse(url)?.queryParameters;
  if (q == null) return null;
  return _nonEmpty(q['lastWrite']) ?? _nonEmpty(q['h']);
}

/// The image of [coverType] in an *arr `images` array.
JsonMap? arrImage(Object? images, String coverType) {
  if (images is! List) return null;
  for (final i in images) {
    final m = readMap(i);
    if (m != null && m['coverType'] == coverType) return m;
  }
  return null;
}

/// Maps Sonarr/Radarr resources to DTOs. Tag labels and profile names are
/// passed in by the caller (they come from cached lookups).
final class LibraryMapper {
  LibraryMapper(this.images, {String Function(String)? redact})
    : _redact = redact ?? redactSecrets;

  final ImageUrls images;
  final String Function(String) _redact;

  // -------------------------------------------------------------------------
  // Images
  // -------------------------------------------------------------------------

  /// The gateway path of a library cover (falls back to the remote URL when
  /// the *arr has not downloaded it yet).
  String? cover(
    ArrService svc,
    int id,
    Object? imagesJson,
    String coverType, {
    int size = 500,
  }) {
    final img = arrImage(imagesJson, coverType);
    if (img == null) return null;
    return images.arr(
      svc,
      id,
      coverType,
      size: size,
      version: arrImageVersion(readString(img['url'])),
      fallbackUrl: readString(img['remoteUrl']),
    );
  }

  /// The proxied remote poster of a lookup result.
  String? lookupPoster(JsonMap j, {int width = 342}) {
    final remote =
        _nonEmpty(j['remotePoster']) ??
        _nonEmpty(arrImage(j['images'], 'poster')?['remoteUrl']);
    return images.remote(remote, width: width);
  }

  // -------------------------------------------------------------------------
  // Shared
  // -------------------------------------------------------------------------

  /// `{quality: {id, name, source, resolution, modifier}, revision: {...}}`.
  QualityInfo quality(Object? v) {
    final q = readMap(v) ?? const {};
    final inner = readMap(q['quality']) ?? q;
    final rev = readMap(q['revision']);
    final version = readInt(rev?['version']);
    final modifier = _nonEmpty(inner['modifier']);
    return QualityInfo(
      name: _nonEmpty(inner['name']) ?? 'Unknown',
      source: _nonEmpty(inner['source']),
      resolution: _positive(inner['resolution']),
      modifier: modifier == 'none' ? null : modifier,
      revision: version != null && version > 1 ? version : null,
      isRepack: readBool(rev?['isRepack']) ?? false,
    );
  }

  /// An episode or movie file (`path` is dropped).
  MediaFileInfo? mediaFile(Object? v) {
    final f = readMap(v);
    final id = readInt(f?['id']);
    if (f == null || id == null) return null;
    final mi = readMap(f['mediaInfo']) ?? const {};
    return MediaFileInfo(
      id: id,
      relativePath: readString(f['relativePath']) ?? '',
      sizeBytes: readInt(f['size']) ?? 0,
      dateAdded: readInstant(f['dateAdded']),
      quality: quality(f['quality']),
      customFormats: _names(f['customFormats']),
      customFormatScore: readInt(f['customFormatScore']) ?? 0,
      cutoffNotMet: readBool(f['qualityCutoffNotMet']) ?? false,
      releaseGroup: _nonEmpty(f['releaseGroup']),
      edition: _nonEmpty(f['edition']),
      languages: _names(f['languages']),
      videoCodec: _nonEmpty(mi['videoCodec']),
      videoDynamicRange:
          _nonEmpty(mi['videoDynamicRangeType']) ??
          _nonEmpty(mi['videoDynamicRange']),
      resolution: _nonEmpty(mi['resolution']),
      audioCodec: _nonEmpty(mi['audioCodec']),
      audioChannels: readDouble(mi['audioChannels']),
      audioLanguages: _slashList(mi['audioLanguages']),
      subtitleLanguages: _slashList(mi['subtitles']),
      runTime: _nonEmpty(mi['runTime']),
    );
  }

  /// A `queue/details` record as [EpisodeQueueState].
  EpisodeQueueState queueState(JsonMap q) {
    final size = readDouble(q['size']) ?? 0;
    final left = readDouble(q['sizeleft']) ?? 0;
    final progress = size <= 0 ? 0.0 : (1 - left / size).clamp(0.0, 1.0);
    return EpisodeQueueState(
      status: _nonEmpty(q['status']) ?? 'unknown',
      trackedState: _nonEmpty(q['trackedDownloadState']) ?? 'unknown',
      progress: double.parse(progress.toStringAsFixed(4)),
      etaSeconds: arrTimeSpanSeconds(q['timeleft']),
    );
  }

  /// Tag labels of `tags: [ids]`; unknown ids are dropped.
  static List<String> tagLabels(Object? ids, Map<int, String> labels) => [
    for (final id in readIntList(ids)) ?labels[id],
  ];

  /// `[{id, label}]` (`GET /api/v3/tag`) as a map.
  static Map<int, String> tagMap(Object? tags) => {
    for (final t in arrList(tags, 'tags'))
      ?readInt(t['id']): ?_nonEmpty(t['label']),
  };

  /// `[{id, name}]` quality profiles as a map.
  static Map<int, String> profileNames(List<JsonMap> profiles) => {
    for (final p in profiles) ?readInt(p['id']): readString(p['name']) ?? '',
  };

  /// The name of a profile's cutoff (a quality id or a group id).
  static String? cutoffName(JsonMap? profile) {
    if (profile == null) return null;
    final cutoff = readInt(profile['cutoff']);
    if (cutoff == null) return null;
    String? search(Object? items) {
      if (items is! List) return null;
      for (final i in items) {
        final m = readMap(i);
        if (m == null) continue;
        final q = readMap(m['quality']);
        if (q != null && readInt(q['id']) == cutoff) {
          return _nonEmpty(q['name']);
        }
        if (q == null && readInt(m['id']) == cutoff) {
          return _nonEmpty(m['name']);
        }
        final nested = search(m['items']);
        if (nested != null) return nested;
      }
      return null;
    }

    return search(profile['items']);
  }

  // -------------------------------------------------------------------------
  // Series
  // -------------------------------------------------------------------------

  static bool _genresAnime(List<String> genres) =>
      genres.any((g) => g.toLowerCase() == 'anime');

  SeriesSummary series(
    JsonMap s, {
    Map<int, String> tags = const {},
    Map<int, String> profiles = const {},
  }) {
    final id = req(readInt(s['id']), 'id');
    final stats = readMap(s['statistics']) ?? const {};
    final genres = readStringList(s['genres']);
    final type = LibrarySeriesType.fromJson(s['seriesType']);
    final episodeCount = readInt(stats['episodeCount']) ?? 0;
    final fileCount = readInt(stats['episodeFileCount']) ?? 0;
    final ratings = readMap(s['ratings']);
    final votes = readInt(ratings?['votes']);
    final profileId = readInt(s['qualityProfileId']) ?? 0;
    final percent = readDouble(stats['percentOfEpisodes']) ?? 0;
    return SeriesSummary(
      id: id,
      title: readString(s['title']) ?? '',
      sortTitle: readString(s['sortTitle']) ?? readString(s['title']) ?? '',
      year: _positive(s['year']),
      status: LibrarySeriesStatus.fromJson(s['status']),
      seriesType: type,
      isAnime: type == LibrarySeriesType.anime || _genresAnime(genres),
      monitored: readBool(s['monitored']) ?? false,
      monitorNewItems: LibraryMonitorNewItems.fromJson(
        s['monitorNewItems'] ?? 'all',
      ),
      network: _nonEmpty(s['network']),
      qualityProfileId: profileId,
      qualityProfileName: profiles[profileId],
      posterPath: cover(
        ArrService.sonarr,
        id,
        s['images'],
        'poster',
        size: 250,
      ),
      fanartPath: cover(ArrService.sonarr, id, s['images'], 'fanart'),
      nextAiring: readInstant(s['nextAiring']),
      previousAiring: readInstant(s['previousAiring']),
      seasonCount: readInt(stats['seasonCount']) ?? 0,
      episodeCount: episodeCount,
      episodeFileCount: fileCount,
      missingCount: episodeCount - fileCount < 0 ? 0 : episodeCount - fileCount,
      totalEpisodeCount: readInt(stats['totalEpisodeCount']) ?? 0,
      sizeOnDiskBytes: readInt(stats['sizeOnDisk']) ?? 0,
      percentComplete: double.parse(percent.toStringAsFixed(1)),
      added: readInstant(s['added']),
      genres: genres,
      tvdbId: _positive(s['tvdbId']),
      tmdbId: _positive(s['tmdbId']),
      imdbId: _nonEmpty(s['imdbId']),
      ratingValue: votes == null || votes == 0
          ? null
          : readDouble(ratings?['value']),
      ratingVotes: votes == null || votes == 0 ? null : votes,
      tags: tagLabels(s['tags'], tags),
    );
  }

  SeasonInfo season(JsonMap s) {
    final stats = readMap(s['statistics']) ?? const {};
    return SeasonInfo(
      seasonNumber: req(readInt(s['seasonNumber']), 'seasonNumber'),
      monitored: readBool(s['monitored']) ?? false,
      episodeCount: readInt(stats['episodeCount']) ?? 0,
      episodeFileCount: readInt(stats['episodeFileCount']) ?? 0,
      totalEpisodeCount: readInt(stats['totalEpisodeCount']) ?? 0,
      sizeOnDiskBytes: readInt(stats['sizeOnDisk']) ?? 0,
      nextAiring: readInstant(stats['nextAiring']),
      previousAiring: readInstant(stats['previousAiring']),
      posterPath: images.remote(
        _nonEmpty(arrImage(s['images'], 'poster')?['remoteUrl']),
        width: 250,
      ),
    );
  }

  /// Seasons ascending with specials (0) last.
  static int compareSeasons(int a, int b) {
    if (a == b) return 0;
    if (a == 0) return 1;
    if (b == 0) return -1;
    return a.compareTo(b);
  }

  Episode episode(JsonMap e, {required bool anime, EpisodeQueueState? queue}) {
    final season = req(readInt(e['seasonNumber']), 'seasonNumber');
    final number = req(readInt(e['episodeNumber']), 'episodeNumber');
    final abs = _positive(e['absoluteEpisodeNumber']);
    return Episode(
      id: req(readInt(e['id']), 'id'),
      seasonNumber: season,
      episodeNumber: number,
      absoluteEpisodeNumber: abs,
      label: ArrEpisodeLabel.format(
        season,
        number,
        absoluteEpisodeNumber: abs,
        anime: anime,
      ),
      title: _nonEmpty(e['title']),
      overview: _nonEmpty(e['overview']),
      airDate: _nonEmpty(e['airDate']),
      airDateUtc: readInstant(e['airDateUtc']),
      runtimeMinutes: _positive(e['runtime']),
      monitored: readBool(e['monitored']) ?? false,
      hasFile: readBool(e['hasFile']) ?? false,
      finaleType: _nonEmpty(e['finaleType']),
      lastSearchTime: readInstant(e['lastSearchTime']),
      file: mediaFile(e['episodeFile']),
      queue: queue,
    );
  }

  SeriesDetail seriesDetail(
    JsonMap s,
    List<JsonMap> episodes,
    List<JsonMap> queue, {
    Map<int, String> tags = const {},
    Map<int, String> profiles = const {},
  }) {
    final summary = series(s, tags: tags, profiles: profiles);
    final anime = summary.seriesType == LibrarySeriesType.anime;
    final queueByEpisode = <int, EpisodeQueueState>{};
    for (final q in queue) {
      final eid = readInt(q['episodeId']);
      if (eid != null) queueByEpisode.putIfAbsent(eid, () => queueState(q));
    }
    final seasons = [
      for (final x in arrList(s['seasons'] ?? const [])) season(x),
    ]..sort((a, b) => compareSeasons(a.seasonNumber, b.seasonNumber));
    final eps =
        [
          for (final e in episodes)
            episode(e, anime: anime, queue: queueByEpisode[readInt(e['id'])]),
        ]..sort((a, b) {
          final c = a.seasonNumber.compareTo(b.seasonNumber);
          return c != 0 ? c : a.episodeNumber.compareTo(b.episodeNumber);
        });
    final alt = <String>[];
    for (final t in arrList(s['alternateTitles'] ?? const [])) {
      final title = _nonEmpty(t['title']);
      if (title != null && title != summary.title && !alt.contains(title)) {
        alt.add(title);
      }
    }
    return SeriesDetail(
      series: summary,
      overview: _nonEmpty(s['overview']),
      airTime: _nonEmpty(s['airTime']),
      runtimeMinutes: _positive(s['runtime']),
      certification: _nonEmpty(s['certification']),
      rootFolderPath: _nonEmpty(s['rootFolderPath']),
      seasonFolder: readBool(s['seasonFolder']) ?? true,
      originalLanguage: _nonEmpty(readMap(s['originalLanguage'])?['name']),
      alternateTitles: alt,
      bannerPath: cover(ArrService.sonarr, summary.id, s['images'], 'banner'),
      seasons: seasons,
      episodes: eps,
      titleSlug: _nonEmpty(s['titleSlug']),
      links: {
        if (summary.tvdbId case final tvdb?)
          'tvdb': 'https://thetvdb.com/?tab=series&id=$tvdb',
        if (summary.imdbId case final imdb?)
          'imdb': 'https://www.imdb.com/title/$imdb/',
      },
    );
  }

  // -------------------------------------------------------------------------
  // Movies
  // -------------------------------------------------------------------------

  MovieSummary movie(
    JsonMap m, {
    Map<int, String> tags = const {},
    Map<int, String> profiles = const {},
  }) {
    final id = req(readInt(m['id']), 'id');
    final file = readMap(m['movieFile']);
    final ratings = readMap(m['ratings']);
    double? rating(String source) {
      final r = readMap(ratings?[source]);
      final votes = readInt(r?['votes']) ?? 0;
      final value = readDouble(r?['value']);
      return votes == 0 || value == null || value == 0 ? null : value;
    }

    final profileId = readInt(m['qualityProfileId']) ?? 0;
    final stats = readMap(m['statistics']);
    return MovieSummary(
      id: id,
      title: readString(m['title']) ?? '',
      sortTitle: readString(m['sortTitle']) ?? readString(m['title']) ?? '',
      year: _positive(m['year']),
      status: LibraryMovieStatus.fromJson(m['status']),
      monitored: readBool(m['monitored']) ?? false,
      hasFile: (readInt(m['movieFileId']) ?? 0) > 0,
      isAvailable: readBool(m['isAvailable']) ?? false,
      minimumAvailability: LibraryMinimumAvailability.fromJson(
        m['minimumAvailability'],
      ),
      qualityProfileId: profileId,
      qualityProfileName: profiles[profileId],
      posterPath: cover(
        ArrService.radarr,
        id,
        m['images'],
        'poster',
        size: 250,
      ),
      fanartPath: cover(ArrService.radarr, id, m['images'], 'fanart'),
      inCinemasDate: arrDatePart(m['inCinemas']),
      digitalReleaseDate: arrDatePart(m['digitalRelease']),
      physicalReleaseDate: arrDatePart(m['physicalRelease']),
      releaseDate: arrDatePart(m['releaseDate']),
      runtimeMinutes: _positive(m['runtime']),
      sizeOnDiskBytes:
          readInt(m['sizeOnDisk']) ?? readInt(stats?['sizeOnDisk']) ?? 0,
      quality: file == null ? null : quality(file['quality']).name,
      cutoffNotMet: readBool(file?['qualityCutoffNotMet']) ?? false,
      added: readInstant(m['added']),
      genres: readStringList(m['genres']),
      tmdbId: _positive(m['tmdbId']),
      imdbId: _nonEmpty(m['imdbId']),
      studio: _nonEmpty(m['studio']),
      certification: _nonEmpty(m['certification']),
      ratingImdb: rating('imdb'),
      ratingTmdb: rating('tmdb'),
      collection: _nonEmpty(readMap(m['collection'])?['title']),
      tags: tagLabels(m['tags'], tags),
    );
  }

  MovieDetail movieDetail(
    JsonMap m,
    List<JsonMap> files,
    List<JsonMap> queue, {
    Map<int, String> tags = const {},
    Map<int, String> profiles = const {},
  }) {
    final summary = movie(m, tags: tags, profiles: profiles);
    final fileList = [for (final f in files) ?mediaFile(f)];
    if (fileList.isEmpty) {
      if (mediaFile(m['movieFile']) case final f?) fileList.add(f);
    }
    final alt = <String>[];
    for (final t in arrList(m['alternateTitles'] ?? const [])) {
      final title = _nonEmpty(t['title']);
      if (title != null && title != summary.title && !alt.contains(title)) {
        alt.add(title);
      }
    }
    return MovieDetail(
      movie: summary,
      overview: _nonEmpty(m['overview']),
      files: fileList,
      queue: queue.isEmpty ? null : queueState(queue.first),
      alternateTitles: alt.length > 10 ? alt.sublist(0, 10) : alt,
      youTubeTrailerId: _nonEmpty(m['youTubeTrailerId']),
      links: {
        if (summary.tmdbId case final tmdb?)
          'tmdb': 'https://www.themoviedb.org/movie/$tmdb',
        if (summary.imdbId case final imdb?)
          'imdb': 'https://www.imdb.com/title/$imdb/',
      },
    );
  }

  // -------------------------------------------------------------------------
  // Lookup
  // -------------------------------------------------------------------------

  SeriesLookup seriesLookup(
    JsonMap s, {
    required LibrarySonarrDefaults defaults,
  }) {
    final genres = readStringList(s['genres']);
    final anime =
        _genresAnime(genres) ||
        LibrarySeriesType.fromJson(s['seriesType']) == LibrarySeriesType.anime;
    final ratings = readMap(s['ratings']);
    final votes = readInt(ratings?['votes']) ?? 0;
    final libraryId = _positive(s['id']);
    return SeriesLookup(
      tvdbId: req(readInt(s['tvdbId']), 'tvdbId'),
      title: readString(s['title']) ?? '',
      year: _positive(s['year']),
      overview: _nonEmpty(s['overview']),
      network: _nonEmpty(s['network']),
      status: _nonEmpty(s['status']) ?? 'unknown',
      genres: genres,
      runtimeMinutes: _positive(s['runtime']),
      seasonNumbers: [
        for (final x in arrList(s['seasons'] ?? const []))
          ?readInt(x['seasonNumber']),
      ]..sort(),
      posterPath: lookupPoster(s),
      ratingValue: votes == 0 ? null : readDouble(ratings?['value']),
      originalLanguage: _nonEmpty(readMap(s['originalLanguage'])?['name']),
      isAnime: anime,
      inLibrary: libraryId != null,
      libraryId: libraryId,
      suggested: SeriesLookupSuggestion(
        seriesType: anime
            ? LibrarySeriesType.anime
            : LibrarySeriesType.standard,
        qualityProfileId: anime
            ? defaults.animeProfileId
            : defaults.standardProfileId,
        rootFolderPath: defaults.rootFolderPath ?? '',
      ),
    );
  }

  MovieLookup movieLookup(
    JsonMap m, {
    required LibraryRadarrDefaults defaults,
  }) {
    final libraryId = _positive(m['id']);
    final tmdb = readMap(readMap(m['ratings'])?['tmdb']);
    final tmdbVotes = readInt(tmdb?['votes']) ?? 0;
    return MovieLookup(
      tmdbId: req(readInt(m['tmdbId']), 'tmdbId'),
      imdbId: _nonEmpty(m['imdbId']),
      title: readString(m['title']) ?? '',
      year: _positive(m['year']),
      overview: _nonEmpty(m['overview']),
      status: _nonEmpty(m['status']) ?? 'unknown',
      runtimeMinutes: _positive(m['runtime']),
      genres: readStringList(m['genres']),
      posterPath: lookupPoster(m),
      ratingTmdb: tmdbVotes == 0 ? null : readDouble(tmdb?['value']),
      studio: _nonEmpty(m['studio']),
      inLibrary: libraryId != null,
      libraryId: libraryId,
      hasFile: (readInt(m['movieFileId']) ?? 0) > 0,
      suggested: MovieLookupSuggestion(
        qualityProfileId: defaults.profileId,
        rootFolderPath: defaults.rootFolderPath ?? '',
        minimumAvailability: defaults.minimumAvailability,
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Wanted
  // -------------------------------------------------------------------------

  WantedItem wantedEpisode(JsonMap e, {String? cutoffQuality}) {
    final series = readMap(e['series']) ?? const {};
    final seriesId = readInt(e['seriesId']) ?? readInt(series['id']);
    final anime =
        LibrarySeriesType.fromJson(series['seriesType']) ==
        LibrarySeriesType.anime;
    final season = readInt(e['seasonNumber']);
    final number = readInt(e['episodeNumber']);
    final file = readMap(e['episodeFile']);
    return WantedItem(
      service: ArrService.sonarr,
      id: req(readInt(e['id']), 'id'),
      seriesId: seriesId,
      title: readString(series['title']) ?? '',
      episodeLabel: season == null || number == null
          ? null
          : ArrEpisodeLabel.format(
              season,
              number,
              absoluteEpisodeNumber: _positive(e['absoluteEpisodeNumber']),
              anime: anime,
            ),
      episodeTitle: _nonEmpty(e['title']),
      airDateUtc: readInstant(e['airDateUtc']),
      posterPath: seriesId == null
          ? null
          : cover(
              ArrService.sonarr,
              seriesId,
              series['images'],
              'poster',
              size: 250,
            ),
      monitored: readBool(e['monitored']) ?? false,
      lastSearchTime: readInstant(e['lastSearchTime']),
      isAvailable: true,
      currentQuality: file == null ? null : quality(file['quality']).name,
      cutoffQuality: cutoffQuality,
    );
  }

  WantedItem wantedMovie(
    JsonMap m, {
    String? currentQuality,
    String? cutoffQuality,
  }) {
    final id = req(readInt(m['id']), 'id');
    return WantedItem(
      service: ArrService.radarr,
      id: id,
      title: readString(m['title']) ?? '',
      releaseDate:
          arrDatePart(m['releaseDate']) ??
          arrDatePart(m['digitalRelease']) ??
          arrDatePart(m['physicalRelease']) ??
          arrDatePart(m['inCinemas']),
      year: _positive(m['year']),
      posterPath: cover(
        ArrService.radarr,
        id,
        m['images'],
        'poster',
        size: 250,
      ),
      monitored: readBool(m['monitored']) ?? false,
      lastSearchTime: readInstant(m['lastSearchTime']),
      isAvailable: readBool(m['isAvailable']) ?? false,
      currentQuality: currentQuality,
      cutoffQuality: cutoffQuality,
    );
  }

  // -------------------------------------------------------------------------
  // History
  // -------------------------------------------------------------------------

  /// A history record (`downloadUrl`, `guid`, `nzbInfoUrl` and paths are
  /// never copied).
  ArrHistoryItem history(
    ArrService svc,
    JsonMap r, {
    String? mediaTitle,
    bool anime = false,
    String? posterPath,
  }) {
    final data = readMap(r['data']) ?? const {};
    final eventType = r['eventType'];
    final type = switch (eventType) {
      final int i => ArrHistoryType.fromEventType(svc, i),
      _ => ArrHistoryType.fromUpstreamName(eventType),
    };
    final ep = readMap(r['episode']);
    ArrHistoryEpisode? episode;
    if (svc == ArrService.sonarr && ep != null) {
      final season = readInt(ep['seasonNumber']);
      final number = readInt(ep['episodeNumber']);
      final eid = readInt(ep['id']) ?? readInt(r['episodeId']);
      if (season != null && number != null && eid != null) {
        final abs = _positive(ep['absoluteEpisodeNumber']);
        episode = ArrHistoryEpisode(
          id: eid,
          seasonNumber: season,
          episodeNumber: number,
          absoluteEpisodeNumber: abs,
          title: _nonEmpty(ep['title']),
          label: ArrEpisodeLabel.format(
            season,
            number,
            absoluteEpisodeNumber: abs,
            anime: anime,
          ),
        );
      }
    }
    final title =
        mediaTitle ??
        _nonEmpty(readMap(r['series'])?['title']) ??
        _nonEmpty(readMap(r['movie'])?['title']);
    return ArrHistoryItem(
      id: '${svc.name}:${req(readInt(r['id']), 'id')}',
      service: svc,
      type: type,
      date: req(readInstant(r['date']), 'date'),
      sourceTitle: readString(r['sourceTitle'])?.trim() ?? '',
      mediaTitle: title,
      seriesId: svc == ArrService.sonarr ? _positive(r['seriesId']) : null,
      movieId: svc == ArrService.radarr ? _positive(r['movieId']) : null,
      episode: episode,
      quality: quality(r['quality']),
      customFormatScore:
          readInt(r['customFormatScore']) ??
          readInt(data['customFormatScore']) ??
          0,
      indexer: _nonEmpty(data['indexer']),
      releaseGroup: _nonEmpty(data['releaseGroup']),
      sizeBytes: _positive(data['size']),
      downloadClient:
          _nonEmpty(data['downloadClientName']) ??
          _nonEmpty(data['downloadClient']),
      releaseSource: type == ArrHistoryType.grabbed
          ? ArrReleaseSource.fromUpstream(data['releaseSource'])
          : null,
      reason: type == ArrHistoryType.deleted ? _nonEmpty(data['reason']) : null,
      downloadId: _nonEmpty(r['downloadId'])?.toLowerCase(),
      posterPath: posterPath,
    );
  }

  // -------------------------------------------------------------------------
  // Commands
  // -------------------------------------------------------------------------

  CommandRef command(ArrService svc, JsonMap c) {
    final body = readMap(c['body']);
    final message = _nonEmpty(c['message']);
    return CommandRef(
      service: svc.serviceId,
      id: req(readInt(c['id']), 'id'),
      name: _nonEmpty(c['name']) ?? _nonEmpty(body?['name']) ?? '',
      status: CommandStatus.fromJson(c['status']),
      result: CommandResult.fromJson(c['result']),
      message: message == null ? null : _redact(message),
      queuedAt: readInstant(c['queued']),
      startedAt: readInstant(c['started']),
      endedAt: readInstant(c['ended']),
    );
  }

  // -------------------------------------------------------------------------
  // Health
  // -------------------------------------------------------------------------

  HealthMessage health(ArrService svc, JsonMap h) => HealthMessage(
    service: svc.serviceId,
    source: _nonEmpty(h['source']) ?? 'Unknown',
    type: HealthMessageType.fromJson(h['type']),
    message: _redact(_nonEmpty(h['message']) ?? ''),
    wikiUrl: _nonEmpty(h['wikiUrl']),
  );

  // -------------------------------------------------------------------------
  // Releases
  // -------------------------------------------------------------------------

  /// The release fields of [r] (without `releaseId`, which the caller
  /// assigns). Secrets (`guid`, `downloadUrl`, `magnetUrl`, `infoHash`,
  /// `commentUrl`) are never read.
  ReleaseChoice release(
    ArrService svc,
    JsonMap r, {
    required String releaseId,
    bool anime = false,
  }) {
    final ageHours = readDouble(r['ageHours']);
    final age = readInt(r['age']);
    final protocol = switch (r['protocol']) {
      'torrent' || 2 => LibraryReleaseProtocol.torrent,
      'usenet' || 1 => LibraryReleaseProtocol.usenet,
      _ => LibraryReleaseProtocol.unknown,
    };
    final labels = <String>[];
    if (svc == ArrService.sonarr) {
      final season =
          readInt(r['mappedSeasonNumber']) ?? readInt(r['seasonNumber']);
      final numbers = readIntList(r['mappedEpisodeNumbers']).isNotEmpty
          ? readIntList(r['mappedEpisodeNumbers'])
          : readIntList(r['episodeNumbers']);
      final absolute = readIntList(r['absoluteEpisodeNumbers']);
      if (season != null) {
        for (var i = 0; i < numbers.length; i++) {
          labels.add(
            ArrEpisodeLabel.format(
              season,
              numbers[i],
              absoluteEpisodeNumber: i < absolute.length ? absolute[i] : null,
              anime: anime,
            ),
          );
        }
      }
    }
    final infoUrl = _nonEmpty(r['infoUrl']);
    final rejections = <String>[];
    for (final x
        in r['rejections'] is List ? r['rejections'] as List : const []) {
      final text = readString(x) ?? readString(readMap(x)?['reason']);
      if (text != null && text.trim().isNotEmpty) {
        rejections.add(_redact(text.trim()));
      }
    }
    final rejected = readBool(r['rejected']) ?? rejections.isNotEmpty;
    return ReleaseChoice(
      releaseId: releaseId,
      service: svc,
      title: readString(r['title']) ?? '',
      indexer: _nonEmpty(r['indexer']) ?? 'Unknown indexer',
      indexerId: readInt(r['indexerId']) ?? 0,
      quality: quality(r['quality']),
      customFormats: _names(r['customFormats']),
      customFormatScore: readInt(r['customFormatScore']) ?? 0,
      sizeBytes: readInt(r['size']) ?? 0,
      ageHours: ageHours != null
          ? ageHours.floor()
          : (age == null ? null : age * 24),
      publishDate: readInstant(r['publishDate']),
      seeders: readInt(r['seeders']),
      leechers: readInt(r['leechers']),
      protocol: protocol,
      languages: _names(r['languages']),
      releaseGroup: _nonEmpty(r['releaseGroup']),
      fullSeason: readBool(r['fullSeason']) ?? false,
      episodeLabels: labels,
      approved: readBool(r['approved']) ?? false,
      temporarilyRejected: readBool(r['temporarilyRejected']) ?? false,
      rejected: rejected,
      rejections: rejections,
      infoUrl: infoUrl == null ? null : _redact(infoUrl),
    );
  }
}
