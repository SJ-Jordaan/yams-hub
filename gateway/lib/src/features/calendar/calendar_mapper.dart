/// Maps Sonarr/Radarr calendar resources to [CalendarItem]s (API.md §9.1,
/// integrations/arr.md §10).
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

/// A calendar window in local calendar dates (both days inclusive).
typedef CalendarWindow = ({DateTime start, DateTime end, bool unmonitored});

/// Builds calendar items from upstream JSON.
final class CalendarMapper {
  CalendarMapper({required this.images, required this.tzOffset});

  final ImageUrls images;

  /// `YAMS_HUB_TZ_OFFSET`: the hub's fixed local-time offset.
  final Duration tzOffset;

  /// The local calendar date of [instant].
  DateTime localDateOf(DateTime instant) =>
      CalendarDates.of(instant.toUtc().add(tzOffset));

  /// The UTC instant of `00:00:00` local on [date].
  DateTime localStartUtc(DateTime date) =>
      CalendarDates.of(date).subtract(tzOffset);

  /// The UTC instant of `23:59:59` local on [date].
  DateTime localEndUtc(DateTime date) =>
      CalendarDates.of(date)
          .add(const Duration(hours: 23, minutes: 59, seconds: 59))
          .subtract(tzOffset);

  /// Sonarr `EpisodeResource`s (with `includeSeries=true`) → items whose local
  /// date lies in [start]..[end]. Records without an id, a series id or any
  /// date are skipped.
  List<CalendarItem> episodes(
    Object? json, {
    required DateTime start,
    required DateTime end,
  }) {
    final out = <CalendarItem>[];
    for (final e in readList(json, (m) => m)) {
      final item = _episode(e);
      if (item != null && _inWindow(item.date, start, end)) out.add(item);
    }
    return out;
  }

  CalendarItem? _episode(JsonMap e) {
    final id = readInt(e['id']);
    final seriesId = readInt(e['seriesId']);
    if (id == null || seriesId == null) return null;
    final airDateUtc = readInstant(e['airDateUtc']);
    final date = airDateUtc != null
        ? localDateOf(airDateUtc)
        : CalendarDates.parse(e['airDate']);
    if (date == null) return null;

    final series = readMap(e['series']);
    final seasonNumber = readInt(e['seasonNumber']) ?? 0;
    final episodeNumber = readInt(e['episodeNumber']) ?? 0;
    final absolute = readInt(e['absoluteEpisodeNumber']);
    final label = ArrEpisodeLabel.format(
      seasonNumber,
      episodeNumber,
      absoluteEpisodeNumber: absolute,
      anime: readString(series?['seriesType']) == 'anime',
    );
    final episodeTitle = readString(e['title'])?.trim();
    final episodeMonitored = readBool(e['monitored']) ?? true;
    final seriesMonitored = readBool(series?['monitored']) ?? true;
    final network = readString(series?['network'])?.trim();

    return CalendarItem(
      id: 'episode:$id',
      kind: CalendarItemKind.episode,
      airDateUtc: airDateUtc,
      date: date,
      title: _nonEmpty(readString(series?['title'])) ?? 'Unknown series',
      subtitle: episodeTitle == null || episodeTitle.isEmpty
          ? label
          : '$label · $episodeTitle',
      seriesId: seriesId,
      episodeId: id,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      absoluteEpisodeNumber: absolute,
      finaleType: _nonEmpty(readString(e['finaleType'])),
      network: _nonEmpty(network),
      hasFile: readBool(e['hasFile']) ?? false,
      // An episode of an unmonitored series is not searched for either.
      monitored: episodeMonitored && seriesMonitored,
      posterPath: _poster(ArrService.sonarr, seriesId, series?['images']),
    );
  }

  /// Radarr `MovieResource`s → one item per release date (`inCinemas`,
  /// `digitalRelease`, `physicalRelease`) inside [start]..[end]. Radarr
  /// release instants are midnight UTC values that mean a date: they are cut
  /// to their date part without time-zone conversion.
  List<CalendarItem> movies(
    Object? json, {
    required DateTime start,
    required DateTime end,
  }) {
    final out = <CalendarItem>[];
    for (final m in readList(json, (m) => m)) {
      final id = readInt(m['id']);
      if (id == null) continue;
      final title = _nonEmpty(readString(m['title'])) ?? 'Unknown movie';
      final hasFile =
          readBool(m['hasFile']) ?? ((readInt(m['movieFileId']) ?? 0) > 0);
      final monitored = readBool(m['monitored']) ?? true;
      final poster = _poster(ArrService.radarr, id, m['images']);
      for (final (type, key) in const [
        (CalendarReleaseType.cinema, 'inCinemas'),
        (CalendarReleaseType.digital, 'digitalRelease'),
        (CalendarReleaseType.physical, 'physicalRelease'),
      ]) {
        final date = CalendarDates.parse(m[key]);
        if (date == null || date.year <= 1 || !_inWindow(date, start, end)) {
          continue;
        }
        out.add(
          CalendarItem(
            id: 'movie:$id:${type.name}',
            kind: CalendarItemKind.movie,
            date: date,
            title: title,
            subtitle: type.subtitle,
            movieId: id,
            releaseType: type,
            hasFile: hasFile,
            monitored: monitored,
            posterPath: poster,
          ),
        );
      }
    }
    return out;
  }

  /// Ids in a Sonarr/Radarr queue page: `episodeId` (Sonarr; season packs
  /// have one record per episode) or `movieId` (Radarr).
  static Set<int> queueIds(Object? json, String field) => {
    for (final r in readList(readMap(json)?['records'], (m) => m))
      ?readInt(r[field]),
  };

  /// The gateway path of the poster in [covers] (`[{coverType, url?,
  /// remoteUrl?}]`). The version is the `lastWrite` (Sonarr) / `h` (Radarr)
  /// value of `url`; `remoteUrl` is the fallback for covers not downloaded
  /// yet. Null when the item has no poster at all.
  String? _poster(ArrService svc, int id, Object? covers) {
    for (final img in readList(covers, (m) => m)) {
      if (readString(img['coverType']) != 'poster') continue;
      final url = readString(img['url']);
      final query = url == null ? null : Uri.tryParse(url)?.queryParameters;
      return images.arr(
        svc,
        id,
        'poster',
        size: 250,
        version: query?['lastWrite'] ?? query?['h'],
        fallbackUrl: readString(img['remoteUrl']),
      );
    }
    return null;
  }

  static bool _inWindow(DateTime date, DateTime start, DateTime end) =>
      !date.isBefore(start) && !date.isAfter(end);

  static String? _nonEmpty(String? s) {
    final t = s?.trim();
    return t == null || t.isEmpty ? null : t;
  }
}
