/// Which torrents with qBittorrent's `has_tracker_error` flag still have a
/// working tracker (issue #1).
///
/// qBittorrent sets the flag when any one tracker is in status 5, so a
/// torrent with one dead tracker out of many healthy ones looked broken. The
/// maindata snapshot cannot tell more (its `tracker` field falls back to the
/// first tracker's URL in 5.x), so only the flagged torrents' tracker lists
/// are read, cached, and refreshed in the background.
library;

import 'dart:async';
import 'dart:collection';

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'maindata.dart';
import 'qbit_mapping.dart';

/// How long a torrent's tracker verdict is used before it is re-read
/// (trackers announce every 30 min or so).
const trackerHealthTtl = Duration(minutes: 2);

/// Retry delay after a failed tracker read.
const trackerHealthRetry = Duration(seconds: 15);

/// How long a read waits for the tracker lists of newly flagged torrents
/// before it falls back to the flag.
const trackerHealthWait = Duration(seconds: 2);

/// Tracker lists read at once.
const trackerHealthConcurrency = 4;

final class _Verdict {
  const _Verdict(this.working, this.expiresAt);

  /// Null when the read failed (the flag stands).
  final bool? working;
  final DateTime expiresAt;
}

/// Tracker verdicts of the flagged torrents.
final class TrackerHealth {
  TrackerHealth(this._ctx);

  final FeatureContext _ctx;
  final _verdicts = <String, _Verdict>{};
  final _inflight = <String, Future<void>>{};
  final _waiting = Queue<Completer<void>>();
  int _running = 0;

  /// The hashes of [view] that qBittorrent flags with a tracker error but
  /// that have a working tracker. A torrent seen flagged for the first time
  /// waits for its tracker list (at most [trackerHealthWait], then the flag
  /// stands); expired verdicts are used while they are re-read.
  Future<Set<String>> trackerWorking(QbitView view) async {
    final flagged = view.trackerErrorFlagged().toSet();
    _verdicts.removeWhere((h, _) => !flagged.contains(h));
    final now = _ctx.clock.now();
    final first = <Future<void>>[];
    for (final h in flagged) {
      final v = _verdicts[h];
      if (v != null && now.isBefore(v.expiresAt)) continue;
      final load = _load(h);
      if (v == null) first.add(load);
    }
    if (first.isNotEmpty) {
      try {
        await Future.wait(first).timeout(trackerHealthWait);
      } on TimeoutException {
        // The rest keep loading for the next read.
      }
    }
    return {
      for (final h in flagged)
        if (_verdicts[h]?.working ?? false) h,
    };
  }

  /// Records a tracker list read elsewhere (the detail route).
  void record(String hash, List<TrackerInfo> trackers) {
    _verdicts[hash] = _Verdict(
      anyTrackerWorking(trackers),
      _ctx.clock.now().add(trackerHealthTtl),
    );
  }

  Future<void> _load(String hash) {
    final running = _inflight[hash];
    if (running != null) return running;
    final future = () async {
      await _acquire();
      try {
        final body = await _ctx.upstreams.qbittorrent.getJson(
          '/api/v2/torrents/trackers',
          query: {'hash': hash},
        );
        record(
          hash,
          trackersOf([
            for (final r in body is List ? body : const <Object?>[])
              ?readMap(r),
          ]),
        );
      } catch (_) {
        // Keep the last verdict (none: the flag stands) and retry soon.
        _verdicts[hash] = _Verdict(
          _verdicts[hash]?.working,
          _ctx.clock.now().add(trackerHealthRetry),
        );
      } finally {
        _release();
      }
    }();
    _inflight[hash] = future;
    return future.whenComplete(() {
      if (identical(_inflight[hash], future)) _inflight.remove(hash);
    });
  }

  Future<void> _acquire() async {
    if (_running < trackerHealthConcurrency) {
      _running++;
      return;
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    await turn.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _running--;
    }
  }
}
