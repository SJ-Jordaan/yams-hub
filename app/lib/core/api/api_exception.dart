/// The one exception type screens and providers see (ARCHITECTURE §7.4).
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:yams_models/yams_models.dart';

/// App-side error codes that the gateway never sends (no HTTP response).
abstract final class ClientErrorCode {
  /// No server reachable / connection failed.
  static const network = 'network';

  /// The request timed out before the gateway answered.
  static const timeout = 'timeout';

  /// A non-GET timed out while waiting for the answer: the gateway may already
  /// have run it (ARCHITECTURE §7.4). Never retried.
  static const resultUnknown = 'result_unknown';

  /// The request was cancelled.
  static const cancelled = 'cancelled';

  /// The response could not be decoded.
  static const badResponse = 'bad_response';

  /// No server profile is active / resolved yet.
  static const noServer = 'no_server';
}

/// A failed hub API call: the gateway's [ApiError] body, or a client-side
/// condition (network, timeout, result unknown).
@immutable
class ApiException implements Exception {
  const ApiException({
    required this.status,
    required this.code,
    required this.message,
    this.service,
    this.details,
    this.requestId,
    this.fields = const [],
    this.retryAfterSeconds,
  });

  /// Wraps a gateway error body.
  factory ApiException.fromApiError(ApiError e) => ApiException(
    status: e.status,
    code: e.code,
    message: e.message.isEmpty ? _defaultMessage(e.code, e.status) : e.message,
    service: e.service,
    details: e.details,
    requestId: e.requestId.isEmpty ? null : e.requestId,
    fields: e.fields,
    retryAfterSeconds: e.retryAfterSeconds,
  );

  /// The hub could not be reached.
  const ApiException.network([String message = "Can't reach the hub."])
    : this(status: 0, code: ClientErrorCode.network, message: message);

  /// The hub did not answer in time.
  const ApiException.timeout([String message = 'The hub did not answer in time.'])
    : this(status: 0, code: ClientErrorCode.timeout, message: message);

  /// A non-idempotent request timed out after it was sent.
  const ApiException.resultUnknown()
    : this(status: 0, code: ClientErrorCode.resultUnknown, message: 'Result unknown, refresh to check.');

  /// No server is configured or reachable yet.
  const ApiException.noServer()
    : this(status: 0, code: ClientErrorCode.noServer, message: 'No hub server is connected.');

  /// Converts anything thrown by an API call into an [ApiException]:
  /// a [DioException] (whose `error` may already be one), an [ApiError],
  /// or an unknown error (mapped to `internal`).
  factory ApiException.from(Object error) => tryFrom(error) ?? _unexpected(error);

  /// Like [ApiException.from] but `null` for errors that are not API or
  /// transport failures (programming errors, format errors in app code).
  static ApiException? tryFrom(Object? error) {
    switch (error) {
      case ApiException():
        return error;
      case ApiError():
        return ApiException.fromApiError(error);
      case DioException():
        return fromDioException(error);
      default:
        return null;
    }
  }

  /// Maps a [DioException] (ARCHITECTURE §7.4, ErrorInterceptor).
  static ApiException fromDioException(DioException e) {
    final inner = e.error;
    if (inner is ApiException) return inner;
    final response = e.response;
    if (response != null) {
      final body = ApiError.tryParseResponseBody(response.data);
      if (body != null) {
        return ApiException.fromApiError(
          body.status == 0
              ? ApiError(
                  code: body.code,
                  message: body.message,
                  status: response.statusCode ?? 0,
                  service: body.service,
                  requestId: body.requestId,
                  fields: body.fields,
                  details: body.details,
                  retryAfterSeconds: body.retryAfterSeconds,
                )
              : body,
        );
      }
      final status = response.statusCode ?? 0;
      return ApiException(
        status: status,
        code: _codeForStatus(status),
        message: _defaultMessage(_codeForStatus(status), status),
        requestId: response.headers.value('x-request-id'),
      );
    }
    return switch (e.type) {
      DioExceptionType.connectionTimeout => const ApiException.timeout(),
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.transformTimeout =>
        const ApiException.timeout(),
      DioExceptionType.cancel => const ApiException(
        status: 0,
        code: ClientErrorCode.cancelled,
        message: 'Cancelled.',
      ),
      DioExceptionType.badCertificate => const ApiException.network(
        "The hub's certificate was rejected.",
      ),
      DioExceptionType.connectionError ||
      DioExceptionType.unknown ||
      DioExceptionType.badResponse => const ApiException.network(),
    };
  }

  static ApiException _unexpected(Object error) => ApiException(
    status: 0,
    code: error is FormatException ? ClientErrorCode.badResponse : ApiErrorCode.internal,
    message: error is FormatException
        ? 'The hub sent a response this app does not understand.'
        : 'Something went wrong.',
  );

  /// HTTP status; 0 for client-side failures.
  final int status;

  /// Gateway code (API.md §1.4) or a [ClientErrorCode].
  final String code;

  /// Human readable, safe to show.
  final String message;
  final ServiceId? service;
  final JsonMap? details;
  final String? requestId;
  final List<ApiFieldError> fields;
  final int? retryAfterSeconds;

  /// No HTTP response: network failure or timeout.
  bool get isNetwork =>
      code == ClientErrorCode.network ||
      code == ClientErrorCode.timeout ||
      code == ClientErrorCode.noServer;

  /// The gateway answered with 4xx.
  bool get isClientError => status >= 400 && status < 500;

  /// Not configured on the hub (`503 service_not_configured`).
  bool get isNotConfigured => code == ApiErrorCode.serviceNotConfigured;

  /// Stub route or card (`501 not_implemented`).
  bool get isNotImplemented => code == ApiErrorCode.notImplemented;

  /// Credentials are gone: the user must sign in again.
  bool get isAuthFailure =>
      status == 401 &&
      (code == ApiErrorCode.unauthorized ||
          code == ApiErrorCode.tokenExpired ||
          code == ApiErrorCode.refreshInvalid);

  /// The validation message for [field], if any.
  String? messageFor(String field) {
    for (final f in fields) {
      if (f.field == field) return f.message;
    }
    return null;
  }

  @override
  String toString() => 'ApiException($status $code: $message)';

  static String _codeForStatus(int status) => switch (status) {
    400 => ApiErrorCode.badRequest,
    401 => ApiErrorCode.unauthorized,
    403 => ApiErrorCode.forbidden,
    404 => ApiErrorCode.notFound,
    409 => ApiErrorCode.conflict,
    422 => ApiErrorCode.validationFailed,
    428 => ApiErrorCode.confirmationRequired,
    429 => ApiErrorCode.rateLimited,
    501 => ApiErrorCode.notImplemented,
    502 => ApiErrorCode.upstreamError,
    503 => ApiErrorCode.upstreamUnavailable,
    504 => ApiErrorCode.upstreamTimeout,
    _ => status >= 500 ? ApiErrorCode.internal : ApiErrorCode.badRequest,
  };

  static String _defaultMessage(String code, int status) => switch (code) {
    ApiErrorCode.unauthorized || ApiErrorCode.tokenExpired => 'Please sign in again.',
    ApiErrorCode.forbidden => 'Admins only.',
    ApiErrorCode.notFound => 'Not found.',
    ApiErrorCode.rateLimited => 'Too many requests. Try again later.',
    ApiErrorCode.notImplemented => 'Not available yet.',
    ApiErrorCode.serviceNotConfigured => 'Not configured on the hub.',
    ApiErrorCode.upstreamUnavailable => 'The service is not reachable.',
    ApiErrorCode.upstreamTimeout => 'The service did not answer in time.',
    _ => 'The hub answered with an error ($status).',
  };
}
