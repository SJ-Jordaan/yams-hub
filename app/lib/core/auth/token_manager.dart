/// Holds the active session's credentials in memory (ARCHITECTURE §7.6).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yams_models/yams_models.dart';

import '../api/interceptors/auth_interceptor.dart';
import '../servers/server_resolver.dart';
import 'token_store.dart';

/// The session of the active server profile.
///
/// Bearer transport: the token pair, session id and server proof key, loaded
/// from the [TokenStore] (keyed by instance id) and kept in memory so every
/// request can read the access token synchronously.
///
/// Cookie transport: the tokens are HttpOnly cookies; only a "signed in"
/// marker is kept (not secret).
///
/// The last known [User] (id, name, role) is cached in SharedPreferences so the
/// router knows the role synchronously at start-up; `GET /auth/me` refreshes it.
class TokenManager extends ChangeNotifier implements AuthSession {
  TokenManager({
    required this._store,
    required this._prefs,
    required this.cookieTransport,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final TokenStore _store;
  final SharedPreferences _prefs;
  final DateTime Function() _clock;

  @override
  final bool cookieTransport;

  /// Scope of the stored session: the instance id (bearer) or `web` (cookie).
  String? _scope;
  StoredTokens? _tokens;
  User? _user;
  bool _cookieSession = false;

  static const cookieScope = 'web';

  static String _userKey(String scope) => 'auth.user.$scope';
  static String _cookieKey(String scope) => 'auth.cookieSession.$scope';

  String? get scope => _scope;
  StoredTokens? get tokens => _tokens;
  User? get user => _user;

  /// Whether a session exists (it may still be rejected by the gateway, in
  /// which case the auth interceptor calls [expire]).
  bool get hasSession {
    if (_scope == null) return false;
    if (cookieTransport) return _cookieSession;
    final t = _tokens;
    return t != null && t.canRefreshAt(_clock());
  }

  /// Credentials for the server proof (bearer transport only).
  ProofCredentials? get proofCredentials {
    final t = _tokens;
    final key = t?.serverProofKey;
    if (cookieTransport || t == null || key == null) return null;
    return ProofCredentials(sessionId: t.sessionId, serverProofKey: key);
  }

  /// Loads the session of [instanceId] (bearer) or of the page origin
  /// (cookie; [instanceId] is ignored). Null clears the in-memory session.
  Future<void> activate(String? instanceId) async {
    final scope = cookieTransport ? cookieScope : instanceId;
    if (scope == _scope && (_tokens != null || _cookieSession)) return;
    _scope = scope;
    _tokens = null;
    _user = null;
    _cookieSession = false;
    if (scope != null) {
      if (cookieTransport) {
        _cookieSession = _prefs.getBool(_cookieKey(scope)) ?? false;
      } else {
        _tokens = await _store.read(scope);
      }
      if (hasSession) _user = _readUser(scope);
    }
    notifyListeners();
  }

  /// Stores a new session after `POST /auth/login`.
  Future<void> signIn({required String scope, required User user, StoredTokens? tokens}) async {
    final effectiveScope = cookieTransport ? cookieScope : scope;
    _scope = effectiveScope;
    if (cookieTransport) {
      _cookieSession = true;
      await _prefs.setBool(_cookieKey(effectiveScope), true);
    } else {
      if (tokens == null) throw ArgumentError('bearer sign-in needs tokens');
      _tokens = tokens;
      await _store.write(effectiveScope, tokens);
    }
    await _writeUser(effectiveScope, user);
    notifyListeners();
  }

  /// Caches the user from `GET /auth/me` (role changes apply immediately).
  Future<void> saveUser(User user) async {
    final scope = _scope;
    if (scope == null || !hasSession) return;
    final changed = jsonEncode(user.toJson()) != jsonEncode(_user?.toJson());
    if (!changed) return;
    await _writeUser(scope, user);
    notifyListeners();
  }

  /// Signs out locally: forgets tokens, the cookie marker and the cached user.
  Future<void> clear() async {
    final scope = _scope;
    final had = hasSession || _user != null;
    _tokens = null;
    _user = null;
    _cookieSession = false;
    if (scope != null) {
      await _prefs.remove(_userKey(scope));
      await _prefs.remove(_cookieKey(scope));
      if (!cookieTransport) await _store.delete(scope);
    }
    if (had) notifyListeners();
  }

  /// Forgets the cached user (and cookie marker) of a profile that is **not**
  /// the active session, after its tokens were deleted (settings: sign out
  /// of / delete another server). The active session uses [clear] instead,
  /// so [scope] equal to the active scope is ignored.
  Future<void> forgetCachedUser(String scope) async {
    if (scope == _scope) return;
    await _prefs.remove(_userKey(scope));
    await _prefs.remove(_cookieKey(scope));
  }

  // --- AuthSession -----------------------------------------------------------

  @override
  String? get accessToken => _tokens?.accessToken;

  @override
  String? get refreshToken => _tokens?.refreshToken;

  @override
  Future<void> storeTokens(TokenPair tokens) async {
    final current = _tokens;
    final scope = _scope;
    if (current == null || scope == null) return;
    final next = current.rotated(tokens);
    _tokens = next;
    // Listeners that hold the access token (image headers) pick up the new one.
    notifyListeners();
    await _store.write(scope, next);
  }

  @override
  Future<void> expire() => clear();

  // --- user cache ------------------------------------------------------------

  User? _readUser(String scope) {
    final raw = _prefs.getString(_userKey(scope));
    if (raw == null) return null;
    try {
      final map = readMap(jsonDecode(raw));
      return map == null ? null : User.fromJson(map);
    } on FormatException {
      return null;
    }
  }

  Future<void> _writeUser(String scope, User user) async {
    _user = user;
    await _prefs.setString(_userKey(scope), jsonEncode(user.toJson()));
  }
}

/// The [TokenManager] of this app run. Created and loaded in `main()` before
/// `runApp` (so auth state is known synchronously) and injected with an
/// override; tests override it too.
final tokenManagerProvider = Provider<TokenManager>(
  (ref) => throw StateError('tokenManagerProvider must be overridden in main()'),
);

/// The current access token (bearer transport), updated when the pair is
/// rotated or the session ends. Widgets that send the token themselves
/// (`HubImage`'s `Authorization` header) watch this instead of reading the
/// [TokenManager] once.
final accessTokenProvider = Provider<String?>((ref) {
  final tokens = ref.watch(tokenManagerProvider);
  void changed() => ref.invalidateSelf();
  tokens.addListener(changed);
  ref.onDispose(() => tokens.removeListener(changed));
  return tokens.accessToken;
});
