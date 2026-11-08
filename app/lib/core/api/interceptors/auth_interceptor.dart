/// Adds credentials and refreshes them transparently (ARCHITECTURE §7.4).
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:yams_models/yams_models.dart';

/// What [AuthInterceptor] needs from the token holder.
abstract interface class AuthSession {
  /// Cookie transport: the browser sends `yh_at`/`yh_rt`; no header is added.
  bool get cookieTransport;

  /// The current access token (bearer transport), if any.
  String? get accessToken;

  /// The current refresh token (bearer transport), if any.
  String? get refreshToken;

  /// Persists a rotated pair from `POST /auth/refresh`.
  Future<void> storeTokens(TokenPair tokens);

  /// The session is gone (refresh rejected): clear credentials, which sends
  /// the router to `/login`.
  Future<void> expire();
}

/// Header carrying the client id; required by the gateway's CSRF check on
/// every cookie-authenticated request (API.md §1.3).
const String hubClientHeaderName = 'X-YAMS-Client';

/// 1. Adds `Authorization: Bearer <access>` (bearer transport).
/// 2. On `401 token_expired|unauthorized` runs one **single-flight** refresh
///    through a separate interceptor-free Dio that copies the main Dio's
///    `baseUrl` and `X-YAMS-Client` header, then retries the request once.
/// 3. If the refresh is rejected, [AuthSession.expire] clears the session.
class AuthInterceptor extends Interceptor {
  AuthInterceptor({required this.dio, required this.session});

  /// The main Dio (retries go through it, the refresh Dio copies its options).
  final Dio dio;
  final AuthSession session;

  Future<bool>? _refreshing;

  static const _retriedKey = 'yh.authRetried';
  static const _authorization = 'Authorization';

  static bool _isRefreshOrLogin(RequestOptions o) {
    final p = o.path;
    return p.endsWith('/auth/refresh') || p.endsWith('/auth/login');
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (!session.cookieTransport && !_isRefreshOrLogin(options)) {
      final token = session.accessToken;
      if (token != null && !options.headers.containsKey(_authorization)) {
        options.headers[_authorization] = 'Bearer $token';
      }
    }
    handler.next(options);
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    final response = err.response;
    if (response?.statusCode != 401 || options.extra[_retriedKey] == true || _isRefreshOrLogin(options)) {
      return handler.next(err);
    }
    final code = ApiError.tryParseResponseBody(response?.data)?.code;
    if (code != ApiErrorCode.tokenExpired && code != ApiErrorCode.unauthorized) {
      return handler.next(err);
    }
    if (!session.cookieTransport && session.refreshToken == null) {
      await session.expire();
      return handler.next(err);
    }

    // Another request may already have rotated the pair while this one was in
    // flight with the old access token: just retry with the new one.
    final sent = options.headers[_authorization];
    final current = session.accessToken;
    final alreadyRefreshed =
        !session.cookieTransport && sent != null && current != null && sent != 'Bearer $current';

    final ok = alreadyRefreshed || await (_refreshing ??= _refresh().whenComplete(() => _refreshing = null));
    if (!ok) return handler.next(err);

    final retry = options.copyWith(
      headers: Map.of(options.headers)..remove(_authorization),
      extra: {...options.extra, _retriedKey: true},
    );
    try {
      handler.resolve(await dio.fetch<Object?>(retry));
    } on DioException catch (e) {
      handler.next(e);
    }
  }

  /// Builds the refresh Dio: no interceptors, same base URL, same adapter,
  /// and the `X-YAMS-Client` header (cookie refresh is CSRF-checked).
  Dio _refreshDio() {
    final main = dio.options;
    final refresh = Dio(
      BaseOptions(
        baseUrl: main.baseUrl,
        connectTimeout: main.connectTimeout,
        receiveTimeout: main.receiveTimeout,
        sendTimeout: main.sendTimeout,
        responseType: ResponseType.json,
        headers: {
          hubClientHeaderName: ?main.headers[hubClientHeaderName],
        },
      ),
    );
    refresh.httpClientAdapter = dio.httpClientAdapter;
    return refresh;
  }

  Future<bool> _refresh() async {
    final refreshDio = _refreshDio();
    try {
      final res = await refreshDio.post<Object?>(
        '/auth/refresh',
        data: session.cookieTransport ? null : {'refreshToken': session.refreshToken},
      );
      if (!session.cookieTransport) {
        final body = readMap(res.data);
        if (body == null) return false;
        await session.storeTokens(RefreshResponse.fromJson(body).tokens);
      }
      return true;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) await session.expire();
      return false;
    } on FormatException {
      return false;
    }
    // The refresh Dio shares the main adapter, so it is never closed.
  }
}
