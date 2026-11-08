/// Upstream failures and their default API mapping (ARCHITECTURE §5.6).
library;

import 'dart:convert';

import 'package:yams_models/yams_models.dart';

import '../http/api_exception.dart';
import '../log/redact.dart';

/// One field problem reported by an upstream (`propertyName`/`errorMessage`
/// and similar shapes).
final class UpstreamValidationError {
  const UpstreamValidationError(this.field, this.message);

  final String field;
  final String message;
}

/// An upstream call failed. Carries only the service, method and path
/// (without query string), never the request URI or the transport error text,
/// which may contain credentials.
///
/// [status] is set for HTTP errors (non-2xx responses) and null for the
/// transport subclasses.
class UpstreamException implements Exception {
  UpstreamException({
    required this.service,
    required this.method,
    required this.path,
    this.status,
    String? message,
    this.validation = const [],
    this.bodySnippet,
  }) : message = message == null ? null : redactSecrets(message);

  final ServiceId service;
  final String method;

  /// Upstream path without query string.
  final String path;
  final int? status;

  /// Redacted, at most 300 characters; null when the body had no usable
  /// message.
  final String? message;
  final List<UpstreamValidationError> validation;

  /// The first bytes of the body, redacted (for debugging; never sent to
  /// clients).
  final String? bodySnippet;

  bool get isNotFound => status == 404;
  bool get isAuthError => status == 401 || status == 403;

  String get _name => service.displayName;

  /// The default API error (ARCHITECTURE §5.6 table). Features catch and map
  /// more specifically first; with [resourceNotFound] false an upstream 404 is
  /// reported as a 502 because the gateway path did not address it.
  ApiException toApiException({bool resourceNotFound = true}) {
    final s = status;
    if (s == null) return ApiException.internal();
    if (s == 401 || s == 403) {
      return ApiException(
        502,
        ApiErrorCode.upstreamAuthFailed,
        '$_name rejected the gateway\'s credentials.',
        service: service,
        details: {'upstreamStatus': s},
      );
    }
    if (s == 404 && resourceNotFound) {
      return ApiException(
        404,
        ApiErrorCode.notFound,
        message ?? 'Not found in $_name.',
        service: service,
      );
    }
    if ((s == 400 || s == 422) && validation.isNotEmpty) {
      return ApiException(
        422,
        ApiErrorCode.validationFailed,
        message ?? '$_name refused the request.',
        service: service,
        fields: [
          for (final v in validation)
            ApiFieldError(field: v.field, message: v.message),
        ],
      );
    }
    return ApiException(
      502,
      ApiErrorCode.upstreamError,
      message == null
          ? '$_name returned an error ($s).'
          : '$_name returned an error: $message',
      service: service,
      details: {'upstreamStatus': s},
    );
  }

  @override
  String toString() =>
      '$runtimeType(${service.name} $method $path${status == null ? '' : ' $status'})';
}

/// Connection refused, DNS failure, reset (503 `upstream_unavailable`).
final class UpstreamUnavailable extends UpstreamException {
  UpstreamUnavailable({
    required super.service,
    required super.method,
    required super.path,
  });

  @override
  ApiException toApiException({bool resourceNotFound = true}) => ApiException(
    503,
    ApiErrorCode.upstreamUnavailable,
    '${service.displayName} is not reachable.',
    service: service,
  );
}

/// No answer in time (504 `upstream_timeout`).
final class UpstreamTimeout extends UpstreamException {
  UpstreamTimeout({
    required super.service,
    required super.method,
    required super.path,
  });

  @override
  ApiException toApiException({bool resourceNotFound = true}) => ApiException(
    504,
    ApiErrorCode.upstreamTimeout,
    '${service.displayName} did not answer in time.',
    service: service,
  );
}

/// The body could not be parsed, was too large or had the wrong type
/// (502 `upstream_bad_response`).
final class UpstreamBadResponse extends UpstreamException {
  UpstreamBadResponse({
    required super.service,
    required super.method,
    required super.path,
    required this.reason,
    super.status,
  });

  /// Internal reason (`response too large`, `invalid JSON`, ...).
  final String reason;

  @override
  ApiException toApiException({bool resourceNotFound = true}) => ApiException(
    502,
    ApiErrorCode.upstreamBadResponse,
    '${service.displayName} sent a response the gateway could not read.',
    service: service,
  );

  @override
  String toString() =>
      'UpstreamBadResponse(${service.name} $method $path: $reason)';
}

/// The service has no URL/secret in the gateway config
/// (503 `service_not_configured`).
final class UpstreamNotConfigured extends UpstreamException {
  UpstreamNotConfigured({
    required super.service,
    required super.method,
    required super.path,
  });

  @override
  ApiException toApiException({bool resourceNotFound = true}) =>
      ApiException.serviceNotConfigured(service);
}

/// The gateway's own credentials were rejected and it backs off (qBittorrent
/// after a 401 login; 502 `upstream_auth_failed`).
final class UpstreamCredentialsRejected extends UpstreamException {
  UpstreamCredentialsRejected({
    required super.service,
    required super.method,
    required super.path,
    super.status,
  });

  @override
  ApiException toApiException({bool resourceNotFound = true}) => ApiException(
    502,
    ApiErrorCode.upstreamAuthFailed,
    '${service.displayName} rejected the gateway\'s credentials.',
    service: service,
  );
}

// ---------------------------------------------------------------------------
// Message extraction
// ---------------------------------------------------------------------------

const _maxMessage = 300;

/// What [extractUpstreamError] found in an error body.
final class ExtractedError {
  const ExtractedError(this.message, this.validation);

  final String? message;
  final List<UpstreamValidationError> validation;
}

String? _clean(Object? v) {
  if (v is! String) return null;
  final s = v.trim();
  if (s.isEmpty || s.length > _maxMessage) return null;
  // Stack traces never leave the gateway.
  if (s.contains('\n   at ') ||
      s.contains('Traceback (most recent call last)') ||
      RegExp(r'\n\s+at .+\(.+:\d+').hasMatch(s)) {
    return null;
  }
  return redactSecrets(s);
}

/// Extracts a short, redacted message and validation errors from an upstream
/// error body. Knows the Servarr (`message`, `[{propertyName, errorMessage}]`,
/// RFC 7807 `{title, errors}`), Seerr (`message`/`error`), Bazarr
/// (`{message, errors}`), Docker (`message`), Shelfmark (`error`), plain text
/// and socket-proxy HTML shapes. `description` and stack traces are dropped.
ExtractedError extractUpstreamError(
  int status,
  List<int> body, {
  String? contentType,
}) {
  if (body.isEmpty) return const ExtractedError(null, []);
  final String text;
  try {
    text = utf8.decode(body, allowMalformed: true).trim();
  } on FormatException {
    return const ExtractedError(null, []);
  }
  if (text.isEmpty) return const ExtractedError(null, []);
  final lower = text.length > 200
      ? text.substring(0, 200).toLowerCase()
      : text.toLowerCase();
  if (lower.startsWith('<!doctype') ||
      lower.startsWith('<html') ||
      lower.contains('<html')) {
    if (status == 403) {
      return const ExtractedError('denied by socket proxy', []);
    }
    return const ExtractedError(null, []);
  }
  Object? json;
  final first = text.codeUnitAt(0);
  if (first == 0x7B || first == 0x5B) {
    try {
      json = jsonDecode(text);
    } on FormatException {
      json = null;
    }
  }
  if (json == null) {
    return ExtractedError(_clean(text.split('\n').first), const []);
  }
  final validation = <UpstreamValidationError>[];
  String? message;
  if (json is List) {
    for (final e in json) {
      if (e is Map) {
        final field = e['propertyName'] ?? e['field'] ?? e['path'];
        final msg = _clean(e['errorMessage'] ?? e['message']);
        if (msg != null) {
          validation.add(
            UpstreamValidationError(field is String ? field : '', msg),
          );
        }
      }
    }
    if (validation.isNotEmpty) message = validation.first.message;
  } else if (json is Map) {
    message =
        _clean(json['message']) ??
        _clean(json['error']) ??
        _clean(json['title']);
    final errors = json['errors'];
    if (errors is Map) {
      for (final e in errors.entries) {
        final v = e.value;
        final msg = v is List ? _clean(v.isEmpty ? null : v.first) : _clean(v);
        if (msg != null) {
          validation.add(UpstreamValidationError('${e.key}', msg));
        }
      }
    } else if (errors is List) {
      for (final e in errors) {
        if (e is Map) {
          final msg = _clean(e['message'] ?? e['errorMessage']);
          final field = e['path'] ?? e['propertyName'] ?? e['field'];
          if (msg != null) {
            validation.add(
              UpstreamValidationError(field is String ? field : '', msg),
            );
          }
        }
      }
    }
  }
  return ExtractedError(message, validation);
}
