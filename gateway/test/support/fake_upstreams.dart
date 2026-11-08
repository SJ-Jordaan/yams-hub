/// Fake upstream services on `MockClient.streaming` (ARCHITECTURE §5.19).
///
/// Every service gets its own fake base URL (`http://sonarr.test:8989`, ...);
/// handlers are registered per `(service, method, path)` where `path` is the
/// exact upstream path on the wire (including `/api/v3`, `/v1.54`, ...) or a
/// [RegExp]. Every call is recorded (method, full path, query, headers with
/// secret values replaced by `***`). Unmatched calls answer 404.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yams_hub_gateway/yams_hub_gateway.dart';
import 'package:yams_models/yams_models.dart';

import 'fixtures.dart';

/// An upstream request as a fake handler sees it.
final class FakeRequest {
  FakeRequest(this.method, this.uri, this.headers, this.bodyBytes);

  final String method;
  final Uri uri;

  /// Lower-case header names.
  final Map<String, String> headers;
  final Uint8List bodyBytes;

  String get path => uri.path;
  Map<String, List<String>> get query => uri.queryParametersAll;
  String get body => utf8.decode(bodyBytes, allowMalformed: true);

  /// The JSON body (null when empty).
  Object? json() => bodyBytes.isEmpty ? null : jsonDecode(body);

  /// `application/x-www-form-urlencoded` fields.
  Map<String, String> get form => Uri.splitQueryString(body);
}

/// A fake upstream answer. [body] may be a chunked stream (Docker events,
/// log follow, oversized images).
final class FakeResponse {
  FakeResponse(
    this.status, {
    Stream<List<int>>? body,
    Map<String, String>? headers,
  }) : body = body ?? const Stream.empty(),
       headers = headers ?? const {};

  /// A JSON body.
  factory FakeResponse.json(
    Object? value, {
    int status = 200,
    Map<String, String>? headers,
  }) => FakeResponse(
    status,
    body: Stream.value(utf8.encode(jsonEncode(value))),
    headers: {'content-type': 'application/json; charset=utf-8', ...?headers},
  );

  /// The JSON of a fixture file.
  factory FakeResponse.fixture(String relativePath, {int status = 200}) =>
      FakeResponse(
        status,
        body: Stream.value(fixtureBytes(relativePath)),
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );

  /// A text body.
  factory FakeResponse.text(
    String text, {
    int status = 200,
    String contentType = 'text/plain; charset=utf-8',
    Map<String, String>? headers,
  }) => FakeResponse(
    status,
    body: Stream.value(utf8.encode(text)),
    headers: {'content-type': contentType, ...?headers},
  );

  /// A binary body.
  factory FakeResponse.bytes(
    List<int> bytes, {
    int status = 200,
    String? contentType,
    Map<String, String>? headers,
  }) => FakeResponse(
    status,
    body: Stream.value(bytes),
    headers: {'content-type': ?contentType, ...?headers},
  );

  /// A body delivered in [chunks].
  factory FakeResponse.chunked(
    Stream<List<int>> chunks, {
    int status = 200,
    Map<String, String>? headers,
  }) => FakeResponse(status, body: chunks, headers: headers);

  final int status;
  final Stream<List<int>> body;
  final Map<String, String> headers;
}

typedef FakeHandler = FutureOr<FakeResponse> Function(FakeRequest request);

/// One recorded upstream call.
final class RecordedCall {
  const RecordedCall({
    required this.service,
    required this.host,
    required this.method,
    required this.path,
    required this.query,
    required this.headers,
    required this.body,
  });

  /// Null for internet (remote) hosts.
  final ServiceId? service;
  final String host;
  final String method;

  /// The full upstream path (no query).
  final String path;
  final Map<String, List<String>> query;

  /// Headers with secret values replaced by `***`.
  final Map<String, String> headers;
  final String body;

  @override
  String toString() =>
      '${service?.name ?? host} $method $path${query.isEmpty ? '' : '?$query'}';
}

final class _Route {
  _Route(this.method, this.path, this.handler);

  final String method;
  final Object path;
  final FakeHandler handler;

  bool matches(String m, String p) {
    if (method != m && method != '*') return false;
    final pattern = path;
    if (pattern is RegExp) return pattern.hasMatch(p);
    return pattern == p;
  }
}

const _secretHeaders = {'x-api-key', 'authorization', 'x-api-token', 'cookie'};

/// The fake API key/token of every service (`test-<service>-key`).
String fakeSecret(ServiceId id) => 'test-${id.name}-key';

/// Fake upstream services and fake internet hosts.
final class FakeUpstreams {
  FakeUpstreams() {
    // qBittorrent accepts the gateway login by default.
    on(
      ServiceId.qbittorrent,
      'POST',
      '/api/v2/auth/login',
      (_) => FakeResponse(
        204,
        headers: {
          'set-cookie':
              'QBT_SID_8081=fake-session; HttpOnly; SameSite=Lax; path=/',
        },
      ),
    );
  }

  /// Base URL of each fake service.
  static const baseUrls = {
    ServiceId.sonarr: 'http://sonarr.test:8989',
    ServiceId.radarr: 'http://radarr.test:7878',
    ServiceId.prowlarr: 'http://prowlarr.test:9696',
    ServiceId.bazarr: 'http://bazarr.test:6767',
    ServiceId.seerr: 'http://seerr.test:5055',
    ServiceId.jellyfin: 'http://jellyfin.test:8096',
    ServiceId.jellystat: 'http://jellystat.test:3000',
    ServiceId.qbittorrent: 'http://gluetun.test:8081',
    ServiceId.gluetun: 'http://gluetun-control.test:8000',
    ServiceId.docker: 'http://socket-proxy-hub.test:2375',
    ServiceId.watchtower: 'http://watchtower.test:8080',
    ServiceId.updater: 'http://yams-hub-updater.test:8080',
    ServiceId.uptimeKuma: 'http://uptime-kuma.test:3001',
    ServiceId.audiobookshelf: 'http://audiobookshelf.test:80',
    ServiceId.kavita: 'http://kavita.test:5000',
    ServiceId.shelfmark: 'http://shelfmark.test:8084',
  };

  static const _envNames = {
    ServiceId.sonarr: ('SONARR_URL', 'SONARR_API_KEY'),
    ServiceId.radarr: ('RADARR_URL', 'RADARR_API_KEY'),
    ServiceId.prowlarr: ('PROWLARR_URL', 'PROWLARR_API_KEY'),
    ServiceId.bazarr: ('BAZARR_URL', 'BAZARR_API_KEY'),
    ServiceId.seerr: ('SEERR_URL', 'SEERR_API_KEY'),
    ServiceId.jellyfin: ('JELLYFIN_URL', 'JELLYFIN_API_KEY'),
    ServiceId.jellystat: ('JELLYSTAT_URL', 'JELLYSTAT_API_KEY'),
    ServiceId.qbittorrent: ('QBIT_URL', null),
    ServiceId.gluetun: ('GLUETUN_URL', null),
    ServiceId.docker: ('DOCKER_URL', null),
    ServiceId.watchtower: ('WATCHTOWER_URL', 'WATCHTOWER_TOKEN'),
    ServiceId.updater: ('UPDATER_URL', 'UPDATER_TOKEN'),
    ServiceId.uptimeKuma: ('UPTIME_KUMA_URL', null),
    ServiceId.audiobookshelf: ('ABS_URL', 'ABS_API_KEY'),
    ServiceId.kavita: ('KAVITA_URL', 'KAVITA_API_KEY'),
    ServiceId.shelfmark: ('SHELFMARK_URL', null),
  };

  final _routes = <ServiceId, List<_Route>>{};
  final _remote = <String, List<_Route>>{};
  final List<RecordedCall> calls = [];

  /// Addresses the fake DNS returns per host (default: a public address).
  final Map<String, List<InternetAddress>> dns = {};

  /// Environment variables that configure every service against the fakes
  /// (unless listed in [unconfigured]).
  Map<String, String> env({Set<ServiceId> unconfigured = const {}}) {
    final out = <String, String>{};
    for (final e in _envNames.entries) {
      final (urlVar, secretVar) = e.value;
      if (unconfigured.contains(e.key)) {
        out[urlVar] = '';
        continue;
      }
      out[urlVar] = baseUrls[e.key]!;
      if (secretVar != null) {
        out[secretVar] = e.key == ServiceId.updater
            ? 'test-updater-token-0123456789abcdef0123'
            : fakeSecret(e.key);
      }
    }
    if (!unconfigured.contains(ServiceId.qbittorrent)) {
      out['QBIT_USERNAME'] = 'qbit-user';
      out['QBIT_PASSWORD'] = 'qbit-pass';
    }
    return out;
  }

  /// Registers [handler] for [service] `method path` (later registrations
  /// win). [path] is a `String` (exact) or a [RegExp]; `method` `*` matches
  /// any method.
  void on(ServiceId service, String method, Object path, FakeHandler handler) {
    (_routes[service] ??= []).insert(0, _Route(method, path, handler));
  }

  /// Like [on] with a JSON fixture body.
  void onFixture(
    ServiceId service,
    String method,
    Object path,
    String fixturePath, {
    int status = 200,
  }) => on(
    service,
    method,
    path,
    (_) => FakeResponse.fixture(fixturePath, status: status),
  );

  /// Registers an internet host (for `RemoteFetcher`, e.g. `image.tmdb.org`).
  void onRemote(String host, String method, Object path, FakeHandler handler) {
    (_remote[host.toLowerCase()] ??= []).insert(
      0,
      _Route(method, path, handler),
    );
  }

  /// Calls made to [service].
  List<RecordedCall> callsTo(ServiceId service) => [
    for (final c in calls)
      if (c.service == service) c,
  ];

  /// Calls made to the internet host [host].
  List<RecordedCall> remoteCalls(String host) => [
    for (final c in calls)
      if (c.service == null && c.host == host) c,
  ];

  void clearCalls() => calls.clear();

  ServiceId? _serviceOf(Uri uri) {
    for (final e in baseUrls.entries) {
      final b = Uri.parse(e.value);
      if (b.host == uri.host && b.port == uri.port) return e.key;
    }
    return null;
  }

  /// The client for `Upstreams` and the remote fetcher.
  late final http.Client client = MockClient.streaming(_handle);

  /// A `RemoteFetcher` on the fake client with a fake DNS (public address
  /// `93.184.216.34` unless [dns] says otherwise).
  RemoteFetcher remoteFetcher() => RemoteFetcher(
    client: client,
    lookup: (host) async =>
        dns[host.toLowerCase()] ?? [InternetAddress('93.184.216.34')],
  );

  Future<http.StreamedResponse> _handle(
    http.BaseRequest request,
    http.ByteStream bodyStream,
  ) async {
    final bytes = await bodyStream.toBytes();
    final uri = request.url;
    final service = _serviceOf(uri);
    final headers = {
      for (final e in request.headers.entries) e.key.toLowerCase(): e.value,
    };
    calls.add(
      RecordedCall(
        service: service,
        host: uri.host,
        method: request.method,
        path: uri.path,
        query: uri.queryParametersAll,
        headers: {
          for (final e in headers.entries)
            e.key: _secretHeaders.contains(e.key) ? '***' : e.value,
        },
        body: utf8.decode(bytes, allowMalformed: true),
      ),
    );
    final routes = service == null
        ? _remote[uri.host.toLowerCase()]
        : _routes[service];
    final route = routes
        ?.where((r) => r.matches(request.method, uri.path))
        .firstOrNull;
    final FakeResponse response;
    if (route == null) {
      response = FakeResponse.json({
        'message': 'no fake for ${request.method} ${uri.path}',
      }, status: 404);
    } else {
      response = await route.handler(
        FakeRequest(request.method, uri, headers, bytes),
      );
    }
    return http.StreamedResponse(
      response.body,
      response.status,
      headers: response.headers,
      request: request,
    );
  }
}
