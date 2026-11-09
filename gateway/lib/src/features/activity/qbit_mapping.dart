/// qBittorrent → activity DTO mapping (integrations/downloads.md §1).
///
/// Pure functions over the raw qBittorrent JSON so they can be tested against
/// the fixtures without a hub.
library;

import 'package:yams_hub_gateway/src/core/log/redact.dart';
import 'package:yams_models/yams_models.dart';

/// qBittorrent's "infinite" ETA.
const qbitEtaInfinity = 8640000;

/// Categories owned by Sonarr/Radarr/Lidarr/books: never renamed or deleted
/// from the hub and marked read-only (downloads.md §1.9).
const readOnlyCategories = {'tv-sonarr', 'radarr', 'lidarr', 'books'};

/// The tag decluttarr honours ("Protect").
const protectTag = 'Keep';

/// Maps a raw qBittorrent v5 state (downloads.md §1.6).
TorrentState torrentStateOf(String raw) => switch (raw) {
  'downloading' || 'forcedDL' => TorrentState.downloading,
  'metaDL' || 'forcedMetaDL' => TorrentState.metadata,
  'uploading' || 'forcedUP' => TorrentState.seeding,
  'stalledDL' || 'stalledUP' => TorrentState.stalled,
  'stoppedDL' ||
  'stoppedUP' ||
  'pausedDL' ||
  'pausedUP' => TorrentState.stopped,
  'queuedDL' || 'queuedUP' => TorrentState.queued,
  'checkingDL' ||
  'checkingUP' ||
  'queuedForChecking' ||
  'checkingResumeData' => TorrentState.checking,
  'moving' => TorrentState.moving,
  'error' || 'missingFiles' || 'unknown' => TorrentState.error,
  _ => TorrentState.unknown,
};

/// `download` for `*DL`/`downloading`/`metaDL`, `upload` for
/// `*UP`/`uploading`; other states (moving, error) go by [progress].
TorrentDirection torrentDirectionOf(String raw, double progress) {
  if (raw == 'downloading' || raw.endsWith('DL')) {
    return TorrentDirection.download;
  }
  if (raw == 'uploading' || raw.endsWith('UP')) return TorrentDirection.upload;
  return progress >= 1 ? TorrentDirection.upload : TorrentDirection.download;
}

/// The *arr that owns a category.
ArrService? managedByOf(String? category) => switch (category) {
  'tv-sonarr' => ArrService.sonarr,
  'radarr' => ArrService.radarr,
  _ => null,
};

/// Unix seconds → instant; `-1`/`0` (never) → null.
DateTime? qbitTime(Object? v) {
  final s = readInt(v);
  if (s == null || s <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true);
}

/// Splits qBittorrent's comma-separated `tags` string.
List<String> splitQbitTags(Object? v) => [
  for (final t in (readString(v) ?? '').split(','))
    if (t.trim().isNotEmpty) t.trim(),
];

double _round3(double v) => (v * 1000).round() / 1000;

/// qBittorrent's `has_tracker_error` (maindata only): set when any one
/// tracker of the torrent is in status 5, even if others work.
bool qbitTrackerErrorFlag(JsonMap t) =>
    readBool(t['has_tracker_error']) ?? false;

/// Maps a torrent of the maindata snapshot (or `torrents/info`); null when
/// the entry is incomplete (a delta for a torrent the snapshot never saw).
///
/// [trackerWorking]: another tracker of the torrent works, so
/// qBittorrent's tracker-error flag is not an error (issue #1). The `tracker`
/// field cannot tell: qBittorrent 5.x falls back to the first tracker's URL
/// and libtorrent keeps the last tracker that ever worked.
TorrentSummary? torrentSummaryOf(
  String hash,
  JsonMap t, {
  bool trackerWorking = false,
}) {
  final name = readString(t['name']);
  final raw = readString(t['state']);
  if (name == null || raw == null) return null;
  final progress = (readDouble(t['progress']) ?? 0).clamp(0.0, 1.0);
  final eta = readInt(t['eta']);
  final category = readString(t['category']);
  final tags = splitQbitTags(t['tags']);
  final priority = readInt(t['priority']);
  return TorrentSummary(
    hash: hash.toLowerCase(),
    name: name,
    state: torrentStateOf(raw),
    stateRaw: raw,
    direction: torrentDirectionOf(raw, progress),
    progress: progress,
    sizeBytes: readInt(t['size']) ?? readInt(t['total_size']) ?? 0,
    downloadedBytes: readInt(t['downloaded']) ?? 0,
    uploadedBytes: readInt(t['uploaded']) ?? 0,
    amountLeftBytes: readInt(t['amount_left']) ?? 0,
    dlBps: readInt(t['dlspeed']) ?? 0,
    upBps: readInt(t['upspeed']) ?? 0,
    etaSeconds: (eta == null || eta < 0 || eta >= qbitEtaInfinity) ? null : eta,
    ratio: _round3(readDouble(t['ratio']) ?? 0),
    seeds: readInt(t['num_seeds']) ?? 0,
    peers: readInt(t['num_leechs']) ?? 0,
    category: (category == null || category.isEmpty) ? null : category,
    tags: tags,
    addedAt:
        qbitTime(t['added_on']) ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    completedAt: qbitTime(t['completion_on']),
    lastActivityAt: qbitTime(t['last_activity']),
    forceStart: readBool(t['force_start']) ?? false,
    queuePosition: (priority == null || priority <= 0) ? null : priority,
    hasTrackerError: qbitTrackerErrorFlag(t) && !trackerWorking,
    hasTrackerWarning: readBool(t['has_tracker_warning']) ?? false,
    protected: tags.contains(protectTag),
    managedBy: managedByOf(category),
  );
}

/// The `torrents/properties` fields as a torrent map, for a torrent that is
/// not (yet) in the maindata snapshot.
/// The state is left empty (→ [TorrentState.unknown]): qBittorrent's own
/// `unknown` state means an error.
JsonMap torrentFromProperties(JsonMap p) => {
  'name': p['name'],
  'state': '',
  'progress': p['progress'],
  'size': p['total_size'],
  'downloaded': p['total_downloaded'],
  'uploaded': p['total_uploaded'],
  'amount_left': null,
  'dlspeed': p['dl_speed'],
  'upspeed': p['up_speed'],
  'eta': p['eta'],
  'ratio': p['share_ratio'],
  'num_seeds': p['seeds'],
  'num_leechs': p['peers'],
  'added_on': p['addition_date'],
  'completion_on': p['completion_date'],
  'last_activity': p['last_seen'],
};

/// `GET /torrents?filter=` values (validated by the gateway: qBittorrent
/// silently ignores unknown ones).
const torrentFilters = [
  'all',
  'downloading',
  'seeding',
  'completed',
  'stopped',
  'running',
  'active',
  'inactive',
  'stalled',
  'checking',
  'errored',
];

const _seedingStates = {
  'uploading',
  'forcedUP',
  'stalledUP',
  'queuedUP',
  'checkingUP',
};

/// qBittorrent's `seeding` filter.
bool isSeedingState(String raw) => _seedingStates.contains(raw);

/// The WebUI's `applyFilter` semantics (downloads.md §1.4).
bool torrentMatchesFilter(String filter, TorrentSummary t) {
  final raw = t.stateRaw;
  final stopped = raw.startsWith('stopped') || raw.startsWith('paused');
  final active = t.dlBps > 0 || t.upBps > 0;
  return switch (filter) {
    'downloading' => raw == 'downloading' || raw.contains('DL'),
    'seeding' => isSeedingState(raw),
    'completed' => raw.contains('UP') || raw == 'uploading',
    'stopped' => stopped,
    'running' => !stopped,
    'active' => active,
    'inactive' => !active,
    'stalled' => raw == 'stalledUP' || raw == 'stalledDL',
    'checking' =>
      raw == 'checkingUP' || raw == 'checkingDL' || raw == 'checkingResumeData',
    'errored' => raw == 'error' || raw == 'unknown' || raw == 'missingFiles',
    _ => true,
  };
}

/// `GET /torrents?sort=` values.
const torrentSorts = [
  'added',
  'name',
  'progress',
  'dlSpeed',
  'upSpeed',
  'eta',
  'ratio',
  'size',
];

/// Compares two torrents by [sort] (ascending).
int compareTorrents(String sort, TorrentSummary a, TorrentSummary b) {
  int byInt(int x, int y) => x.compareTo(y);
  return switch (sort) {
    'name' => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    'progress' => a.progress.compareTo(b.progress),
    'dlSpeed' => byInt(a.dlBps, b.dlBps),
    'upSpeed' => byInt(a.upBps, b.upBps),
    'eta' => byInt(
      a.etaSeconds ?? qbitEtaInfinity,
      b.etaSeconds ?? qbitEtaInfinity,
    ),
    'ratio' => a.ratio.compareTo(b.ratio),
    'size' => byInt(a.sizeBytes, b.sizeBytes),
    _ => a.addedAt.compareTo(b.addedAt),
  };
}

TransferConnectionStatus _connection(Object? v) => switch (readString(v)) {
  'connected' => TransferConnectionStatus.connected,
  'firewalled' => TransferConnectionStatus.firewalled,
  'disconnected' => TransferConnectionStatus.disconnected,
  _ => TransferConnectionStatus.unknown,
};

/// Builds [TransferState] from maindata `server_state`.
TransferState transferStateOf(
  JsonMap s, {
  required DateTime updatedAt,
  TransferLimits? limits,
  TransferSchedule? schedule,
  bool stale = false,
}) => TransferState(
  dlBps: readInt(s['dl_info_speed']) ?? 0,
  upBps: readInt(s['up_info_speed']) ?? 0,
  dlLimitBps: _limit(s['dl_rate_limit']),
  upLimitBps: _limit(s['up_rate_limit']),
  altSpeedEnabled: readBool(s['use_alt_speed_limits']) ?? false,
  limits: limits,
  schedule: schedule,
  connectionStatus: _connection(s['connection_status']),
  dhtNodes: readInt(s['dht_nodes']) ?? 0,
  freeSpaceBytes: readInt(s['free_space_on_disk']) ?? 0,
  sessionPaused: readBool(s['session_state']) ?? false,
  globalRatio: readDouble(s['global_ratio']) ?? 0,
  allTimeDownloadedBytes: readInt(s['alltime_dl']) ?? 0,
  allTimeUploadedBytes: readInt(s['alltime_ul']) ?? 0,
  sessionDownloadedBytes: readInt(s['dl_info_data']) ?? 0,
  sessionUploadedBytes: readInt(s['up_info_data']) ?? 0,
  updatedAt: updatedAt,
  stale: stale,
);

/// Limits use 0 for unlimited (`-1` from some endpoints too).
int _limit(Object? v) {
  final n = readInt(v) ?? 0;
  return n < 0 ? 0 : n;
}

/// `transfer/getSpeedLimits` → [TransferLimits].
TransferLimits transferLimitsOf(JsonMap j) => TransferLimits(
  dlBps: _limit(j['dl_limit']),
  upBps: _limit(j['up_limit']),
  altDlBps: _limit(j['alt_dl_limit']),
  altUpBps: _limit(j['alt_up_limit']),
);

/// The `app/preferences` keys the gateway keeps (the full object holds
/// secrets and never leaves the gateway; downloads.md §1.11).
const preferenceKeys = {
  'scheduler_enabled',
  'schedule_from_hour',
  'schedule_from_min',
  'schedule_to_hour',
  'schedule_to_min',
  'scheduler_days',
  'listen_port',
  'max_ratio',
  'max_ratio_enabled',
  'max_ratio_act',
  'max_seeding_time',
  'max_seeding_time_enabled',
  'max_inactive_seeding_time',
  'max_inactive_seeding_time_enabled',
};

/// Keeps only [preferenceKeys].
JsonMap whitelistPreferences(JsonMap prefs) => {
  for (final k in preferenceKeys)
    if (prefs.containsKey(k)) k: prefs[k],
};

String _hhmm(Object? h, Object? m) =>
    '${(readInt(h) ?? 0).toString().padLeft(2, '0')}:'
    '${(readInt(m) ?? 0).toString().padLeft(2, '0')}';

/// The alternative-speed schedule from whitelisted preferences.
TransferSchedule transferScheduleOf(JsonMap p) => TransferSchedule(
  enabled: readBool(p['scheduler_enabled']) ?? false,
  from: _hhmm(p['schedule_from_hour'], p['schedule_from_min']),
  to: _hhmm(p['schedule_to_hour'], p['schedule_to_min']),
  days: TransferScheduleDays.fromQbit(readInt(p['scheduler_days'])),
);

/// The global ratio limit (-1 = none).
double globalRatioLimit(JsonMap prefs) =>
    (readBool(prefs['max_ratio_enabled']) ?? false)
    ? (readDouble(prefs['max_ratio']) ?? -1)
    : -1;

/// The global seeding-time limit in minutes (-1 = none).
int globalSeedingMinutes(JsonMap prefs) =>
    (readBool(prefs['max_seeding_time_enabled']) ?? false)
    ? (readInt(prefs['max_seeding_time']) ?? -1)
    : -1;

/// Share limits of a snapshot torrent (`ratio_limit` etc.: -2 = global,
/// -1 = none).
ShareLimits shareLimitsOf(JsonMap t) {
  final ratio = readDouble(t['ratio_limit']) ?? -2;
  final seeding = readInt(t['seeding_time_limit']) ?? -2;
  final inactive = readInt(t['inactive_seeding_time_limit']) ?? -2;
  final ShareLimitsMode mode;
  if (ratio == -2 && seeding == -2 && inactive == -2) {
    mode = ShareLimitsMode.global;
  } else if (ratio == -1 && seeding == -1 && inactive == -1) {
    mode = ShareLimitsMode.unlimited;
  } else {
    mode = ShareLimitsMode.custom;
  }
  final action = ShareLimitsAction.fromQbit(t['share_limit_action']);
  final custom = mode == ShareLimitsMode.custom;
  return ShareLimits(
    mode: mode,
    ratio: custom && ratio >= 0 ? ratio : null,
    seedingMinutes: custom && seeding >= 0 ? seeding : null,
    inactiveMinutes: custom && inactive >= 0 ? inactive : null,
    action: action == ShareLimitsAction.unknown
        ? ShareLimitsAction.byDefault
        : action,
    effectiveRatio: readDouble(t['max_ratio']) ?? -1,
    effectiveSeedingMinutes: readInt(t['max_seeding_time']) ?? -1,
  );
}

/// `torrents/files` entry → [TorrentFile].
TorrentFile torrentFileOf(JsonMap f) {
  final availability = readDouble(f['availability']);
  return TorrentFile(
    index: readInt(f['index']) ?? 0,
    name: readString(f['name']) ?? '',
    sizeBytes: readInt(f['size']) ?? 0,
    progress: (readDouble(f['progress']) ?? 0).clamp(0.0, 1.0),
    priority: TorrentFilePriority.fromQbit(readInt(f['priority'])),
    availability: availability == null || availability < 0
        ? null
        : availability,
  );
}

/// Reduces a tracker URL to `scheme://host[:port]` (path and query dropped:
/// private announce URLs embed passkeys). Null when it is not a URL.
String? reduceTrackerUrl(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null || !u.hasScheme || u.host.isEmpty) return null;
  final host = u.host.contains(':') ? '[${u.host}]' : u.host;
  return u.hasPort ? '${u.scheme}://$host:${u.port}' : '${u.scheme}://$host';
}

int? _count(Object? v) {
  final n = readInt(v);
  return n == null || n < 0 ? null : n;
}

/// `torrents/trackers` → [TrackerInfo]s without the DHT/PeX/LSD rows and
/// without `endpoints[]`.
List<TrackerInfo> trackersOf(List<JsonMap> rows) => [
  for (final r in rows)
    if ((readInt(r['tier']) ?? 0) >= 0)
      if (reduceTrackerUrl(readString(r['url']) ?? '') case final url?)
        TrackerInfo(
          url: url,
          tier: readInt(r['tier']) ?? 0,
          status: TrackerInfoStatus.fromQbit(readInt(r['status'])),
          message: switch (readString(r['msg'])) {
            final m? when m.trim().isNotEmpty => redactSecrets(m.trim()),
            _ => null,
          },
          seeds: _count(r['num_seeds']),
          peers: _count(r['num_peers']),
          downloaded: _count(r['num_downloaded']),
        ),
];
