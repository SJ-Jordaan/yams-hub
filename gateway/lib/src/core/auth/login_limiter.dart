/// Brute-force protection for logins and refreshes (ARCHITECTURE §5.4).
library;

import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';

import '../clock.dart';
import '../http/api_exception.dart';
import '../store/json_file_store.dart';

final _log = Logger('core.auth.limiter');

/// Remembers which IPs logged in successfully as which user (30 days, at most
/// 20 per user), stored in `known_ips.json`. Known IPs are exempt from the
/// per-username lockout.
final class KnownIps {
  KnownIps(this._file, this._clock) {
    final doc = _file.read();
    if (doc is Map) {
      for (final e in doc.entries) {
        final ips = e.value;
        if (e.key is! String || ips is! Map) continue;
        final m = <String, DateTime>{};
        for (final ip in ips.entries) {
          final at = ip.value is String
              ? DateTime.tryParse(ip.value as String)
              : null;
          if (ip.key is String && at != null) m[ip.key as String] = at.toUtc();
        }
        _byUser[e.key as String] = m;
      }
    }
  }

  static const maxPerUser = 20;
  static const retention = Duration(days: 30);

  final JsonFileStore _file;
  final Clock _clock;
  final _byUser = <String, Map<String, DateTime>>{};

  bool isKnown(String userId, String ip) {
    final at = _byUser[userId]?[ip];
    return at != null && _clock.now().difference(at) < retention;
  }

  void remember(String userId, String ip) {
    final now = _clock.now();
    final m = _byUser.putIfAbsent(userId, () => {});
    m[ip] = now;
    m.removeWhere((_, at) => now.difference(at) >= retention);
    while (m.length > maxPerUser) {
      final oldest = m.entries.reduce(
        (a, b) => a.value.isBefore(b.value) ? a : b,
      );
      m.remove(oldest.key);
    }
    _persist();
  }

  void forgetUser(String userId) {
    if (_byUser.remove(userId) != null) _persist();
  }

  void _persist() => _file.write({
    for (final e in _byUser.entries)
      e.key: {
        for (final ip in e.value.entries) ip.key: ip.value.toIso8601String(),
      },
  });
}

/// Failure timestamps of one bucket plus its lockout state.
final class _Bucket {
  final failures = <DateTime>[];
  DateTime? lockedUntil;
  int lockouts = 0;
  DateTime lastSeen = DateTime.utc(1970);

  void prune(DateTime now, Duration window) =>
      failures.removeWhere((t) => now.difference(t) >= window);
}

/// An attempt counted against the buckets before the password is hashed.
/// Call exactly one of [succeeded] or [failed].
final class LoginAttempt {
  LoginAttempt._(
    this._limiter,
    this.username,
    this.ip,
    this._stamp, {
    required this._countedIp,
    required this._countedUser,
  });

  final LoginLimiter _limiter;
  final String username;
  final String ip;
  final DateTime _stamp;

  /// Which shared buckets this attempt was counted in (refunds must only
  /// touch those, or they would remove another attempt's failure).
  final bool _countedIp;
  final bool _countedUser;
  bool _done = false;

  /// Refunds the counted failure and resets the pair counter.
  void succeeded(String userId) {
    if (_done) return;
    _done = true;
    _limiter._succeeded(this, userId);
  }

  /// The verification did not run (busy gate, error): refunds the counted
  /// failure without resetting anything.
  void cancel() {
    if (_done) return;
    _done = true;
    _limiter._cancel(this);
  }

  /// Keeps the counted failure. Returns true when this failure locked a
  /// bucket.
  bool failed() {
    if (_done) return false;
    _done = true;
    return _limiter._failed(this);
  }
}

/// In-memory login limiter.
///
/// - per `(username, ip)`: 5 failures in 15 min lock the pair for 15 min,
///   doubling on each further lockout (max 24 h);
/// - per `ip`: 20 failures in 1 h lock the IP for 1 h (skipped for loopback
///   and Docker bridge gateways, where client IPs collapse);
/// - per `username`: 50 failures in 1 h lock the name for 1 h, except for IPs
///   that logged in successfully as that user in the last 30 days.
final class LoginLimiter {
  LoginLimiter(this._clock, this._knownIps);

  final Clock _clock;
  final KnownIps _knownIps;

  static const pairLimit = 5;
  static const pairWindow = Duration(minutes: 15);
  static const pairBaseLock = Duration(minutes: 15);
  static const pairMaxLock = Duration(hours: 24);
  static const ipLimit = 20;
  static const ipWindow = Duration(hours: 1);
  static const ipLock = Duration(hours: 1);
  static const userLimit = 50;
  static const userWindow = Duration(hours: 1);
  static const userLock = Duration(hours: 1);
  static const refreshLimit = 30;
  static const refreshWindow = Duration(minutes: 1);

  final _pairs = <String, _Bucket>{};
  final _ips = <String, _Bucket>{};
  final _users = <String, _Bucket>{};
  final _refresh = <String, List<DateTime>>{};
  bool _warnedCollapsedIp = false;
  int _ops = 0;

  /// Whether [ip] is loopback or a Docker bridge gateway (`172.16.0.0/12`
  /// ending in `.1`), where per-IP accounting is meaningless.
  static bool isCollapsedIp(String ip) {
    final a = InternetAddress.tryParse(ip);
    if (a == null) return false;
    if (a.isLoopback) return true;
    if (a.type != InternetAddressType.IPv4) return false;
    final b = a.rawAddress;
    return b[0] == 172 && b[1] >= 16 && b[1] <= 31 && b[3] == 1;
  }

  /// Counts an attempt before hashing. Throws `429 rate_limited` (with
  /// `Retry-After`) when a bucket is locked or already full of in-flight and
  /// recent failures. [userId] is the account [username] names, if any (for
  /// the known-IP exemption).
  LoginAttempt begin(String username, String ip, {String? userId}) {
    final now = _clock.now();
    if (++_ops % 512 == 0) _gc(now);
    final skipIp = isCollapsedIp(ip);
    if (skipIp && !_warnedCollapsedIp) {
      _warnedCollapsedIp = true;
      _log.warning(
        'client IPs collapse to the bridge gateway ($ip); use the IPv4-only '
        'port binding. Per-IP login limits are skipped for this address.',
      );
    }
    final knownIp = userId != null && _knownIps.isKnown(userId, ip);

    final pair = _pairs.putIfAbsent('$username\u0000$ip', _Bucket.new);
    final ipBucket = skipIp ? null : _ips.putIfAbsent(ip, _Bucket.new);
    final userBucket = knownIp
        ? null
        : _users.putIfAbsent(username, _Bucket.new);

    _check(pair, now, pairWindow, pairLimit);
    if (ipBucket != null) _check(ipBucket, now, ipWindow, ipLimit);
    if (userBucket != null) _check(userBucket, now, userWindow, userLimit);

    pair.failures.add(now);
    ipBucket?.failures.add(now);
    // Known IPs neither count against nor are blocked by the username bucket.
    if (userBucket != null) userBucket.failures.add(now);
    for (final b in [pair, ?ipBucket, ?userBucket]) {
      b.lastSeen = now;
    }
    return LoginAttempt._(
      this,
      username,
      ip,
      now,
      countedIp: ipBucket != null,
      countedUser: userBucket != null,
    );
  }

  void _check(_Bucket b, DateTime now, Duration window, int limit) {
    final locked = b.lockedUntil;
    if (locked != null && now.isBefore(locked)) {
      throw ApiException.rateLimited(_seconds(locked.difference(now)));
    }
    b.prune(now, window);
    if (b.failures.length >= limit) {
      // Attempts still in flight fill the bucket; they resolve within seconds.
      throw ApiException.rateLimited(5);
    }
  }

  void _succeeded(LoginAttempt a, String userId) {
    final pair = _pairs['${a.username}\u0000${a.ip}'];
    if (pair != null) {
      pair.failures.clear();
      pair.lockouts = 0;
      pair.lockedUntil = null;
    }
    if (a._countedIp) _refund(_ips[a.ip], a._stamp);
    if (a._countedUser) _refund(_users[a.username], a._stamp);
    _knownIps.remember(userId, a.ip);
  }

  void _cancel(LoginAttempt a) {
    _refund(_pairs['${a.username}\u0000${a.ip}'], a._stamp);
    if (a._countedIp) _refund(_ips[a.ip], a._stamp);
    if (a._countedUser) _refund(_users[a.username], a._stamp);
  }

  /// Forgets the known IPs of a deleted user.
  void forgetUser(String userId) => _knownIps.forgetUser(userId);

  void _refund(_Bucket? b, DateTime stamp) {
    if (b == null) return;
    final i = b.failures.indexOf(stamp);
    if (i >= 0) b.failures.removeAt(i);
  }

  bool _failed(LoginAttempt a) {
    final now = _clock.now();
    var locked = false;
    final pair = _pairs['${a.username}\u0000${a.ip}'];
    if (pair != null) {
      pair.prune(now, pairWindow);
      if (pair.failures.length >= pairLimit) {
        final factor = pow(2, pair.lockouts).toInt();
        var d = pairBaseLock * factor;
        if (d > pairMaxLock) d = pairMaxLock;
        pair.lockouts++;
        pair.lockedUntil = now.add(d);
        pair.failures.clear();
        locked = true;
      }
    }
    final ip = a._countedIp ? _ips[a.ip] : null;
    if (ip != null) {
      ip.prune(now, ipWindow);
      if (ip.failures.length >= ipLimit) {
        ip.lockedUntil = now.add(ipLock);
        ip.failures.clear();
        locked = true;
      }
    }
    final user = a._countedUser ? _users[a.username] : null;
    if (user != null) {
      user.prune(now, userWindow);
      if (user.failures.length >= userLimit) {
        user.lockedUntil = now.add(userLock);
        user.failures.clear();
        locked = true;
      }
    }
    return locked;
  }

  /// Counts a refresh from [ip]; throws `429` beyond 30 per minute.
  void checkRefresh(String ip) {
    final now = _clock.now();
    final list = _refresh.putIfAbsent(ip, () => []);
    list.removeWhere((t) => now.difference(t) >= refreshWindow);
    if (list.length >= refreshLimit) {
      throw ApiException.rateLimited(
        _seconds(refreshWindow - now.difference(list.first)),
      );
    }
    list.add(now);
  }

  int _seconds(Duration d) => max(1, (d.inMilliseconds / 1000).ceil());

  void _gc(DateTime now) {
    bool stale(_Bucket b) =>
        (b.lockedUntil == null || !now.isBefore(b.lockedUntil!)) &&
        now.difference(b.lastSeen) > const Duration(hours: 25);
    _pairs.removeWhere((_, b) => stale(b));
    _ips.removeWhere((_, b) => stale(b));
    _users.removeWhere((_, b) => stale(b));
    _refresh.removeWhere(
      (_, l) => l.isEmpty || now.difference(l.last) >= refreshWindow,
    );
  }
}
