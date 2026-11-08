/// `$DATA/sessions.json` (ARCHITECTURE §5.4).
library;

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:yams_models/yams_models.dart';

import '../clock.dart';
import '../ids.dart';
import '../store/json_file_store.dart';
import 'records.dart';

final _log = Logger('core.auth.sessions');

/// Session ids: `s_<12 hex>`.
final sessionIdPattern = RegExp(r'^s_[0-9a-f]{12}$');

/// The session store. Structural changes (create, rotate, revoke) are written
/// before they return; `lastSeenAt`/`lastIp` updates are batched and written
/// at most once per [touchFlushInterval].
final class SessionStore {
  SessionStore(
    this._file,
    this._clock, {
    this.touchFlushInterval = const Duration(minutes: 1),
  }) {
    final doc = _file.read();
    final list = doc is Map ? doc['sessions'] : null;
    if (list is List) {
      final now = _clock.now();
      for (final e in list) {
        final m = readMap(e);
        if (m == null) continue;
        try {
          final s = SessionRecord.fromJson(m);
          if (!s.isExpired(now)) _byId[s.id] = s;
        } on FormatException catch (err) {
          _log.warning('skipping a malformed session record', err);
        }
      }
    }
  }

  final JsonFileStore _file;
  final Clock _clock;
  final Duration touchFlushInterval;
  final _byId = <String, SessionRecord>{};
  Timer? _touchTimer;
  bool _touchDirty = false;

  /// The live (unexpired) session [id], or null.
  SessionRecord? byId(String id) {
    final s = _byId[id];
    if (s == null) return null;
    if (s.isExpired(_clock.now())) {
      _byId.remove(id);
      return null;
    }
    return s;
  }

  /// Live sessions of [userId].
  List<SessionRecord> forUser(String userId) => [
    for (final s in _byId.values)
      if (s.userId == userId && !s.isExpired(_clock.now())) s,
  ];

  /// Every live session.
  List<SessionRecord> get all => [
    for (final s in _byId.values)
      if (!s.isExpired(_clock.now())) s,
  ];

  String newId() {
    while (true) {
      final id = 's_${randomHex(12)}';
      if (!_byId.containsKey(id)) return id;
    }
  }

  /// Adds or replaces [session] and writes the store.
  Future<void> put(SessionRecord session) async {
    _byId[session.id] = session;
    await _persist();
  }

  /// Writes the store after an in-place change of a session (rotation).
  Future<void> save() => _persist();

  /// Removes the sessions [ids]; returns the ones that existed.
  Future<List<SessionRecord>> removeAll(Iterable<String> ids) async {
    final removed = <SessionRecord>[];
    for (final id in ids) {
      final s = _byId.remove(id);
      if (s != null) removed.add(s);
    }
    if (removed.isNotEmpty) await _persist();
    return removed;
  }

  /// Records activity; written within [touchFlushInterval].
  void touch(SessionRecord s, String? ip) {
    final now = _clock.now();
    final changedIp = ip != null && ip != s.lastIp;
    if (!changedIp && now.difference(s.lastSeenAt) < touchFlushInterval) {
      return;
    }
    s.lastSeenAt = now;
    if (ip != null) s.lastIp = ip;
    _touchDirty = true;
    _touchTimer ??= Timer(touchFlushInterval, () {
      _touchTimer = null;
      if (_touchDirty) unawaited(_persist().catchError((Object _) {}));
    });
  }

  Future<void> flush() async {
    _touchTimer?.cancel();
    _touchTimer = null;
    if (_touchDirty) await _persist();
  }

  Future<void> _persist() {
    _touchDirty = false;
    final now = _clock.now();
    _byId.removeWhere((_, s) => s.isExpired(now));
    return _file.writeNow({
      'version': 1,
      'sessions': [for (final s in _byId.values) s.toJson()],
    });
  }
}
