/// DTOs shared by the Sonarr/Radarr based features (API.md §5).
library;

import 'package:meta/meta.dart';

import 'common.dart';
import 'json.dart';

/// Which *arr a record comes from.
enum ArrService {
  sonarr,
  radarr,
  unknown;

  /// The matching [ServiceId] ([ServiceId.unknown] for [unknown]).
  ServiceId get serviceId => switch (this) {
    sonarr => ServiceId.sonarr,
    radarr => ServiceId.radarr,
    unknown => ServiceId.unknown,
  };

  static ArrService fromJson(Object? v) =>
      readEnum(v, ArrService.values, ArrService.unknown);

  String toJson() => name;
}

/// Builds Sonarr episode labels (API.md §7.1): `S{ss}E{ee}`, plus
/// ` ({abs, 3 digits})` for anime series with an absolute number.
abstract final class ArrEpisodeLabel {
  /// `S03E01`, or `S03E01 (049)` when [anime] and [absoluteEpisodeNumber] is
  /// set.
  static String format(
    int seasonNumber,
    int episodeNumber, {
    int? absoluteEpisodeNumber,
    bool anime = false,
  }) {
    final base =
        'S${seasonNumber.toString().padLeft(2, '0')}'
        'E${episodeNumber.toString().padLeft(2, '0')}';
    if (!anime || absoluteEpisodeNumber == null) return base;
    return '$base (${absoluteEpisodeNumber.toString().padLeft(3, '0')})';
  }
}

/// A release or file quality, e.g. `WEBDL-1080p`.
@immutable
final class QualityInfo {
  const QualityInfo({
    required this.name,
    this.source,
    this.resolution,
    this.modifier,
    this.revision,
    this.isRepack = false,
  });

  factory QualityInfo.fromJson(JsonMap j) => QualityInfo(
    name: readString(j['name']) ?? 'Unknown',
    source: readString(j['source']),
    resolution: readInt(j['resolution']),
    modifier: readString(j['modifier']),
    revision: readInt(j['revision']),
    isRepack: readBool(j['isRepack']) ?? false,
  );

  final String name;
  final String? source;

  /// Vertical resolution, e.g. 1080.
  final int? resolution;
  final String? modifier;

  /// Only present when greater than 1 (a PROPER/REAL release).
  final int? revision;
  final bool isRepack;

  JsonMap toJson() => compactJson({
    'name': name,
    'source': source,
    'resolution': resolution,
    'modifier': modifier,
    'revision': revision,
    'isRepack': isRepack,
  });
}

/// An episode or movie file (the absolute `path` is never included).
@immutable
final class MediaFileInfo {
  const MediaFileInfo({
    required this.id,
    required this.relativePath,
    required this.sizeBytes,
    required this.quality,
    this.dateAdded,
    this.customFormats = const [],
    this.customFormatScore = 0,
    this.cutoffNotMet = false,
    this.releaseGroup,
    this.edition,
    this.languages = const [],
    this.videoCodec,
    this.videoDynamicRange,
    this.resolution,
    this.audioCodec,
    this.audioChannels,
    this.audioLanguages = const [],
    this.subtitleLanguages = const [],
    this.runTime,
  });

  factory MediaFileInfo.fromJson(JsonMap j) => MediaFileInfo(
    id: req(readInt(j['id']), 'id'),
    relativePath: readString(j['relativePath']) ?? '',
    sizeBytes: readInt(j['sizeBytes']) ?? 0,
    dateAdded: readInstant(j['dateAdded']),
    quality: QualityInfo.fromJson(readMap(j['quality']) ?? const {}),
    customFormats: readStringList(j['customFormats']),
    customFormatScore: readInt(j['customFormatScore']) ?? 0,
    cutoffNotMet: readBool(j['cutoffNotMet']) ?? false,
    releaseGroup: readString(j['releaseGroup']),
    edition: readString(j['edition']),
    languages: readStringList(j['languages']),
    videoCodec: readString(j['videoCodec']),
    videoDynamicRange: readString(j['videoDynamicRange']),
    resolution: readString(j['resolution']),
    audioCodec: readString(j['audioCodec']),
    audioChannels: readDouble(j['audioChannels']),
    audioLanguages: readStringList(j['audioLanguages']),
    subtitleLanguages: readStringList(j['subtitleLanguages']),
    runTime: readString(j['runTime']),
  );

  final int id;
  final String relativePath;
  final int sizeBytes;
  final DateTime? dateAdded;
  final QualityInfo quality;

  /// Custom format names.
  final List<String> customFormats;
  final int customFormatScore;
  final bool cutoffNotMet;
  final String? releaseGroup;
  final String? edition;
  final List<String> languages;
  final String? videoCodec;

  /// e.g. `HDR10`.
  final String? videoDynamicRange;

  /// e.g. `1920x1080`.
  final String? resolution;
  final String? audioCodec;
  final double? audioChannels;
  final List<String> audioLanguages;
  final List<String> subtitleLanguages;

  /// e.g. `41:55`.
  final String? runTime;

  JsonMap toJson() => compactJson({
    'id': id,
    'relativePath': relativePath,
    'sizeBytes': sizeBytes,
    'dateAdded': optionalInstantToJson(dateAdded),
    'quality': quality.toJson(),
    'customFormats': customFormats,
    'customFormatScore': customFormatScore,
    'cutoffNotMet': cutoffNotMet,
    'releaseGroup': releaseGroup,
    'edition': edition,
    'languages': languages,
    'videoCodec': videoCodec,
    'videoDynamicRange': videoDynamicRange,
    'resolution': resolution,
    'audioCodec': audioCodec,
    'audioChannels': audioChannels,
    'audioLanguages': audioLanguages,
    'subtitleLanguages': subtitleLanguages,
    'runTime': runTime,
  });
}

/// Severity of a [HealthMessage].
enum HealthMessageType {
  ok,
  notice,
  warning,
  error,
  unknown;

  static HealthMessageType fromJson(Object? v) =>
      readEnum(v, HealthMessageType.values, HealthMessageType.unknown);

  String toJson() => name;
}

/// One entry of an *arr/Prowlarr `GET /api/v3/health` style check list.
@immutable
final class HealthMessage {
  const HealthMessage({
    required this.service,
    required this.source,
    required this.type,
    required this.message,
    this.wikiUrl,
  });

  factory HealthMessage.fromJson(JsonMap j) => HealthMessage(
    service: ServiceId.fromJson(j['service']),
    source: readString(j['source']) ?? '',
    type: HealthMessageType.fromJson(j['type']),
    message: readString(j['message']) ?? '',
    wikiUrl: readString(j['wikiUrl']),
  );

  final ServiceId service;

  /// Upstream check name, e.g. `IndexerLongTermStatusCheck`.
  final String source;
  final HealthMessageType type;
  final String message;
  final String? wikiUrl;

  JsonMap toJson() => compactJson({
    'service': service.toJson(),
    'source': source,
    'type': type.toJson(),
    'message': message,
    'wikiUrl': wikiUrl,
  });
}

/// Normalised *arr history event type.
///
/// Sonarr and Radarr number their events differently from 5 upward; use
/// [sonarrEventTypes]/[radarrEventTypes] for upstream `eventType=` filters
/// (integers only) and [fromUpstreamName] for the camelCase names in records.
enum ArrHistoryType {
  grabbed([1], [1]),
  imported([2, 3], [3, 7]),
  failed([4], [4]),
  deleted([5], [6]),
  renamed([6], [8]),
  ignored([7], [9]),
  unknown([], []);

  const ArrHistoryType(this.sonarrEventTypes, this.radarrEventTypes);

  /// Sonarr `eventType` integers for this type.
  final List<int> sonarrEventTypes;

  /// Radarr `eventType` integers for this type.
  final List<int> radarrEventTypes;

  /// Upstream `eventType` integers of [service] for this type.
  List<int> eventTypesFor(ArrService service) => switch (service) {
    ArrService.sonarr => sonarrEventTypes,
    ArrService.radarr => radarrEventTypes,
    ArrService.unknown => const [],
  };

  /// Maps an upstream `eventType` integer of [service].
  static ArrHistoryType fromEventType(ArrService service, int eventType) {
    for (final t in values) {
      if (t.eventTypesFor(service).contains(eventType)) return t;
    }
    return unknown;
  }

  /// Maps the camelCase `eventType` name of a Sonarr or Radarr history
  /// record (`downloadFolderImported`, `movieFileDeleted`, ...).
  static ArrHistoryType fromUpstreamName(Object? v) => switch (v) {
    'grabbed' => grabbed,
    'seriesFolderImported' ||
    'downloadFolderImported' ||
    'movieFolderImported' => imported,
    'downloadFailed' => failed,
    'episodeFileDeleted' || 'movieFileDeleted' => deleted,
    'episodeFileRenamed' || 'movieFileRenamed' => renamed,
    'downloadIgnored' => ignored,
    _ => unknown,
  };

  static ArrHistoryType fromJson(Object? v) =>
      readEnum(v, ArrHistoryType.values, ArrHistoryType.unknown);

  String toJson() => name;
}

/// How a grabbed release was found.
enum ArrReleaseSource {
  rss,
  search,
  interactiveSearch,
  unknown;

  /// Maps the upstream `data.releaseSource` value (`Rss`, `Search`,
  /// `InteractiveSearch`, case-insensitive).
  static ArrReleaseSource fromUpstream(Object? v) =>
      switch (v is String ? v.toLowerCase() : null) {
        'rss' => rss,
        'search' => search,
        'interactivesearch' => interactiveSearch,
        _ => unknown,
      };

  static ArrReleaseSource fromJson(Object? v) =>
      readEnum(v, ArrReleaseSource.values, ArrReleaseSource.unknown);

  String toJson() => name;
}

/// The episode of a Sonarr [ArrHistoryItem].
@immutable
final class ArrHistoryEpisode {
  const ArrHistoryEpisode({
    required this.id,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.label,
    this.absoluteEpisodeNumber,
    this.title,
  });

  factory ArrHistoryEpisode.fromJson(JsonMap j) {
    final season = req(readInt(j['seasonNumber']), 'seasonNumber');
    final episode = req(readInt(j['episodeNumber']), 'episodeNumber');
    return ArrHistoryEpisode(
      id: req(readInt(j['id']), 'id'),
      seasonNumber: season,
      episodeNumber: episode,
      absoluteEpisodeNumber: readInt(j['absoluteEpisodeNumber']),
      title: readString(j['title']),
      label: readString(j['label']) ?? ArrEpisodeLabel.format(season, episode),
    );
  }

  final int id;
  final int seasonNumber;
  final int episodeNumber;
  final int? absoluteEpisodeNumber;
  final String? title;

  /// `S01E02`, or `S03E01 (049)` for anime ([ArrEpisodeLabel]).
  final String label;

  JsonMap toJson() => compactJson({
    'id': id,
    'seasonNumber': seasonNumber,
    'episodeNumber': episodeNumber,
    'absoluteEpisodeNumber': absoluteEpisodeNumber,
    'title': title,
    'label': label,
  });
}

/// One normalised Sonarr/Radarr history record. Download URLs, GUIDs, NZB
/// info URLs and paths are never included.
@immutable
final class ArrHistoryItem {
  const ArrHistoryItem({
    required this.id,
    required this.service,
    required this.type,
    required this.date,
    required this.sourceTitle,
    required this.quality,
    this.mediaTitle,
    this.seriesId,
    this.movieId,
    this.episode,
    this.customFormatScore = 0,
    this.indexer,
    this.releaseGroup,
    this.sizeBytes,
    this.downloadClient,
    this.releaseSource,
    this.reason,
    this.downloadId,
    this.posterPath,
  });

  factory ArrHistoryItem.fromJson(JsonMap j) => ArrHistoryItem(
    id: req(readString(j['id']), 'id'),
    service: ArrService.fromJson(j['service']),
    type: ArrHistoryType.fromJson(j['type']),
    date: req(readInstant(j['date']), 'date'),
    sourceTitle: readString(j['sourceTitle']) ?? '',
    mediaTitle: readString(j['mediaTitle']),
    seriesId: readInt(j['seriesId']),
    movieId: readInt(j['movieId']),
    episode: switch (readMap(j['episode'])) {
      final m? => ArrHistoryEpisode.fromJson(m),
      null => null,
    },
    quality: QualityInfo.fromJson(readMap(j['quality']) ?? const {}),
    customFormatScore: readInt(j['customFormatScore']) ?? 0,
    indexer: readString(j['indexer']),
    releaseGroup: readString(j['releaseGroup']),
    sizeBytes: readInt(j['sizeBytes']),
    downloadClient: readString(j['downloadClient']),
    releaseSource: j['releaseSource'] == null
        ? null
        : ArrReleaseSource.fromJson(j['releaseSource']),
    reason: readString(j['reason']),
    downloadId: readString(j['downloadId']),
    posterPath: readString(j['posterPath']),
  );

  /// `<service>:<upstream id>`, e.g. `sonarr:98123`.
  final String id;
  final ArrService service;
  final ArrHistoryType type;
  final DateTime date;
  final String sourceTitle;

  /// Series or movie title.
  final String? mediaTitle;
  final int? seriesId;
  final int? movieId;

  /// Sonarr only.
  final ArrHistoryEpisode? episode;
  final QualityInfo quality;
  final int customFormatScore;
  final String? indexer;
  final String? releaseGroup;
  final int? sizeBytes;
  final String? downloadClient;

  /// Grabbed records only.
  final ArrReleaseSource? releaseSource;

  /// Deleted records: `ManualOverride`, `Upgrade`, ...
  final String? reason;

  /// Lower-cased download client id (torrent hash).
  final String? downloadId;

  /// Gateway-relative image path.
  final String? posterPath;

  JsonMap toJson() => compactJson({
    'id': id,
    'service': service.toJson(),
    'type': type.toJson(),
    'date': instantToJson(date),
    'sourceTitle': sourceTitle,
    'mediaTitle': mediaTitle,
    'seriesId': seriesId,
    'movieId': movieId,
    'episode': episode?.toJson(),
    'quality': quality.toJson(),
    'customFormatScore': customFormatScore,
    'indexer': indexer,
    'releaseGroup': releaseGroup,
    'sizeBytes': sizeBytes,
    'downloadClient': downloadClient,
    'releaseSource': releaseSource?.toJson(),
    'reason': reason,
    'downloadId': downloadId,
    'posterPath': posterPath,
  });
}
