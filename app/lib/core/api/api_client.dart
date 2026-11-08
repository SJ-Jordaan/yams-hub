/// The app's single Dio instance (`dioProvider`, ARCHITECTURE §7.4).
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_models/yams_models.dart';

import '../app_info.dart';
import '../auth/token_manager.dart';
import '../servers/server_connection.dart';
import 'api_exception.dart';
import 'interceptors/auth_interceptor.dart';
import 'interceptors/error_interceptor.dart';
import 'interceptors/failover_interceptor.dart';

export 'api_exception.dart';
export 'interceptors/auth_interceptor.dart' show AuthSession, hubClientHeaderName;
export 'long_timeouts.dart';

/// Overrides the HTTP adapter of every Dio the app builds (tests serve canned
/// JSON through it). Null = the platform default.
final httpClientAdapterProvider = Provider<HttpClientAdapter?>((ref) => null);

/// Default timeouts (ARCHITECTURE §7.4).
const Duration apiConnectTimeout = Duration(seconds: 4);
const Duration apiReceiveTimeout = Duration(seconds: 20);
const Duration apiSendTimeout = Duration(seconds: 20);

/// Builds a hub Dio with the core interceptors, in order: auth, failover,
/// error. [baseUrl] null means no server is resolved: a request first waits
/// for [awaitServer] (a resolution in progress) and is sent to the API base
/// it returns; when there is none it fails with [ApiException.noServer] and
/// nothing leaves the device.
Dio createHubDio({
  required String? baseUrl,
  required AuthSession session,
  required Reprobe reprobe,
  HttpClientAdapter? adapter,
  Future<String?> Function()? awaitServer,
}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: baseUrl ?? 'http://unresolved.invalid/api/v1',
      connectTimeout: apiConnectTimeout,
      receiveTimeout: apiReceiveTimeout,
      sendTimeout: apiSendTimeout,
      responseType: ResponseType.json,
      contentType: Headers.jsonContentType,
      headers: {hubClientHeaderName: hubClientHeader},
    ),
  );
  if (adapter != null) dio.httpClientAdapter = adapter;
  if (baseUrl == null) dio.interceptors.add(_NoServerInterceptor(awaitServer));
  // Release builds never add LogInterceptor (it would print Authorization).
  dio.interceptors.addAll([
    AuthInterceptor(dio: dio, session: session),
    FailoverInterceptor(dio: dio, reprobe: reprobe),
    ErrorInterceptor(),
  ]);
  return dio;
}

class _NoServerInterceptor extends Interceptor {
  _NoServerInterceptor(this.awaitServer);

  final Future<String?> Function()? awaitServer;

  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    String? base;
    try {
      base = await awaitServer?.call();
    } catch (_) {
      base = null; // The provider that owned the callback is gone.
    }
    if (base != null) {
      options.baseUrl = base;
      return handler.next(options);
    }
    handler.reject(
      DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: const ApiException.noServer(),
        message: 'No hub server is connected.',
      ),
    );
  }
}

/// The Dio for the active server. Rebuilt when the resolved API base or the
/// transport changes, so providers that watch it refetch against the new URL.
final dioProvider = Provider<Dio>((ref) {
  final (apiBase, _) = ref.watch(activeServerProvider.select((s) => (s.apiBase, s.transport)));
  final dio = createHubDio(
    baseUrl: apiBase,
    session: ref.watch(tokenManagerProvider),
    reprobe: () => ref.read(activeServerProvider.notifier).failover(),
    awaitServer: () => ref.read(activeServerProvider.notifier).settledApiBase(),
    adapter: ref.watch(httpClientAdapterProvider),
  );
  // Not closed on dispose: in-flight retries of the old instance may still
  // use its adapter, and the default adapter is released with the instance.
  return dio;
});

/// Typed helpers over Dio that throw [ApiException] (never [DioException]).
/// Feature `data/<feature>_api.dart` classes use these.
extension HubDio on Dio {
  /// GET returning a JSON object.
  Future<JsonMap> getMap(String path, {Map<String, Object?>? query, Options? options}) =>
      _map(() => get<Object?>(path, queryParameters: _q(query), options: options));

  /// GET decoded with [decode].
  Future<T> getModel<T>(
    String path,
    T Function(JsonMap json) decode, {
    Map<String, Object?>? query,
    Options? options,
  }) async => _decode(await getMap(path, query: query, options: options), decode);

  /// POST with a JSON [body]; returns the JSON object answered (empty for 204).
  Future<JsonMap> postMap(String path, {Object? body, Map<String, Object?>? query, Options? options}) =>
      _map(() => post<Object?>(path, data: body, queryParameters: _q(query), options: options), allowEmpty: true);

  /// PUT with a JSON [body].
  Future<JsonMap> putMap(String path, {Object? body, Map<String, Object?>? query, Options? options}) =>
      _map(() => put<Object?>(path, data: body, queryParameters: _q(query), options: options), allowEmpty: true);

  /// PATCH with a JSON [body].
  Future<JsonMap> patchMap(String path, {Object? body, Map<String, Object?>? query, Options? options}) =>
      _map(() => patch<Object?>(path, data: body, queryParameters: _q(query), options: options), allowEmpty: true);

  /// DELETE; returns the JSON object answered (empty for 204).
  Future<JsonMap> deleteMap(String path, {Object? body, Map<String, Object?>? query, Options? options}) =>
      _map(() => delete<Object?>(path, data: body, queryParameters: _q(query), options: options), allowEmpty: true);

  static Map<String, Object?>? _q(Map<String, Object?>? query) {
    if (query == null) return null;
    return {
      for (final e in query.entries)
        if (e.value != null) e.key: e.value is List ? (e.value! as List).join(',') : e.value,
    };
  }

  static Future<JsonMap> _map(Future<Response<Object?>> Function() send, {bool allowEmpty = false}) async {
    try {
      final res = await send();
      final data = res.data;
      if (data == null || (data is String && data.isEmpty)) {
        if (allowEmpty) return const {};
        throw const FormatException('empty body');
      }
      final map = readMap(data);
      if (map == null) throw const FormatException('not a JSON object');
      return map;
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    } on FormatException {
      throw const ApiException(
        status: 0,
        code: ClientErrorCode.badResponse,
        message: 'The hub sent a response this app does not understand.',
      );
    }
  }

  static T _decode<T>(JsonMap json, T Function(JsonMap json) decode) {
    try {
      return decode(json);
    } on FormatException {
      throw const ApiException(
        status: 0,
        code: ClientErrorCode.badResponse,
        message: 'The hub sent a response this app does not understand.',
      );
    }
  }
}
