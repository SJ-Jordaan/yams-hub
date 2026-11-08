/// A Dio [HttpClientAdapter] that serves canned JSON by method and path
/// (ARCHITECTURE §7.12). Paths are relative to the API mount (`/dashboard`,
/// not `/api/v1/dashboard`); `/yh/api/v1` is stripped too.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:yams_models/yams_models.dart';

/// A canned answer: a JSON [body] with [status], or a transport failure of
/// [failure] type (no response at all).
class FakeResponse {
  const FakeResponse(this.body, {this.status = 200, this.headers = const {}}) : failure = null;

  /// The gateway's error body (API.md §1.4).
  FakeResponse.error(int status, String code, {String message = 'error', JsonMap? details, int? retryAfterSeconds})
    : this(
        ApiError(
          code: code,
          message: message,
          status: status,
          requestId: 'test-request-id',
          details: details,
          retryAfterSeconds: retryAfterSeconds,
        ).toResponseBody(),
        status: status,
      );

  /// `204 No Content`.
  const FakeResponse.noContent() : this(null, status: 204);

  /// The request fails without a response (`connectionError`, timeouts).
  const FakeResponse.fail(DioExceptionType this.failure) : body = null, status = 0, headers = const {};

  final Object? body;
  final int status;
  final Map<String, String> headers;
  final DioExceptionType? failure;
}

typedef FakeHandler = FutureOr<FakeResponse> Function(RequestOptions request);

class FakeApi implements HttpClientAdapter {
  final Map<String, FakeHandler> _routes = {};

  /// Every request received, in order.
  final List<RequestOptions> requests = [];

  static String _key(String method, String path) => '${method.toUpperCase()} $path';

  /// Registers [handler] for `METHOD path` (exact path, query ignored).
  void on(String method, String path, FakeHandler handler) => _routes[_key(method, path)] = handler;

  /// Serves the JSON value [body] (call `toJson()` on models) for `GET path`.
  void getJson(String path, Object? body, {int status = 200}) =>
      on('GET', path, (_) => FakeResponse(_encodable(body), status: status));

  /// Serves [body] for `POST path`.
  void postJson(String path, Object? body, {int status = 200}) =>
      on('POST', path, (_) => FakeResponse(_encodable(body), status: status));

  /// Requests whose API path equals [path] (and [method] when given).
  List<RequestOptions> requestsTo(String path, {String? method}) => [
    for (final r in requests)
      if (apiPath(r.uri) == path && (method == null || r.method.toUpperCase() == method.toUpperCase())) r,
  ];

  /// The path below the API mount.
  static String apiPath(Uri uri) {
    final p = uri.path;
    for (final prefix in const ['/yh/api/v1', '/api/v1']) {
      if (p.startsWith(prefix)) return p.substring(prefix.length);
    }
    return p;
  }

  static Object? _encodable(Object? body) {
    assert(
      body == null || body is Map || body is List || body is String || body is num || body is bool,
      'pass JSON values (call toJson() on models)',
    );
    return body;
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    final handler = _routes[_key(options.method, apiPath(options.uri))];
    final response = handler == null
        ? FakeResponse.error(404, ApiErrorCode.notFound, message: 'No fake for ${options.method} ${options.uri.path}')
        : await handler(options);
    final failure = response.failure;
    if (failure != null) {
      throw DioException(requestOptions: options, type: failure, message: 'fake $failure');
    }
    final body = response.body;
    return ResponseBody.fromString(
      body == null ? '' : jsonEncode(body),
      response.status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        for (final e in response.headers.entries) e.key: [e.value],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
