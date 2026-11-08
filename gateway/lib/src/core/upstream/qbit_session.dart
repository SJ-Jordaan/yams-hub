/// The gateway's single qBittorrent WebUI session (ARCHITECTURE §5.6).
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:yams_models/yams_models.dart';

import '../../config/config.dart';
import '../../version.dart';
import '../clock.dart';
import 'body_reader.dart';
import 'upstream_client.dart';
import 'upstream_exception.dart';

final _log = Logger('core.upstream.qbittorrent');

const _loginPath = '/api/v2/auth/login';

/// One long-lived cookie session for the whole gateway.
///
/// - Login: `POST /api/v2/auth/login` (form); success is 204 (or 200) with a
///   cookie whose name starts with `QBT_SID_` (parsed, not hard-coded).
///   Logins are single-flight.
/// - A 403 from any call logs in once and retries once.
/// - A 401 (or 403) from login marks [credentialsRejected]: no further login
///   attempt for 10 minutes (5 failures ban the IP for an hour); calls fail
///   fast with `502 upstream_auth_failed`.
final class QbitSession extends UpstreamAuth {
  QbitSession({
    required this._config,
    required this._client,
    required this._clock,
    this.backoff = const Duration(minutes: 10),
  });

  final ServiceConfig _config;
  final http.Client _client;
  final Clock _clock;
  final Duration backoff;

  String? _cookie;
  Future<void>? _login;
  DateTime? _rejectedUntil;
  int _generation = 0;

  /// Incremented on every successful login (the maindata poller restarts from
  /// `rid=0`).
  int get sessionGeneration => _generation;

  /// The credentials were rejected recently; no login is attempted until the
  /// back-off expires.
  bool get credentialsRejected {
    final until = _rejectedUntil;
    return until != null && _clock.now().isBefore(until);
  }

  bool get hasSession => _cookie != null;

  /// Forgets the session (next call logs in).
  void invalidate() => _cookie = null;

  @override
  Future<void> apply(Map<String, String> headers) async {
    if (_cookie == null) await _ensureLogin();
    final c = _cookie;
    if (c != null) headers['cookie'] = c;
  }

  @override
  Future<bool> recover(int status) async {
    if (status != 403) return false;
    _cookie = null;
    await _ensureLogin();
    return _cookie != null;
  }

  Future<void> _ensureLogin() {
    if (credentialsRejected) {
      return Future.error(
        UpstreamCredentialsRejected(
          service: ServiceId.qbittorrent,
          method: 'POST',
          path: _loginPath,
        ),
      );
    }
    return _login ??= _doLogin().whenComplete(() => _login = null);
  }

  Future<void> _doLogin() async {
    final base = _config.url;
    if (base == null || !_config.configured) {
      throw UpstreamNotConfigured(
        service: ServiceId.qbittorrent,
        method: 'POST',
        path: _loginPath,
      );
    }
    final uri = base.replace(
      pathSegments: [
        ...base.pathSegments.where((s) => s.isNotEmpty),
        'api',
        'v2',
        'auth',
        'login',
      ],
    );
    final request = http.Request('POST', uri)
      ..followRedirects = false
      ..headers.addAll({
        'content-type': 'application/x-www-form-urlencoded',
        'user-agent': 'yams-hub/$hubVersion',
      })
      ..bodyBytes = Uri(
        queryParameters: {
          'username': _config.username ?? '',
          'password': _config.password ?? '',
        },
      ).query.codeUnits;
    request.headers['content-type'] = 'application/x-www-form-urlencoded';
    final http.StreamedResponse r;
    try {
      r = await _client.send(request).timeout(defaultUpstreamTimeout);
      await readCapped(
        r.stream,
        maxBytes: 4096,
        timeout: defaultUpstreamTimeout,
      );
    } on TimeoutException {
      throw UpstreamTimeout(
        service: ServiceId.qbittorrent,
        method: 'POST',
        path: _loginPath,
      );
    } on http.ClientException {
      throw UpstreamUnavailable(
        service: ServiceId.qbittorrent,
        method: 'POST',
        path: _loginPath,
      );
    } on SocketException {
      throw UpstreamUnavailable(
        service: ServiceId.qbittorrent,
        method: 'POST',
        path: _loginPath,
      );
    } on BodyTooLargeException {
      throw UpstreamBadResponse(
        service: ServiceId.qbittorrent,
        method: 'POST',
        path: _loginPath,
        reason: 'response too large',
      );
    }
    if (r.statusCode == 401 || r.statusCode == 403) {
      _rejectedUntil = _clock.now().add(backoff);
      _log.severe(
        'qBittorrent rejected the gateway credentials (${r.statusCode}); '
        'no login attempt for ${backoff.inMinutes} min',
      );
      throw UpstreamCredentialsRejected(
        service: ServiceId.qbittorrent,
        method: 'POST',
        path: _loginPath,
        status: r.statusCode,
      );
    }
    if (r.statusCode != 200 && r.statusCode != 204) {
      throw UpstreamException(
        service: ServiceId.qbittorrent,
        method: 'POST',
        path: _loginPath,
        status: r.statusCode,
      );
    }
    final cookie = parseQbitCookie(r.headers['set-cookie'] ?? '');
    if (cookie == null) {
      throw UpstreamBadResponse(
        service: ServiceId.qbittorrent,
        method: 'POST',
        path: _loginPath,
        status: r.statusCode,
        reason: 'login answered without a session cookie',
      );
    }
    _cookie = cookie;
    _rejectedUntil = null;
    _generation++;
    _log.fine('qBittorrent session established (generation $_generation)');
  }
}

/// Extracts `QBT_SID_<port>=<value>` (or legacy `SID=<value>`) from a
/// `Set-Cookie` header (several cookies may be joined by commas).
String? parseQbitCookie(String setCookie) {
  final m = RegExp(r'(?:^|[\s,;])((?:QBT_SID_[A-Za-z0-9_]*|SID))=([^;,\s]+)')
      .firstMatch(setCookie);
  if (m == null) return null;
  return '${m[1]}=${m[2]}';
}
