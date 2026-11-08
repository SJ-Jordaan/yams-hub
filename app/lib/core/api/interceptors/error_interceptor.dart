/// Converts every [DioException] into an [ApiException] (ARCHITECTURE §7.4).
library;

import 'package:dio/dio.dart';

import '../api_exception.dart';

/// Last interceptor: puts an [ApiException] (from the gateway's error body,
/// or `network`/`timeout`) into `DioException.error`, so callers can always
/// use `ApiException.from(error)`.
class ErrorInterceptor extends Interceptor {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.error is ApiException) return handler.next(err);
    final api = ApiException.fromDioException(err);
    handler.next(err.copyWith(error: api, message: api.message));
  }
}
