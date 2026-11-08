/// The request object handed to every API handler (ARCHITECTURE §5.3).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:yams_models/yams_models.dart';

import '../auth/records.dart';
import 'api_exception.dart';

/// Request context keys set by the pipeline.
abstract final class ContextKeys {
  static const requestId = 'yamsHub.requestId';
  static const clientIp = 'yamsHub.clientIp';
  static const cookieMount = 'yamsHub.cookieMount';
  static const secure = 'yamsHub.secure';
  static const jsonBody = 'yamsHub.jsonBody';
  static const errorCode = 'yamsHub.errorCode';
  static const userId = 'yamsHub.userId';
}

/// Maximum accepted request body (1 MiB).
const maxRequestBodyBytes = 1 << 20;

/// An API request: the shelf [request] plus the authenticated caller and typed
/// parameter readers. Readers throw `400 bad_request` on invalid input.
final class ApiRequest {
  ApiRequest(this.request, {this.principal});

  /// The underlying shelf request (path relative to the API mount).
  final Request request;

  /// The caller; null only on public routes (`/ping`, login, refresh).
  final Principal? principal;

  Object? _body;
  bool _bodyRead = false;
  List<int>? _rawBody;

  /// The authenticated user (from the user store, read for this request).
  User get user => _principal.user.toDto();

  /// The stored record of the caller.
  UserRecord get userRecord => _principal.user;

  /// The caller's session.
  SessionInfo get session => _principal.session.toDto(current: true);

  /// The caller's session id.
  String get sessionId => _principal.session.id;

  Principal get _principal =>
      principal ?? (throw StateError('public route has no authenticated user'));

  bool get isAuthenticated => principal != null;

  bool get isAdmin => principal?.user.role == Role.admin;

  /// `X-Request-Id` of this request.
  String get requestId =>
      request.context[ContextKeys.requestId] as String? ?? 'unknown';

  /// The client IP (from the socket, or `X-Forwarded-For` with
  /// `YAMS_HUB_TRUST_PROXY`).
  String get clientIp =>
      request.context[ContextKeys.clientIp] as String? ?? 'unknown';

  /// Served through `/yh/api/v1` (cookie transport mount).
  bool get onCookieMount => request.context[ContextKeys.cookieMount] == true;

  /// HTTPS (directly, or `X-Forwarded-Proto` behind a trusted proxy).
  bool get isSecure => request.context[ContextKeys.secure] == true;

  String get method => request.method;

  /// Path below the API mount, starting with `/` (`/library/tv/54`).
  String get path => '/${request.url.path}';

  Map<String, String> get pathParams => request.params;

  /// Query parameters (last value wins for repeated keys).
  Map<String, String> get query => request.url.queryParameters;

  /// A path parameter registered on the route.
  String pathParam(String name) =>
      request.params[name] ??
      (throw ApiException.badRequest('missing path parameter $name'));

  /// A path parameter parsed as an int (routes constrain it with `[0-9]+`).
  int pathInt(String name) {
    final v = int.tryParse(pathParam(name));
    if (v == null) throw ApiException.badRequest('$name must be an integer');
    return v;
  }

  /// A query parameter, trimmed; null when absent or empty.
  String? queryString(String name) {
    final v = query[name]?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  /// Reads an integer query parameter; out-of-range values are rejected.
  int queryInt(
    String name, {
    int? defaultValue,
    int? min,
    int? max,
    bool clamp = false,
  }) {
    final raw = queryString(name);
    if (raw == null) {
      if (defaultValue != null) return defaultValue;
      throw ApiException.badRequest('$name is required');
    }
    final v = int.tryParse(raw);
    if (v == null) throw ApiException.badRequest('$name must be an integer');
    if (min != null && v < min) {
      if (clamp) return min;
      throw ApiException.badRequest('$name must be at least $min');
    }
    if (max != null && v > max) {
      if (clamp) return max;
      throw ApiException.badRequest('$name must be at most $max');
    }
    return v;
  }

  /// An optional integer query parameter.
  int? queryIntOrNull(String name, {int? min, int? max}) =>
      queryString(name) == null ? null : queryInt(name, min: min, max: max);

  /// Reads an enum by name; unknown values are `400 bad_request`.
  T queryEnum<T extends Enum>(String name, List<T> values, {T? defaultValue}) {
    final raw = queryString(name);
    if (raw == null) {
      if (defaultValue != null) return defaultValue;
      throw ApiException.badRequest('$name is required');
    }
    for (final v in values) {
      if (v.name == raw) return v;
    }
    throw ApiException.badRequest(
      '$name must be one of ${values.map((v) => v.name).join(', ')}',
    );
  }

  /// Reads one of the allowed string values; unknown values are `400`.
  String queryChoice(
    String name,
    List<String> allowed, {
    String? defaultValue,
  }) {
    final raw = queryString(name);
    if (raw == null) {
      if (defaultValue != null) return defaultValue;
      throw ApiException.badRequest('$name is required');
    }
    if (!allowed.contains(raw)) {
      throw ApiException.badRequest(
        '$name must be one of ${allowed.join(', ')}',
      );
    }
    return raw;
  }

  /// Reads `true`/`false`.
  bool queryBool(String name, {bool defaultValue = false}) {
    final raw = queryString(name);
    if (raw == null) return defaultValue;
    return switch (raw.toLowerCase()) {
      'true' || '1' => true,
      'false' || '0' => false,
      _ => throw ApiException.badRequest('$name must be true or false'),
    };
  }

  /// A comma-separated list (also accepts repeated keys); empty entries are
  /// dropped.
  List<String> queryList(String name) {
    final all = request.url.queryParametersAll[name] ?? const [];
    return [
      for (final v in all)
        for (final part in v.split(','))
          if (part.trim().isNotEmpty) part.trim(),
    ];
  }

  /// The raw body (at most 1 MiB), read once.
  Future<List<int>> bodyBytes() async {
    if (_rawBody case final b?) return b;
    final length = request.contentLength;
    if (length != null && length > maxRequestBodyBytes) {
      throw const ApiException(
        413,
        ApiErrorCode.badRequest,
        'Request body too large.',
      );
    }
    final out = BytesBuilder(copy: false);
    await for (final chunk in request.read()) {
      out.add(chunk);
      if (out.length > maxRequestBodyBytes) {
        throw const ApiException(
          413,
          ApiErrorCode.badRequest,
          'Request body too large.',
        );
      }
    }
    return _rawBody = out.takeBytes();
  }

  /// The JSON object body. An empty body is `{}`; invalid JSON or a non-object
  /// is `400 bad_request`.
  Future<JsonMap> jsonBody() async {
    if (!_bodyRead) {
      final bytes = await bodyBytes();
      _bodyRead = true;
      if (bytes.isEmpty) {
        _body = <String, Object?>{};
      } else {
        try {
          _body = jsonDecode(utf8.decode(bytes));
        } on FormatException {
          _body = const _InvalidJson();
        }
      }
    }
    final b = _body;
    if (b is _InvalidJson) {
      throw ApiException.badRequest('Body is not valid JSON.');
    }
    final m = readMap(b);
    if (m == null) throw ApiException.badRequest('Body must be a JSON object.');
    return m;
  }

  /// The JSON body if it was (or can be) parsed, without throwing (audit).
  Future<JsonMap?> jsonBodyOrNull() async {
    try {
      return await jsonBody();
    } on ApiException {
      return null;
    }
  }

  /// Whether `confirm=true` was sent (query parameter or JSON body field).
  Future<bool> isConfirmed() async {
    if (queryString('confirm')?.toLowerCase() == 'true') return true;
    final ct = request.mimeType;
    if (ct == null || ct == 'application/json') {
      final body = await jsonBodyOrNull();
      if (body != null && body['confirm'] == true) return true;
    }
    return false;
  }

  /// Throws `428 confirmation_required` with `details.impact` unless
  /// `confirm=true` was sent (ARCHITECTURE §5.12).
  Future<void> requireConfirm(String impact) async {
    if (!await isConfirmed()) throw ApiException.confirmationRequired(impact);
  }

  /// Throws `403 forbidden` unless the caller is an admin.
  void requireAdmin() {
    if (!isAdmin) throw ApiException.forbidden('Admins only.');
  }
}

final class _InvalidJson {
  const _InvalidJson();
}

/// Resolves the client IP of a shelf request.
String resolveClientIp(Request request, {required bool trustProxy}) {
  if (trustProxy) {
    final xff = request.headers['x-forwarded-for'];
    if (xff != null) {
      final first = xff.split(',').first.trim();
      if (InternetAddress.tryParse(first) != null) return first;
    }
  }
  final info = request.context['shelf.io.connection_info'];
  if (info is HttpConnectionInfo) {
    final a = info.remoteAddress;
    // Report IPv4-mapped IPv6 addresses as IPv4.
    final s = a.address;
    if (s.startsWith('::ffff:') && s.contains('.')) return s.substring(7);
    return s;
  }
  return 'unknown';
}
