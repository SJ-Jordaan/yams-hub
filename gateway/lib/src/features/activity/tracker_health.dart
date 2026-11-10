/// Which torrents with qBittorrent's `has_tracker_error` flag still have a
/// working tracker (issue #1).
///
/// qBittorrent sets the flag when any one tracker is in status 5, so a
/// torrent with one dead tracker out of many healthy ones looked broken. The
/// maindata snapshot cannot tell more (its `tracker` field falls back to the
/// first tracker's URL in 5.x), so only the flagged torrents' tracker lists
/// are read, cached, and refreshed in the background.
///
/// qBittorrent reports a tracker as "updating" while any of its endpoints
/// announces, even when it works, and "not contacted" before its first
/// announce. A list with no working tracker but such a tracker is pending:
/// the flag is held back and the list re-read after [trackerHealthRetry],
/// and only a list that stays without a working tracker for
/// [trackerHealthPendingLimit] counts as an error.
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

/// How long a tracker list may stay pending (no working tracker, but one is
/// updating or not contacted yet) before the flag stands.
const trackerHealthPendingLimit = Duration(minutes: 2);

/// What a torrent's tracker list says about qBittorrent's tracker error flag.
enum TrackerListHealth {
  /// A tracker works: the flag does not stand.
  working,

  /// None works yet, but one is updating or not contacted: undecided.
  pending,

  /// Every tracker is disabled or failing: the flag stands.
  failing;

  static TrackerListHealth of(Iterable<TrackerInfo> trackers) {
    if (anyTrackerWorking(trackers)) return working;
    final busy = trackers.any(
      (t) =>
          t.status == TrackerInfoStatus.updating ||
          t.status == TrackerInfoStatus.notContacted,
    );
    return busy ? pending : failing;
  }
}

final class _Verdict {
  const _Verdict(this.clear, this.expiresAt, {this.pendingSince});

  /// Whether the flag is held back; null when the read failed (the flag
  /// stands).
  final bool? clear;
  final DateTime expiresAt;

  /// Since when the tracker list has been pending (null: not pending).
  final DateTime? pendingSince;
}

/// Tracker verdicts of the flagged torrents.
final class TrackerHealth {
  TrackerHealth(this._ctx);

  final FeatureContext _ctx;
  final _verdicts = <String, _Verdict>{};
  final _inflight = <String, Future<void>>{};

  /// Reads of newly flagged torrents, served before [_waiting].
  final _urgent = Queue<Completer<void>>();
  final _waiting = Queue<Completer<void>>();
  int _running = 0;

  /// The hashes of [view] that qBittorrent flags with a tracker error but
  /// whose tracker list has a working tracker (or is still pending). A
  /// torrent seen flagged for the first time waits for its tracker list (at
  /// most [trackerHealthWait], then the flag stands); expired verdicts are
  /// used while they are re-read.
  Future<Set<String>> trackerWorking(QbitView view) async {
    final flagged = view.trackerErrorFlagged().toSet();
    final now = _ctx.clock.now();
    // qBittorrent drops the flag while the failing tracker re-announces, so
    // verdicts of unflagged torrents are kept a while for when it returns.
    _verdicts.removeWhere(
      (h, v) =>
          !flagged.contains(h) &&
          !now.isBefore(v.expiresAt.add(trackerHealthTtl)),
    );
    final first = <Future<void>>[];
    for (final h in flagged) {
      final v = _verdicts[h];
      if (v != null && now.isBefore(v.expiresAt)) continue;
      final load = _load(h, urgent: v == null);
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
        if (_verdicts[h]?.clear ?? false) h,
    };
  }

  /// Records a tracker list (also read by the detail route) and returns
  /// whether the flag is held back.
  bool record(String hash, List<TrackerInfo> trackers) {
    final now = _ctx.clock.now();
    final v = switch (TrackerListHealth.of(trackers)) {
      TrackerListHealth.working => _Verdict(true, now.add(trackerHealthTtl)),
      TrackerListHealth.failing => _Verdict(false, now.add(trackerHealthTtl)),
      TrackerListHealth.pending => () {
        final since = _verdicts[hash]?.pendingSince ?? now;
        final settled = !now.isBefore(since.add(trackerHealthPendingLimit));
        return _Verdict(
          !settled,
          now.add(settled ? trackerHealthTtl : trackerHealthRetry),
          pendingSince: since,
        );
      }(),
    };
    _verdicts[hash] = v;
    return v.clear!;
  }

  Future<void> _load(String hash, {bool urgent = false}) {
    final running = _inflight[hash];
    if (running != null) return running;
    final future = () async {
      await _acquire(urgent: urgent);
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
        final last = _verdicts[hash];
        _verdicts[hash] = _Verdict(
          last?.clear,
          _ctx.clock.now().add(trackerHealthRetry),
          pendingSince: last?.pendingSince,
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

  Future<void> _acquire({required bool urgent}) async {
    if (_running < trackerHealthConcurrency) {
      _running++;
      return;
    }
    final turn = Completer<void>();
    (urgent ? _urgent : _waiting).add(turn);
    await turn.future;
  }

  void _release() {
    if (_urgent.isNotEmpty) {
      _urgent.removeFirst().complete();
    } else if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _running--;
    }
  }
}
