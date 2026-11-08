/// Re-probes the server's URLs on connection problems (ARCHITECTURE §7.4).
library;

import 'dart:async';

import 'package:dio/dio.dart';

import '../api_exception.dart';

/// Asks the server resolver to re-probe the profile's URLs; returns the API
/// base URL to use now (possibly a different one), or null when nothing is
/// reachable.
typedef Reprobe = Future<String?> Function();

/// On a connection problem, re-probes the active profile and retries once
/// against the URL that answers (with a valid server proof).
///
/// Retries **only** `GET`/`HEAD`, or any method when the request never left the
/// device (`connectionError`, `connectionTimeout`). A `receiveTimeout` or
/// `sendTimeout` on any other method is never retried: the gateway may already
/// have run the action, so the error becomes [ApiException.resultUnknown].
class FailoverInterceptor extends Interceptor {
  FailoverInterceptor({required this.dio, required this.reprobe});

  final Dio dio;
  final Reprobe reprobe;

  static const _retriedKey = 'yh.failoverRetried';

  static bool isConnectionProblem(DioExceptionType type) => switch (type) {
    DioExceptionType.connectionError ||
    DioExceptionType.connectionTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.sendTimeout => true,
    _ => false,
  };

  /// Whether a request that failed with [type] may be sent again.
  static bool mayRetry(String method, DioExceptionType type) {
    final m = method.toUpperCase();
    if (m == 'GET' || m == 'HEAD') return true;
    return type == DioExceptionType.connectionError || type == DioExceptionType.connectionTimeout;
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    // Already converted (a retry that failed through the whole chain) or
    // already retried once: pass through.
    if (err.error is ApiException ||
        options.extra[_retriedKey] == true ||
        !isConnectionProblem(err.type)) {
      return handler.next(err);
    }

    if (!mayRetry(options.method, err.type)) {
      // Never resend; still look for a working URL for the next request.
      unawaited(_safeReprobe());
      return handler.next(err.copyWith(error: const ApiException.resultUnknown()));
    }

    final base = await _safeReprobe();
    if (base == null) return handler.next(err);

    final retry = options.copyWith(
      baseUrl: base,
      headers: Map.of(options.headers)..remove('Authorization'),
      extra: {...options.extra, _retriedKey: true},
    );
    try {
      handler.resolve(await dio.fetch<Object?>(retry));
    } on DioException catch (e) {
      handler.next(e);
    }
  }

  Future<String?> _safeReprobe() async {
    try {
      return await reprobe();
    } catch (_) {
      return null;
    }
  }
}
