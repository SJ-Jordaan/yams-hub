/// The HTTP pipeline middleware (ARCHITECTURE §5.3, §5.15).
library;

import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:yams_models/yams_models.dart';

import '../ids.dart';
import '../log/log.dart';
import '../log/redact.dart';
import '../upstream/upstream_exception.dart';
import 'api_exception.dart';
import 'api_request.dart';
import 'api_response.dart';

final _accessLog = Logger('http.access');
final _errorLog = Logger('http.error');

final _requestIdPattern = RegExp(r'^[A-Za-z0-9-]{8,64}$');

/// CSP of HTML responses (the Flutter web build).
///
/// `base-uri 'self'`, not ARCHITECTURE §5.15's `'none'`: Flutter web needs its
/// `<base href="/">`. With `'none'` the browser ignores it, `document.baseURI`
/// becomes the page URL, and a deep link such as `/login` aborts at startup
/// ("The base href has to end with a "/"") while relative asset URLs resolve
/// against the route. `'self'` still forbids a foreign base URL.
const htmlCsp =
    "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; "
    "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; "
    "connect-src 'self'; font-src 'self' data:; worker-src 'self' blob:; "
    "frame-ancestors 'none'; base-uri 'self'; form-action 'self'";

/// CSP of JSON responses.
const jsonCsp = "default-src 'none'; frame-ancestors 'none'";

bool _isApiPath(String path) =>
    path == 'api' ||
    path.startsWith('api/') ||
    path == 'yh' ||
    path.startsWith('yh/');

/// Reuses `X-Request-Id` when it matches `^[A-Za-z0-9-]{8,64}$`, else
/// generates 16 hex chars; echoed in the response header. Also resolves the
/// client IP and the scheme once for the whole pipeline.
Middleware requestIdMiddleware({required bool trustProxy}) =>
    (inner) => (request) {
      final incoming = request.headers['x-request-id'];
      final id = incoming != null && _requestIdPattern.hasMatch(incoming)
          ? incoming
          : randomHex(16);
      final secure =
          request.requestedUri.scheme == 'https' ||
          (trustProxy &&
              request.headers['x-forwarded-proto']?.toLowerCase() == 'https');
      final r = request.change(
        context: {
          ContextKeys.requestId: id,
          ContextKeys.clientIp: resolveClientIp(
            request,
            trustProxy: trustProxy,
          ),
          ContextKeys.secure: secure,
        },
      );
      return runZoned(() async {
        final response = await inner(r);
        return response.change(headers: {'x-request-id': id});
      }, zoneValues: {requestIdZoneKey: id});
    };

/// Decides whether a `Host` header (without port) is a hub host.
final class HostAllowList {
  HostAllowList({
    List<String> extraHosts = const [],
    List<Uri> publicUrls = const [],
  }) : _exact = {
         'localhost',
         for (final h in extraHosts) h.toLowerCase(),
         for (final u in publicUrls) u.host.toLowerCase(),
       };

  final Set<String> _exact;

  bool allows(String host) {
    final h = host.toLowerCase();
    if (_exact.contains(h)) return true;
    if (h.endsWith('.ts.net')) return true;
    final bare = h.startsWith('[') && h.endsWith(']')
        ? h.substring(1, h.length - 1)
        : h;
    final a = InternetAddress.tryParse(bare);
    if (a == null) return false;
    if (a.isLoopback) return true;
    if (a.type != InternetAddressType.IPv4) return false;
    final b = a.rawAddress;
    // LAN (RFC 1918) and Tailscale CGNAT (100.64.0.0/10) literals.
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
  }

  /// The host part of a `Host` header value.
  static String hostOf(String header) {
    final v = header.trim();
    if (v.startsWith('[')) {
      final end = v.indexOf(']');
      return end < 0 ? v : v.substring(0, end + 1);
    }
    final i = v.lastIndexOf(':');
    return i < 0 ? v : v.substring(0, i);
  }
}

/// Answers `421` (JSON `bad_request`) for requests whose `Host` is not a hub
/// host (DNS-rebinding guard). `GET /api/v1/ping` is exempt.
Middleware hostCheckMiddleware(HostAllowList allowList) =>
    (inner) => (request) {
      final path = request.url.path;
      final isPing =
          (request.method == 'GET' || request.method == 'HEAD') &&
          (path == 'api/v1/ping' || path == 'yh/api/v1/ping');
      if (!isPing) {
        final header = request.headers['host'];
        final host = header == null ? '' : HostAllowList.hostOf(header);
        if (host.isEmpty || !allowList.allows(host)) {
          // This answer short-circuits the later middleware, so it carries
          // the security headers itself.
          return ApiResponse.error(
            const ApiException(
              421,
              ApiErrorCode.badRequest,
              'This host name is not allowed.',
            ),
            request.context[ContextKeys.requestId] as String? ?? 'unknown',
          ).change(
            headers: const {
              'x-content-type-options': 'nosniff',
              'referrer-policy': 'no-referrer',
              'x-frame-options': 'DENY',
              'cross-origin-resource-policy': 'same-origin',
              'cache-control': 'no-store',
              'content-security-policy': jsonCsp,
            },
          );
        }
      }
      return inner(request);
    };

/// Logs every `/api` request at info (path without query string).
Middleware accessLogMiddleware() =>
    (inner) => (request) async {
      final sw = Stopwatch()..start();
      final response = await inner(request);
      if (_isApiPath(request.url.path)) {
        _accessLog.info(
          LogEvent(
            '${request.method} /${request.url.path} ${response.statusCode}',
            {
              'method': request.method,
              'path': '/${request.url.path}',
              'status': response.statusCode,
              'ms': sw.elapsedMilliseconds,
              'user': response.context[ContextKeys.userId] as String?,
            },
          ),
        );
      }
      return response;
    };

/// Security headers on every response; API responses also get
/// `Cache-Control: no-store` (unless set), CORP and the JSON CSP; HTML gets
/// the web CSP.
Middleware securityHeadersMiddleware() =>
    (inner) => (request) async {
      final response = await inner(request);
      final headers = <String, Object>{
        'x-content-type-options': 'nosniff',
        'referrer-policy': 'no-referrer',
        'x-frame-options': 'DENY',
      };
      final api = _isApiPath(request.url.path);
      if (api) {
        headers['cross-origin-resource-policy'] = 'same-origin';
        if (!response.headers.containsKey('cache-control')) {
          headers['cache-control'] = 'no-store';
        }
      }
      if (!response.headers.containsKey('content-security-policy')) {
        final type = response.mimeType ?? '';
        if (type == 'text/html') {
          headers['content-security-policy'] = htmlCsp;
        } else if (api || type == 'application/json') {
          headers['content-security-policy'] = jsonCsp;
        }
      }
      return response.change(headers: headers);
    };

/// CORS for the exact origins of `YAMS_HUB_CORS_ORIGINS` (dev only; no
/// credentials). Preflights from other origins get no CORS headers.
Middleware corsMiddleware(List<String> origins) {
  final allowed = origins.toSet();
  const preflight = {
    'access-control-allow-methods': 'GET, POST, PUT, PATCH, DELETE',
    'access-control-allow-headers':
        'Authorization, Content-Type, X-YAMS-Client, X-Request-Id',
    'access-control-max-age': '600',
  };
  return (inner) => (request) async {
    final origin = request.headers['origin'];
    final ok = origin != null && allowed.contains(origin.toLowerCase());
    if (request.method == 'OPTIONS') {
      if (ok) {
        return Response(
          204,
          headers: {
            'access-control-allow-origin': origin,
            'vary': 'Origin',
            ...preflight,
          },
        );
      }
      return Response(204, headers: {'vary': 'Origin'});
    }
    final response = await inner(request);
    if (!ok) return response;
    return response.change(
      headers: {
        'access-control-allow-origin': origin,
        'vary': 'Origin',
        'access-control-expose-headers': 'ETag, Retry-After, X-Request-Id',
      },
    );
  };
}

/// Maps exceptions to JSON errors. Never returns a stack trace or an
/// exception's own text; logs the type with a redacted message.
Middleware errorHandlerMiddleware() =>
    (inner) => (request) async {
      String requestId() =>
          request.context[ContextKeys.requestId] as String? ?? 'unknown';
      try {
        return await inner(request);
      } on ApiException catch (e) {
        return ApiResponse.error(e, requestId());
      } on UpstreamException catch (e) {
        final api = e.toApiException();
        if (api.status >= 500) {
          _errorLog.warning(
            LogEvent('upstream failure', {
              'service': e.service.name,
              'method': e.method,
              'path': e.path,
              'status': e.status,
              'error': e.runtimeType.toString(),
            }),
          );
        }
        return ApiResponse.error(api, requestId());
      } on FormatException catch (e) {
        _errorLog.warning(
          LogEvent('could not parse an upstream response', {
            'error': 'FormatException: ${redactSecrets(e.message)}',
          }),
        );
        return ApiResponse.error(
          const ApiException(
            502,
            ApiErrorCode.upstreamBadResponse,
            'An upstream response could not be read.',
          ),
          requestId(),
        );
      } on TypeError catch (e, st) {
        _errorLog.warning('unexpected upstream data shape', 'TypeError', st);
        assert(() {
          // Surface the full error in debug runs (tests).
          _errorLog.fine(redactSecrets('$e'));
          return true;
        }());
        return ApiResponse.error(
          const ApiException(
            502,
            ApiErrorCode.upstreamBadResponse,
            'An upstream response could not be read.',
          ),
          requestId(),
        );
      } on HijackException {
        rethrow;
      } catch (e, st) {
        _errorLog.severe(
          'unhandled ${e.runtimeType}: ${redactSecrets('$e')}',
          e.runtimeType.toString(),
          st,
        );
        return ApiResponse.error(ApiException.internal(), requestId());
      }
    };
