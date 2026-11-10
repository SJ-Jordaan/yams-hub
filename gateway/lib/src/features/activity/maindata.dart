/// The gateway's single qBittorrent `sync/maindata` poller (API.md §8,
/// ARCHITECTURE §5.7): 1.5 s interval, 20 s lease, deltas merged into one
/// in-memory snapshot the way the WebUI's `client.js` does.
library;

import 'dart:async';

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'qbit_mapping.dart';

/// How long the first read after idle waits for a fresh tick.
const maindataFirstTickWait = Duration(seconds: 3);

/// A read of the snapshot.
final class QbitView {
  const QbitView({
    required this.torrents,
    required this.serverState,
    required this.categories,
    required this.tags,
    required this.updatedAt,
    required this.stale,
  });

  /// Raw torrents keyed by lower-case hash.
  final Map<String, JsonMap> torrents;
  final JsonMap serverState;

  /// Raw categories keyed by name.
  final Map<String, JsonMap> categories;
  final List<String> tags;
  final DateTime updatedAt;

  /// The last tick failed (or the first tick did not answer in time).
  final bool stale;

  /// Hashes qBittorrent flags with `has_tracker_error`.
  Iterable<String> trackerErrorFlagged() => [
    for (final e in torrents.entries)
      if (qbitTrackerErrorFlag(e.value)) e.key,
  ];

  /// Mapped torrents (incomplete delta entries are skipped). [trackerWorking]:
  /// flagged hashes that still have a working tracker (TrackerHealth).
  List<TorrentSummary> summaries({Set<String> trackerWorking = const {}}) => [
    for (final e in torrents.entries)
      ?torrentSummaryOf(
        e.key,
        e.value,
        trackerWorking: trackerWorking.contains(e.key),
      ),
  ];
}

/// Holds the merged maindata snapshot.
final class QbitMaindata {
  QbitMaindata(this._ctx) {
    _poller = _ctx.pollers.create(
      'activity.qbittorrent.maindata',
      const Duration(milliseconds: 1500),
      const Duration(seconds: 20),
      _tick,
    );
  }

  final FeatureContext _ctx;
  late final DemandPoller _poller;

  final _torrents = <String, JsonMap>{};
  final _categories = <String, JsonMap>{};
  final _tags = <String>{};
  JsonMap _serverState = {};
  int _rid = 0;
  int? _generation;
  bool _loaded = false;
  DateTime? _updatedAt;
  Object? _lastError;
  bool _loggedFailure = false;

  /// The tick in progress (a read before the first snapshot waits for it).
  Completer<void>? _ticking;

  UpstreamClient get _qbit => _ctx.upstreams.qbittorrent;

  /// Ticks run so far (tests).
  int get ticks => _poller.ticks;

  Future<void> _tick() async {
    final done = _ticking = Completer<void>();
    try {
      await _poll();
    } finally {
      done.complete();
      if (identical(_ticking, done)) _ticking = null;
    }
  }

  Future<void> _poll() async {
    final session = _ctx.upstreams.qbitSession;
    // rid is per cookie session: restart from 0 after a re-login.
    if (_generation != session.sessionGeneration) _rid = 0;
    try {
      final body = readMap(
        await _qbit.getJson('/api/v2/sync/maindata', query: {'rid': _rid}),
      );
      if (body == null) {
        throw UpstreamBadResponse(
          service: ServiceId.qbittorrent,
          method: 'GET',
          path: '/api/v2/sync/maindata',
          reason: 'maindata is not an object',
        );
      }
      apply(body);
      _generation = session.sessionGeneration;
      _lastError = null;
      _loggedFailure = false;
      _loaded = true;
      _updatedAt = _ctx.clock.now();
    } catch (e) {
      _lastError = e;
      if (!_loggedFailure) {
        _loggedFailure = true;
        _ctx.log.warning('qBittorrent maindata poll failed: $e');
      }
    }
  }

  /// Merges one maindata answer (full update or delta).
  void apply(JsonMap body) {
    final full = readBool(body['full_update']) ?? false;
    if (full) {
      _torrents.clear();
      _categories.clear();
      _tags.clear();
      _serverState = {};
    }
    if (readMap(body['server_state']) case final s?) {
      _serverState = {..._serverState, ...s};
    }
    if (readMap(body['torrents']) case final ts?) {
      for (final e in ts.entries) {
        final patch = readMap(e.value);
        if (patch == null) continue;
        final key = e.key.toLowerCase();
        _torrents[key] = {...?_torrents[key], ...patch};
      }
    }
    if (readMap(body['categories']) case final cs?) {
      for (final e in cs.entries) {
        final patch = readMap(e.value);
        if (patch == null) continue;
        _categories[e.key] = {...?_categories[e.key], ...patch};
      }
    }
    for (final t in readStringList(body['tags'])) {
      _tags.add(t);
    }
    for (final h in readStringList(body['torrents_removed'])) {
      _torrents.remove(h.toLowerCase());
    }
    for (final c in readStringList(body['categories_removed'])) {
      _categories.remove(c);
    }
    for (final t in readStringList(body['tags_removed'])) {
      _tags.remove(t);
    }
    _rid = readInt(body['rid']) ?? _rid;
  }

  /// Touches the lease and returns the snapshot. When the poller was idle
  /// this waits for one fresh tick (at most 3 s, then the last snapshot is
  /// returned with `stale: true`). Throws the last failure when there has
  /// never been a snapshot.
  Future<QbitView> read() async {
    var timedOut = false;
    try {
      final touch = _poller.touch();
      final pending = _ticking?.future;
      await Future.wait([touch, if (!_loaded && pending != null) pending])
          .timeout(maindataFirstTickWait);
    } on TimeoutException {
      timedOut = true;
    }
    if (!_loaded) {
      final e = _lastError;
      // The gateway route did not address a qBittorrent resource: an
      // upstream 404 is a 502 here.
      if (e is UpstreamException) {
        throw e.toApiException(resourceNotFound: false);
      }
      if (e != null) throw e;
      throw UpstreamTimeout(
        service: ServiceId.qbittorrent,
        method: 'GET',
        path: '/api/v2/sync/maindata',
      );
    }
    return view(stale: timedOut || _lastError != null);
  }

  /// The current snapshot without touching the lease (null before the first
  /// successful tick).
  QbitView? peek() => _loaded ? view(stale: _lastError != null) : null;

  QbitView view({required bool stale}) => QbitView(
    torrents: Map.unmodifiable(_torrents),
    serverState: Map.unmodifiable(_serverState),
    categories: Map.unmodifiable(_categories),
    tags: List.unmodifiable(_tags),
    updatedAt: _updatedAt ?? _ctx.clock.now(),
    stale: stale,
  );

  /// Runs a tick now (after a write) and waits for it (at most 2 s).
  Future<void> refresh() async {
    try {
      await _poller.runNow().timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // The tick continues in the background.
    }
  }

  void stop() => _poller.stop();
}
