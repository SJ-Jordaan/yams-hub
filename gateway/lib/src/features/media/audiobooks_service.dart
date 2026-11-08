/// Audiobookshelf overview (API.md §14.5; integrations/system.md §6).
///
/// The ABS key belongs to one ABS user (root), so progress and listening
/// stats are that user's. `/api/me` carries the user's `token` and `email`:
/// only `mediaProgress` is read from it. Times are epoch ms, durations
/// seconds.
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

/// Reads Audiobookshelf.
final class AudiobooksService {
  AudiobooksService(this._ctx)
    : _overview = _ctx.caches.ttl<int, AudiobooksOverview>(
        'media.audiobooks.overview',
        const Duration(seconds: 60),
      );

  final FeatureContext _ctx;
  final TtlCache<int, AudiobooksOverview> _overview;

  UpstreamClient get _abs => _ctx.upstreams.audiobookshelf;

  /// `GET /media/audiobooks` (cache 60 s).
  Future<AudiobooksOverview> overview() => _overview.value(0, _load);

  Future<AudiobooksOverview> _load() async {
    final librariesBody = readMap(await _abs.getJson('/api/libraries'));
    final libs = readList(librariesBody?['libraries'], (m) => m);
    final ids = [for (final l in libs) ?readString(l['id'])]
        .where(_absId.hasMatch)
        .toList();

    // One Future.wait: every call is listened to, the first failure wins.
    final results = await Future.wait<Object?>([
      _serverVersion(),
      _abs.getJson('/api/me/items-in-progress', query: {'limit': 10}),
      _abs.getJson('/api/me'),
      _abs.getJson('/api/me/listening-stats'),
      for (final id in ids) _abs.getJson('/api/libraries/$id/stats'),
      for (final id in ids)
        _abs.getJson(
          '/api/libraries/$id/items',
          query: {
            'sort': 'addedAt',
            'desc': 1,
            'limit': 12,
            'page': 0,
            'minified': 1,
          },
        ),
    ], eagerError: true);
    const fixed = 4;
    return mapAudiobooksOverview(
      version: results[0] as String?,
      libraries: libs,
      stats: {
        for (final (i, id) in ids.indexed) id: readMap(results[fixed + i]),
      },
      recentPages: [
        for (var i = 0; i < ids.length; i++)
          readMap(results[fixed + ids.length + i]),
      ],
      inProgress: readMap(results[1]),
      me: readMap(results[2]),
      listening: readMap(results[3]),
      images: _ctx.images,
      today: _localToday(),
    );
  }

  /// `GET /status` `serverVersion` (no auth); null on failure.
  Future<String?> _serverVersion() async {
    try {
      return readString(
        readMap(await _abs.getJson('/status'))?['serverVersion'],
      );
    } on UpstreamException catch (e) {
      if (e is UpstreamNotConfigured) rethrow;
      return null;
    }
  }

  /// Today in the server's time zone (ABS `days` keys are server-local).
  DateTime _localToday() {
    final local = _ctx.clock.now().add(_ctx.config.tzOffset);
    return DateTime.utc(local.year, local.month, local.day);
  }
}

final _absId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

DateTime? _epochMs(Object? v) {
  final ms = readInt(v) ?? readDouble(v)?.round();
  if (ms == null || ms <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

/// The cover version: the item's `updatedAt`.
String? _version(JsonMap item) => readInt(item['updatedAt'])?.toString();

int _secs(Object? v) => (readDouble(v) ?? 0).round();

String? _nonEmpty(Object? v) {
  final s = readString(v)?.trim();
  return (s == null || s.isEmpty) ? null : s;
}

String _date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Assembles [AudiobooksOverview] from the raw ABS answers.
///
/// `items-in-progress` has no progress number (and may list an item twice):
/// it is de-duplicated and joined with `/api/me` `mediaProgress` on
/// `libraryItemId` (newest `lastUpdate` wins).
AudiobooksOverview mapAudiobooksOverview({
  required List<JsonMap> libraries,
  required Map<String, JsonMap?> stats,
  required List<JsonMap?> recentPages,
  required JsonMap? inProgress,
  required JsonMap? me,
  required JsonMap? listening,
  required ImageUrls images,
  required DateTime today,
  String? version,
}) {
  final libs = <AudiobookLibrary>[];
  for (final l in libraries) {
    final id = readString(l['id']);
    if (id == null || !_absId.hasMatch(id)) continue;
    final s = stats[id] ?? const {};
    libs.add(
      AudiobookLibrary(
        id: id,
        name: readString(l['name']) ?? '',
        mediaType: AudiobookMediaType.fromJson(l['mediaType']),
        items: readInt(s['totalItems']) ?? 0,
        authors: readInt(s['totalAuthors']) ?? 0,
        durationSeconds: _secs(s['totalDuration']),
        sizeBytes: readInt(s['totalSize']) ?? 0,
      ),
    );
  }

  ExternalLink itemLink(String id) =>
      ExternalLink(ExternalApp.audiobookshelf, '/item/$id');

  final progressById = <String, JsonMap>{};
  for (final p in readList(me?['mediaProgress'], (m) => m)) {
    final id = readString(p['libraryItemId']);
    if (id == null || readString(p['episodeId']) != null) continue;
    final old = progressById[id];
    if (old == null ||
        (readInt(p['lastUpdate']) ?? 0) > (readInt(old['lastUpdate']) ?? 0)) {
      progressById[id] = p;
    }
  }

  final seen = <String>{};
  final continueListening = <AudiobookProgressItem>[];
  for (final item in readList(inProgress?['libraryItems'], (m) => m)) {
    final id = readString(item['id']);
    if (id == null || !_absId.hasMatch(id) || !seen.add(id)) continue;
    final media = readMap(item['media']) ?? const {};
    final meta = readMap(media['metadata']) ?? const {};
    final p = progressById[id] ?? const {};
    final duration = _secs(p['duration'] ?? media['duration']);
    continueListening.add(
      AudiobookProgressItem(
        id: id,
        title: readString(meta['title']) ?? '',
        author: _nonEmpty(meta['authorName']),
        narrator: _nonEmpty(meta['narratorName']),
        coverPath: images.abs(id, width: 500, version: _version(item)) ?? '',
        progress: (readDouble(p['progress']) ?? 0).clamp(0, 1).toDouble(),
        currentTimeSeconds: _secs(p['currentTime']),
        durationSeconds: duration,
        lastUpdateAt: _epochMs(p['lastUpdate'] ?? item['progressLastUpdate']),
        link: itemLink(id),
      ),
    );
  }

  final recent = <AudiobookRecentItem>[];
  final recentSeen = <String>{};
  for (final page in recentPages) {
    for (final item in readList(page?['results'], (m) => m)) {
      final id = readString(item['id']);
      final addedAt = _epochMs(item['addedAt']);
      if (id == null || addedAt == null || !_absId.hasMatch(id)) continue;
      if (!recentSeen.add(id)) continue;
      final media = readMap(item['media']) ?? const {};
      final meta = readMap(media['metadata']) ?? const {};
      final duration = readDouble(media['duration']);
      recent.add(
        AudiobookRecentItem(
          id: id,
          title: readString(meta['title']) ?? '',
          author: _nonEmpty(meta['authorName']),
          coverPath: images.abs(id, width: 500, version: _version(item)) ?? '',
          addedAt: addedAt,
          durationSeconds: duration?.round(),
          link: itemLink(id),
        ),
      );
    }
  }
  recent.sort((a, b) => b.addedAt.compareTo(a.addedAt));

  final daysMap = readMap(listening?['days']) ?? const {};
  final last7 = [
    for (var i = 6; i >= 0; i--)
      () {
        final date = _date(today.subtract(Duration(days: i)));
        return AudiobookListeningDay(date: date, seconds: _secs(daysMap[date]));
      }(),
  ];

  return AudiobooksOverview(
    version: version,
    libraries: libs,
    continueListening: continueListening,
    recentlyAdded: recent.take(12).toList(),
    listening: AudiobookListening(
      todaySeconds: _secs(listening?['today']),
      totalSeconds: _secs(listening?['totalTime']),
      last7Days: last7,
    ),
    library: ExternalLink(
      ExternalApp.audiobookshelf,
      libs.isEmpty ? '/' : '/library/${libs.first.id}',
    ),
  );
}
