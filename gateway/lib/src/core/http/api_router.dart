/// The API router shared by core and the feature modules (ARCHITECTURE §5.3).
library;

import 'dart:async';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:yams_models/yams_models.dart';

import '../audit/audit_log.dart';
import '../auth/records.dart';
import 'api_exception.dart';
import 'api_request.dart';
import 'api_response.dart';

/// An API handler.
typedef ApiHandler = Future<Response> Function(ApiRequest req);

/// Authenticates API requests (implemented by the auth service).
abstract interface class RequestAuthenticator {
  /// Returns the caller or throws `401`.
  Future<Principal> authenticate(Request request);

  /// Throws `403 csrf_rejected` when a cookie-authenticated request lacks the
  /// `X-YAMS-Client` header (image GETs excepted).
  void checkCsrf(Request request, Principal principal);
}

/// One registered route (for introspection and tests).
final class RouteSpec {
  const RouteSpec({
    required this.method,
    required this.path,
    required this.role,
    required this.audit,
    required this.public,
    this.action,
  });

  final String method;

  /// shelf_router pattern below `/api/v1`, e.g. `/library/tv/<id|[0-9]+>`.
  final String path;
  final Role role;
  final bool audit;
  final bool public;
  final String? action;

  @override
  String toString() => '$method $path';
}

/// Parameters whose values are numeric ids and must be regex-constrained.
const _numericParams = {
  'id',
  'tmdbId',
  'n',
  'seasonNumber',
  'queueId',
  'episodeId',
  'seriesId',
  'movieId',
  'seerrUserId',
};

final _paramPattern = RegExp(r'<([A-Za-z_][A-Za-z0-9_]*)(\|[^>]*)?>');

/// Wraps a shelf_router [Router] built with `notFoundHandler: jsonNotFound`,
/// so unknown paths and method mismatches return the JSON `404 not_found`.
/// Routes match in registration order: register static segments before
/// parameterised ones and constrain numeric parameters (`<id|[0-9]+>`).
///
/// Every non-public route authenticates the caller, applies the CSRF rule of
/// the cookie transport and checks [Role]. Non-GET routes registered with
/// `audit: true` are audited automatically; the action defaults to the static
/// path segments joined by `.` (plus `.delete`/`.update` for DELETE and
/// PUT/PATCH), override it with `action:`.
final class ApiRouter {
  ApiRouter({required this.authenticator, required this.auditLog});

  final RequestAuthenticator authenticator;
  final AuditLog auditLog;
  final _router = Router(notFoundHandler: jsonNotFound);
  final _routes = <RouteSpec>[];

  /// Every registered route, in registration order.
  List<RouteSpec> get routes => List.unmodifiable(_routes);

  /// The shelf handler (mounted at `/api/v1` and `/yh/api/v1`).
  Handler get handler => _router.call;

  void get(
    String path,
    ApiHandler handler, {
    Role role = Role.member,
    bool audit = false,
    String? action,
  }) => _add('GET', path, handler, role: role, audit: audit, action: action);

  void post(
    String path,
    ApiHandler handler, {
    Role role = Role.member,
    bool audit = false,
    String? action,
  }) => _add('POST', path, handler, role: role, audit: audit, action: action);

  void put(
    String path,
    ApiHandler handler, {
    Role role = Role.member,
    bool audit = false,
    String? action,
  }) => _add('PUT', path, handler, role: role, audit: audit, action: action);

  void patch(
    String path,
    ApiHandler handler, {
    Role role = Role.member,
    bool audit = false,
    String? action,
  }) => _add('PATCH', path, handler, role: role, audit: audit, action: action);

  void delete(
    String path,
    ApiHandler handler, {
    Role role = Role.member,
    bool audit = false,
    String? action,
  }) => _add('DELETE', path, handler, role: role, audit: audit, action: action);

  /// A route without authentication (core only: ping, login, refresh).
  void public(String method, String path, ApiHandler handler) => _add(
    method,
    path,
    handler,
    role: Role.member,
    audit: false,
    public: true,
  );

  void _add(
    String method,
    String path,
    ApiHandler handler, {
    required Role role,
    required bool audit,
    String? action,
    bool public = false,
  }) {
    _validatePattern(path);
    if (role == Role.unknown) {
      throw ArgumentError.value(role, 'role', 'routes need member or admin');
    }
    final spec = RouteSpec(
      method: method,
      path: path,
      role: role,
      audit: audit && method != 'GET',
      public: public,
      action: action ?? defaultAuditAction(method, path),
    );
    _routes.add(spec);
    _router.add(method, path, (Request r) => _invoke(spec, handler, r));
  }

  Future<Response> _invoke(
    RouteSpec spec,
    ApiHandler handler,
    Request r,
  ) async {
    Principal? principal;
    if (!spec.public) {
      principal = await authenticator.authenticate(r);
      authenticator.checkCsrf(r, principal);
      if (!principal.user.role.satisfies(spec.role)) {
        throw ApiException.forbidden(
          spec.role == Role.admin
              ? 'Admins only.'
              : 'You are not allowed to do this.',
        );
      }
    }
    final req = ApiRequest(r, principal: principal);
    final Response response;
    try {
      response = spec.audit
          ? await auditLog.runRoute(req, spec.action!, () => handler(req))
          : await handler(req);
    } on ApiException catch (e) {
      // Stubs: name the matched route so tests (and developers) can see
      // which registration answered.
      if (e.code == ApiErrorCode.notImplemented && e.details == null) {
        throw ApiException(
          e.status,
          e.code,
          e.message,
          details: {'route': spec.toString()},
        );
      }
      rethrow;
    }
    if (principal == null) return response;
    return response.change(context: {ContextKeys.userId: principal.user.id});
  }

  static void _validatePattern(String path) {
    if (!path.startsWith('/')) {
      throw ArgumentError.value(path, 'path', 'must start with /');
    }
    if (path.startsWith('/api/') || path.startsWith('/yh/')) {
      throw ArgumentError.value(path, 'path', 'paths are relative to /api/v1');
    }
    for (final m in _paramPattern.allMatches(path)) {
      final name = m[1]!;
      if (_numericParams.contains(name) && m[2] == null) {
        throw ArgumentError.value(
          path,
          'path',
          'numeric parameter <$name> must be regex-constrained, e.g. <$name|[0-9]+>',
        );
      }
    }
  }

  /// `library.tv` for `POST /library/tv`, `library.tv.delete` for
  /// `DELETE /library/tv/<id>`, `containers.actions` for
  /// `POST /containers/<name>/actions`.
  static String defaultAuditAction(String method, String path) {
    final segments = [
      for (final s in path.split('/'))
        if (s.isNotEmpty && !s.startsWith('<')) s,
    ];
    final base = segments.join('.');
    return switch (method) {
      'DELETE' => '$base.delete',
      'PUT' || 'PATCH' => '$base.update',
      _ => base,
    };
  }
}

/// A handler for stub routes: `501 not_implemented`.
Future<Response> notImplementedHandler(ApiRequest req) async =>
    throw ApiException.notImplemented();
