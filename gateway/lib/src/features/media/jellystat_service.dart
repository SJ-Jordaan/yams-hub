/// Jellystat watch statistics (API.md §14.4; integrations/seerr.md §3).
///
/// Only the read-only `/stats/*` routes listed in the integration spec are
/// called. `/api/keys`, `/api/getconfig`, `/sync/*`, `/backup/*` and
/// `/api/stopTask` are never called.
library;

import 'dart:convert';

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'jellyfin_service.dart' show mapPlayMethod;

/// Reads Jellystat for the stats screens.
final class JellystatService {
  JellystatService(this._ctx)
    : _stats = _ctx.caches.ttl<int, WatchStats>(
        'media.jellystat.stats',
        const Duration(minutes: 5),
        maxEntries: 8,
      ),
      _users = _ctx.caches.ttl<int, List<WatchUser>>(
        'media.jellystat.users',
        const Duration(minutes: 5),
      ),
      _history = _ctx.caches.ttl<String, PagedList<PlaybackRecord>>(
        'media.jellystat.history',
        const Duration(seconds: 30),
        maxEntries: 100,
      );

  final FeatureContext _ctx;
  final TtlCache<int, WatchStats> _stats;
  final TtlCache<int, List<WatchUser>> _users;
  final TtlCache<String, PagedList<PlaybackRecord>> _history;

  UpstreamClient get _js => _ctx.upstreams.jellystat;

  /// `GET /media/stats?days=` (cache 5 min). Every Jellystat query runs in
  /// parallel; a failing one leaves its part empty and sets `partial`. When
  /// all of them fail, the first error is thrown.
  Future<WatchStats> stats(int days) => _stats.value(days, () async {
    Future<Object?> get(String path) =>
        _js.getJson(path, query: {'days': days});
    Future<Object?> post(
      String path, [
      Map<String, Object?> extra = const {},
    ]) => _js.sendJson('POST', path, body: {'days': days, ...extra});

    final parts = await Future.wait([
      _attempt(() => get('/stats/getViewsOverTime')),
      _attempt(() => get('/stats/getViewsByDays')),
      _attempt(() => get('/stats/getViewsByHour')),
      _attempt(() => post('/stats/getPlaybackMethodStats')),
      _attempt(() => post('/stats/getMostViewedByType', {'type': 'Movie'})),
      _attempt(() => post('/stats/getMostViewedByType', {'type': 'Series'})),
      _attempt(() => post('/stats/getMostPopularByType', {'type': 'Series'})),
      _attempt(() => post('/stats/getMostActiveUsers')),
      _attempt(() => post('/stats/getMostUsedClient')),
      _attempt(() => post('/stats/getMostViewedLibraries')),
    ]);
    final failures = [
      for (final p in parts)
        if (p.error != null) p.error!,
    ];
    if (failures.length == parts.length) throw failures.first;
    return mapWatchStats(
      days: days,
      images: _ctx.images,
      viewsOverTime: parts[0].value,
      byDays: parts[1].value,
      byHour: parts[2].value,
      playMethods: parts[3].value,
      topMovies: parts[4].value,
      topSeries: parts[5].value,
      popularSeries: parts[6].value,
      topUsers: parts[7].value,
      topClients: parts[8].value,
      topLibraries: parts[9].value,
      partial: failures.isNotEmpty,
    );
  });

  Future<({Object? value, Object? error})> _attempt(
    Future<Object?> Function() call,
  ) async {
    try {
      return (value: await call(), error: null);
    } on UpstreamException catch (e) {
      if (e is UpstreamNotConfigured) rethrow;
      _ctx.log.fine('Jellystat query failed: $e');
      return (value: null, error: e);
    }
  }

  /// `GET /stats/getAllUserActivity` (cache 5 min), most plays first.
  Future<List<WatchUser>> users() => _users.value(0, () async {
    final body = await _js.getJson('/stats/getAllUserActivity');
    final now = _ctx.clock.now();
    final users = [
      if (body is List)
        for (final e in body)
          if (readMap(e) case final m?) ?mapWatchUser(m, now, _ctx.images),
    ];
    users.sort((a, b) {
      final byPlays = b.totalPlays.compareTo(a.totalPlays);
      return byPlays != 0
          ? byPlays
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return users;
  });

  /// `GET /stats/getPlaybackActivity`, newest first, optionally only
  /// [userId]'s plays (cache 30 s).
  Future<PagedList<PlaybackRecord>> history({
    required int page,
    required int pageSize,
    String? userId,
  }) => _history.value('${userId ?? '*'}|$page|$pageSize', () async {
    final body = readMap(
      await _js.getJson(
        '/stats/getPlaybackActivity',
        query: {
          'size': pageSize,
          'page': page,
          'sort': 'ActivityDateInserted',
          'desc': true,
          if (userId != null)
            'filters': jsonEncode([
              {'field': 'UserId', 'value': userId},
            ]),
        },
      ),
    );
    final records = [
      for (final r in readList(body?['results'], (m) => m))
        ?mapPlaybackRecord(r, _ctx.images),
    ];
    final pages = readInt(body?['pages']) ?? 0;
    final total = page < pages
        ? pages * pageSize
        : page == pages
        ? (pages - 1) * pageSize + records.length
        : pages * pageSize;
    return PagedList.of(
      items: records,
      page: page,
      pageSize: pageSize,
      total: total < records.length ? records.length : total,
    );
  });
}

// ---------------------------------------------------------------------------
// Mapping (pure)
// ---------------------------------------------------------------------------

const _months = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// Jellystat's `"Nov 01, 2026"` → `"2026-11-01"`; ISO dates pass through;
/// null when unparsable.
String? parseJellystatDate(Object? key) {
  final s = readString(key)?.trim();
  if (s == null) return null;
  final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(s);
  if (iso != null) return '${iso[1]}-${iso[2]}-${iso[3]}';
  final m = RegExp(r'^([A-Za-z]{3})[A-Za-z]*\.? (\d{1,2}),? (\d{4})$')
      .firstMatch(s);
  if (m == null) return null;
  final month = _months[m[1]!.toLowerCase()];
  if (month == null) return null;
  return '${m[3]}-${month.toString().padLeft(2, '0')}-'
      '${m[2]!.padLeft(2, '0')}';
}

/// A Postgres interval object (`{"minutes":5,"seconds":12,
/// "milliseconds":719.1}`, keys only when non-zero) → [Duration].
Duration? parsePgInterval(Object? v) {
  final m = readMap(v);
  if (m == null) return null;
  double n(String k) => readDouble(m[k]) ?? 0;
  final ms =
      n('milliseconds') +
      n('seconds') * 1e3 +
      n('minutes') * 6e4 +
      n('hours') * 3.6e6 +
      n('days') * 8.64e7 +
      n('months') * 30 * 8.64e7 +
      n('years') * 365 * 8.64e7;
  return Duration(milliseconds: ms.round());
}

/// `{libraries, stats: [{Key, "<LibraryName>": {count, duration}}]}` rows:
/// the per-library cells of one row, keyed by library id.
Map<String, ({int count, int minutes})> _cells(
  JsonMap row,
  Map<String, String> idByName,
) {
  final out = <String, ({int count, int minutes})>{};
  for (final e in row.entries) {
    if (e.key == 'Key') continue;
    final cell = readMap(e.value);
    if (cell == null) continue;
    final id = idByName[e.key] ?? e.key;
    out[id] = (
      count: readInt(cell['count']) ?? 0,
      minutes: readInt(cell['duration']) ?? 0,
    );
  }
  return out;
}

List<WatchLibrary> _libraries(JsonMap? body) => [
  for (final l in readList(body?['libraries'], (m) => m))
    if (readString(l['Id']) case final id?)
      WatchLibrary(id: id, name: readString(l['Name']) ?? id),
];

List<JsonMap> _rows(Object? v) => readList(v, (m) => m);

/// Assembles [WatchStats] from the raw Jellystat answers (null = failed).
///
/// The views endpoints report `duration` in **minutes** (a 1559 s play is
/// `26`), converted to seconds here; every other Jellystat duration is
/// seconds.
WatchStats mapWatchStats({
  required int days,
  required ImageUrls images,
  Object? viewsOverTime,
  Object? byDays,
  Object? byHour,
  Object? playMethods,
  Object? topMovies,
  Object? topSeries,
  Object? popularSeries,
  Object? topUsers,
  Object? topClients,
  Object? topLibraries,
  bool partial = false,
}) {
  final vot = readMap(viewsOverTime);
  final days7 = readMap(byDays);
  final hours = readMap(byHour);
  var libraries = _libraries(vot);
  if (libraries.isEmpty) libraries = _libraries(days7);
  if (libraries.isEmpty) libraries = _libraries(hours);
  final idByName = {for (final l in libraries) l.name: l.id};

  var totalPlays = 0;
  var totalSeconds = 0;
  final points = <WatchViewsPoint>[];
  for (final row in _rows(vot?['stats'])) {
    final date = parseJellystatDate(row['Key']);
    if (date == null) continue;
    final cells = _cells(row, idByName);
    final plays = {for (final e in cells.entries) e.key: e.value.count};
    final secs = {for (final e in cells.entries) e.key: e.value.minutes * 60};
    totalPlays += plays.values.fold(0, (a, b) => a + b);
    totalSeconds += secs.values.fold(0, (a, b) => a + b);
    points.add(
      WatchViewsPoint(date: date, plays: plays, durationSeconds: secs),
    );
  }
  points.sort((a, b) => a.date.compareTo(b.date));

  List<WatchDayPlays> weekdays = const [];
  if (days7 != null) {
    final byDay = <WatchWeekday, int>{};
    for (final row in _rows(days7['stats'])) {
      final day = WatchWeekday.fromJson(readString(row['Key'])?.toLowerCase());
      if (day == WatchWeekday.unknown) continue;
      byDay[day] =
          (byDay[day] ?? 0) +
          _cells(row, idByName).values.fold(0, (a, c) => a + c.count);
    }
    weekdays = [
      for (final d in WatchWeekday.values)
        if (d != WatchWeekday.unknown)
          WatchDayPlays(day: d, plays: byDay[d] ?? 0),
    ];
  }

  List<WatchHourPlays> hourly = const [];
  if (hours != null) {
    final byH = <int, int>{};
    for (final row in _rows(hours['stats'])) {
      final h = readInt(row['Key']);
      if (h == null || h < 0 || h > 23) continue;
      byH[h] =
          (byH[h] ?? 0) +
          _cells(row, idByName).values.fold(0, (a, c) => a + c.count);
    }
    hourly = [
      for (var h = 0; h < 24; h++) WatchHourPlays(hour: h, plays: byH[h] ?? 0),
    ];
  }

  String? poster(String? id) => images.jellyfin(id, 'Primary', fillHeight: 342);

  List<WatchTopItem> top(Object? v) => [
    for (final r in _rows(v))
      if (normaliseJellyfinId(readString(r['Id'])) case final id?)
        WatchTopItem(
          id: id,
          name: readString(r['Name']) ?? '',
          plays: readInt(r['Plays']) ?? 0,
          durationSeconds: readInt(r['total_playback_duration']) ?? 0,
          imagePath: poster(id),
        ),
  ];

  final libs = [
    for (final r in _rows(topLibraries))
      WatchTopLibrary(
        id: readString(r['Id']) ?? '',
        name: readString(r['Name']) ?? '',
        plays: readInt(r['Plays']) ?? 0,
      ),
  ];
  if (vot == null) {
    totalPlays = libs.fold(0, (a, l) => a + l.plays);
  }

  return WatchStats(
    days: days,
    libraries: libraries,
    viewsOverTime: points,
    byWeekday: weekdays,
    byHour: hourly,
    playMethods: [
      for (final r in _rows(playMethods))
        WatchPlayMethodCount(
          method: mapPlayMethod(readString(r['Name'])),
          count: readInt(r['Count']) ?? 0,
        ),
    ],
    topMovies: top(topMovies),
    topSeries: top(topSeries),
    popularSeries: [
      for (final r in _rows(popularSeries))
        if (normaliseJellyfinId(readString(r['Id'])) case final id?)
          WatchPopularItem(
            id: id,
            name: readString(r['Name']) ?? '',
            uniqueViewers: readInt(r['unique_viewers']) ?? 0,
            imagePath: poster(id),
          ),
    ],
    topUsers: [
      for (final r in _rows(topUsers))
        WatchTopUser(
          userId: readString(r['UserId']) ?? '',
          name: readString(r['Name']) ?? '',
          plays: readInt(r['Plays']) ?? 0,
        ),
    ],
    topClients: [
      for (final r in _rows(topClients))
        WatchTopClient(
          client: readString(r['Client']) ?? '',
          plays: readInt(r['Plays']) ?? 0,
        ),
    ],
    topLibraries: libs,
    totals: WatchTotals(plays: totalPlays, durationSeconds: totalSeconds),
    partial: partial,
  );
}

/// A `getAllUserActivity` row → [WatchUser]; `LastSeen` (an interval) is
/// converted to an instant `now − interval`.
WatchUser? mapWatchUser(JsonMap r, DateTime now, ImageUrls images) {
  final id = normaliseJellyfinId(readString(r['UserId']));
  if (id == null) return null;
  final lastSeen = parsePgInterval(r['LastSeen']);
  final tag = readString(r['PrimaryImageTag']);
  return WatchUser(
    userId: id,
    name: readString(r['UserName']) ?? '',
    totalPlays: readInt(r['TotalPlays']) ?? 0,
    totalWatchSeconds: readInt(r['TotalWatchTime']) ?? 0,
    lastSeenAt: lastSeen == null ? null : now.subtract(lastSeen),
    lastWatched: readString(r['LastWatched']),
    lastClient: readString(r['LastClient']),
    avatarPath: tag == null ? null : images.jellyfinUser(id, tag: tag),
  );
}

/// A `jf_playback_activity` row → [PlaybackRecord]. For episodes
/// `NowPlayingItemId` is the series, so the image uses `EpisodeId`.
PlaybackRecord? mapPlaybackRecord(JsonMap r, ImageUrls images) {
  final id = readString(r['Id']);
  final at = readInstant(r['ActivityDateInserted']);
  if (id == null || at == null) return null;
  final imageId =
      normaliseJellyfinId(readString(r['EpisodeId'])) ??
      normaliseJellyfinId(readString(r['NowPlayingItemId']));
  return PlaybackRecord(
    id: id,
    userName: readString(r['UserName']) ?? '',
    title: readString(r['NowPlayingItemName']) ?? '',
    seriesName: readString(r['SeriesName']),
    client: readString(r['Client']) ?? '',
    device: readString(r['DeviceName']) ?? '',
    playMethod: mapPlayMethod(readString(r['PlayMethod'])),
    durationSeconds: readInt(r['PlaybackDuration']) ?? 0,
    at: at,
    imagePath: images.jellyfin(imageId, 'Primary', maxWidth: 342),
  );
}
