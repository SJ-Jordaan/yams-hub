/// JSON responses (ARCHITECTURE §5.3).
library;

import 'dart:convert';
import 'dart:io' show gzip;

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:yams_models/yams_models.dart';

import 'api_exception.dart';
import 'api_request.dart';

const jsonContentType = 'application/json; charset=utf-8';

/// Builds API responses.
abstract final class ApiResponse {
  /// A JSON response. [body] is a model with `toJson()`, a `Map` or a `List`
  /// (envelopes such as `ItemList` must be converted by the caller with their
  /// item codec).
  static Response json(
    Object? body, {
    int status = 200,
    Map<String, Object>? headers,
  }) {
    final bytes = utf8.encode(jsonEncode(body));
    return Response(
      status,
      body: bytes,
      headers: {'content-type': jsonContentType, ...?headers},
      context: {ContextKeys.jsonBody: bytes},
    );
  }

  /// `204 No Content`.
  static Response noContent({Map<String, Object>? headers}) =>
      Response(204, headers: headers);

  /// `ItemList<T>` as `{"items": [...]}`.
  static Response items<T>(
    Iterable<T> items,
    JsonMap Function(T) codec, {
    int status = 200,
  }) => json({
    'items': [for (final i in items) codec(i)],
  }, status: status);

  /// The error body for [e].
  static Response error(ApiException e, String requestId) {
    final headers = <String, Object>{'content-type': jsonContentType};
    if (e.retryAfterSeconds case final s?) headers['retry-after'] = '$s';
    return Response(
      e.status,
      body: utf8.encode(jsonEncode(e.toApiError(requestId).toResponseBody())),
      headers: headers,
      context: {ContextKeys.errorCode: e.code},
    );
  }
}

/// The JSON `404 not_found` returned for unknown paths and method mismatches.
Response jsonNotFound(Request request) => ApiResponse.error(
  ApiException.notFound('No such endpoint.'),
  request.context[ContextKeys.requestId] as String? ?? 'unknown',
);

/// Adds a weak ETag to GET JSON responses (answering `If-None-Match` with
/// 304) and gzips bodies over 1 KiB when the client accepts it.
Middleware jsonFinisher() =>
    (inner) => (request) async {
      final response = await inner(request);
      final bytes = response.context[ContextKeys.jsonBody];
      if (bytes is! List<int>) return response;
      final isGet = request.method == 'GET' || request.method == 'HEAD';
      var r = response;
      if (isGet && response.statusCode == 200) {
        final etag = 'W/"${sha1.convert(bytes)}"';
        final inm = request.headers['if-none-match'];
        if (inm != null && inm.split(',').map((s) => s.trim()).contains(etag)) {
          return Response.notModified(headers: {'etag': etag});
        }
        r = r.change(headers: {'etag': etag});
      }
      final accept = request.headers['accept-encoding'] ?? '';
      if (bytes.length > 1024 &&
          request.method != 'HEAD' &&
          accept.toLowerCase().contains('gzip') &&
          !r.headers.containsKey('content-encoding')) {
        final gz = gzip.encode(bytes);
        final headers = Map<String, Object>.of(r.headersAll)
          ..remove('content-length')
          ..['content-encoding'] = 'gzip'
          ..['vary'] = 'Accept-Encoding';
        r = Response(
          r.statusCode,
          body: gz,
          headers: headers,
          context: r.context,
        );
      }
      return r;
    };
