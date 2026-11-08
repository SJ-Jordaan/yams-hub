/// `/auth/**` (API.md §2.2).
library;

import 'package:collection/collection.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:yams_models/yams_models.dart';

import '../audit/audit_log.dart';
import '../clock.dart';
import '../http/api_exception.dart';
import '../http/api_request.dart';
import '../http/api_response.dart';
import '../http/api_router.dart';
import '../services/seerr_identity.dart';
import 'auth_service.dart';
import 'session_store.dart';

final _log = Logger('core.auth.routes');

/// Minimum length of new passwords.
const minPasswordLength = 10;

/// Registers the auth routes.
final class AuthRoutes {
  AuthRoutes({
    required this.auth,
    required this.seerrIdentity,
    required this.audit,
    required this.clock,
  });

  final AuthService auth;
  final SeerrIdentityResolver seerrIdentity;
  final AuditLog audit;
  final Clock clock;

  void register(ApiRouter r) {
    r
      ..public('POST', '/auth/login', _login)
      ..public('POST', '/auth/refresh', _refresh)
      ..post('/auth/logout', _logout)
      ..get('/auth/me', _me)
      ..post('/auth/password', _password)
      ..get('/auth/sessions', _sessions)
      ..delete('/auth/sessions/<id|s_[0-9a-f]{12}>', _deleteSession);
  }

  List<String> _cookies(ApiRequest req, IssuedTokens t) => [
    buildCookie(
      AuthCookies.access,
      t.accessToken,
      path: AuthCookies.accessPath,
      maxAgeSeconds: t.accessExpiresAt.difference(clock.now()).inSeconds,
      secure: req.isSecure,
    ),
    buildCookie(
      AuthCookies.refresh,
      t.refreshToken,
      path: AuthCookies.refreshPath,
      maxAgeSeconds: t.refreshExpiresAt.difference(clock.now()).inSeconds,
      secure: req.isSecure,
    ),
  ];

  List<String> _clearCookies(ApiRequest req) => [
    buildCookie(
      AuthCookies.access,
      '',
      path: AuthCookies.accessPath,
      maxAgeSeconds: 0,
      secure: req.isSecure,
    ),
    buildCookie(
      AuthCookies.refresh,
      '',
      path: AuthCookies.refreshPath,
      maxAgeSeconds: 0,
      secure: req.isSecure,
    ),
  ];

  void _requireClientHeader(ApiRequest req) {
    final h = req.request.headers[clientHeader];
    if (h == null || h.trim().isEmpty) throw ApiException.csrfRejected();
  }

  Future<Response> _login(ApiRequest req) async {
    final body = await req.jsonBody();
    final username = body['username'];
    final password = body['password'];
    final deviceName = body['deviceName'];
    final fields = <ApiFieldError>[
      if (username is! String || username.trim().isEmpty)
        const ApiFieldError(field: 'username', message: 'Required'),
      if (password is! String || password.isEmpty)
        const ApiFieldError(field: 'password', message: 'Required'),
      if (deviceName is! String ||
          deviceName.trim().isEmpty ||
          deviceName.trim().length > 64)
        const ApiFieldError(field: 'deviceName', message: '1 to 64 characters'),
    ];
    if (fields.isNotEmpty) throw ApiException.validation(fields);
    final transportRaw = body['transport'];
    final transport = transportRaw == null
        ? AuthTransport.token
        : AuthTransport.fromJson(transportRaw);
    if (transport == AuthTransport.unknown) {
      throw ApiException.badRequest('transport must be token or cookie');
    }
    final platform = switch (ClientPlatform.fromJson(body['platform'])) {
      ClientPlatform.unknown => ClientPlatform.other,
      final p => p,
    };
    if (transport == AuthTransport.cookie) {
      if (!req.onCookieMount) {
        throw ApiException.badRequest(
          'The cookie transport is only available on /yh/api/v1.',
        );
      }
      _requireClientHeader(req);
    }
    final result = await auth.login(
      username: username as String,
      password: password as String,
      deviceName: (deviceName as String).trim(),
      platform: platform,
      ip: req.clientIp,
    );
    final response = LoginResponse(
      user: result.user.toDto(),
      session: result.session.toDto(current: true),
      tokens: transport == AuthTransport.token ? result.tokens.toDto() : null,
      serverProofKey: transport == AuthTransport.token
          ? result.session.proofKey
          : null,
    );
    return ApiResponse.json(
      response,
      headers: transport == AuthTransport.cookie
          ? {'set-cookie': _cookies(req, result.tokens)}
          : null,
    );
  }

  Future<Response> _refresh(ApiRequest req) async {
    final body = await req.jsonBodyOrNull() ?? const <String, Object?>{};
    var token = body['refreshToken'] is String
        ? body['refreshToken'] as String
        : null;
    var viaCookie = false;
    if (token == null && req.onCookieMount) {
      token = parseCookies(req.request)[AuthCookies.refresh];
      viaCookie = token != null;
      if (viaCookie) _requireClientHeader(req);
    }
    if (token == null || token.isEmpty) throw ApiException.refreshInvalid();
    final result = await auth.refresh(token, req.clientIp);
    if (viaCookie) {
      return ApiResponse.json(
        {},
        headers: {'set-cookie': _cookies(req, result.tokens)},
      );
    }
    return ApiResponse.json(RefreshResponse(tokens: result.tokens.toDto()));
  }

  Future<Response> _logout(ApiRequest req) async {
    await auth.revokeSessions([req.sessionId]);
    await audit.record(
      actor: AuditActor.of(req),
      action: 'auth.logout',
      target: req.sessionId,
    );
    return ApiResponse.noContent(
      headers: req.onCookieMount ? {'set-cookie': _clearCookies(req)} : null,
    );
  }

  Future<Response> _me(ApiRequest req) async {
    var seerr = const MeSeerrInfo.unlinked();
    try {
      final link = await seerrIdentity.forUser(req.user);
      if (link != null) {
        SeerrQuota? quota;
        try {
          quota = _quota(await seerrIdentity.quota(link.seerrUserId));
        } catch (e) {
          _log.fine('Seerr quota unavailable: $e');
        }
        seerr = MeSeerrInfo(
          linked: true,
          seerrUserId: link.seerrUserId,
          displayName: link.displayName,
          canAutoApprove: link.canAutoApprove,
          quota: quota,
        );
      }
    } catch (e) {
      _log.fine('Seerr link unavailable: $e');
    }
    return ApiResponse.json(
      MeResponse(user: req.user, session: req.session, seerr: seerr),
    );
  }

  static QuotaInfo _quotaInfo(JsonMap? j) {
    final limit = readInt(j?['limit']);
    final unlimited = limit == null || limit == 0;
    return QuotaInfo(
      limit: unlimited ? null : limit,
      days: readInt(j?['days']),
      used: readInt(j?['used']) ?? 0,
      remaining: unlimited ? null : readInt(j?['remaining']),
      restricted: readBool(j?['restricted']) ?? false,
    );
  }

  static SeerrQuota _quota(JsonMap j) => SeerrQuota(
    movie: _quotaInfo(readMap(j['movie'])),
    tv: _quotaInfo(readMap(j['tv'])),
  );

  Future<Response> _password(ApiRequest req) async {
    final body = await req.jsonBody();
    final current = body['currentPassword'];
    final next = body['newPassword'];
    if (current is! String || next is! String) {
      throw ApiException.validation([
        if (current is! String)
          const ApiFieldError(field: 'currentPassword', message: 'Required'),
        if (next is! String)
          const ApiFieldError(field: 'newPassword', message: 'Required'),
      ]);
    }
    if (next.length < minPasswordLength) {
      throw ApiException.invalidField(
        'newPassword',
        'At least $minPasswordLength characters',
      );
    }
    return audit.run(req, 'auth.password', req.user.username, null, () async {
      final user = req.userRecord;
      await auth.verifyCurrentPassword(user, current, req.clientIp);
      final hash = await auth.hasher.hash(next);
      final fresh = auth.users.byId(user.id) ?? user;
      await auth.users.put(
        fresh.copyWith(passwordHash: hash, updatedAt: clock.now()),
      );
      await auth.revokeUserSessions(user.id, exceptSessionId: req.sessionId);
      return ApiResponse.noContent();
    });
  }

  Future<Response> _sessions(ApiRequest req) async {
    final all = req.queryBool('all');
    if (all && !req.isAdmin) throw ApiException.forbidden('Admins only.');
    final sessions = all
        ? auth.sessions.all
        : auth.sessions.forUser(req.user.id);
    final users = {for (final u in auth.users.all) u.id: u.username};
    final items = sessions
        .sortedBy((s) => s.lastSeenAt)
        .reversed
        .map(
          (s) => s.toDto(
            current: s.id == req.sessionId,
            username: all ? users[s.userId] : null,
          ),
        );
    return ApiResponse.items(items, (s) => s.toJson());
  }

  Future<Response> _deleteSession(ApiRequest req) async {
    final id = req.pathParam('id');
    if (!sessionIdPattern.hasMatch(id)) {
      throw ApiException.notFound('Session not found.');
    }
    final s = auth.sessions.byId(id);
    if (s == null || (s.userId != req.user.id && !req.isAdmin)) {
      throw ApiException.notFound('Session not found.');
    }
    return audit.run(req, 'auth.session_revoke', id, null, () async {
      await auth.revokeSessions([id]);
      return ApiResponse.noContent(
        headers: id == req.sessionId && req.onCookieMount
            ? {'set-cookie': _clearCookies(req)}
            : null,
      );
    });
  }
}
