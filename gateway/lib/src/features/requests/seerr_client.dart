/// Seerr transport for the requests feature: strict query encoding, the
/// `X-API-User` identity header and Seerr's error shapes
/// (integrations/seerr.md §1.1, §1.2).
library;

import 'dart:convert';

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

/// Encodes one query value the way Seerr's OpenAPI validator accepts it:
/// `Uri.encodeComponent` (spaces become `%20`, never `+`) plus
/// `! ' ( ) *` → `%21 %27 %28 %29 %2A`.
String seerrEncode(String value) =>
    Uri.encodeComponent(value)
        .replaceAll('!', '%21')
        .replaceAll("'", '%27')
        .replaceAll('(', '%28')
        .replaceAll(')', '%29')
        .replaceAll('*', '%2A');

/// Builds a raw query string (for `rawQuery`) from [params], skipping nulls.
String seerrQuery(Map<String, Object?> params) => [
  for (final e in params.entries)
    if (e.value != null) '${seerrEncode(e.key)}=${seerrEncode('${e.value}')}',
].join('&');

/// A non-2xx Seerr answer.
final class SeerrError implements Exception {
  SeerrError({
    required this.status,
    required this.method,
    required this.path,
    this.message,
    this.keyRejected = false,
  });

  final int status;
  final String method;
  final String path;

  /// Seerr's `message` (redacted, short), if any.
  final String? message;

  /// The gateway's API key was not accepted: a 401 from the OpenAPI
  /// validator, or Seerr's `{"status":403,"error":...}` body on a call made
  /// as the key's own admin user. The same 403 body on a call with
  /// `X-API-User` is that user's permission check failing (Seerr's auth
  /// middleware answers both the same way), so it is not a key problem.
  final bool keyRejected;

  bool get isNotFound => status == 404;

  /// The default API error (API.md §6.7, ARCHITECTURE §5.6):
  /// - rejected key → `502 upstream_auth_failed`;
  /// - 403, or a 401 with a message → `403 forbidden` with Seerr's message
  ///   (permission checks of the user the call ran as);
  /// - 404 → `404 not_found` when the gateway path addressed the resource,
  ///   else `502`;
  /// - 500 "Unable to retrieve ..." on a TMDB lookup ([tmdbLookup]) →
  ///   `404 not_found`;
  /// - anything else (including the 400 "must be url encoded" that strict
  ///   encoding prevents) → `502 upstream_error`.
  ApiException toApi({bool resourceNotFound = true, bool tmdbLookup = false}) {
    if (keyRejected) {
      return ApiException(
        502,
        ApiErrorCode.upstreamAuthFailed,
        'Seerr rejected the gateway\'s credentials.',
        service: ServiceId.seerr,
        details: {'upstreamStatus': status},
      );
    }
    // 403 (permission middleware, run as the X-API-User) and the handler
    // level 401 "You do not have permission to ..." both mean the Seerr user
    // the call ran as may not do this.
    if (status == 403 || status == 401) {
      return ApiException(
        403,
        ApiErrorCode.forbidden,
        message ?? 'Your Seerr account is not allowed to do this.',
        service: ServiceId.seerr,
      );
    }
    if (status == 404 && resourceNotFound) {
      return ApiException(
        404,
        ApiErrorCode.notFound,
        message ?? 'Not found in Seerr.',
        service: ServiceId.seerr,
      );
    }
    if (tmdbLookup &&
        status == 500 &&
        (message == null || message!.startsWith('Unable to retrieve'))) {
      return ApiException(
        404,
        ApiErrorCode.notFound,
        message ?? 'This title does not exist on TMDB.',
        service: ServiceId.seerr,
      );
    }
    return ApiException(
      502,
      ApiErrorCode.upstreamError,
      message == null
          ? 'Seerr returned an error ($status).'
          : 'Seerr returned an error: $message',
      service: ServiceId.seerr,
      details: {'upstreamStatus': status},
    );
  }

  @override
  String toString() => 'SeerrError($method $path $status)';
}

/// A successful Seerr answer (2xx).
final class SeerrReply {
  const SeerrReply(this.status, this.json);

  final int status;

  /// The decoded body (null for empty bodies, e.g. 204).
  final Object? json;

  JsonMap get map => readMap(json) ?? const {};
}

/// Maps a [SeerrError] to a more specific API error, or null for the default.
typedef SeerrErrorMap = ApiException? Function(SeerrError e);

/// Seerr calls with the identity rule of API.md §6. [asUser] adds
/// `X-API-User: <seerrUserId>` (members); null runs the call as the Seerr
/// admin (the API key's default user).
///
/// Every failure is thrown as an [ApiException]: transport problems with the
/// core mapping, non-2xx answers through [onError] and then
/// [SeerrError.toApi].
final class SeerrClient {
  SeerrClient(this._upstream);

  final UpstreamClient _upstream;

  bool get configured => _upstream.configured;

  /// GET [path] (absolute, e.g. `/api/v1/discover/trending`) with a raw
  /// [query] built by [seerrQuery].
  Future<Object?> get(
    String path, {
    String? query,
    int? asUser,
    Duration? timeout,
    bool resourceNotFound = true,
    bool tmdbLookup = false,
    SeerrErrorMap? onError,
  }) async => (await send(
    'GET',
    path,
    query: query,
    asUser: asUser,
    timeout: timeout,
    resourceNotFound: resourceNotFound,
    tmdbLookup: tmdbLookup,
    onError: onError,
  )).json;

  /// Like [get] but expects a JSON object.
  Future<JsonMap> getMap(
    String path, {
    String? query,
    int? asUser,
    Duration? timeout,
    bool resourceNotFound = true,
    bool tmdbLookup = false,
    SeerrErrorMap? onError,
  }) async {
    final json = await get(
      path,
      query: query,
      asUser: asUser,
      timeout: timeout,
      resourceNotFound: resourceNotFound,
      tmdbLookup: tmdbLookup,
      onError: onError,
    );
    return readMap(json) ?? (throw _badResponse('GET', path));
  }

  /// Sends a request; returns any 2xx answer, throws otherwise.
  Future<SeerrReply> send(
    String method,
    String path, {
    Object? body,
    String? query,
    int? asUser,
    Duration? timeout,
    bool resourceNotFound = true,
    bool tmdbLookup = false,
    SeerrErrorMap? onError,
  }) async {
    final UpstreamResponse r;
    try {
      r = await _upstream.send(
        method,
        path,
        jsonBody: body,
        rawQuery: (query == null || query.isEmpty) ? null : query,
        timeout: timeout,
        headers: asUser == null ? null : {'X-API-User': '$asUser'},
      );
    } on UpstreamException catch (e) {
      throw e.toApiException(resourceNotFound: false);
    }
    if (!r.ok) {
      final e = _errorOf(r, method, path, asUser: asUser != null);
      throw onError?.call(e) ??
          e.toApi(resourceNotFound: resourceNotFound, tmdbLookup: tmdbLookup);
    }
    try {
      return SeerrReply(r.status, r.json());
    } on UpstreamException catch (e) {
      throw e.toApiException(resourceNotFound: false);
    }
  }

  ApiException _badResponse(String method, String path) => UpstreamBadResponse(
    service: ServiceId.seerr,
    method: method,
    path: path,
    reason: 'expected a JSON object',
  ).toApiException();

  static SeerrError _errorOf(
    UpstreamResponse r,
    String method,
    String path, {
    required bool asUser,
  }) {
    final extracted = extractUpstreamError(
      r.status,
      r.bodyBytes,
      contentType: r.contentType,
    );
    JsonMap? body;
    try {
      body = readMap(jsonDecode(utf8.decode(r.bodyBytes)));
    } on FormatException {
      body = null;
    }
    final hasMessage = body?['message'] is String;
    final keyRejected =
        (r.status == 401 &&
            (!hasMessage ||
                (body!['message'] as String).contains('connect.sid'))) ||
        (!asUser && r.status == 403 && body?['error'] != null && !hasMessage);
    return SeerrError(
      status: r.status,
      method: method,
      path: path,
      message: hasMessage ? extracted.message : null,
      keyRejected: keyRejected,
    );
  }
}
