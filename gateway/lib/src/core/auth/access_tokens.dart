/// In-memory access tokens, indexed by token hash and by session
/// (ARCHITECTURE §5.4).
library;

import '../clock.dart';
import '../ids.dart';

/// A live access token.
final class AccessTokenEntry {
  const AccessTokenEntry(this.sessionId, this.expiresAt);

  final String sessionId;
  final DateTime expiresAt;
}

/// The result of looking up an access token.
sealed class AccessLookup {
  const AccessLookup();
}

final class AccessValid extends AccessLookup {
  const AccessValid(this.entry);
  final AccessTokenEntry entry;
}

/// Unknown (for example after a restart) or expired: the client refreshes.
final class AccessExpired extends AccessLookup {
  const AccessExpired();
}

/// Access tokens `yha_<32 random bytes base64url>`. Only `sha256(token)` is
/// kept; revoking a session drops all of its tokens at once.
final class AccessTokenIndex {
  AccessTokenIndex(this._clock);

  final Clock _clock;
  final _byHash = <String, AccessTokenEntry>{};
  final _bySession = <String, Set<String>>{};
  int _issuedSinceSweep = 0;

  int get size => _byHash.length;

  /// Issues a token for [sessionId] valid for [ttl].
  ({String token, DateTime expiresAt}) issue(String sessionId, Duration ttl) {
    if (++_issuedSinceSweep >= 256) _sweep();
    final token = 'yha_${randomToken(32)}';
    final hash = sha256Hex(token);
    final expiresAt = _clock.now().add(ttl);
    _byHash[hash] = AccessTokenEntry(sessionId, expiresAt);
    (_bySession[sessionId] ??= <String>{}).add(hash);
    return (token: token, expiresAt: expiresAt);
  }

  AccessLookup lookup(String token) {
    final hash = sha256Hex(token);
    final entry = _byHash[hash];
    if (entry == null) return const AccessExpired();
    if (!_clock.now().isBefore(entry.expiresAt)) {
      _remove(hash, entry.sessionId);
      return const AccessExpired();
    }
    return AccessValid(entry);
  }

  /// Drops every token of [sessionId].
  void revokeSession(String sessionId) {
    final hashes = _bySession.remove(sessionId);
    if (hashes == null) return;
    for (final h in hashes) {
      _byHash.remove(h);
    }
  }

  void _remove(String hash, String sessionId) {
    _byHash.remove(hash);
    final set = _bySession[sessionId];
    if (set != null) {
      set.remove(hash);
      if (set.isEmpty) _bySession.remove(sessionId);
    }
  }

  void _sweep() {
    _issuedSinceSweep = 0;
    final now = _clock.now();
    final expired = [
      for (final e in _byHash.entries)
        if (!now.isBefore(e.value.expiresAt)) (e.key, e.value.sessionId),
    ];
    for (final (hash, sid) in expired) {
      _remove(hash, sid);
    }
  }
}
