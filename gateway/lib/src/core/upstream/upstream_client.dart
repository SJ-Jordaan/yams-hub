/// HTTP transport to one upstream service (ARCHITECTURE §5.6).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:yams_models/yams_models.dart';

import '../../config/config.dart';
import '../../version.dart';
import '../log/log.dart';
import '../log/redact.dart';
import 'body_reader.dart';
import 'multipart.dart';
import 'upstream_exception.dart';

export 'multipart.dart' show MultipartPart;

final _log = Logger('core.upstream');

/// Default per-call timeout.
const defaultUpstreamTimeout = Duration(seconds: 10);

/// Cap for error bodies read to extract a message.
const _errorBodyCap = 64 * 1024;

/// Adds credentials to upstream requests.
abstract class UpstreamAuth {
  const UpstreamAuth();

  /// Adds headers to an outgoing request (may log in first).
  FutureOr<void> apply(Map<String, String> headers);

  /// Called with a non-2xx status; returns true when the request should be
  /// retried once (qBittorrent re-login on 403).
  Future<bool> recover(int status) async => false;
}

/// No credentials (gluetun, Uptime Kuma, Docker proxy, Shelfmark).
final class NoAuth extends UpstreamAuth {
  const NoAuth();

  @override
  void apply(Map<String, String> headers) {}
}

/// Static credential headers.
final class HeaderAuth extends UpstreamAuth {
  const HeaderAuth(this.headers);

  final Map<String, String> headers;

  @override
  void apply(Map<String, String> h) => h.addAll(headers);
}

/// A raw upstream response.
final class UpstreamResponse {
  const UpstreamResponse({
    required this.service,
    required this.method,
    required this.path,
    required this.status,
    required this.headers,
    required this.bodyBytes,
  });

  final ServiceId service;
  final String method;
  final String path;
  final int status;

  /// Lower-case header names.
  final Map<String, String> headers;
  final Uint8List bodyBytes;

  bool get ok => status >= 200 && status < 300;

  String? get contentType => headers['content-type'];

  /// The body as UTF-8 text.
  String text() => utf8.decode(bodyBytes, allowMalformed: true);

  /// The body decoded as JSON (regardless of the content type: gluetun sends
  /// JSON as text/plain). Empty bodies are null.
  Object? json() {
    if (bodyBytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(bodyBytes));
    } on FormatException {
      throw UpstreamBadResponse(
        service: service,
        method: method,
        path: path,
        status: status,
        reason: 'invalid JSON',
      );
    }
  }

  /// Throws the mapped [UpstreamException] unless the status is 2xx.
  UpstreamResponse ensureOk() {
    if (ok) return this;
    throw errorFor(service, method, path, status, bodyBytes, contentType);
  }
}

/// Builds the [UpstreamException] for a non-2xx response.
UpstreamException errorFor(
  ServiceId service,
  String method,
  String path,
  int status,
  List<int> body,
  String? contentType,
) {
  final extracted = extractUpstreamError(
    status,
    body,
    contentType: contentType,
  );
  final snippet = body.isEmpty
      ? null
      : redactSecrets(
          utf8.decode(
            body.length > 200 ? body.sublist(0, 200) : body,
            allowMalformed: true,
          ),
        );
  return UpstreamException(
    service: service,
    method: method,
    path: path,
    status: status,
    message: extracted.message,
    validation: extracted.validation,
    bodySnippet: snippet,
  );
}

/// A long-lived response body (Docker events, log follow).
final class UpstreamStream {
  UpstreamStream({
    required this.status,
    required this.headers,
    required this.body,
  });

  final int status;
  final Map<String, String> headers;

  /// The body; cancel the subscription to close the connection.
  final Stream<List<int>> body;
}

/// One client per service. `path` arguments are absolute from the service
/// root and include the API prefix (`/api/v3/series`), unencoded, without a
/// query string; query values may be `String`, `num`, `bool` or an `Iterable`
/// of those (repeated keys). [rawQuery] is used as-is (Seerr's strict
/// encoding).
///
/// Transport errors are never rethrown with their own text (it contains the
/// URI): they become [UpstreamUnavailable] / [UpstreamTimeout] carrying only
/// service, method and path. Redirects are not followed.
class UpstreamClient {
  UpstreamClient({
    required this.service,
    required ServiceConfig config,
    required this._client,
    this._auth = const NoAuth(),
    this.defaultTimeout = defaultUpstreamTimeout,
  }) : baseUrl =
           config.url ??
           Uri.parse('http://${service.name.toLowerCase()}.invalid'),
       configured = config.configured;

  final ServiceId service;
  final Uri baseUrl;
  final bool configured;
  final Duration defaultTimeout;
  final http.Client _client;
  final UpstreamAuth _auth;

  /// Prepended to every path (Docker's pinned API version).
  String get pathPrefix => '';

  /// The full URI for [path] (exposed for tests and image routes).
  Uri buildUri(String path, {Map<String, Object?>? query, String? rawQuery}) {
    if (!path.startsWith('/')) {
      throw ArgumentError.value(path, 'path', 'must start with /');
    }
    if (path.contains('?') || path.contains('#')) {
      throw ArgumentError.value(
        path,
        'path',
        'pass query parameters separately',
      );
    }
    final full = '$pathPrefix$path';
    final raw = full.split('/').skip(1).toList();
    for (final s in raw) {
      if (s == '.' || s == '..') {
        throw ArgumentError.value(path, 'path', 'dot segments are not allowed');
      }
    }
    final segments = [
      ...baseUrl.pathSegments.where((s) => s.isNotEmpty),
      ...raw,
    ];
    var uri = baseUrl.replace(pathSegments: segments);
    if (rawQuery != null && rawQuery.isNotEmpty) {
      uri = uri.replace(query: rawQuery);
    } else if (query != null) {
      final qp = encodeQuery(query);
      if (qp.isNotEmpty) uri = uri.replace(queryParameters: qp);
    }
    return uri;
  }

  /// Converts a query map to `Uri.queryParameters` values.
  static Map<String, dynamic> encodeQuery(Map<String, Object?> query) {
    final out = <String, dynamic>{};
    for (final e in query.entries) {
      final v = e.value;
      if (v == null) continue;
      if (v is Iterable) {
        final list = [
          for (final x in v)
            if (x != null) '$x',
        ];
        if (list.isNotEmpty) out[e.key] = list;
      } else {
        out[e.key] = '$v';
      }
    }
    return out;
  }

  UpstreamException _notConfigured(String method, String path) =>
      UpstreamNotConfigured(service: service, method: method, path: path);

  /// GET [path] and decode the JSON body; non-2xx throws [UpstreamException].
  Future<Object?> getJson(
    String path, {
    Map<String, Object?>? query,
    String? rawQuery,
    Duration? timeout,
    Map<String, String>? headers,
  }) async {
    final r = await send(
      'GET',
      path,
      query: query,
      rawQuery: rawQuery,
      timeout: timeout,
      headers: headers,
    );
    return r.ensureOk().json();
  }

  /// Sends [body] as JSON and decodes the JSON answer (null for empty bodies);
  /// non-2xx throws [UpstreamException].
  Future<Object?> sendJson(
    String method,
    String path, {
    Object? body,
    Map<String, Object?>? query,
    String? rawQuery,
    Duration? timeout,
    Map<String, String>? headers,
  }) async {
    final r = await send(
      method,
      path,
      jsonBody: body,
      query: query,
      rawQuery: rawQuery,
      timeout: timeout,
      headers: headers,
    );
    return r.ensureOk().json();
  }

  /// Sends a request and returns the raw response whatever its status. At
  /// most one of [jsonBody], [form], [multipart] and [bytes] may be given.
  /// [maxBytes] aborts the body once exceeded ([UpstreamBadResponse]
  /// "response too large").
  Future<UpstreamResponse> send(
    String method,
    String path, {
    Object? jsonBody,
    Map<String, String>? form,
    List<MultipartPart>? multipart,
    List<int>? bytes,
    String? contentType,
    Map<String, Object?>? query,
    String? rawQuery,
    Duration? timeout,
    Map<String, String>? headers,
    int? maxBytes,
  }) async {
    if (!configured) throw _notConfigured(method, path);
    final uri = buildUri(path, query: query, rawQuery: rawQuery);
    Uint8List? body;
    String? type = contentType;
    final bodies = [
      jsonBody,
      form,
      multipart,
      bytes,
    ].where((b) => b != null).length;
    if (bodies > 1) throw ArgumentError('only one request body may be given');
    if (jsonBody != null) {
      body = utf8.encode(jsonEncode(jsonBody));
      type ??= 'application/json';
    } else if (form != null) {
      body = utf8.encode(Uri(queryParameters: form).query);
      type ??= 'application/x-www-form-urlencoded';
    } else if (multipart != null) {
      final mp = encodeMultipart(multipart);
      body = mp.bytes;
      type = mp.contentType;
    } else if (bytes != null) {
      body = Uint8List.fromList(bytes);
    }

    final t = timeout ?? defaultTimeout;
    final sw = Stopwatch()..start();
    var response = await _sendOnce(
      method,
      uri,
      path,
      body,
      type,
      headers,
      t,
      maxBytes,
    );
    if (!response.ok && await _auth.recover(response.status)) {
      response = await _sendOnce(
        method,
        uri,
        path,
        body,
        type,
        headers,
        t,
        maxBytes,
      );
    }
    _log.fine(
      LogEvent('upstream call', {
        'service': service.name,
        'method': method,
        'path': '$pathPrefix$path',
        'status': response.status,
        'ms': sw.elapsedMilliseconds,
      }),
    );
    return response;
  }

  Future<UpstreamResponse> _sendOnce(
    String method,
    Uri uri,
    String path,
    Uint8List? body,
    String? contentType,
    Map<String, String>? extraHeaders,
    Duration timeout,
    int? maxBytes,
  ) async {
    final h = <String, String>{
      'accept': 'application/json',
      'accept-encoding': 'gzip',
      'user-agent': 'yams-hub/$hubVersion',
    };
    await _auth.apply(h);
    if (extraHeaders != null) {
      for (final e in extraHeaders.entries) {
        h[e.key.toLowerCase()] = e.value;
      }
    }
    if (contentType != null) h['content-type'] = contentType;
    h.remove('origin');
    h.remove('referer');

    final request = http.Request(method, uri)
      ..followRedirects = false
      ..persistentConnection = true
      ..headers.addAll(h);
    if (body != null) request.bodyBytes = body;
    // bodyBytes sets a text/plain default; restore ours.
    if (contentType != null) request.headers['content-type'] = contentType;

    final deadline = DateTime.now().add(timeout);
    final p = '$pathPrefix$path';
    try {
      final streamed = await _client.send(request).timeout(timeout);
      final remaining = deadline.difference(DateTime.now());
      final ok = streamed.statusCode >= 200 && streamed.statusCode < 300;
      final cap = ok ? maxBytes : _errorBodyCap;
      final Uint8List bytes;
      try {
        bytes = await readCapped(
          streamed.stream,
          maxBytes: cap,
          timeout: remaining.isNegative ? Duration.zero : remaining,
        );
      } on BodyTooLargeException {
        if (!ok) {
          return UpstreamResponse(
            service: service,
            method: method,
            path: p,
            status: streamed.statusCode,
            headers: _lower(streamed.headers),
            bodyBytes: Uint8List(0),
          );
        }
        throw UpstreamBadResponse(
          service: service,
          method: method,
          path: p,
          status: streamed.statusCode,
          reason: 'response too large',
        );
      }
      return UpstreamResponse(
        service: service,
        method: method,
        path: p,
        status: streamed.statusCode,
        headers: _lower(streamed.headers),
        bodyBytes: bytes,
      );
    } on UpstreamException {
      rethrow;
    } on TimeoutException {
      throw UpstreamTimeout(service: service, method: method, path: p);
    } on http.ClientException {
      throw UpstreamUnavailable(service: service, method: method, path: p);
    } on SocketException {
      throw UpstreamUnavailable(service: service, method: method, path: p);
    } on HttpException {
      throw UpstreamUnavailable(service: service, method: method, path: p);
    } on TlsException {
      throw UpstreamUnavailable(service: service, method: method, path: p);
    } on OSError {
      throw UpstreamUnavailable(service: service, method: method, path: p);
    }
  }

  /// Opens a long-lived GET (no body timeout). Non-2xx throws
  /// [UpstreamException].
  Future<UpstreamStream> openStream(
    String path, {
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration connectTimeout = defaultUpstreamTimeout,
  }) async {
    const method = 'GET';
    if (!configured) throw _notConfigured(method, path);
    final uri = buildUri(path, query: query);
    final h = <String, String>{
      'accept': 'application/json',
      'user-agent': 'yams-hub/$hubVersion',
    };
    await _auth.apply(h);
    if (headers != null) h.addAll(headers);
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers.addAll(h);
    final p = '$pathPrefix$path';
    try {
      final streamed = await _client.send(request).timeout(connectTimeout);
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        List<int> bytes;
        try {
          bytes = await readCapped(
            streamed.stream,
            maxBytes: _errorBodyCap,
            timeout: connectTimeout,
          );
        } on Exception {
          bytes = const [];
        }
        throw errorFor(
          service,
          method,
          p,
          streamed.statusCode,
          bytes,
          streamed.headers['content-type'],
        );
      }
      _log.fine(
        LogEvent('upstream stream opened', {
          'service': service.name,
          'method': method,
          'path': p,
          'status': streamed.statusCode,
        }),
      );
      return UpstreamStream(
        status: streamed.statusCode,
        headers: _lower(streamed.headers),
        body: streamed.stream.handleError((Object e) {
          // Never surface the transport text (it contains the URI).
          throw UpstreamUnavailable(service: service, method: method, path: p);
        }, test: (e) => e is! UpstreamException),
      );
    } on UpstreamException {
      rethrow;
    } on TimeoutException {
      throw UpstreamTimeout(service: service, method: method, path: p);
    } on Exception {
      throw UpstreamUnavailable(service: service, method: method, path: p);
    }
  }

  static Map<String, String> _lower(Map<String, String> h) => {
    for (final e in h.entries) e.key.toLowerCase(): e.value,
  };
}

/// The Docker client: every path gets the pinned API version prefix
/// (`/containers/json` → `/v1.54/containers/json`).
final class DockerClient extends UpstreamClient {
  DockerClient({
    required super.config,
    required super.client,
    this.apiVersion = 'v1.54',
  }) : super(service: ServiceId.docker);

  final String apiVersion;

  @override
  String get pathPrefix => '/$apiVersion';
}
