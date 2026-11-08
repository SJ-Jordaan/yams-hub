/// Errors that handlers throw to produce a JSON error response (API.md §1.4).
library;

import 'package:yams_models/yams_models.dart';

/// An error with an HTTP status and a stable [code]. The error handler turns
/// it into `{"error": ApiError}`; [message] must be safe to show to users.
class ApiException implements Exception {
  const ApiException(
    this.status,
    this.code,
    this.message, {
    this.service,
    this.fields = const [],
    this.details,
    this.retryAfterSeconds,
  });

  factory ApiException.badRequest(
    String message, {
    Map<String, Object?>? details,
  }) => ApiException(400, ApiErrorCode.badRequest, message, details: details);

  factory ApiException.unauthorized([
    String message = 'Authentication required.',
  ]) => ApiException(401, ApiErrorCode.unauthorized, message);

  factory ApiException.tokenExpired() => const ApiException(
    401,
    ApiErrorCode.tokenExpired,
    'The access token has expired; refresh it and retry.',
  );

  factory ApiException.invalidCredentials() => const ApiException(
    401,
    ApiErrorCode.invalidCredentials,
    'Wrong username or password.',
  );

  factory ApiException.refreshInvalid() => const ApiException(
    401,
    ApiErrorCode.refreshInvalid,
    'The session has ended; log in again.',
  );

  factory ApiException.forbidden([
    String message = 'You are not allowed to do this.',
  ]) => ApiException(403, ApiErrorCode.forbidden, message);

  factory ApiException.csrfRejected() => const ApiException(
    403,
    ApiErrorCode.csrfRejected,
    'Missing X-YAMS-Client header.',
  );

  factory ApiException.policyDenied(String message) =>
      ApiException(403, ApiErrorCode.policyDenied, message);

  factory ApiException.notFound([String message = 'Not found.']) =>
      ApiException(404, ApiErrorCode.notFound, message);

  factory ApiException.conflict(
    String message, {
    Map<String, Object?>? details,
  }) => ApiException(409, ApiErrorCode.conflict, message, details: details);

  factory ApiException.alreadyExists(String message) =>
      ApiException(409, ApiErrorCode.alreadyExists, message);

  factory ApiException.invalidState(String message) =>
      ApiException(409, ApiErrorCode.invalidState, message);

  factory ApiException.jobRunning(String message, {String? jobId}) =>
      ApiException(
        409,
        ApiErrorCode.jobRunning,
        message,
        details: jobId == null ? null : {'jobId': jobId},
      );

  /// 422 with per-field messages.
  factory ApiException.validation(
    List<ApiFieldError> fields, {
    String message = 'Some fields are invalid.',
    ServiceId? service,
  }) => ApiException(
    422,
    ApiErrorCode.validationFailed,
    message,
    fields: fields,
    service: service,
  );

  /// 422 for a single field.
  factory ApiException.invalidField(String field, String message) =>
      ApiException.validation([
        ApiFieldError(field: field, message: message),
      ], message: message);

  /// 428: a [confirm] route was called without `confirm=true`.
  factory ApiException.confirmationRequired(String impact) => ApiException(
    428,
    ApiErrorCode.confirmationRequired,
    'This action needs confirmation.',
    details: {'impact': impact},
  );

  factory ApiException.rateLimited(
    int retryAfterSeconds, [
    String message = 'Too many attempts; try again later.',
  ]) => ApiException(
    429,
    ApiErrorCode.rateLimited,
    message,
    retryAfterSeconds: retryAfterSeconds,
  );

  factory ApiException.internal() =>
      const ApiException(500, ApiErrorCode.internal, 'Internal error.');

  /// 501 for stub routes and stub dashboard cards.
  factory ApiException.notImplemented() => const ApiException(
    501,
    ApiErrorCode.notImplemented,
    'Not implemented yet.',
  );

  factory ApiException.serviceNotConfigured(
    ServiceId service, [
    String? message,
  ]) => ApiException(
    503,
    ApiErrorCode.serviceNotConfigured,
    message ?? '${service.displayName} is not configured in the gateway.',
    service: service,
  );

  final int status;
  final String code;
  final String message;
  final ServiceId? service;
  final List<ApiFieldError> fields;
  final Map<String, Object?>? details;
  final int? retryAfterSeconds;

  /// The model of this error for [requestId].
  ApiError toApiError(String requestId) => ApiError(
    code: code,
    message: message,
    status: status,
    service: service,
    requestId: requestId,
    fields: fields,
    details: details,
    retryAfterSeconds: retryAfterSeconds,
  );

  @override
  String toString() => 'ApiException($status $code: $message)';
}
