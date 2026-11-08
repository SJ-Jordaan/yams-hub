/// Sonarr/Radarr → activity DTO mapping (integrations/arr.md §8, §9, §12).
library;

import 'package:yams_hub_gateway/src/core/images/image_urls.dart';
import 'package:yams_hub_gateway/src/core/log/redact.dart';
import 'package:yams_models/yams_models.dart';

/// The upstream quality object `{quality: {name, source, resolution,
/// modifier}, revision: {version, real, isRepack}}` → [QualityInfo].
QualityInfo arrQualityOf(Object? v) {
  final q = readMap(v);
  final inner = readMap(q?['quality']) ?? q ?? const {};
  final revision = readMap(q?['revision']);
  final version = readInt(revision?['version']);
  final resolution = readInt(inner['resolution']);
  final modifier = readString(inner['modifier']);
  return QualityInfo(
    name: readString(inner['name']) ?? 'Unknown',
    source: readString(inner['source']),
    resolution: resolution == null || resolution <= 0 ? null : resolution,
    modifier: modifier == null || modifier == 'none' ? null : modifier,
    revision: version != null && version > 1 ? version : null,
    isRepack: readBool(revision?['isRepack']) ?? false,
  );
}

/// Language objects `[{id, name}]` → names.
List<String> arrLanguagesOf(Object? v) => [
  for (final l in v is List ? v : const <Object?>[])
    if (readString(readMap(l)?['name']) case final n? when n.isNotEmpty) n,
];

final _versionParam = RegExp(r'[?&](?:lastWrite|h)=([A-Za-z0-9._:-]+)');

/// The poster of an embedded series/movie (`images[]`), through the
/// gateway's image proxy.
String? arrPosterOf(
  ImageUrls images,
  ArrService service,
  int? id,
  JsonMap? media,
) {
  if (id == null || media == null) return null;
  for (final i
      in media['images'] is List
          ? media['images'] as List
          : const <Object?>[]) {
    final m = readMap(i);
    if (m == null || m['coverType'] != 'poster') continue;
    final url = readString(m['url']);
    return images.arr(
      service,
      id,
      'poster',
      size: 250,
      version: url == null ? null : _versionParam.firstMatch(url)?[1],
      fallbackUrl: readString(m['remoteUrl']),
    );
  }
  return images.arr(service, id, 'poster', size: 250);
}

/// A Sonarr/Radarr command resource → [CommandRef].
CommandRef commandRefOf(ArrService service, JsonMap c) => CommandRef(
  service: service.serviceId,
  id: readInt(c['id']) ?? 0,
  name: readString(c['name']) ?? '',
  status: CommandStatus.fromJson(c['status']),
  result: CommandResult.fromJson(c['result']),
  message: switch (readString(c['message'])) {
    final m? when m.isNotEmpty => redactSecrets(m),
    _ => null,
  },
  queuedAt: readInstant(c['queued']),
  startedAt: readInstant(c['started']),
  endedAt: readInstant(c['ended']),
);

/// `S04E01`, `S04E01–E24` or `S01E01–S02E03` for a set of episodes.
String? episodesLabelOf(List<(int, int)> episodes) {
  if (episodes.isEmpty) return null;
  final sorted = episodes.toSet().toList()
    ..sort((a, b) {
      final s = a.$1.compareTo(b.$1);
      return s != 0 ? s : a.$2.compareTo(b.$2);
    });
  final first = sorted.first;
  final last = sorted.last;
  final start = ArrEpisodeLabel.format(first.$1, first.$2);
  if (sorted.length == 1) return start;
  if (first.$1 == last.$1) {
    return '$start–E${last.$2.toString().padLeft(2, '0')}';
  }
  return '$start–${ArrEpisodeLabel.format(last.$1, last.$2)}';
}

/// .NET TimeSpan `[d.]hh:mm:ss[.fffffff]` → seconds.
int? timeSpanSeconds(Object? v) {
  final s = readString(v);
  if (s == null) return null;
  final m = RegExp(r'^(?:(\d+)\.)?(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?$')
      .firstMatch(s.trim());
  if (m == null) return null;
  final days = int.parse(m[1] ?? '0');
  return days * 86400 +
      int.parse(m[2]!) * 3600 +
      int.parse(m[3]!) * 60 +
      int.parse(m[4]!);
}

/// A Sonarr/Radarr history record → [ArrHistoryItem]; null when it has no
/// usable date. `downloadUrl`, `guid`, `nzbInfoUrl` and paths are dropped.
ArrHistoryItem? historyItemOf(ArrService service, JsonMap r, ImageUrls images) {
  final id = readInt(r['id']);
  final date = readInstant(r['date']);
  if (id == null || date == null) return null;
  final data = readMap(r['data']) ?? const {};
  final rawType = r['eventType'];
  final type = rawType is int
      ? ArrHistoryType.fromEventType(service, rawType)
      : ArrHistoryType.fromUpstreamName(rawType);
  final series = readMap(r['series']);
  final movie = readMap(r['movie']);
  final seriesId = readInt(r['seriesId']) ?? readInt(series?['id']);
  final movieId = readInt(r['movieId']) ?? readInt(movie?['id']);
  ArrHistoryEpisode? episode;
  final e = readMap(r['episode']);
  if (service == ArrService.sonarr && e != null) {
    final season = readInt(e['seasonNumber']);
    final number = readInt(e['episodeNumber']);
    final episodeId = readInt(e['id']) ?? readInt(r['episodeId']);
    if (season != null && number != null && episodeId != null) {
      final absolute = readInt(e['absoluteEpisodeNumber']);
      episode = ArrHistoryEpisode(
        id: episodeId,
        seasonNumber: season,
        episodeNumber: number,
        absoluteEpisodeNumber: absolute,
        title: readString(e['title']),
        label: ArrEpisodeLabel.format(
          season,
          number,
          absoluteEpisodeNumber: absolute,
          anime: series?['seriesType'] == 'anime',
        ),
      );
    }
  }
  final source = readString(data['releaseSource']);
  final reason = readString(data['reason']);
  return ArrHistoryItem(
    id: '${service.name}:$id',
    service: service,
    type: type,
    date: date,
    sourceTitle: readString(r['sourceTitle']) ?? '',
    mediaTitle: readString(series?['title']) ?? readString(movie?['title']),
    seriesId: service == ArrService.sonarr ? seriesId : null,
    movieId: service == ArrService.radarr ? movieId : null,
    episode: episode,
    quality: arrQualityOf(r['quality']),
    customFormatScore:
        readInt(r['customFormatScore']) ??
        readInt(data['customFormatScore']) ??
        0,
    indexer: readString(data['indexer']),
    releaseGroup: readString(data['releaseGroup']),
    sizeBytes: readInt(data['size']),
    downloadClient:
        readString(data['downloadClientName']) ??
        readString(data['downloadClient']),
    releaseSource: type == ArrHistoryType.grabbed && source != null
        ? ArrReleaseSource.fromUpstream(source)
        : null,
    reason: type == ArrHistoryType.deleted ? reason : null,
    downloadId: readString(r['downloadId'])?.toLowerCase(),
    posterPath: service == ArrService.sonarr
        ? arrPosterOf(images, service, seriesId, series)
        : arrPosterOf(images, service, movieId, movie),
  );
}
