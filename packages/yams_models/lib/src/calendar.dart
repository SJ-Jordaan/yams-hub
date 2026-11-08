/// Calendar DTOs (API.md §9): the merged Sonarr/Radarr agenda and its
/// dashboard card.
library;

import 'package:meta/meta.dart';

import 'common.dart';
import 'json.dart';

/// What a [CalendarItem] is.
enum CalendarItemKind {
  episode,
  movie,
  unknown;

  static CalendarItemKind fromJson(Object? v) =>
      readEnum(v, CalendarItemKind.values, CalendarItemKind.unknown);

  String toJson() => name;
}

/// Which Radarr release date a movie [CalendarItem] stands for.
enum CalendarReleaseType {
  cinema('In cinemas', 'Cinema'),
  digital('Digital release', 'Digital'),
  physical('Physical release', 'Physical'),
  unknown('Release', 'Release');

  const CalendarReleaseType(this.subtitle, this.label);

  /// The item subtitle the gateway writes ("Digital release").
  final String subtitle;

  /// A short chip label ("Digital").
  final String label;

  static CalendarReleaseType fromJson(Object? v) =>
      readEnum(v, CalendarReleaseType.values, CalendarReleaseType.unknown);

  static CalendarReleaseType? fromJsonOrNull(Object? v) =>
      v == null ? null : fromJson(v);

  String toJson() => name;
}

final _datePattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})');

/// Reads a `Date` (`"YYYY-MM-DD"`, a full instant is cut to its date part)
/// as a UTC midnight [DateTime] that only carries the calendar date.
DateTime? _readDate(Object? v) {
  if (v is! String) return null;
  final m = _datePattern.firstMatch(v.trim());
  if (m == null) return null;
  final y = int.parse(m[1]!);
  final mo = int.parse(m[2]!);
  final d = int.parse(m[3]!);
  final date = DateTime.utc(y, mo, d);
  // Reject overflowing values such as 2026-02-31.
  if (date.year != y || date.month != mo || date.day != d) return null;
  return date;
}

String _dateToJson(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Helpers for `Date` values (`"YYYY-MM-DD"`, never time-zone converted).
/// The DTOs keep them as UTC midnight [DateTime]s that only carry the
/// calendar date.
abstract final class CalendarDates {
  /// The calendar date of [d] (its year, month and day, ignoring time and
  /// zone).
  static DateTime of(DateTime d) => DateTime.utc(d.year, d.month, d.day);

  /// Parses `"YYYY-MM-DD"` (a full instant is cut to its date part); null
  /// for anything else, including impossible dates such as `2026-02-31`.
  static DateTime? parse(Object? v) => _readDate(v);

  /// `"YYYY-MM-DD"`.
  static String format(DateTime d) => _dateToJson(d);
}

/// One agenda entry: an episode airing or a movie release date.
@immutable
final class CalendarItem {
  const CalendarItem({
    required this.id,
    required this.kind,
    required this.date,
    required this.title,
    required this.subtitle,
    this.airDateUtc,
    this.seriesId,
    this.episodeId,
    this.movieId,
    this.seasonNumber,
    this.episodeNumber,
    this.absoluteEpisodeNumber,
    this.finaleType,
    this.network,
    this.releaseType,
    this.hasFile = false,
    this.monitored = true,
    this.downloading = false,
    this.posterPath,
  });

  factory CalendarItem.fromJson(JsonMap j) => CalendarItem(
    id: req(readString(j['id']), 'id'),
    kind: CalendarItemKind.fromJson(j['kind']),
    date: req(_readDate(j['date']), 'date'),
    title: readString(j['title']) ?? '',
    subtitle: readString(j['subtitle']) ?? '',
    airDateUtc: readInstant(j['airDateUtc']),
    seriesId: readInt(j['seriesId']),
    episodeId: readInt(j['episodeId']),
    movieId: readInt(j['movieId']),
    seasonNumber: readInt(j['seasonNumber']),
    episodeNumber: readInt(j['episodeNumber']),
    absoluteEpisodeNumber: readInt(j['absoluteEpisodeNumber']),
    finaleType: readString(j['finaleType']),
    network: readString(j['network']),
    releaseType: CalendarReleaseType.fromJsonOrNull(j['releaseType']),
    hasFile: readBool(j['hasFile']) ?? false,
    monitored: readBool(j['monitored']) ?? true,
    downloading: readBool(j['downloading']) ?? false,
    posterPath: readString(j['posterPath']),
  );

  /// `episode:<episodeId>` or `movie:<movieId>:<releaseType>`.
  final String id;
  final CalendarItemKind kind;

  /// The local date (episodes: of [airDateUtc] with the hub's offset;
  /// movies: the release date). A UTC midnight value; only year, month and
  /// day are meaningful.
  final DateTime date;

  /// Series or movie title.
  final String title;

  /// `S02E17 · Title` (episodes) or `Digital release` (movies).
  final String subtitle;

  /// Episodes only.
  final DateTime? airDateUtc;
  final int? seriesId;
  final int? episodeId;
  final int? movieId;
  final int? seasonNumber;
  final int? episodeNumber;
  final int? absoluteEpisodeNumber;

  /// Sonarr `finaleType` (`series`, `season`, `midseason`).
  final String? finaleType;
  final String? network;

  /// Movies only.
  final CalendarReleaseType? releaseType;
  final bool hasFile;
  final bool monitored;

  /// Tracked in the Sonarr/Radarr download queue right now.
  final bool downloading;
  final String? posterPath;

  bool get isEpisode => kind == CalendarItemKind.episode;
  bool get isMovie => kind == CalendarItemKind.movie;

  /// A copy with [downloading] replaced (the gateway re-applies the queue
  /// flags on every request).
  CalendarItem withDownloading(bool downloading) => CalendarItem(
    id: id,
    kind: kind,
    date: date,
    title: title,
    subtitle: subtitle,
    airDateUtc: airDateUtc,
    seriesId: seriesId,
    episodeId: episodeId,
    movieId: movieId,
    seasonNumber: seasonNumber,
    episodeNumber: episodeNumber,
    absoluteEpisodeNumber: absoluteEpisodeNumber,
    finaleType: finaleType,
    network: network,
    releaseType: releaseType,
    hasFile: hasFile,
    monitored: monitored,
    downloading: downloading,
    posterPath: posterPath,
  );

  /// The agenda order (API.md §9.1): by [date], then [airDateUtc] (items
  /// without a time, i.e. movie releases, first), then [title], then [id].
  static int compare(CalendarItem a, CalendarItem b) {
    final byDate = a.date.compareTo(b.date);
    if (byDate != 0) return byDate;
    final at = a.airDateUtc;
    final bt = b.airDateUtc;
    if (at != null || bt != null) {
      if (at == null) return -1;
      if (bt == null) return 1;
      final byTime = at.compareTo(bt);
      if (byTime != 0) return byTime;
    }
    final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
    if (byTitle != 0) return byTitle;
    return a.id.compareTo(b.id);
  }

  JsonMap toJson() => compactJson({
    'id': id,
    'kind': kind.toJson(),
    'airDateUtc': optionalInstantToJson(airDateUtc),
    'date': _dateToJson(date),
    'title': title,
    'subtitle': subtitle,
    'seriesId': seriesId,
    'episodeId': episodeId,
    'movieId': movieId,
    'seasonNumber': seasonNumber,
    'episodeNumber': episodeNumber,
    'absoluteEpisodeNumber': absoluteEpisodeNumber,
    'finaleType': finaleType,
    'network': network,
    'releaseType': releaseType?.toJson(),
    'hasFile': hasFile,
    'monitored': monitored,
    'downloading': downloading,
    'posterPath': posterPath,
  });
}

/// Per-source outcome of a [CalendarResponse]: `{"sonarr": SectionStatus,
/// "radarr": SectionStatus}`. A source that was not queried (`types`
/// excluded it) is omitted.
@immutable
final class CalendarSources {
  const CalendarSources({this.sonarr, this.radarr});

  factory CalendarSources.fromJson(JsonMap j) => CalendarSources(
    sonarr: _status(j['sonarr']),
    radarr: _status(j['radarr']),
  );

  final SectionStatus? sonarr;
  final SectionStatus? radarr;

  /// The statuses that were reported, Sonarr first.
  List<SectionStatus> get all => [?sonarr, ?radarr];

  /// True when a queried source failed (its items are missing).
  bool get anyFailed => all.any((s) => s.status == SectionState.error);

  JsonMap toJson() =>
      compactJson({'sonarr': sonarr?.toJson(), 'radarr': radarr?.toJson()});

  static SectionStatus? _status(Object? v) {
    final m = readMap(v);
    return m == null ? null : SectionStatus.fromJson(m);
  }
}

/// `GET /calendar` (API.md §9.1).
@immutable
final class CalendarResponse {
  const CalendarResponse({
    required this.start,
    required this.end,
    required this.items,
    this.sources = const CalendarSources(),
  });

  factory CalendarResponse.fromJson(JsonMap j) => CalendarResponse(
    start: req(_readDate(j['start']), 'start'),
    end: req(_readDate(j['end']), 'end'),
    items: readList(j['items'], CalendarItem.fromJson),
    sources: CalendarSources.fromJson(readMap(j['sources']) ?? const {}),
  );

  /// First day of the window (inclusive, calendar date).
  final DateTime start;

  /// Last day of the window (inclusive, calendar date).
  final DateTime end;

  /// Sorted with [CalendarItem.compare].
  final List<CalendarItem> items;
  final CalendarSources sources;

  JsonMap toJson() => {
    'start': _dateToJson(start),
    'end': _dateToJson(end),
    'items': [for (final i in items) i.toJson()],
    'sources': sources.toJson(),
  };
}

/// The `calendar` dashboard card (API.md §9.2): the next items of the coming
/// week. The raw key `countNext7Days` is read by the app shell (API.md §4).
@immutable
final class CalendarCard {
  const CalendarCard({required this.items, required this.countNext7Days});

  factory CalendarCard.fromJson(JsonMap j) => CalendarCard(
    items: readList(j['items'], CalendarItem.fromJson),
    countNext7Days: readInt(j['countNext7Days']) ?? 0,
  );

  /// Today .. today+6 (local), at most [maxItems].
  final List<CalendarItem> items;

  /// Every item in the 7-day window (episodes and movie releases).
  final int countNext7Days;

  /// Most items the card carries.
  static const maxItems = 8;

  /// Days covered by the card, today included.
  static const days = 7;

  JsonMap toJson() => {
    'items': [for (final i in items) i.toJson()],
    'countNext7Days': countNext7Days,
  };
}
