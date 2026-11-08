/// Login, refresh, logout and per-request authentication (ARCHITECTURE §5.4).
library;

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:yams_models/yams_models.dart';

import '../../config/config.dart';
import '../audit/audit_log.dart';
import '../audit/sanitize.dart';
import '../clock.dart';
import '../http/api_exception.dart';
import '../http/api_request.dart';
import '../http/api_router.dart';
import '../ids.dart';
import 'access_tokens.dart';
import 'login_limiter.dart';
import 'password_hasher.dart';
import 'records.dart';
import 'server_proof.dart';
import 'session_store.dart';
import 'user_store.dart';

final _log = Logger('core.auth');

/// Cookie names and paths of the cookie transport.
abstract final class AuthCookies {
  static const access = 'yh_at';
  static const refresh = 'yh_rt';
  static const accessPath = '/yh/api';
  static const refreshPath = '/yh/api/v1/auth/refresh';
}

/// The CSRF header required on cookie-authenticated requests.
const clientHeader = 'x-yams-client';

/// Grace window in which the previous refresh token still rotates.
const refreshGrace = Duration(seconds: 30);

/// A freshly issued token pair.
final class IssuedTokens {
  const IssuedTokens({
    required this.accessToken,
    required this.accessExpiresAt,
    required this.refreshToken,
    required this.refreshExpiresAt,
  });

  final String accessToken;
  final DateTime accessExpiresAt;
  final String refreshToken;
  final DateTime refreshExpiresAt;

  TokenPair toDto() => TokenPair(
    accessToken: accessToken,
    accessTokenExpiresAt: accessExpiresAt,
    refreshToken: refreshToken,
    refreshTokenExpiresAt: refreshExpiresAt,
  );
}

/// Result of a successful login.
final class LoginResult {
  const LoginResult(this.user, this.session, this.tokens);

  final UserRecord user;
  final SessionRecord session;
  final IssuedTokens tokens;
}

/// Result of a successful refresh.
final class RefreshResult {
  const RefreshResult(this.session, this.tokens);

  final SessionRecord session;
  final IssuedTokens tokens;
}

/// Parses `Cookie` headers.
Map<String, String> parseCookies(Request request) {
  final out = <String, String>{};
  for (final header in request.headersAll['cookie'] ?? const <String>[]) {
    for (final part in header.split(';')) {
      final i = part.indexOf('=');
      if (i <= 0) continue;
      out.putIfAbsent(
        part.substring(0, i).trim(),
        () => part.substring(i + 1).trim(),
      );
    }
  }
  return out;
}

/// Builds a `Set-Cookie` value for the cookie transport.
String buildCookie(
  String name,
  String value, {
  required String path,
  required int maxAgeSeconds,
  required bool secure,
}) {
  final parts = [
    '$name=$value',
    'HttpOnly',
    'SameSite=Strict',
    'Path=$path',
    'Max-Age=$maxAgeSeconds',
    if (secure) 'Secure',
  ];
  return parts.join('; ');
}

/// The authentication service.
final class AuthService implements RequestAuthenticator {
  AuthService({
    required this._config,
    required this.users,
    required this.sessions,
    required this.tokens,
    required this.hasher,
    required this.limiter,
    required this.audit,
    required this._clock,
  });

  final HubConfig _config;
  final UserStore users;
  final SessionStore sessions;
  final AccessTokenIndex tokens;
  final PasswordHasher hasher;
  final LoginLimiter limiter;
  final AuditLog audit;
  final Clock _clock;

  AuthSettings get _auth => _config.auth;

  // -------------------------------------------------------------------------
  // Bootstrap and recovery
  // -------------------------------------------------------------------------

  /// Creates the bootstrap admin when the user store is empty. Once
  /// `users.json` has users, the bootstrap hash is ignored.
  Future<void> ensureBootstrapAdmin() async {
    final hash = _config.adminPasswordHash;
    // Ignored once users.json exists, even when it holds no (readable) user:
    // a damaged store must not silently re-create the admin from a hash
    // left in the secrets file (`reset-admin` is the recovery path).
    if (!users.isEmpty || users.fileExisted) {
      if (hash != null) _log.info('bootstrap hash ignored, users exist');
      if (users.isEmpty) {
        _log.severe(
          'users.json exists but holds no readable user; nobody can log in '
          '(run reset-admin with YAMS_HUB_ADMIN_PASSWORD_HASH set)',
        );
      }
      return;
    }
    if (hash == null) {
      _log.severe(
        'no hub users exist and YAMS_HUB_ADMIN_PASSWORD_HASH is not set; '
        'nobody can log in (run hash-password and add it to the secrets file)',
      );
      return;
    }
    if (PasswordHasher.parse(hash) == null) {
      _log.severe(
        'YAMS_HUB_ADMIN_PASSWORD_HASH is malformed (expected '
        'pbkdf2-sha256\$<iterations>\$<salt>\$<hash>; check for shell \$ '
        'interpolation); the bootstrap admin was not created',
      );
      return;
    }
    final now = _clock.now();
    final admin = UserRecord(
      id: users.newId(),
      username: _config.adminUsername,
      displayName: 'Administrator',
      role: Role.admin,
      passwordHash: hash,
      createdAt: now,
      updatedAt: now,
    );
    await users.put(admin);
    _log.info('bootstrap admin "${admin.username}" created');
    await audit.record(action: 'auth.bootstrap_admin', target: admin.username);
  }

  /// `reset-admin`: sets the admin's password to the bootstrap hash, enables
  /// the account and revokes every session.
  Future<UserRecord> resetAdmin() async {
    final hash = _config.adminPasswordHash;
    if (hash == null || PasswordHasher.parse(hash) == null) {
      throw const ConfigException([
        'YAMS_HUB_ADMIN_PASSWORD_HASH must be set to a valid hash for reset-admin',
      ]);
    }
    final now = _clock.now();
    final existing = users.byUsername(_config.adminUsername);
    final admin = existing == null
        ? UserRecord(
            id: users.newId(),
            username: _config.adminUsername,
            displayName: 'Administrator',
            role: Role.admin,
            passwordHash: hash,
            createdAt: now,
            updatedAt: now,
          )
        : existing.copyWith(
            passwordHash: hash,
            role: Role.admin,
            disabled: false,
            updatedAt: now,
          );
    await users.put(admin);
    final all = sessions.all;
    for (final s in all) {
      tokens.revokeSession(s.id);
    }
    await sessions.removeAll(all.map((s) => s.id));
    await audit.record(action: 'auth.reset_admin', target: admin.username);
    await audit.flush();
    return admin;
  }

  // -------------------------------------------------------------------------
  // Login / refresh / logout
  // -------------------------------------------------------------------------

  /// Verifies the credentials and creates a session. Throws `401
  /// invalid_credentials`, `403 forbidden` (disabled) or `429 rate_limited`.
  Future<LoginResult> login({
    required String username,
    required String password,
    required String deviceName,
    required ClientPlatform platform,
    required String ip,
  }) async {
    final name = username.trim().toLowerCase();
    final user = usernamePattern.hasMatch(name) ? users.byUsername(name) : null;
    final LoginAttempt attempt;
    try {
      attempt = limiter.begin(name, ip, userId: user?.id);
    } on ApiException catch (e) {
      if (e.status == 429) {
        await audit.record(
          actor: AuditActor(ip: ip),
          action: 'auth.locked',
          target: loginFailedTarget(name),
          outcome: AuditOutcome.error,
          errorCode: e.code,
        );
      }
      rethrow;
    }

    final bool ok;
    try {
      if (user == null) {
        await hasher.verifyDummy(password, iterations: dummyIterations());
        ok = false;
      } else {
        ok = await hasher.verify(
          password,
          user.passwordHash,
          subject: user.username,
        );
      }
    } catch (e) {
      // The gate was full (429) or hashing failed: the attempt does not count.
      attempt.cancel();
      rethrow;
    }

    if (!ok) {
      final locked = attempt.failed();
      await audit.record(
        actor: AuditActor(ip: ip, userId: user?.id),
        action: 'auth.login_failed',
        target: loginFailedTarget(name),
        outcome: AuditOutcome.error,
        errorCode: ApiErrorCode.invalidCredentials,
      );
      if (locked) {
        await audit.record(
          actor: AuditActor(ip: ip),
          action: 'auth.locked',
          target: loginFailedTarget(name),
          outcome: AuditOutcome.error,
          errorCode: ApiErrorCode.rateLimited,
        );
      }
      throw ApiException.invalidCredentials();
    }

    attempt.succeeded(user!.id);
    if (!user.disabled) await _rehashIfNeeded(user, password);
    if (user.disabled) {
      await audit.record(
        actor: AuditActor(ip: ip, userId: user.id, username: user.username),
        action: 'auth.login',
        target: user.username,
        outcome: AuditOutcome.error,
        errorCode: ApiErrorCode.forbidden,
      );
      throw ApiException.forbidden('Account disabled');
    }

    final now = _clock.now();
    final sessionId = sessions.newId();
    final refresh = _newRefreshToken(sessionId);
    final session = SessionRecord(
      id: sessionId,
      userId: user.id,
      deviceName: deviceName,
      platform: platform,
      createdAt: now,
      lastSeenAt: now,
      lastIp: ip,
      refreshHash: sha256Hex(refresh),
      expiresAt: now.add(_auth.refreshTokenTtl(user.role)),
      proofKey: newProofKey(),
    );
    await sessions.put(session);
    final access = tokens.issue(sessionId, _auth.accessTokenTtl);
    await audit.record(
      actor: AuditActor(
        ip: ip,
        userId: user.id,
        username: user.username,
        sessionId: sessionId,
      ),
      action: 'auth.login',
      target: user.username,
      params: {'deviceName': deviceName, 'platform': platform.name},
    );
    return LoginResult(
      user,
      session,
      IssuedTokens(
        accessToken: access.token,
        accessExpiresAt: access.expiresAt,
        refreshToken: refresh,
        refreshExpiresAt: session.expiresAt,
      ),
    );
  }

  /// The iteration count unknown user names are verified at: the highest
  /// count among the stored hashes (the bootstrap hash and accounts created
  /// before an auto-tune keep the configured count), else the count of new
  /// hashes. A real account's verification is then never slower than an
  /// unknown name's.
  int dummyIterations() {
    var n = 0;
    for (final u in users.all) {
      final i = PasswordHasher.iterationsOf(u.passwordHash);
      if (i != null && i > n) n = i;
    }
    return n == 0 ? hasher.iterations : n;
  }

  /// Re-hashes [password] at the current iteration count when the stored
  /// hash uses another one, so every account converges on one count (and
  /// on the dummy timing). Failures (busy gate) are logged and skipped.
  Future<void> _rehashIfNeeded(UserRecord user, String password) async {
    if (!hasher.needsRehash(user.passwordHash)) return;
    try {
      final hash = await hasher.hash(password);
      final fresh = users.byId(user.id);
      // A password change that raced this login wins.
      if (fresh == null || fresh.passwordHash != user.passwordHash) return;
      await users.put(
        fresh.copyWith(passwordHash: hash, updatedAt: _clock.now()),
      );
      _log.info(
        'password of "${user.username}" re-hashed at '
        '${hasher.iterations} iterations',
      );
    } on Object catch (e) {
      _log.warning('re-hashing the password of "${user.username}" failed: $e');
    }
  }

  /// Verifies [password] as the current password of [user] (`POST
  /// /auth/password`) through the login limiter, so a stolen access token
  /// cannot guess it at the gate's rate: failures count against the same
  /// `(username, ip)`, IP and username buckets as logins. Throws `401
  /// invalid_credentials` or `429 rate_limited`.
  Future<void> verifyCurrentPassword(
    UserRecord user,
    String password,
    String ip,
  ) async {
    final attempt = limiter.begin(user.username, ip, userId: user.id);
    final bool ok;
    try {
      ok = await hasher.verify(
        password,
        user.passwordHash,
        subject: user.username,
      );
    } catch (_) {
      attempt.cancel();
      rethrow;
    }
    if (!ok) {
      final locked = attempt.failed();
      if (locked) {
        await audit.record(
          actor: AuditActor(ip: ip, userId: user.id, username: user.username),
          action: 'auth.locked',
          target: loginFailedTarget(user.username),
          outcome: AuditOutcome.error,
          errorCode: ApiErrorCode.rateLimited,
        );
      }
      throw ApiException.invalidCredentials();
    }
    attempt.succeeded(user.id);
  }

  String _newRefreshToken(String sessionId) =>
      'yhr_$sessionId.${randomToken(32)}';

  static final _refreshPattern = RegExp(
    r'^yhr_(s_[0-9a-f]{12})\.([A-Za-z0-9_-]{43})$',
  );

  /// Rotates a refresh token (ARCHITECTURE §5.4 reuse detection).
  Future<RefreshResult> refresh(String refreshToken, String ip) async {
    limiter.checkRefresh(ip);
    final m = _refreshPattern.firstMatch(refreshToken);
    if (m == null) throw ApiException.refreshInvalid();
    final session = sessions.byId(m[1]!);
    if (session == null) throw ApiException.refreshInvalid();
    final user = users.byId(session.userId);
    if (user == null || user.disabled) {
      await revokeSessions([session.id]);
      throw ApiException.refreshInvalid();
    }
    final now = _clock.now();
    final hash = sha256Hex(refreshToken);
    final isCurrent = constantTimeEquals(hash, session.refreshHash);
    final prev = session.prevRefreshHash;
    final prevUntil = session.prevValidUntil;
    final isGrace =
        !isCurrent &&
        prev != null &&
        prevUntil != null &&
        now.isBefore(prevUntil) &&
        constantTimeEquals(hash, prev);
    if (!isCurrent && !isGrace) {
      await revokeSessions([session.id]);
      await audit.record(
        actor: AuditActor(
          userId: user.id,
          username: user.username,
          sessionId: session.id,
          ip: ip,
        ),
        action: 'auth.refresh_reuse',
        target: session.id,
        outcome: AuditOutcome.error,
        errorCode: ApiErrorCode.refreshInvalid,
      );
      _log.warning(
        'refresh token reuse for session ${session.id}; session revoked',
      );
      throw ApiException.refreshInvalid();
    }
    final next = _newRefreshToken(session.id);
    session
      ..prevRefreshHash = session.refreshHash
      ..prevValidUntil = now.add(refreshGrace)
      ..refreshHash = sha256Hex(next)
      ..expiresAt = now.add(_auth.refreshTokenTtl(user.role))
      ..lastSeenAt = now
      ..lastIp = ip;
    await sessions.save();
    final access = tokens.issue(session.id, _auth.accessTokenTtl);
    return RefreshResult(
      session,
      IssuedTokens(
        accessToken: access.token,
        accessExpiresAt: access.expiresAt,
        refreshToken: next,
        refreshExpiresAt: session.expiresAt,
      ),
    );
  }

  /// Revokes sessions and drops their access tokens immediately.
  Future<void> revokeSessions(Iterable<String> sessionIds) async {
    final ids = sessionIds.toList();
    for (final id in ids) {
      tokens.revokeSession(id);
    }
    await sessions.removeAll(ids);
  }

  /// Revokes every session of [userId] except [exceptSessionId].
  Future<int> revokeUserSessions(
    String userId, {
    String? exceptSessionId,
  }) async {
    final ids = [
      for (final s in sessions.forUser(userId))
        if (s.id != exceptSessionId) s.id,
    ];
    await revokeSessions(ids);
    return ids.length;
  }

  /// `proof` for `GET /ping`, or null when [sessionId] is not a live session.
  String? serverProof(String sessionId, String nonce) {
    if (!sessionIdPattern.hasMatch(sessionId)) return null;
    final s = sessions.byId(sessionId);
    if (s == null) return null;
    return computeServerProof(s.proofKey, nonce);
  }

  // -------------------------------------------------------------------------
  // Per-request authentication
  // -------------------------------------------------------------------------

  @override
  Future<Principal> authenticate(Request request) async {
    final cookieMount = request.context[ContextKeys.cookieMount] == true;
    String? token;
    var viaCookie = false;
    final authz = request.headers['authorization'];
    if (authz != null) {
      final m = RegExp(
        r'^Bearer\s+(\S+)$',
        caseSensitive: false,
      ).firstMatch(authz.trim());
      if (m == null) {
        throw ApiException.unauthorized('Unsupported Authorization header.');
      }
      token = m[1];
    } else if (cookieMount) {
      token = parseCookies(request)[AuthCookies.access];
      viaCookie = token != null;
    }
    if (token == null || token.isEmpty) throw ApiException.unauthorized();
    if (!token.startsWith('yha_')) {
      throw ApiException.unauthorized('Invalid access token.');
    }

    final lookup = tokens.lookup(token);
    if (lookup is! AccessValid) throw ApiException.tokenExpired();
    final session = sessions.byId(lookup.entry.sessionId);
    if (session == null) {
      tokens.revokeSession(lookup.entry.sessionId);
      throw ApiException.tokenExpired();
    }
    // Role and disabled always come from the store, never from the token.
    final user = users.byId(session.userId);
    if (user == null || user.disabled) {
      await revokeSessions([session.id]);
      throw ApiException.unauthorized('Account disabled or removed.');
    }
    final ip = request.context[ContextKeys.clientIp] as String?;
    sessions.touch(session, ip);
    return Principal(user: user, session: session, viaCookie: viaCookie);
  }

  @override
  void checkCsrf(Request request, Principal principal) {
    if (!principal.viaCookie) return;
    final isImageGet =
        (request.method == 'GET' || request.method == 'HEAD') &&
        request.url.path.startsWith('img/');
    if (isImageGet) return;
    final header = request.headers[clientHeader];
    if (header == null || header.trim().isEmpty) {
      throw ApiException.csrfRejected();
    }
  }
}
