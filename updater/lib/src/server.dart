/// The updater's HTTP API (gateway-facing only; ARCHITECTURE §5.17).
///
/// | Route | Result |
/// |---|---|
/// | `GET /healthz` | `{"status":"ok","version":"1.0.0"}` |
/// | `GET /services` | `{"services":[...]}` (allow-list minus deny-list) |
/// | `POST /update/{service}` | 202 `{"jobId"}`, 404 unknown/denied, 409 busy, 503 shutting down |
/// | `POST /exec/recyclarr-sync` | 202 `{"jobId"}`, 409 busy, 503 shutting down |
/// | `GET /jobs/{id}` | the job, 404 unknown/expired |
///
/// With `UPDATER_ALLOWED_SOURCES` set, a request whose TCP peer is not in the
/// list (loopback always is) gets a bare 403 before anything else, the token
/// check included. Every other request without the bearer token gets 401,
/// including unknown paths, so nothing can be probed without it. Request
/// bodies are never read or logged; query strings are never logged.
library;

import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'allow_list.dart';
import 'auth.dart';
import 'commands.dart';
import 'config.dart';
import 'jobs.dart';
import 'source_allow_list.dart';
import 'version.dart';

final _log = Logger('updater.http');

/// Builds the complete handler (source check → logging → auth → routes).
///
/// [allowedSources] null means any peer may try the token (`serve` warns).
Handler buildUpdaterHandler({
  required BearerAuth auth,
  required ServiceAllowList allowList,
  required JobManager jobs,
  required ComposeCommands commands,
  SourceAllowList? allowedSources,
}) {
  final router =
      Router(notFoundHandler: (_) => _error(404, 'not_found', 'Not found'))
        ..get(
          '/healthz',
          (Request _) =>
              _json(200, {'status': 'ok', 'version': updaterVersion}),
        )
        ..get(
          '/services',
          (Request _) async =>
              _json(200, {'services': await allowList.servicesFresh()}),
        )
        ..post('/update/<service>', (Request _, String service) async {
          // shelf_router hands over the raw (percent-decoded) segment; validate
          // it again here, then require it in the allow-list.
          if (!isValidServiceName(service) ||
              !await allowList.allowsFresh(service)) {
            return _error(404, 'not_found', 'Unknown or denied service');
          }
          return _startJob(
            jobs,
            kind: JobKind.update,
            service: service,
            plan: commands.updatePlan(service),
          );
        })
        ..post(
          '/exec/recyclarr-sync',
          (Request _) => _startJob(
            jobs,
            kind: JobKind.recyclarrSync,
            service: 'recyclarr',
            plan: ComposeCommands.recyclarrSyncPlan,
          ),
        )
        ..get('/jobs/<id>', (Request _, String id) {
          final job = jobIdPattern.hasMatch(id) ? jobs[id] : null;
          if (job == null) return _error(404, 'not_found', 'Unknown job');
          return _json(200, job.toJson());
        });

  var pipeline = const Pipeline();
  if (allowedSources != null) {
    pipeline = pipeline.addMiddleware(requireAllowedSource(allowedSources));
  }
  return pipeline
      .addMiddleware(_accessLog())
      .addMiddleware(_requireBearer(auth))
      .addHandler(router.call);
}

Response _startJob(
  JobManager jobs, {
  required JobKind kind,
  required String service,
  required List<StepSpec> plan,
}) {
  try {
    final job = jobs.start(kind: kind, service: service, plan: plan);
    return _json(202, {'jobId': job.id});
  } on JobBusyException catch (e) {
    return _json(409, {
      'error': 'busy',
      'message': 'Another job is running',
      'jobId': e.activeJobId,
    });
  } on JobManagerClosedException {
    return _error(503, 'shutting_down', 'The updater is shutting down');
  }
}

/// The `request.context` key under which `shelf_io` stores the
/// [HttpConnectionInfo] of the request's connection.
const connectionInfoKey = 'shelf.io.connection_info';

/// 403 (no detail) for every request whose TCP peer [sources] does not allow,
/// before logging, auth and routing. A request without connection info (not
/// served by `shelf_io`) is refused too: the check fails closed.
Middleware requireAllowedSource(SourceAllowList sources) {
  final log = _RejectLog();
  return (inner) => (request) {
    final info = request.context[connectionInfoKey];
    final peer = info is HttpConnectionInfo ? info.remoteAddress : null;
    if (peer == null || !sources.allows(peer)) {
      log.rejected(peer, request.method);
      return _error(403, 'forbidden', 'Forbidden');
    }
    return inner(request);
  };
}

/// Logs refused peers at WARNING, at most once a minute per address (with
/// the number of refusals since), so a noisy neighbour cannot flood the log.
final class _RejectLog {
  static const _every = Duration(minutes: 1);
  static const _maxTracked = 256;

  final _last = <String, (DateTime, int)>{};

  void rejected(InternetAddress? peer, String method) {
    final ip = peer?.address ?? 'unknown peer';
    final now = DateTime.now();
    final seen = _last[ip];
    if (seen != null && now.difference(seen.$1) < _every) {
      _last[ip] = (seen.$1, seen.$2 + 1);
      return;
    }
    final since = seen == null || seen.$2 == 0
        ? ''
        : ' (${seen.$2} more since the last report)';
    _log.warning(
      'refused $method from $ip: not in UPDATER_ALLOWED_SOURCES$since',
    );
    if (_last.length >= _maxTracked && !_last.containsKey(ip)) _last.clear();
    _last[ip] = (now, 0);
  }
}

/// 401 for every request without the right bearer token, before routing.
Middleware _requireBearer(BearerAuth auth) =>
    (inner) => (request) {
      if (!auth.accepts(request.headers['authorization'])) {
        return _error(
          401,
          'unauthorized',
          'Missing or invalid token',
          headers: const {'www-authenticate': 'Bearer'},
        );
      }
      return inner(request);
    };

/// Logs method, path, status and duration only (no query, headers or body).
/// Health checks log at FINE so the 30 s Docker healthcheck does not flood.
Middleware _accessLog() =>
    (inner) => (request) async {
      final sw = Stopwatch()..start();
      final path = '/${request.url.path}';
      void write(int status) {
        final level = path == '/healthz' && status == 200
            ? Level.FINE
            : Level.INFO;
        _log.log(
          level,
          '${request.method} ${_clipPath(path)} $status ${sw.elapsedMilliseconds}ms',
        );
      }

      try {
        final response = await inner(request);
        write(response.statusCode);
        return response;
      } on HijackException {
        rethrow;
      } on Object catch (e, st) {
        _log.severe(
          '${request.method} ${_clipPath(path)} failed (${e.runtimeType})',
          null,
          st,
        );
        write(500);
        return _error(500, 'internal', 'Internal error');
      }
    };

String _clipPath(String p) => p.length <= 120 ? p : '${p.substring(0, 120)}…';

const _jsonHeaders = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
  'x-content-type-options': 'nosniff',
};

Response _json(
  int status,
  Object body, {
  Map<String, String> headers = const {},
}) => Response(
  status,
  body: jsonEncode(body),
  headers: {..._jsonHeaders, ...headers},
);

Response _error(
  int status,
  String code,
  String message, {
  Map<String, String> headers = const {},
}) => _json(status, {'error': code, 'message': message}, headers: headers);
