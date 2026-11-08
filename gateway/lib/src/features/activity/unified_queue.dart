/// The unified queue: qBittorrent torrents merged with the Sonarr/Radarr
/// queue records of the same download (API.md §8.1, §8.2).
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'arr_mapping.dart';
import 'maindata.dart';
import 'qbit_mapping.dart';

/// The *arr services whose queues are merged.
const queueServices = [ArrService.sonarr, ArrService.radarr];

/// Records read from each *arr queue (`page=1&pageSize=200`).
const queuePageSize = 200;

/// The source status for a failure (`disabled` when not configured).
SectionStatus sectionStatusFor(Object error, String requestId) {
  final api = apiExceptionFor(error);
  final e = api.toApiError(requestId);
  return api.code == ApiErrorCode.serviceNotConfigured
      ? SectionStatus.disabled(e)
      : SectionStatus.failure(e);
}

/// Maps any failure of a multi-source read to an [ApiException] (an
/// upstream 404 here never means the gateway path was not found).
ApiException apiExceptionFor(Object error) => switch (error) {
  ApiException() => error,
  UpstreamException() => error.toApiException(resourceNotFound: false),
  FormatException() || TypeError() => const ApiException(
    502,
    ApiErrorCode.upstreamBadResponse,
    'An upstream response could not be read.',
  ),
  _ => ApiException.internal(),
};

/// The records of one *arr queue, or why they are missing.
final class ArrQueueResult {
  const ArrQueueResult(this.service, this.records, this.error, this.stale);

  final ArrService service;
  final List<JsonMap> records;
  final Object? error;
  final bool stale;

  bool get ok => error == null || stale;
}

/// Sonarr and Radarr `GET /api/v3/queue` (cache 5 s each).
final class ArrQueueSources {
  ArrQueueSources(this._ctx)
    : _cache = _ctx.caches.ttl<ArrService, List<JsonMap>>(
        'activity.queue',
        const Duration(seconds: 5),
        maxStale: const Duration(minutes: 2),
      );

  final FeatureContext _ctx;
  final TtlCache<ArrService, List<JsonMap>> _cache;

  /// The queue of [service] (throws on failure).
  Future<List<JsonMap>> records(ArrService service) async =>
      (await _cache.get(service, () => _load(service))).value;

  Future<List<JsonMap>> _load(ArrService service) async {
    final query = <String, Object?>{
      'page': 1,
      'pageSize': queuePageSize,
      if (service == ArrService.sonarr) ...{
        'includeSeries': true,
        'includeEpisode': true,
      } else
        'includeMovie': true,
    };
    final body = await _ctx.upstreams
        .arr(service)
        .getJson('/api/v3/queue', query: query);
    final records = readMap(body)?['records'];
    if (records is! List) {
      throw UpstreamBadResponse(
        service: service.serviceId,
        method: 'GET',
        path: '/api/v3/queue',
        reason: 'queue has no records',
      );
    }
    return [for (final r in records) ?readMap(r)];
  }

  /// Both queues; a failing source is reported, never thrown.
  Future<List<ArrQueueResult>> loadAll() =>
      Future.wait([for (final s in queueServices) _result(s)]);

  Future<ArrQueueResult> _result(ArrService s) async {
    try {
      final r = await _cache.get(s, () => _load(s));
      return ArrQueueResult(s, r.value, r.error, r.stale);
    } catch (e) {
      return ArrQueueResult(s, const [], e, false);
    }
  }

  /// One record by queue id: the cached queue first, else
  /// `GET /api/v3/queue/{id}`. Null when the record is gone.
  Future<JsonMap?> record(ArrService service, int queueId) async {
    try {
      for (final r in await records(service)) {
        if (readInt(r['id']) == queueId) return r;
      }
    } on UpstreamNotConfigured {
      rethrow;
    } catch (_) {
      // Fall back to the single-record call.
    }
    try {
      return readMap(
        await _ctx.upstreams
            .arr(service)
            .getJson(
              '/api/v3/queue/$queueId',
              timeout: const Duration(seconds: 10),
            ),
      );
    } on UpstreamException catch (e) {
      if (e.isNotFound) return null;
      rethrow;
    }
  }

  void invalidate([ArrService? service]) =>
      service == null ? _cache.clear() : _cache.invalidate(service);
}

/// The records of one download in one *arr.
final class ArrQueueGroup {
  ArrQueueGroup(this.service, this.downloadId);

  final ArrService service;

  /// As the *arr reports it (upper-case hash); null when absent.
  final String? downloadId;
  final records = <JsonMap>[];

  String? get hash => downloadId?.toLowerCase();
}

/// Groups records by `(service, downloadId)` (season packs have one record
/// per episode); records without a download id stay alone.
List<ArrQueueGroup> groupQueueRecords(List<ArrQueueResult> sources) {
  final groups = <String, ArrQueueGroup>{};
  for (final source in sources) {
    for (final r in source.records) {
      final downloadId = readString(r['downloadId']);
      final key = downloadId == null || downloadId.isEmpty
          ? '${source.service.name}:q${readInt(r['id'])}'
          : '${source.service.name}:${downloadId.toLowerCase()}';
      (groups[key] ??= ArrQueueGroup(
        source.service,
        downloadId == null || downloadId.isEmpty ? null : downloadId,
      )).records.add(r);
    }
  }
  return groups.values.toList();
}

const _trackedStatusRank = {
  QueueTrackedStatus.error: 3,
  QueueTrackedStatus.warning: 2,
  QueueTrackedStatus.ok: 1,
};

const _trackedStateRank = {
  QueueTrackedState.importBlocked: 8,
  QueueTrackedState.importPending: 7,
  QueueTrackedState.failedPending: 6,
  QueueTrackedState.failed: 5,
  QueueTrackedState.importing: 4,
  QueueTrackedState.downloading: 3,
  QueueTrackedState.imported: 2,
  QueueTrackedState.ignored: 1,
};

/// One [QueueArrEntry] per group. Links and manual import are for admins.
QueueArrEntry queueArrEntryOf(
  ArrQueueGroup g,
  ImageUrls images, {
  required bool admin,
  String Function(String) redact = redactSecrets,
}) {
  final first = g.records.first;
  final series = readMap(first['series']);
  final movie = readMap(first['movie']);
  final seriesId = readInt(first['seriesId']) ?? readInt(series?['id']);
  final movieId = readInt(first['movieId']) ?? readInt(movie?['id']);
  final episodeIds = <int>{};
  final episodes = <(int, int)>[];
  var status = QueueArrStatus.unknown;
  var trackedStatus = QueueTrackedStatus.unknown;
  var trackedState = QueueTrackedState.unknown;
  final messages = <String>[];
  var upgrade = false;
  for (final r in g.records) {
    final episode = readMap(r['episode']);
    final episodeId = readInt(r['episodeId']) ?? readInt(episode?['id']);
    if (episodeId != null) episodeIds.add(episodeId);
    final season =
        readInt(episode?['seasonNumber']) ?? readInt(r['seasonNumber']);
    final number = readInt(episode?['episodeNumber']);
    if (season != null && number != null) episodes.add((season, number));
    if (status == QueueArrStatus.unknown) {
      status = QueueArrStatus.fromJson(r['status']);
    }
    final ts = QueueTrackedStatus.fromJson(r['trackedDownloadStatus']);
    if ((_trackedStatusRank[ts] ?? 0) >
        (_trackedStatusRank[trackedStatus] ?? 0)) {
      trackedStatus = ts;
    }
    final st = QueueTrackedState.fromJson(r['trackedDownloadState']);
    if ((_trackedStateRank[st] ?? 0) > (_trackedStateRank[trackedState] ?? 0)) {
      trackedState = st;
    }
    for (final sm
        in r['statusMessages'] is List
            ? r['statusMessages'] as List
            : const <Object?>[]) {
      final m = readMap(sm);
      for (final text in readStringList(m?['messages'])) {
        if (text.trim().isNotEmpty) messages.add(redact(text.trim()));
      }
      if (readStringList(m?['messages']).isEmpty) {
        final title = readString(m?['title']);
        if (title != null && title.trim().isNotEmpty) {
          messages.add(redact(title.trim()));
        }
      }
    }
    final err = readString(r['errorMessage']);
    if (err != null && err.trim().isNotEmpty) messages.add(redact(err.trim()));
    if (readBool(r['episodeHasFile']) == true ||
        readBool(readMap(r['movie'])?['hasFile']) == true) {
      upgrade = true;
    }
  }
  final unique = messages.toSet().take(5).toList();
  final app = g.service == ArrService.sonarr
      ? ExternalApp.sonarr
      : ExternalApp.radarr;
  return QueueArrEntry(
    service: g.service,
    queueIds: [for (final r in g.records) ?readInt(r['id'])],
    mediaTitle: readString(series?['title']) ?? readString(movie?['title']),
    seriesId: g.service == ArrService.sonarr ? seriesId : null,
    movieId: g.service == ArrService.radarr ? movieId : null,
    episodeIds: episodeIds.toList()..sort(),
    episodesLabel: g.service == ArrService.sonarr
        ? episodesLabelOf(episodes)
        : null,
    status: status,
    trackedStatus: trackedStatus,
    trackedState: trackedState,
    messages: unique,
    isUpgrade: upgrade,
    posterPath: g.service == ArrService.sonarr
        ? arrPosterOf(images, g.service, seriesId, series)
        : arrPosterOf(images, g.service, movieId, movie),
    downloadId: g.downloadId,
    canManualImport: admin && trackedState.needsImport && g.downloadId != null,
    links: admin ? [ExternalLink(app, '/activity/queue')] : const [],
  );
}

/// A queue item plus what the gateway sorts and filters it by.
final class QueueRow {
  const QueueRow(this.item, {this.addedAt, required this.downloading});

  final QueueItem item;
  final DateTime? addedAt;

  /// Still downloading (sorted by ETA, counted as "downloading").
  final bool downloading;
}

QueueAttention? _attentionOf(TorrentSummary? t, List<QueueArrEntry> arr) {
  bool anyState(Set<QueueTrackedState> s) =>
      arr.any((a) => s.contains(a.trackedState));
  if (anyState({QueueTrackedState.importBlocked})) {
    return QueueAttention.importBlocked;
  }
  if (anyState({QueueTrackedState.importPending})) {
    return QueueAttention.importPending;
  }
  if (anyState({QueueTrackedState.failedPending, QueueTrackedState.failed})) {
    return QueueAttention.failed;
  }
  if (t?.hasTrackerError ?? false) return QueueAttention.trackerError;
  if (t?.state == TorrentState.error ||
      arr.any((a) => a.trackedStatus == QueueTrackedStatus.error)) {
    return QueueAttention.error;
  }
  if (arr.any((a) => a.trackedStatus == QueueTrackedStatus.warning)) {
    return QueueAttention.warning;
  }
  return null;
}

QueueItemState _stateOf(TorrentSummary? t, List<QueueArrEntry> arr) {
  for (final (tracked, state) in const [
    (QueueTrackedState.importBlocked, QueueItemState.importBlocked),
    (QueueTrackedState.importPending, QueueItemState.importPending),
    (QueueTrackedState.failedPending, QueueItemState.failed),
    (QueueTrackedState.failed, QueueItemState.failed),
  ]) {
    if (arr.any((a) => a.trackedState == tracked)) return state;
  }
  if (t != null) return QueueItemState.fromTorrent(t.state);
  if (arr.any((a) => a.trackedState == QueueTrackedState.importing)) {
    return QueueItemState.importing;
  }
  if (arr.any((a) => a.trackedState == QueueTrackedState.imported)) {
    return QueueItemState.completed;
  }
  return switch (arr.firstOrNull?.status) {
    QueueArrStatus.downloading => QueueItemState.downloading,
    QueueArrStatus.queued => QueueItemState.queued,
    QueueArrStatus.paused => QueueItemState.stopped,
    QueueArrStatus.completed => QueueItemState.completed,
    QueueArrStatus.failed => QueueItemState.failed,
    QueueArrStatus.delay => QueueItemState.delayed,
    QueueArrStatus.warning => QueueItemState.downloading,
    _ => QueueItemState.unknown,
  };
}

String _serviceLabel(ArrService s) =>
    s == ArrService.sonarr ? 'Sonarr' : 'Radarr';

/// Merges the torrent snapshot (null when qBittorrent failed) with the
/// *arr queue groups.
List<QueueRow> buildQueueRows({
  required QbitView? qbit,
  required List<ArrQueueGroup> groups,
  required ImageUrls images,
  required bool admin,
  String Function(String) redact = redactSecrets,
}) {
  final torrents = <String, TorrentSummary>{
    for (final t in qbit?.summaries() ?? const <TorrentSummary>[]) t.hash: t,
  };
  final byHash = <String, List<(ArrQueueGroup, QueueArrEntry)>>{};
  final orphans = <(ArrQueueGroup, QueueArrEntry)>[];
  for (final g in groups) {
    final entry = queueArrEntryOf(g, images, admin: admin, redact: redact);
    final hash = g.hash;
    if (hash != null && torrents.containsKey(hash)) {
      (byHash[hash] ??= []).add((g, entry));
    } else {
      orphans.add((g, entry));
    }
  }

  final rows = <QueueRow>[];
  for (final t in torrents.values) {
    final arr = <QueueArrEntry>[
      for (final (_, e)
          in byHash[t.hash] ?? const <(ArrQueueGroup, QueueArrEntry)>[])
        e,
    ];
    rows.add(_row(t.hash, t, arr, const []));
  }
  for (final (g, e) in orphans) {
    final key = g.downloadId == null
        ? '${g.service.name}:q${e.queueIds.firstOrNull ?? 0}'
        : '${g.service.name}:${g.hash}';
    rows.add(_row(key, null, [e], g.records));
  }
  return rows;
}

QueueRow _row(
  String key,
  TorrentSummary? t,
  List<QueueArrEntry> arr,
  List<JsonMap> records,
) {
  final attention = _attentionOf(t, arr);
  final state = _stateOf(t, arr);
  final a = arr.firstOrNull;
  final String title;
  final String? subtitle;
  if (a != null) {
    title =
        a.mediaTitle ??
        t?.name ??
        readString(records.firstOrNull?['title']) ??
        'Unknown';
    final detail =
        a.episodesLabel ??
        (a.episodeIds.length > 1 ? '${a.episodeIds.length} episodes' : null);
    subtitle = detail == null
        ? _serviceLabel(a.service)
        : '${_serviceLabel(a.service)} · $detail';
  } else {
    title = t?.name ?? 'Unknown';
    subtitle = t?.category == null
        ? 'qBittorrent'
        : 'qBittorrent · ${t!.category}';
  }

  int size;
  int left;
  double progress;
  int? eta;
  if (t != null) {
    size = t.sizeBytes;
    left = t.amountLeftBytes;
    progress = t.progress;
    eta = t.etaSeconds;
  } else {
    size = 0;
    left = 0;
    int? maxEta;
    for (final r in records) {
      size += readInt(r['size']) ?? 0;
      left += readInt(r['sizeleft']) ?? 0;
      final s = timeSpanSeconds(r['timeleft']);
      if (s != null && (maxEta == null || s > maxEta)) maxEta = s;
    }
    // Season packs repeat the whole download's size on every record.
    if (records.length > 1 &&
        records.every((r) => r['size'] == records.first['size'])) {
      size = readInt(records.first['size']) ?? 0;
      left = readInt(records.first['sizeleft']) ?? 0;
    }
    progress = size <= 0 ? 0 : (1 - left / size).clamp(0.0, 1.0);
    eta = maxEta;
  }
  final downloading = t != null
      ? t.direction == TorrentDirection.download &&
            t.state != TorrentState.stopped
      : {
          QueueItemState.downloading,
          QueueItemState.queued,
          QueueItemState.delayed,
        }.contains(state);
  return QueueRow(
    QueueItem(
      key: key,
      title: title,
      subtitle: subtitle,
      state: state,
      needsAttention: attention != null,
      attention: attention,
      progress: progress,
      sizeBytes: size,
      sizeLeftBytes: left,
      etaSeconds: eta,
      dlBps: t?.dlBps ?? 0,
      upBps: t?.upBps ?? 0,
      torrent: t,
      arr: arr,
    ),
    addedAt: t?.addedAt ?? readInstant(records.firstOrNull?['added']),
    downloading: downloading,
  );
}

/// `GET /activity/queue?filter=` values.
const queueFilters = ['active', 'all', 'downloading', 'seeding', 'attention'];

/// `GET /activity/queue?sort=` values.
const queueSorts = ['progress', 'eta', 'added', 'name', 'speed'];

bool queueRowMatches(String filter, QueueRow row) {
  final i = row.item;
  final t = i.torrent;
  return switch (filter) {
    'all' => true,
    'downloading' => row.downloading,
    'seeding' => t != null && isSeedingState(t.stateRaw),
    'attention' => i.needsAttention,
    _ =>
      i.arr.isNotEmpty ||
          row.downloading ||
          i.needsAttention ||
          (t != null &&
              const {
                TorrentState.checking,
                TorrentState.metadata,
                TorrentState.error,
                TorrentState.moving,
              }.contains(t.state)) ||
          i.dlBps > 0 ||
          i.upBps > 0,
  };
}

int _byEta(QueueRow a, QueueRow b) => (a.item.etaSeconds ?? qbitEtaInfinity)
    .compareTo(b.item.etaSeconds ?? qbitEtaInfinity);

int _byAddedDesc(QueueRow a, QueueRow b) {
  final x = a.addedAt;
  final y = b.addedAt;
  if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1;
  return y.compareTo(x);
}

/// Default order: attention first, then downloading by ETA, then the rest
/// by added (newest first).
int compareQueueRowsDefault(QueueRow a, QueueRow b) {
  int group(QueueRow r) => r.item.needsAttention ? 0 : (r.downloading ? 1 : 2);
  final g = group(a).compareTo(group(b));
  if (g != 0) return g;
  if (group(a) == 1) {
    final e = _byEta(a, b);
    if (e != 0) return e;
  }
  return _byAddedDesc(a, b);
}

/// Explicit `sort=` orders.
int compareQueueRows(String sort, QueueRow a, QueueRow b) => switch (sort) {
  'progress' => b.item.progress.compareTo(a.item.progress),
  'eta' => _byEta(a, b),
  'added' => _byAddedDesc(a, b),
  'name' => a.item.title.toLowerCase().compareTo(b.item.title.toLowerCase()),
  'speed' => (b.item.dlBps + b.item.upBps).compareTo(
    a.item.dlBps + a.item.upBps,
  ),
  _ => compareQueueRowsDefault(a, b),
};

/// Counters over every row.
QueueSummary queueSummaryOf(List<QueueRow> rows, JsonMap? serverState) =>
    QueueSummary(
      downloading: rows.where((r) => r.downloading).length,
      seeding: rows
          .where(
            (r) =>
                r.item.torrent != null &&
                isSeedingState(r.item.torrent!.stateRaw),
          )
          .length,
      stalled: rows
          .where((r) => r.item.torrent?.state == TorrentState.stalled)
          .length,
      attention: rows.where((r) => r.item.needsAttention).length,
      dlBps:
          readInt(serverState?['dl_info_speed']) ??
          rows.fold<int>(0, (s, r) => s + r.item.dlBps),
      upBps:
          readInt(serverState?['up_info_speed']) ??
          rows.fold<int>(0, (s, r) => s + r.item.upBps),
    );
