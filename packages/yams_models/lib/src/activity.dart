/// Activity DTOs: qBittorrent, the unified *arr queue, manual import,
/// transfer settings and the VPN (API.md §8).
library;

import 'package:meta/meta.dart';

import 'arr_common.dart';
import 'common.dart';
import 'json.dart';

// ---------------------------------------------------------------------------
// Torrents (API.md §8.1)
// ---------------------------------------------------------------------------

/// Normalised qBittorrent torrent state (integrations/downloads.md §1.6).
enum TorrentState {
  downloading,
  seeding,
  stalled,
  stopped,
  queued,
  checking,
  moving,
  error,
  metadata,
  unknown;

  static TorrentState fromJson(Object? v) =>
      readEnum(v, TorrentState.values, TorrentState.unknown);

  String toJson() => name;
}

/// Whether a torrent is still downloading or already seeding.
enum TorrentDirection {
  download,
  upload,
  unknown;

  static TorrentDirection fromJson(Object? v) =>
      readEnum(v, TorrentDirection.values, TorrentDirection.unknown);

  String toJson() => name;
}

/// One torrent of the qBittorrent snapshot.
@immutable
final class TorrentSummary {
  const TorrentSummary({
    required this.hash,
    required this.name,
    required this.state,
    required this.stateRaw,
    required this.direction,
    required this.progress,
    required this.sizeBytes,
    required this.downloadedBytes,
    required this.uploadedBytes,
    required this.amountLeftBytes,
    required this.dlBps,
    required this.upBps,
    required this.ratio,
    required this.seeds,
    required this.peers,
    required this.addedAt,
    this.etaSeconds,
    this.category,
    this.tags = const [],
    this.completedAt,
    this.lastActivityAt,
    this.forceStart = false,
    this.queuePosition,
    this.hasTrackerError = false,
    this.hasTrackerWarning = false,
    this.protected = false,
    this.managedBy,
  });

  factory TorrentSummary.fromJson(JsonMap j) => TorrentSummary(
    hash: req(readString(j['hash']), 'hash'),
    name: readString(j['name']) ?? '',
    state: TorrentState.fromJson(j['state']),
    stateRaw: readString(j['stateRaw']) ?? '',
    direction: TorrentDirection.fromJson(j['direction']),
    progress: readDouble(j['progress']) ?? 0,
    sizeBytes: readInt(j['sizeBytes']) ?? 0,
    downloadedBytes: readInt(j['downloadedBytes']) ?? 0,
    uploadedBytes: readInt(j['uploadedBytes']) ?? 0,
    amountLeftBytes: readInt(j['amountLeftBytes']) ?? 0,
    dlBps: readInt(j['dlBps']) ?? 0,
    upBps: readInt(j['upBps']) ?? 0,
    etaSeconds: readInt(j['etaSeconds']),
    ratio: readDouble(j['ratio']) ?? 0,
    seeds: readInt(j['seeds']) ?? 0,
    peers: readInt(j['peers']) ?? 0,
    category: readString(j['category']),
    tags: readStringList(j['tags']),
    addedAt: req(readInstant(j['addedAt']), 'addedAt'),
    completedAt: readInstant(j['completedAt']),
    lastActivityAt: readInstant(j['lastActivityAt']),
    forceStart: readBool(j['forceStart']) ?? false,
    queuePosition: readInt(j['queuePosition']),
    hasTrackerError: readBool(j['hasTrackerError']) ?? false,
    hasTrackerWarning: readBool(j['hasTrackerWarning']) ?? false,
    protected: readBool(j['protected']) ?? false,
    managedBy: j['managedBy'] == null
        ? null
        : ArrService.fromJson(j['managedBy']),
  );

  /// Lower-case info hash.
  final String hash;
  final String name;
  final TorrentState state;

  /// The qBittorrent state string (`uploading`, `stalledDL`, ...).
  final String stateRaw;
  final TorrentDirection direction;

  /// 0..1.
  final double progress;
  final int sizeBytes;
  final int downloadedBytes;
  final int uploadedBytes;
  final int amountLeftBytes;
  final int dlBps;
  final int upBps;

  /// Null when qBittorrent reports "infinity" (8640000).
  final int? etaSeconds;
  final double ratio;

  /// Connected seeds and peers.
  final int seeds;
  final int peers;

  /// Null when uncategorised.
  final String? category;
  final List<String> tags;
  final DateTime addedAt;
  final DateTime? completedAt;
  final DateTime? lastActivityAt;
  final bool forceStart;

  /// Queue position; null when not queued.
  final int? queuePosition;
  final bool hasTrackerError;
  final bool hasTrackerWarning;

  /// Tagged `Keep` (decluttarr never removes it).
  final bool protected;

  /// `sonarr` for category `tv-sonarr`, `radarr` for `radarr`.
  final ArrService? managedBy;

  JsonMap toJson() => compactJson({
    'hash': hash,
    'name': name,
    'state': state.toJson(),
    'stateRaw': stateRaw,
    'direction': direction.toJson(),
    'progress': progress,
    'sizeBytes': sizeBytes,
    'downloadedBytes': downloadedBytes,
    'uploadedBytes': uploadedBytes,
    'amountLeftBytes': amountLeftBytes,
    'dlBps': dlBps,
    'upBps': upBps,
    'etaSeconds': etaSeconds,
    'ratio': ratio,
    'seeds': seeds,
    'peers': peers,
    'category': category,
    'tags': tags,
    'addedAt': instantToJson(addedAt),
    'completedAt': optionalInstantToJson(completedAt),
    'lastActivityAt': optionalInstantToJson(lastActivityAt),
    'forceStart': forceStart,
    'queuePosition': queuePosition,
    'hasTrackerError': hasTrackerError,
    'hasTrackerWarning': hasTrackerWarning,
    'protected': protected,
    'managedBy': managedBy?.toJson(),
  });
}

// ---------------------------------------------------------------------------
// Transfer (API.md §8.1, §8.5)
// ---------------------------------------------------------------------------

/// qBittorrent's `connection_status`.
enum TransferConnectionStatus {
  connected,
  firewalled,
  disconnected,
  unknown;

  static TransferConnectionStatus fromJson(Object? v) => readEnum(
    v,
    TransferConnectionStatus.values,
    TransferConnectionStatus.unknown,
  );

  String toJson() => name;
}

/// Days of the alternative-speed schedule (`scheduler_days` 0..9).
enum TransferScheduleDays {
  everyDay,
  weekdays,
  weekends,
  monday,
  tuesday,
  wednesday,
  thursday,
  friday,
  saturday,
  sunday,
  unknown;

  /// Maps qBittorrent's `scheduler_days` integer.
  static TransferScheduleDays fromQbit(int? v) =>
      (v == null || v < 0 || v > 9) ? unknown : values[v];

  static TransferScheduleDays fromJson(Object? v) =>
      readEnum(v, TransferScheduleDays.values, TransferScheduleDays.unknown);

  String toJson() => name;
}

/// The four global speed limits in B/s (0 = unlimited). Also the body of
/// `PUT /transfer/limits`.
@immutable
final class TransferLimits {
  const TransferLimits({
    required this.dlBps,
    required this.upBps,
    required this.altDlBps,
    required this.altUpBps,
  });

  factory TransferLimits.fromJson(JsonMap j) => TransferLimits(
    dlBps: readInt(j['dlBps']) ?? 0,
    upBps: readInt(j['upBps']) ?? 0,
    altDlBps: readInt(j['altDlBps']) ?? 0,
    altUpBps: readInt(j['altUpBps']) ?? 0,
  );

  final int dlBps;
  final int upBps;
  final int altDlBps;
  final int altUpBps;

  JsonMap toJson() => {
    'dlBps': dlBps,
    'upBps': upBps,
    'altDlBps': altDlBps,
    'altUpBps': altUpBps,
  };
}

/// The alternative-speed schedule (read-only in the hub).
@immutable
final class TransferSchedule {
  const TransferSchedule({
    required this.enabled,
    required this.from,
    required this.to,
    required this.days,
  });

  factory TransferSchedule.fromJson(JsonMap j) => TransferSchedule(
    enabled: readBool(j['enabled']) ?? false,
    from: readString(j['from']) ?? '00:00',
    to: readString(j['to']) ?? '00:00',
    days: TransferScheduleDays.fromJson(j['days']),
  );

  final bool enabled;

  /// `HH:MM` in the container's local time.
  final String from;
  final String to;
  final TransferScheduleDays days;

  JsonMap toJson() => {
    'enabled': enabled,
    'from': from,
    'to': to,
    'days': days.toJson(),
  };
}

/// Global qBittorrent transfer state.
@immutable
final class TransferState {
  const TransferState({
    required this.dlBps,
    required this.upBps,
    required this.dlLimitBps,
    required this.upLimitBps,
    required this.altSpeedEnabled,
    required this.connectionStatus,
    required this.dhtNodes,
    required this.freeSpaceBytes,
    required this.sessionPaused,
    required this.globalRatio,
    required this.allTimeDownloadedBytes,
    required this.allTimeUploadedBytes,
    required this.sessionDownloadedBytes,
    required this.sessionUploadedBytes,
    required this.updatedAt,
    this.limits,
    this.schedule,
    this.stale = false,
  });

  factory TransferState.fromJson(JsonMap j) => TransferState(
    dlBps: readInt(j['dlBps']) ?? 0,
    upBps: readInt(j['upBps']) ?? 0,
    dlLimitBps: readInt(j['dlLimitBps']) ?? 0,
    upLimitBps: readInt(j['upLimitBps']) ?? 0,
    altSpeedEnabled: readBool(j['altSpeedEnabled']) ?? false,
    limits: switch (readMap(j['limits'])) {
      final m? => TransferLimits.fromJson(m),
      null => null,
    },
    schedule: switch (readMap(j['schedule'])) {
      final m? => TransferSchedule.fromJson(m),
      null => null,
    },
    connectionStatus: TransferConnectionStatus.fromJson(j['connectionStatus']),
    dhtNodes: readInt(j['dhtNodes']) ?? 0,
    freeSpaceBytes: readInt(j['freeSpaceBytes']) ?? 0,
    sessionPaused: readBool(j['sessionPaused']) ?? false,
    globalRatio: readDouble(j['globalRatio']) ?? 0,
    allTimeDownloadedBytes: readInt(j['allTimeDownloadedBytes']) ?? 0,
    allTimeUploadedBytes: readInt(j['allTimeUploadedBytes']) ?? 0,
    sessionDownloadedBytes: readInt(j['sessionDownloadedBytes']) ?? 0,
    sessionUploadedBytes: readInt(j['sessionUploadedBytes']) ?? 0,
    updatedAt: req(readInstant(j['updatedAt']), 'updatedAt'),
    stale: readBool(j['stale']) ?? false,
  );

  final int dlBps;
  final int upBps;

  /// Currently effective limits (the alternative ones while
  /// [altSpeedEnabled]); 0 = unlimited.
  final int dlLimitBps;
  final int upLimitBps;
  final bool altSpeedEnabled;

  /// All four configured limits; absent when they could not be read.
  final TransferLimits? limits;

  /// The alternative-speed schedule; absent when it could not be read.
  final TransferSchedule? schedule;
  final TransferConnectionStatus connectionStatus;
  final int dhtNodes;
  final int freeSpaceBytes;

  /// The whole session is paused.
  final bool sessionPaused;
  final double globalRatio;
  final int allTimeDownloadedBytes;
  final int allTimeUploadedBytes;
  final int sessionDownloadedBytes;
  final int sessionUploadedBytes;
  final DateTime updatedAt;
  final bool stale;

  JsonMap toJson() => compactJson({
    'dlBps': dlBps,
    'upBps': upBps,
    'dlLimitBps': dlLimitBps,
    'upLimitBps': upLimitBps,
    'altSpeedEnabled': altSpeedEnabled,
    'limits': limits?.toJson(),
    'schedule': schedule?.toJson(),
    'connectionStatus': connectionStatus.toJson(),
    'dhtNodes': dhtNodes,
    'freeSpaceBytes': freeSpaceBytes,
    'sessionPaused': sessionPaused,
    'globalRatio': globalRatio,
    'allTimeDownloadedBytes': allTimeDownloadedBytes,
    'allTimeUploadedBytes': allTimeUploadedBytes,
    'sessionDownloadedBytes': sessionDownloadedBytes,
    'sessionUploadedBytes': sessionUploadedBytes,
    'updatedAt': instantToJson(updatedAt),
    'stale': stale,
  });
}

// ---------------------------------------------------------------------------
// Unified queue (API.md §8.1, §8.2)
// ---------------------------------------------------------------------------

/// State of a [QueueItem]: a [TorrentState] or one of the *arr tracked
/// states that win over it.
enum QueueItemState {
  downloading,
  seeding,
  stalled,
  stopped,
  queued,
  checking,
  moving,
  error,
  metadata,
  importPending,
  importBlocked,
  importing,
  failed,
  delayed,
  completed,
  unknown;

  /// The queue state of a torrent state.
  static QueueItemState fromTorrent(TorrentState s) => switch (s) {
    TorrentState.downloading => downloading,
    TorrentState.seeding => seeding,
    TorrentState.stalled => stalled,
    TorrentState.stopped => stopped,
    TorrentState.queued => queued,
    TorrentState.checking => checking,
    TorrentState.moving => moving,
    TorrentState.error => error,
    TorrentState.metadata => metadata,
    TorrentState.unknown => unknown,
  };

  static QueueItemState fromJson(Object? v) =>
      readEnum(v, QueueItemState.values, QueueItemState.unknown);

  String toJson() => name;
}

/// Why a [QueueItem] needs attention (the first matching reason).
enum QueueAttention {
  importBlocked,
  importPending,
  failed,
  trackerError,
  error,
  warning,
  unknown;

  /// Manual import resolves it.
  bool get isImport => this == importBlocked || this == importPending;

  static QueueAttention fromJson(Object? v) =>
      readEnum(v, QueueAttention.values, QueueAttention.unknown);

  String toJson() => name;
}

/// The download-client status of an *arr queue record.
enum QueueArrStatus {
  unknown,
  queued,
  paused,
  downloading,
  completed,
  failed,
  warning,
  delay,
  downloadClientUnavailable,
  fallback;

  static QueueArrStatus fromJson(Object? v) =>
      readEnum(v, QueueArrStatus.values, QueueArrStatus.unknown);

  String toJson() => name;
}

/// `trackedDownloadStatus` of an *arr queue record (row colour).
enum QueueTrackedStatus {
  ok,
  warning,
  error,
  unknown;

  static QueueTrackedStatus fromJson(Object? v) =>
      readEnum(v, QueueTrackedStatus.values, QueueTrackedStatus.unknown);

  String toJson() => name;
}

/// `trackedDownloadState` of an *arr queue record.
enum QueueTrackedState {
  downloading,
  importBlocked,
  importPending,
  importing,
  imported,
  failedPending,
  failed,
  ignored,
  unknown;

  /// Sonarr/Radarr need a manual import.
  bool get needsImport => this == importBlocked || this == importPending;

  static QueueTrackedState fromJson(Object? v) =>
      readEnum(v, QueueTrackedState.values, QueueTrackedState.unknown);

  String toJson() => name;
}

/// The Sonarr or Radarr side of a [QueueItem]: every queue record of one
/// download (season packs have one record per episode).
@immutable
final class QueueArrEntry {
  const QueueArrEntry({
    required this.service,
    required this.queueIds,
    required this.status,
    required this.trackedStatus,
    required this.trackedState,
    this.mediaTitle,
    this.seriesId,
    this.movieId,
    this.episodeIds = const [],
    this.episodesLabel,
    this.messages = const [],
    this.isUpgrade = false,
    this.posterPath,
    this.downloadId,
    this.canManualImport = false,
    this.links = const [],
  });

  factory QueueArrEntry.fromJson(JsonMap j) => QueueArrEntry(
    service: ArrService.fromJson(j['service']),
    queueIds: readIntList(j['queueIds']),
    mediaTitle: readString(j['mediaTitle']),
    seriesId: readInt(j['seriesId']),
    movieId: readInt(j['movieId']),
    episodeIds: readIntList(j['episodeIds']),
    episodesLabel: readString(j['episodesLabel']),
    status: QueueArrStatus.fromJson(j['status']),
    trackedStatus: QueueTrackedStatus.fromJson(j['trackedStatus']),
    trackedState: QueueTrackedState.fromJson(j['trackedState']),
    messages: readStringList(j['messages']),
    isUpgrade: readBool(j['isUpgrade']) ?? false,
    posterPath: readString(j['posterPath']),
    downloadId: readString(j['downloadId']),
    canManualImport: readBool(j['canManualImport']) ?? false,
    links: readList(j['links'], ExternalLink.fromJson),
  );

  final ArrService service;
  final List<int> queueIds;

  /// Series or movie title.
  final String? mediaTitle;
  final int? seriesId;
  final int? movieId;
  final List<int> episodeIds;

  /// `S04E01–E24` (Sonarr only).
  final String? episodesLabel;
  final QueueArrStatus status;
  final QueueTrackedStatus trackedStatus;
  final QueueTrackedState trackedState;

  /// Status messages (at most 5).
  final List<String> messages;
  final bool isUpgrade;
  final String? posterPath;

  /// The download client id as the *arr reports it.
  final String? downloadId;

  /// The caller (an admin) can resolve it with a manual import.
  final bool canManualImport;

  /// The *arr's own queue page (admins only).
  final List<ExternalLink> links;

  JsonMap toJson() => compactJson({
    'service': service.toJson(),
    'queueIds': queueIds,
    'mediaTitle': mediaTitle,
    'seriesId': seriesId,
    'movieId': movieId,
    'episodeIds': episodeIds,
    'episodesLabel': episodesLabel,
    'status': status.toJson(),
    'trackedStatus': trackedStatus.toJson(),
    'trackedState': trackedState.toJson(),
    'messages': messages,
    'isUpgrade': isUpgrade,
    'posterPath': posterPath,
    'downloadId': downloadId,
    'canManualImport': canManualImport,
    'links': [for (final l in links) l.toJson()],
  });
}

/// One row of the unified queue: a torrent, its *arr records, or both.
@immutable
final class QueueItem {
  const QueueItem({
    required this.key,
    required this.title,
    required this.state,
    required this.progress,
    required this.sizeBytes,
    required this.sizeLeftBytes,
    this.subtitle,
    this.needsAttention = false,
    this.attention,
    this.etaSeconds,
    this.dlBps = 0,
    this.upBps = 0,
    this.torrent,
    this.arr = const [],
  });

  factory QueueItem.fromJson(JsonMap j) => QueueItem(
    key: req(readString(j['key']), 'key'),
    title: readString(j['title']) ?? '',
    subtitle: readString(j['subtitle']),
    state: QueueItemState.fromJson(j['state']),
    needsAttention: readBool(j['needsAttention']) ?? false,
    attention: j['attention'] == null
        ? null
        : QueueAttention.fromJson(j['attention']),
    progress: readDouble(j['progress']) ?? 0,
    sizeBytes: readInt(j['sizeBytes']) ?? 0,
    sizeLeftBytes: readInt(j['sizeLeftBytes']) ?? 0,
    etaSeconds: readInt(j['etaSeconds']),
    dlBps: readInt(j['dlBps']) ?? 0,
    upBps: readInt(j['upBps']) ?? 0,
    torrent: switch (readMap(j['torrent'])) {
      final m? => TorrentSummary.fromJson(m),
      null => null,
    },
    arr: readList(j['arr'], QueueArrEntry.fromJson),
  );

  /// Lower-case info hash, or `{service}:{downloadId}` without a torrent.
  final String key;
  final String title;
  final String? subtitle;
  final QueueItemState state;
  final bool needsAttention;
  final QueueAttention? attention;
  final double progress;
  final int sizeBytes;
  final int sizeLeftBytes;
  final int? etaSeconds;
  final int dlBps;
  final int upBps;
  final TorrentSummary? torrent;
  final List<QueueArrEntry> arr;

  /// The first *arr entry that a manual import can resolve.
  QueueArrEntry? get importEntry {
    for (final e in arr) {
      if (e.canManualImport) return e;
    }
    return null;
  }

  JsonMap toJson() => compactJson({
    'key': key,
    'title': title,
    'subtitle': subtitle,
    'state': state.toJson(),
    'needsAttention': needsAttention,
    'attention': attention?.toJson(),
    'progress': progress,
    'sizeBytes': sizeBytes,
    'sizeLeftBytes': sizeLeftBytes,
    'etaSeconds': etaSeconds,
    'dlBps': dlBps,
    'upBps': upBps,
    'torrent': torrent?.toJson(),
    'arr': [for (final a in arr) a.toJson()],
  });
}

/// Counters of the whole queue (independent of the filter).
@immutable
final class QueueSummary {
  const QueueSummary({
    this.downloading = 0,
    this.seeding = 0,
    this.stalled = 0,
    this.attention = 0,
    this.dlBps = 0,
    this.upBps = 0,
  });

  factory QueueSummary.fromJson(JsonMap j) => QueueSummary(
    downloading: readInt(j['downloading']) ?? 0,
    seeding: readInt(j['seeding']) ?? 0,
    stalled: readInt(j['stalled']) ?? 0,
    attention: readInt(j['attention']) ?? 0,
    dlBps: readInt(j['dlBps']) ?? 0,
    upBps: readInt(j['upBps']) ?? 0,
  );

  final int downloading;
  final int seeding;
  final int stalled;
  final int attention;
  final int dlBps;
  final int upBps;

  JsonMap toJson() => {
    'downloading': downloading,
    'seeding': seeding,
    'stalled': stalled,
    'attention': attention,
    'dlBps': dlBps,
    'upBps': upBps,
  };
}

/// `GET /activity/queue`. One failing source does not fail the response:
/// [sonarr], [radarr] and [qbittorrent] say which sources answered.
@immutable
final class QueueResponse {
  const QueueResponse({
    required this.items,
    required this.summary,
    required this.sonarr,
    required this.radarr,
    required this.qbittorrent,
    this.stale = false,
  });

  factory QueueResponse.fromJson(JsonMap j) {
    final arr = readMap(j['arr']) ?? const {};
    SectionStatus status(Object? v) => switch (readMap(v)) {
      final m? => SectionStatus.fromJson(m),
      null => const SectionStatus(status: SectionState.unknown),
    };
    return QueueResponse(
      items: readList(j['items'], QueueItem.fromJson),
      summary: QueueSummary.fromJson(readMap(j['summary']) ?? const {}),
      sonarr: status(arr['sonarr']),
      radarr: status(arr['radarr']),
      qbittorrent: status(j['qbittorrent']),
      stale: readBool(j['stale']) ?? false,
    );
  }

  final List<QueueItem> items;
  final QueueSummary summary;
  final SectionStatus sonarr;
  final SectionStatus radarr;
  final SectionStatus qbittorrent;
  final bool stale;

  /// The status of [service]'s queue.
  SectionStatus statusOf(ArrService service) => switch (service) {
    ArrService.sonarr => sonarr,
    ArrService.radarr => radarr,
    ArrService.unknown => const SectionStatus(status: SectionState.unknown),
  };

  JsonMap toJson() => {
    'items': [for (final i in items) i.toJson()],
    'summary': summary.toJson(),
    'arr': {'sonarr': sonarr.toJson(), 'radarr': radarr.toJson()},
    'qbittorrent': qbittorrent.toJson(),
    'stale': stale,
  };
}

/// Queue records of one *arr to remove.
@immutable
final class QueueRemoveTarget {
  const QueueRemoveTarget({required this.service, required this.queueIds});

  factory QueueRemoveTarget.fromJson(JsonMap j) => QueueRemoveTarget(
    service: ArrService.fromJson(j['service']),
    queueIds: readIntList(j['queueIds']),
  );

  final ArrService service;
  final List<int> queueIds;

  JsonMap toJson() => {'service': service.toJson(), 'queueIds': queueIds};
}

/// Body of `POST /activity/queue/remove` [confirm].
@immutable
final class QueueRemoveRequest {
  const QueueRemoveRequest({
    required this.items,
    this.removeFromClient = true,
    this.blocklist = false,
    this.searchAgain = false,
    this.confirm,
  });

  factory QueueRemoveRequest.fromJson(JsonMap j) => QueueRemoveRequest(
    items: readList(j['items'], QueueRemoveTarget.fromJson),
    removeFromClient: readBool(j['removeFromClient']) ?? true,
    blocklist: readBool(j['blocklist']) ?? false,
    searchAgain: readBool(j['searchAgain']) ?? false,
    confirm: readBool(j['confirm']),
  );

  final List<QueueRemoveTarget> items;
  final bool removeFromClient;
  final bool blocklist;

  /// Only with [blocklist]: let the *arr search for another release.
  final bool searchAgain;
  final bool? confirm;

  JsonMap toJson() => compactJson({
    'items': [for (final i in items) i.toJson()],
    'removeFromClient': removeFromClient,
    'blocklist': blocklist,
    'searchAgain': searchAgain,
    'confirm': confirm,
  });
}

/// Answer of `POST /activity/queue/remove`.
@immutable
final class QueueRemoveResult {
  const QueueRemoveResult({required this.removed, required this.alreadyGone});

  factory QueueRemoveResult.fromJson(JsonMap j) => QueueRemoveResult(
    removed: readInt(j['removed']) ?? 0,
    alreadyGone: readInt(j['alreadyGone']) ?? 0,
  );

  final int removed;
  final int alreadyGone;

  JsonMap toJson() => {'removed': removed, 'alreadyGone': alreadyGone};
}

// ---------------------------------------------------------------------------
// Manual import (API.md §8.3.1)
// ---------------------------------------------------------------------------

/// An episode a candidate file was matched to.
@immutable
final class ManualImportFileEpisode {
  const ManualImportFileEpisode({
    required this.id,
    required this.label,
    this.title,
  });

  factory ManualImportFileEpisode.fromJson(JsonMap j) =>
      ManualImportFileEpisode(
        id: req(readInt(j['id']), 'id'),
        label: readString(j['label']) ?? '',
        title: readString(j['title']),
      );

  final int id;

  /// `S04E01`.
  final String label;
  final String? title;

  JsonMap toJson() => compactJson({'id': id, 'label': label, 'title': title});
}

/// Kind of a manual-import rejection.
enum ManualImportFileRejectionType {
  permanent,
  temporary,
  unknown;

  static ManualImportFileRejectionType fromJson(Object? v) => readEnum(
    v,
    ManualImportFileRejectionType.values,
    ManualImportFileRejectionType.unknown,
  );

  String toJson() => name;
}

/// Why the *arr would not import a candidate file automatically.
@immutable
final class ManualImportFileRejection {
  const ManualImportFileRejection({required this.reason, required this.type});

  factory ManualImportFileRejection.fromJson(JsonMap j) =>
      ManualImportFileRejection(
        reason: readString(j['reason']) ?? '',
        type: ManualImportFileRejectionType.fromJson(j['type']),
      );

  final String reason;
  final ManualImportFileRejectionType type;

  JsonMap toJson() => {'reason': reason, 'type': type.toJson()};
}

/// One file the *arr found in a download. The absolute path stays in the
/// gateway behind [fileId].
@immutable
final class ManualImportFile {
  const ManualImportFile({
    required this.fileId,
    required this.relativePath,
    required this.sizeBytes,
    required this.quality,
    this.languages = const [],
    this.releaseGroup,
    this.seriesId,
    this.seasonNumber,
    this.episodes = const [],
    this.movieId,
    this.movieTitle,
    this.customFormatScore,
    this.rejections = const [],
    this.importable = false,
  });

  factory ManualImportFile.fromJson(JsonMap j) => ManualImportFile(
    fileId: req(readString(j['fileId']), 'fileId'),
    relativePath: readString(j['relativePath']) ?? '',
    sizeBytes: readInt(j['sizeBytes']) ?? 0,
    quality: QualityInfo.fromJson(readMap(j['quality']) ?? const {}),
    languages: readStringList(j['languages']),
    releaseGroup: readString(j['releaseGroup']),
    seriesId: readInt(j['seriesId']),
    seasonNumber: readInt(j['seasonNumber']),
    episodes: readList(j['episodes'], ManualImportFileEpisode.fromJson),
    movieId: readInt(j['movieId']),
    movieTitle: readString(j['movieTitle']),
    customFormatScore: readInt(j['customFormatScore']),
    rejections: readList(j['rejections'], ManualImportFileRejection.fromJson),
    importable: readBool(j['importable']) ?? false,
  );

  /// Gateway token for the upstream path (valid 30 min, per user).
  final String fileId;
  final String relativePath;
  final int sizeBytes;
  final QualityInfo quality;
  final List<String> languages;
  final String? releaseGroup;
  final int? seriesId;
  final int? seasonNumber;
  final List<ManualImportFileEpisode> episodes;
  final int? movieId;
  final String? movieTitle;
  final int? customFormatScore;
  final List<ManualImportFileRejection> rejections;

  /// Series/movie (and, for Sonarr, at least one episode) are resolved.
  final bool importable;

  JsonMap toJson() => compactJson({
    'fileId': fileId,
    'relativePath': relativePath,
    'sizeBytes': sizeBytes,
    'quality': quality.toJson(),
    'languages': languages,
    'releaseGroup': releaseGroup,
    'seriesId': seriesId,
    'seasonNumber': seasonNumber,
    'episodes': [for (final e in episodes) e.toJson()],
    'movieId': movieId,
    'movieTitle': movieTitle,
    'customFormatScore': customFormatScore,
    'rejections': [for (final r in rejections) r.toJson()],
    'importable': importable,
  });
}

/// `GET /activity/queue/{service}/{queueId}/import`.
@immutable
final class ManualImportCandidates {
  const ManualImportCandidates({
    required this.service,
    required this.queueId,
    required this.downloadId,
    required this.title,
    this.items = const [],
  });

  factory ManualImportCandidates.fromJson(JsonMap j) => ManualImportCandidates(
    service: ArrService.fromJson(j['service']),
    queueId: req(readInt(j['queueId']), 'queueId'),
    downloadId: readString(j['downloadId']) ?? '',
    title: readString(j['title']) ?? '',
    items: readList(j['items'], ManualImportFile.fromJson),
  );

  final ArrService service;
  final int queueId;
  final String downloadId;
  final String title;
  final List<ManualImportFile> items;

  JsonMap toJson() => {
    'service': service.toJson(),
    'queueId': queueId,
    'downloadId': downloadId,
    'title': title,
    'items': [for (final i in items) i.toJson()],
  };
}

/// How the *arr moves imported files.
enum QueueImportMode {
  auto,
  move,
  copy,
  unknown;

  static QueueImportMode fromJson(Object? v) =>
      readEnum(v, QueueImportMode.values, QueueImportMode.unknown);

  String toJson() => name;
}

/// One file to import; unset mappings default to the candidate's values.
@immutable
final class QueueImportFileSelection {
  const QueueImportFileSelection({
    required this.fileId,
    this.seriesId,
    this.episodeIds,
    this.movieId,
  });

  factory QueueImportFileSelection.fromJson(JsonMap j) =>
      QueueImportFileSelection(
        fileId: req(readString(j['fileId']), 'fileId'),
        seriesId: readInt(j['seriesId']),
        episodeIds: j['episodeIds'] == null
            ? null
            : readIntList(j['episodeIds']),
        movieId: readInt(j['movieId']),
      );

  final String fileId;
  final int? seriesId;
  final List<int>? episodeIds;
  final int? movieId;

  JsonMap toJson() => compactJson({
    'fileId': fileId,
    'seriesId': seriesId,
    'episodeIds': episodeIds,
    'movieId': movieId,
  });
}

/// Body of `POST /activity/queue/import`.
@immutable
final class QueueImportRequest {
  const QueueImportRequest({
    required this.service,
    required this.queueId,
    required this.files,
    this.importMode = QueueImportMode.auto,
  });

  factory QueueImportRequest.fromJson(JsonMap j) => QueueImportRequest(
    service: ArrService.fromJson(j['service']),
    queueId: req(readInt(j['queueId']), 'queueId'),
    importMode: j['importMode'] == null
        ? QueueImportMode.auto
        : QueueImportMode.fromJson(j['importMode']),
    files: readList(j['files'], QueueImportFileSelection.fromJson),
  );

  final ArrService service;
  final int queueId;
  final QueueImportMode importMode;
  final List<QueueImportFileSelection> files;

  JsonMap toJson() => {
    'service': service.toJson(),
    'queueId': queueId,
    'importMode': importMode.toJson(),
    'files': [for (final f in files) f.toJson()],
  };
}

// ---------------------------------------------------------------------------
// Torrent list and detail (API.md §8.4)
// ---------------------------------------------------------------------------

/// `GET /torrents`.
@immutable
final class TorrentList {
  const TorrentList({
    required this.items,
    required this.transfer,
    this.categories = const [],
    this.tags = const [],
    this.stale = false,
  });

  factory TorrentList.fromJson(JsonMap j) => TorrentList(
    items: readList(j['items'], TorrentSummary.fromJson),
    transfer: TransferState.fromJson(req(readMap(j['transfer']), 'transfer')),
    categories: readStringList(j['categories']),
    tags: readStringList(j['tags']),
    stale: readBool(j['stale']) ?? false,
  );

  final List<TorrentSummary> items;
  final TransferState transfer;
  final List<String> categories;
  final List<String> tags;
  final bool stale;

  JsonMap toJson() => {
    'items': [for (final i in items) i.toJson()],
    'transfer': transfer.toJson(),
    'categories': categories,
    'tags': tags,
    'stale': stale,
  };
}

/// Which share limits apply to a torrent.
enum ShareLimitsMode {
  global,
  unlimited,
  custom,
  unknown;

  static ShareLimitsMode fromJson(Object? v) =>
      readEnum(v, ShareLimitsMode.values, ShareLimitsMode.unknown);

  String toJson() => name;
}

/// What qBittorrent does when a share limit is reached.
enum ShareLimitsAction {
  byDefault('default', 'Default'),
  stop('stop', 'Stop'),
  remove('remove', 'Remove'),
  removeWithContent('removeWithContent', 'RemoveWithContent'),
  enableSuperSeeding('enableSuperSeeding', 'EnableSuperSeeding'),
  unknown('unknown', 'Default');

  const ShareLimitsAction(this.wire, this.qbit);

  /// The JSON value (`default`, `removeWithContent`, ...).
  final String wire;

  /// qBittorrent's `shareLimitAction` value.
  final String qbit;

  /// Deletes the torrent (and with [removeWithContent] its files).
  bool get removes => this == remove || this == removeWithContent;

  /// Maps qBittorrent's `share_limit_action` (`Default`, `Stop`, ...).
  static ShareLimitsAction fromQbit(Object? v) {
    for (final a in values) {
      if (a != unknown && a.qbit == v) return a;
    }
    return unknown;
  }

  /// Parses the JSON value; null when it is not one of the known values.
  static ShareLimitsAction? tryParse(Object? v) {
    for (final a in values) {
      if (a != unknown && a.wire == v) return a;
    }
    return null;
  }

  static ShareLimitsAction fromJson(Object? v) => tryParse(v) ?? unknown;

  String toJson() => wire;
}

/// Share limits of one torrent.
@immutable
final class ShareLimits {
  const ShareLimits({
    required this.mode,
    required this.action,
    required this.effectiveRatio,
    required this.effectiveSeedingMinutes,
    this.ratio,
    this.seedingMinutes,
    this.inactiveMinutes,
  });

  factory ShareLimits.fromJson(JsonMap j) => ShareLimits(
    mode: ShareLimitsMode.fromJson(j['mode']),
    ratio: readDouble(j['ratio']),
    seedingMinutes: readInt(j['seedingMinutes']),
    inactiveMinutes: readInt(j['inactiveMinutes']),
    action: ShareLimitsAction.fromJson(j['action']),
    effectiveRatio: readDouble(j['effectiveRatio']) ?? -1,
    effectiveSeedingMinutes: readInt(j['effectiveSeedingMinutes']) ?? -1,
  );

  final ShareLimitsMode mode;

  /// Custom limits (absent = no limit for that criterion).
  final double? ratio;
  final int? seedingMinutes;
  final int? inactiveMinutes;
  final ShareLimitsAction action;

  /// Limits after resolving the global ones; -1 = none.
  final double effectiveRatio;
  final int effectiveSeedingMinutes;

  JsonMap toJson() => compactJson({
    'mode': mode.toJson(),
    'ratio': ratio,
    'seedingMinutes': seedingMinutes,
    'inactiveMinutes': inactiveMinutes,
    'action': action.toJson(),
    'effectiveRatio': effectiveRatio,
    'effectiveSeedingMinutes': effectiveSeedingMinutes,
  });
}

/// Body of `PUT /torrents/{hash}/share-limits` ([confirm] when [action]
/// removes the torrent).
@immutable
final class ShareLimitsUpdate {
  const ShareLimitsUpdate({
    required this.mode,
    this.ratio,
    this.seedingMinutes,
    this.inactiveMinutes,
    this.action = ShareLimitsAction.byDefault,
    this.confirm,
  });

  factory ShareLimitsUpdate.fromJson(JsonMap j) => ShareLimitsUpdate(
    mode: ShareLimitsMode.fromJson(j['mode']),
    ratio: readDouble(j['ratio']),
    seedingMinutes: readInt(j['seedingMinutes']),
    inactiveMinutes: readInt(j['inactiveMinutes']),
    action: j['action'] == null
        ? ShareLimitsAction.byDefault
        : ShareLimitsAction.fromJson(j['action']),
    confirm: readBool(j['confirm']),
  );

  final ShareLimitsMode mode;
  final double? ratio;
  final int? seedingMinutes;
  final int? inactiveMinutes;
  final ShareLimitsAction action;
  final bool? confirm;

  JsonMap toJson() => compactJson({
    'mode': mode.toJson(),
    'ratio': ratio,
    'seedingMinutes': seedingMinutes,
    'inactiveMinutes': inactiveMinutes,
    'action': action.toJson(),
    'confirm': confirm,
  });
}

/// Download priority of a file in a torrent.
enum TorrentFilePriority {
  skip(0),
  normal(1),
  high(6),
  max(7),
  unknown(1);

  const TorrentFilePriority(this.qbit);

  /// qBittorrent's `priority` value.
  final int qbit;

  /// Maps qBittorrent's `priority` (0 skip, 1..5 normal, 6 high, 7 max).
  static TorrentFilePriority fromQbit(int? v) => switch (v) {
    0 => skip,
    6 => high,
    7 => max,
    null => unknown,
    _ => normal,
  };

  static TorrentFilePriority fromJson(Object? v) =>
      readEnum(v, TorrentFilePriority.values, TorrentFilePriority.unknown);

  String toJson() => name;
}

/// One file of a torrent.
@immutable
final class TorrentFile {
  const TorrentFile({
    required this.index,
    required this.name,
    required this.sizeBytes,
    required this.progress,
    required this.priority,
    this.availability,
  });

  factory TorrentFile.fromJson(JsonMap j) => TorrentFile(
    index: req(readInt(j['index']), 'index'),
    name: readString(j['name']) ?? '',
    sizeBytes: readInt(j['sizeBytes']) ?? 0,
    progress: readDouble(j['progress']) ?? 0,
    priority: TorrentFilePriority.fromJson(j['priority']),
    availability: readDouble(j['availability']),
  );

  final int index;

  /// Relative path with `/` separators.
  final String name;
  final int sizeBytes;
  final double progress;
  final TorrentFilePriority priority;
  final double? availability;

  JsonMap toJson() => compactJson({
    'index': index,
    'name': name,
    'sizeBytes': sizeBytes,
    'progress': progress,
    'priority': priority.toJson(),
    'availability': availability,
  });
}

/// Body of `PUT /torrents/{hash}/files/priority`.
@immutable
final class TorrentFilePriorityRequest {
  const TorrentFilePriorityRequest({
    required this.indexes,
    required this.priority,
  });

  factory TorrentFilePriorityRequest.fromJson(JsonMap j) =>
      TorrentFilePriorityRequest(
        indexes: readIntList(j['indexes']),
        priority: TorrentFilePriority.fromJson(j['priority']),
      );

  final List<int> indexes;
  final TorrentFilePriority priority;

  JsonMap toJson() => {'indexes': indexes, 'priority': priority.toJson()};
}

/// Status of a tracker (qBittorrent 0..6).
enum TrackerInfoStatus {
  disabled,
  notContacted,
  working,
  updating,
  notWorking,
  trackerError,
  unreachable,
  unknown;

  /// Maps qBittorrent's tracker `status` integer.
  static TrackerInfoStatus fromQbit(int? v) =>
      (v == null || v < 0 || v > 6) ? unknown : values[v];

  static TrackerInfoStatus fromJson(Object? v) =>
      readEnum(v, TrackerInfoStatus.values, TrackerInfoStatus.unknown);

  String toJson() => name;
}

/// One tracker. [url] is reduced to `scheme://host[:port]` (announce URLs of
/// private trackers embed passkeys).
@immutable
final class TrackerInfo {
  const TrackerInfo({
    required this.url,
    required this.tier,
    required this.status,
    this.message,
    this.seeds,
    this.peers,
    this.downloaded,
  });

  factory TrackerInfo.fromJson(JsonMap j) => TrackerInfo(
    url: readString(j['url']) ?? '',
    tier: readInt(j['tier']) ?? 0,
    status: TrackerInfoStatus.fromJson(j['status']),
    message: readString(j['message']),
    seeds: readInt(j['seeds']),
    peers: readInt(j['peers']),
    downloaded: readInt(j['downloaded']),
  );

  final String url;
  final int tier;
  final TrackerInfoStatus status;
  final String? message;
  final int? seeds;
  final int? peers;
  final int? downloaded;

  JsonMap toJson() => compactJson({
    'url': url,
    'tier': tier,
    'status': status.toJson(),
    'message': message,
    'seeds': seeds,
    'peers': peers,
    'downloaded': downloaded,
  });
}

/// `GET /torrents/{hash}`.
@immutable
final class TorrentDetail {
  const TorrentDetail({
    required this.summary,
    required this.savePath,
    required this.pieceSizeBytes,
    required this.piecesHave,
    required this.piecesTotal,
    required this.timeActiveSeconds,
    required this.seedingTimeSeconds,
    required this.wastedBytes,
    required this.avgDlBps,
    required this.avgUpBps,
    required this.connections,
    required this.seedsTotal,
    required this.peersTotal,
    required this.isPrivate,
    required this.shareLimits,
    this.comment,
    this.files = const [],
    this.trackers = const [],
    this.arr = const [],
  });

  factory TorrentDetail.fromJson(JsonMap j) => TorrentDetail(
    summary: TorrentSummary.fromJson(req(readMap(j['summary']), 'summary')),
    savePath: readString(j['savePath']) ?? '',
    pieceSizeBytes: readInt(j['pieceSizeBytes']) ?? 0,
    piecesHave: readInt(j['piecesHave']) ?? 0,
    piecesTotal: readInt(j['piecesTotal']) ?? 0,
    timeActiveSeconds: readInt(j['timeActiveSeconds']) ?? 0,
    seedingTimeSeconds: readInt(j['seedingTimeSeconds']) ?? 0,
    wastedBytes: readInt(j['wastedBytes']) ?? 0,
    avgDlBps: readInt(j['avgDlBps']) ?? 0,
    avgUpBps: readInt(j['avgUpBps']) ?? 0,
    connections: readInt(j['connections']) ?? 0,
    seedsTotal: readInt(j['seedsTotal']) ?? 0,
    peersTotal: readInt(j['peersTotal']) ?? 0,
    comment: readString(j['comment']),
    isPrivate: readBool(j['isPrivate']) ?? false,
    shareLimits: ShareLimits.fromJson(readMap(j['shareLimits']) ?? const {}),
    files: readList(j['files'], TorrentFile.fromJson),
    trackers: readList(j['trackers'], TrackerInfo.fromJson),
    arr: readList(j['arr'], QueueArrEntry.fromJson),
  );

  final TorrentSummary summary;

  /// Container path (useful for support).
  final String savePath;
  final int pieceSizeBytes;
  final int piecesHave;
  final int piecesTotal;
  final int timeActiveSeconds;
  final int seedingTimeSeconds;
  final int wastedBytes;
  final int avgDlBps;
  final int avgUpBps;
  final int connections;
  final int seedsTotal;
  final int peersTotal;
  final String? comment;
  final bool isPrivate;
  final ShareLimits shareLimits;
  final List<TorrentFile> files;
  final List<TrackerInfo> trackers;

  /// The *arr queue records of this torrent.
  final List<QueueArrEntry> arr;

  JsonMap toJson() => compactJson({
    'summary': summary.toJson(),
    'savePath': savePath,
    'pieceSizeBytes': pieceSizeBytes,
    'piecesHave': piecesHave,
    'piecesTotal': piecesTotal,
    'timeActiveSeconds': timeActiveSeconds,
    'seedingTimeSeconds': seedingTimeSeconds,
    'wastedBytes': wastedBytes,
    'avgDlBps': avgDlBps,
    'avgUpBps': avgUpBps,
    'connections': connections,
    'seedsTotal': seedsTotal,
    'peersTotal': peersTotal,
    'comment': comment,
    'isPrivate': isPrivate,
    'shareLimits': shareLimits.toJson(),
    'files': [for (final f in files) f.toJson()],
    'trackers': [for (final t in trackers) t.toJson()],
    'arr': [for (final a in arr) a.toJson()],
  });
}

/// A bulk action on torrents (`POST /torrents/actions`).
enum TorrentAction {
  stop,
  start,
  forceStart,
  recheck,
  reannounce,
  delete,
  setCategory,
  addTags,
  removeTags,
  topPriority,
  bottomPriority,
  increasePriority,
  decreasePriority,
  unknown;

  static TorrentAction fromJson(Object? v) =>
      readEnum(v, TorrentAction.values, TorrentAction.unknown);

  String toJson() => name;
}

/// Body of `POST /torrents/actions`.
@immutable
final class TorrentActionRequest {
  const TorrentActionRequest({
    required this.hashes,
    required this.action,
    this.deleteFiles,
    this.category,
    this.tags,
    this.force,
    this.confirm,
  });

  factory TorrentActionRequest.fromJson(JsonMap j) => TorrentActionRequest(
    hashes: readStringList(j['hashes']),
    action: TorrentAction.fromJson(j['action']),
    deleteFiles: readBool(j['deleteFiles']),
    category: readString(j['category']),
    tags: j['tags'] == null ? null : readStringList(j['tags']),
    force: readBool(j['force']),
    confirm: readBool(j['confirm']),
  );

  final List<String> hashes;
  final TorrentAction action;

  /// `delete`: also delete the files (permanently).
  final bool? deleteFiles;

  /// `setCategory`; `""` clears it.
  final String? category;

  /// `addTags` / `removeTags`.
  final List<String>? tags;

  /// `delete` of torrents that Sonarr/Radarr still track.
  final bool? force;
  final bool? confirm;

  JsonMap toJson() => compactJson({
    'hashes': hashes,
    'action': action.toJson(),
    'deleteFiles': deleteFiles,
    'category': category,
    'tags': tags,
    'force': force,
    'confirm': confirm,
  });
}

/// One torrent of a `409 managed_by_arr` answer (`details.items`).
@immutable
final class TorrentManagedByArr {
  const TorrentManagedByArr({
    required this.hash,
    required this.service,
    required this.queueIds,
  });

  factory TorrentManagedByArr.fromJson(JsonMap j) => TorrentManagedByArr(
    hash: readString(j['hash']) ?? '',
    service: ArrService.fromJson(j['service']),
    queueIds: readIntList(j['queueIds']),
  );

  /// The entries of an error's `details` (empty when absent).
  static List<TorrentManagedByArr> listFromDetails(JsonMap? details) =>
      readList(details?['items'], TorrentManagedByArr.fromJson);

  final String hash;
  final ArrService service;
  final List<int> queueIds;

  JsonMap toJson() => {
    'hash': hash,
    'service': service.toJson(),
    'queueIds': queueIds,
  };
}

/// Body of `POST /torrents/add`: magnet/http(s) URLs and/or `.torrent`
/// files (base64).
@immutable
final class TorrentAddRequest {
  const TorrentAddRequest({
    this.urls = const [],
    this.torrentFilesBase64 = const [],
    this.category,
    this.tags = const [],
    this.stopped,
  });

  factory TorrentAddRequest.fromJson(JsonMap j) => TorrentAddRequest(
    urls: readStringList(j['urls']),
    torrentFilesBase64: readStringList(j['torrentFilesBase64']),
    category: readString(j['category']),
    tags: readStringList(j['tags']),
    stopped: readBool(j['stopped']),
  );

  final List<String> urls;
  final List<String> torrentFilesBase64;

  /// Defaults to `manual` in the gateway.
  final String? category;
  final List<String> tags;

  /// Add without starting.
  final bool? stopped;

  JsonMap toJson() => compactJson({
    'urls': urls.isEmpty ? null : urls,
    'torrentFilesBase64': torrentFilesBase64.isEmpty
        ? null
        : torrentFilesBase64,
    'category': category,
    'tags': tags.isEmpty ? null : tags,
    'stopped': stopped,
  });
}

/// A qBittorrent category.
@immutable
final class TorrentCategory {
  const TorrentCategory({
    required this.name,
    this.savePath,
    this.readOnly = false,
  });

  factory TorrentCategory.fromJson(JsonMap j) => TorrentCategory(
    name: req(readString(j['name']), 'name'),
    savePath: readString(j['savePath']),
    readOnly: readBool(j['readOnly']) ?? false,
  );

  final String name;

  /// Null = the default save path.
  final String? savePath;

  /// Owned by Sonarr/Radarr/Lidarr/books: never renamed or deleted, and not
  /// offered when adding a torrent.
  final bool readOnly;

  JsonMap toJson() =>
      compactJson({'name': name, 'savePath': savePath, 'readOnly': readOnly});
}

/// `GET /transfer/categories`.
@immutable
final class CategoryList {
  const CategoryList({this.categories = const [], this.tags = const []});

  factory CategoryList.fromJson(JsonMap j) => CategoryList(
    categories: readList(j['categories'], TorrentCategory.fromJson),
    tags: readStringList(j['tags']),
  );

  final List<TorrentCategory> categories;
  final List<String> tags;

  JsonMap toJson() => {
    'categories': [for (final c in categories) c.toJson()],
    'tags': tags,
  };
}

// ---------------------------------------------------------------------------
// VPN (API.md §8.6)
// ---------------------------------------------------------------------------

/// Overall VPN state.
enum VpnConnectionState {
  connected,
  degraded,
  down,
  unknown;

  static VpnConnectionState fromJson(Object? v) =>
      readEnum(v, VpnConnectionState.values, VpnConnectionState.unknown);

  String toJson() => name;
}

/// Docker health of the gluetun container.
enum VpnGluetunHealth {
  healthy,
  unhealthy,
  starting,
  none,
  unknown;

  static VpnGluetunHealth fromJson(Object? v) =>
      readEnum(v, VpnGluetunHealth.values, VpnGluetunHealth.unknown);

  String toJson() => name;
}

/// `GET /vpn`.
@immutable
final class VpnStatus {
  const VpnStatus({
    required this.status,
    required this.portInSync,
    required this.qbitConnection,
    required this.gluetunHealth,
    required this.checkedAt,
    this.publicIp,
    this.country,
    this.region,
    this.city,
    this.organization,
    this.forwardedPort,
    this.listenPort,
  });

  factory VpnStatus.fromJson(JsonMap j) => VpnStatus(
    status: VpnConnectionState.fromJson(j['status']),
    publicIp: readString(j['publicIp']),
    country: readString(j['country']),
    region: readString(j['region']),
    city: readString(j['city']),
    organization: readString(j['organization']),
    forwardedPort: readInt(j['forwardedPort']),
    listenPort: readInt(j['listenPort']),
    portInSync: readBool(j['portInSync']) ?? false,
    qbitConnection: readString(j['qbitConnection']) ?? 'unknown',
    gluetunHealth: VpnGluetunHealth.fromJson(j['gluetunHealth']),
    checkedAt: req(readInstant(j['checkedAt']), 'checkedAt'),
  );

  final VpnConnectionState status;

  /// The VPN exit address.
  final String? publicIp;
  final String? country;
  final String? region;
  final String? city;
  final String? organization;

  /// Gluetun's forwarded port (null while none is assigned).
  final int? forwardedPort;

  /// qBittorrent's `listen_port`.
  final int? listenPort;
  final bool portInSync;

  /// qBittorrent's `connection_status`.
  final String qbitConnection;
  final VpnGluetunHealth gluetunHealth;
  final DateTime checkedAt;

  JsonMap toJson() => compactJson({
    'status': status.toJson(),
    'publicIp': publicIp,
    'country': country,
    'region': region,
    'city': city,
    'organization': organization,
    'forwardedPort': forwardedPort,
    'listenPort': listenPort,
    'portInSync': portInSync,
    'qbitConnection': qbitConnection,
    'gluetunHealth': gluetunHealth.toJson(),
    'checkedAt': instantToJson(checkedAt),
  });
}

// ---------------------------------------------------------------------------
// Dashboard card (API.md §8.9)
// ---------------------------------------------------------------------------

/// The transfer line of the [ActivityCard].
@immutable
final class ActivityCardTransfer {
  const ActivityCardTransfer({
    this.dlBps = 0,
    this.upBps = 0,
    this.altSpeedEnabled = false,
    this.connectionStatus = TransferConnectionStatus.unknown,
  });

  factory ActivityCardTransfer.fromJson(JsonMap j) => ActivityCardTransfer(
    dlBps: readInt(j['dlBps']) ?? 0,
    upBps: readInt(j['upBps']) ?? 0,
    altSpeedEnabled: readBool(j['altSpeedEnabled']) ?? false,
    connectionStatus: TransferConnectionStatus.fromJson(j['connectionStatus']),
  );

  final int dlBps;
  final int upBps;
  final bool altSpeedEnabled;
  final TransferConnectionStatus connectionStatus;

  JsonMap toJson() => {
    'dlBps': dlBps,
    'upBps': upBps,
    'altSpeedEnabled': altSpeedEnabled,
    'connectionStatus': connectionStatus.toJson(),
  };
}

/// Counters of the [ActivityCard]. `attention` is also read raw by the
/// app's Activity badge (`cards.activity.data.counts.attention`).
@immutable
final class ActivityCardCounts {
  const ActivityCardCounts({
    this.downloading = 0,
    this.seeding = 0,
    this.stalled = 0,
    this.attention = 0,
  });

  factory ActivityCardCounts.fromJson(JsonMap j) => ActivityCardCounts(
    downloading: readInt(j['downloading']) ?? 0,
    seeding: readInt(j['seeding']) ?? 0,
    stalled: readInt(j['stalled']) ?? 0,
    attention: readInt(j['attention']) ?? 0,
  );

  final int downloading;
  final int seeding;
  final int stalled;
  final int attention;

  JsonMap toJson() => {
    'downloading': downloading,
    'seeding': seeding,
    'stalled': stalled,
    'attention': attention,
  };
}

/// The `activity` dashboard card.
@immutable
final class ActivityCard {
  const ActivityCard({
    this.transfer = const ActivityCardTransfer(),
    this.counts = const ActivityCardCounts(),
    this.top = const [],
    this.vpn,
  });

  factory ActivityCard.fromJson(JsonMap j) => ActivityCard(
    transfer: ActivityCardTransfer.fromJson(readMap(j['transfer']) ?? const {}),
    counts: ActivityCardCounts.fromJson(readMap(j['counts']) ?? const {}),
    top: readList(j['top'], QueueItem.fromJson),
    vpn: switch (readMap(j['vpn'])) {
      final m? => VpnStatus.fromJson(m),
      null => null,
    },
  );

  final ActivityCardTransfer transfer;
  final ActivityCardCounts counts;

  /// At most 3 queue items: attention first, then by ETA.
  final List<QueueItem> top;

  /// Absent when the VPN status could not be read.
  final VpnStatus? vpn;

  JsonMap toJson() => compactJson({
    'transfer': transfer.toJson(),
    'counts': counts.toJson(),
    'top': [for (final t in top) t.toJson()],
    'vpn': vpn?.toJson(),
  });
}
