/// Cross-feature DTOs: errors, envelopes, sections, alerts, shared enums, jobs
/// and *arr command references (API.md §1.4 - §1.8).
library;

import 'package:meta/meta.dart';

import 'json.dart';

// ---------------------------------------------------------------------------
// Shared enums (API.md §1.8)
// ---------------------------------------------------------------------------

/// Every service the gateway talks to (or reports on).
enum ServiceId {
  sonarr('Sonarr'),
  radarr('Radarr'),
  prowlarr('Prowlarr'),
  bazarr('Bazarr'),
  seerr('Seerr'),
  jellyfin('Jellyfin'),
  jellystat('Jellystat'),
  qbittorrent('qBittorrent'),
  gluetun('Gluetun'),
  docker('Docker'),
  watchtower('Watchtower'),
  updater('Updater'),
  uptimeKuma('Uptime Kuma'),
  audiobookshelf('Audiobookshelf'),
  kavita('Kavita'),
  shelfmark('Shelfmark'),
  host('Host'),
  unknown('Unknown');

  const ServiceId(this.displayName);

  /// Human readable name, e.g. `Uptime Kuma`.
  final String displayName;

  static ServiceId fromJson(Object? v) =>
      readEnum(v, ServiceId.values, ServiceId.unknown);

  /// Like [fromJson] but `null` for a missing value (unknown strings still
  /// map to [unknown]).
  static ServiceId? fromJsonOrNull(Object? v) => v == null ? null : fromJson(v);

  String toJson() => name;
}

/// The web apps the launcher can open (ARCHITECTURE §7.10).
enum ExternalApp {
  jellyfin('Jellyfin'),
  audiobookshelf('Audiobookshelf'),
  kavita('Kavita'),
  seerr('Seerr'),
  shelfmark('Shelfmark'),
  sonarr('Sonarr'),
  radarr('Radarr'),
  prowlarr('Prowlarr'),
  bazarr('Bazarr'),
  qbittorrent('qBittorrent'),
  uptimeKuma('Uptime Kuma'),
  jellystat('Jellystat'),
  portainer('Portainer'),
  unknown('Unknown');

  const ExternalApp(this.displayName);

  /// Human readable name, e.g. `Uptime Kuma`.
  final String displayName;

  /// The service whose health drives the launcher's status dot.
  ///
  /// Every app except [portainer] maps 1:1 to the [ServiceId] of the same
  /// name; [portainer] and [unknown] have no status source (`null`).
  ServiceId? get serviceId => switch (this) {
    portainer || unknown => null,
    _ => ServiceId.values.byName(name),
  };

  static ExternalApp fromJson(Object? v) =>
      readEnum(v, ExternalApp.values, ExternalApp.unknown);

  String toJson() => name;
}

// ---------------------------------------------------------------------------
// Errors (API.md §1.4)
// ---------------------------------------------------------------------------

/// The well-known values of [ApiError.code] (API.md §1.4).
abstract final class ApiErrorCode {
  static const badRequest = 'bad_request';
  static const unauthorized = 'unauthorized';
  static const tokenExpired = 'token_expired';
  static const invalidCredentials = 'invalid_credentials';
  static const refreshInvalid = 'refresh_invalid';
  static const forbidden = 'forbidden';
  static const csrfRejected = 'csrf_rejected';
  static const policyDenied = 'policy_denied';
  static const seerrUserNotLinked = 'seerr_user_not_linked';
  static const quotaExceeded = 'quota_exceeded';
  static const blocklisted = 'blocklisted';
  static const notFound = 'not_found';
  static const conflict = 'conflict';
  static const alreadyExists = 'already_exists';
  static const alreadyRequested = 'already_requested';
  static const invalidState = 'invalid_state';
  static const managedByArr = 'managed_by_arr';
  static const jobRunning = 'job_running';
  static const validationFailed = 'validation_failed';
  static const confirmationRequired = 'confirmation_required';
  static const rateLimited = 'rate_limited';
  static const internal = 'internal';
  static const notImplemented = 'not_implemented';
  static const upstreamError = 'upstream_error';
  static const upstreamAuthFailed = 'upstream_auth_failed';
  static const upstreamBadResponse = 'upstream_bad_response';
  static const upstreamUnavailable = 'upstream_unavailable';
  static const serviceNotConfigured = 'service_not_configured';
  static const upstreamTimeout = 'upstream_timeout';
}

/// One validation problem in [ApiError.fields].
@immutable
final class ApiFieldError {
  const ApiFieldError({required this.field, required this.message});

  factory ApiFieldError.fromJson(JsonMap j) => ApiFieldError(
    field: readString(j['field']) ?? '',
    message: readString(j['message']) ?? '',
  );

  final String field;
  final String message;

  JsonMap toJson() => {'field': field, 'message': message};
}

/// The body of every gateway error response, wrapped as `{"error": ApiError}`.
///
/// Parsing is deliberately forgiving (only `code` is required) because an
/// error must never fail to decode on the error path.
@immutable
final class ApiError implements Exception {
  const ApiError({
    required this.code,
    required this.message,
    required this.status,
    this.service,
    this.requestId = '',
    this.fields = const [],
    this.details,
    this.retryAfterSeconds,
  });

  factory ApiError.fromJson(JsonMap j) => ApiError(
    code: req(readString(j['code']), 'code'),
    message: readString(j['message']) ?? '',
    status: readInt(j['status']) ?? 0,
    service: ServiceId.fromJsonOrNull(j['service']),
    requestId: readString(j['requestId']) ?? '',
    fields: readList(j['fields'], ApiFieldError.fromJson),
    details: readMap(j['details']),
    retryAfterSeconds: readInt(j['retryAfterSeconds']),
  );

  /// Parses an error response body (`{"error": {...}}`); `null` when [body]
  /// does not have that shape.
  static ApiError? tryParseResponseBody(Object? body) {
    final error = readMap(readMap(body)?['error']);
    if (error == null || readString(error['code']) == null) return null;
    return ApiError.fromJson(error);
  }

  /// Machine readable code, see [ApiErrorCode].
  final String code;

  /// Human readable message, safe to show to the user.
  final String message;

  /// The HTTP status of the response.
  final int status;
  final ServiceId? service;
  final String requestId;

  /// Validation problems (only for `validation_failed`); never null.
  final List<ApiFieldError> fields;

  /// Code-specific details documented per endpoint.
  final JsonMap? details;

  /// Seconds to wait before retrying (with `429 rate_limited`).
  final int? retryAfterSeconds;

  /// The message for [field], if the gateway reported one.
  String? messageFor(String field) {
    for (final f in fields) {
      if (f.field == field) return f.message;
    }
    return null;
  }

  JsonMap toJson() => compactJson({
    'code': code,
    'message': message,
    'status': status,
    'service': service?.toJson(),
    'requestId': requestId,
    'fields': [for (final f in fields) f.toJson()],
    'details': details,
    'retryAfterSeconds': retryAfterSeconds,
  });

  /// The full response body: `{"error": toJson()}`.
  JsonMap toResponseBody() => {'error': toJson()};

  @override
  String toString() =>
      'ApiError($status $code${service == null ? '' : ' ${service!.name}'}: $message)';
}

// ---------------------------------------------------------------------------
// Envelopes (API.md §1.5)
// ---------------------------------------------------------------------------

/// `{"items": T[]}`: a small unpaged list.
@immutable
final class ItemList<T> {
  const ItemList(this.items);

  factory ItemList.fromJson(JsonMap j, T Function(JsonMap) item) =>
      ItemList(readList(j['items'], item));

  final List<T> items;

  JsonMap toJson(JsonMap Function(T) item) => {
    'items': [for (final i in items) item(i)],
  };
}

/// A page of a single-source paged list (`page` is 1-based).
@immutable
final class PagedList<T> {
  const PagedList({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.total,
    required this.hasMore,
  });

  /// Builds a page and derives [hasMore] as `page * pageSize < total`.
  factory PagedList.of({
    required List<T> items,
    required int page,
    required int pageSize,
    required int total,
  }) => PagedList(
    items: items,
    page: page,
    pageSize: pageSize,
    total: total,
    hasMore: page * pageSize < total,
  );

  factory PagedList.fromJson(JsonMap j, T Function(JsonMap) item) {
    final page = readInt(j['page']) ?? 1;
    final pageSize = readInt(j['pageSize']) ?? 0;
    final total = req(readInt(j['total']), 'total');
    return PagedList(
      items: readList(j['items'], item),
      page: page,
      pageSize: pageSize,
      total: total,
      hasMore: readBool(j['hasMore']) ?? page * pageSize < total,
    );
  }

  final List<T> items;
  final int page;
  final int pageSize;
  final int total;
  final bool hasMore;

  JsonMap toJson(JsonMap Function(T) item) => {
    'items': [for (final i in items) item(i)],
    'page': page,
    'pageSize': pageSize,
    'total': total,
    'hasMore': hasMore,
  };
}

/// A page of a merged, cursor-paged feed. [nextCursor] is null on the last
/// page.
@immutable
final class CursorPage<T> {
  const CursorPage({required this.items, this.nextCursor});

  factory CursorPage.fromJson(JsonMap j, T Function(JsonMap) item) =>
      CursorPage(
        items: readList(j['items'], item),
        nextCursor: readString(j['nextCursor']),
      );

  final List<T> items;
  final String? nextCursor;

  bool get hasMore => nextCursor != null;

  JsonMap toJson(JsonMap Function(T) item) => compactJson({
    'items': [for (final i in items) item(i)],
    'nextCursor': nextCursor,
  });
}

// ---------------------------------------------------------------------------
// Sections (API.md §1.6)
// ---------------------------------------------------------------------------

/// The `status` of a [Section] or [SectionStatus].
enum SectionState {
  ok,
  error,
  disabled,
  unknown;

  static SectionState fromJson(Object? v) =>
      readEnum(v, SectionState.values, SectionState.unknown);

  String toJson() => name;
}

/// The outcome of one source in a multi-source response:
/// `{"status": "ok"|"error"|"disabled", "error": ApiError?}`.
@immutable
final class SectionStatus {
  const SectionStatus({required this.status, this.error});

  const SectionStatus.ok() : status = SectionState.ok, error = null;

  const SectionStatus.failure(ApiError this.error)
    : status = SectionState.error;

  const SectionStatus.disabled(ApiError this.error)
    : status = SectionState.disabled;

  factory SectionStatus.fromJson(JsonMap j) => SectionStatus(
    status: SectionState.fromJson(j['status']),
    error: _readError(j['error']),
  );

  final SectionState status;
  final ApiError? error;

  bool get isOk => status == SectionState.ok;

  JsonMap toJson() =>
      compactJson({'status': status.toJson(), 'error': error?.toJson()});
}

/// A dashboard card or one part of a multi-source screen.
///
/// Not generic: [data] stays a raw map (the feature DTO as JSON) and the
/// consumer calls [decode] with its own codec. The raw map also lets the app
/// read the badge keys of API.md §4 without the feature classes.
@immutable
final class Section {
  const Section({
    required this.status,
    this.data,
    this.error,
    this.fetchedAt,
    this.stale = false,
  });

  /// A successful section. Pass [stale] and [error] when the data was served
  /// from cache after a failed refresh.
  const Section.ok(
    JsonMap this.data, {
    required DateTime this.fetchedAt,
    this.stale = false,
    this.error,
  }) : status = SectionState.ok;

  /// A failed section (`status: "error"`).
  const Section.failure(ApiError this.error, {this.fetchedAt})
    : status = SectionState.error,
      data = null,
      stale = false;

  /// A section whose service is not configured (`status: "disabled"`).
  const Section.disabled(ApiError this.error, {this.fetchedAt})
    : status = SectionState.disabled,
      data = null,
      stale = false;

  factory Section.fromJson(JsonMap j) => Section(
    status: SectionState.fromJson(j['status']),
    data: readMap(j['data']),
    error: _readError(j['error']),
    fetchedAt: readInstant(j['fetchedAt']),
    stale: readBool(j['stale']) ?? false,
  );

  final SectionState status;

  /// The feature DTO as JSON; present when [status] is ok.
  final JsonMap? data;

  /// Why the section failed, or (with [stale]) why the refresh failed.
  final ApiError? error;
  final DateTime? fetchedAt;

  /// True when [data] was served from cache after a failed refresh.
  final bool stale;

  bool get isOk => status == SectionState.ok;

  /// Decodes [data] with [f]; `null` when there is no data. A
  /// [FormatException] from [f] propagates.
  T? decode<T>(T Function(JsonMap) f) {
    final d = data;
    return d == null ? null : f(d);
  }

  JsonMap toJson() => compactJson({
    'status': status.toJson(),
    'data': data,
    'error': error?.toJson(),
    'fetchedAt': optionalInstantToJson(fetchedAt),
    'stale': stale,
  });
}

ApiError? _readError(Object? v) {
  final m = readMap(v);
  if (m == null || readString(m['code']) == null) return null;
  return ApiError.fromJson(m);
}

// ---------------------------------------------------------------------------
// Links and alerts (API.md §1.8)
// ---------------------------------------------------------------------------

/// A link into another app's web UI; the app resolves the base URL.
///
/// Positional, as used by the launcher: `ExternalLink(app, '/')`
/// (ARCHITECTURE §7.9).
@immutable
final class ExternalLink {
  const ExternalLink(this.app, this.path);

  factory ExternalLink.fromJson(JsonMap j) => ExternalLink(
    ExternalApp.fromJson(j['app']),
    readString(j['path']) ?? '/',
  );

  final ExternalApp app;

  /// Path (with query/fragment) relative to the app's base URL.
  final String path;

  JsonMap toJson() => {'app': app.toJson(), 'path': path};
}

/// Severity of an [Alert]; compare with [rank].
enum AlertSeverity {
  info(1),
  warning(2),
  error(3),
  critical(4),
  unknown(0);

  const AlertSeverity(this.rank);

  /// Ordering weight: higher is more severe; [unknown] ranks lowest.
  final int rank;

  static AlertSeverity fromJson(Object? v) =>
      readEnum(v, AlertSeverity.values, AlertSeverity.unknown);

  String toJson() => name;
}

/// A problem shown on the dashboard. [route] is an app route that also works
/// as a web deep link.
@immutable
final class Alert {
  const Alert({
    required this.id,
    required this.severity,
    required this.source,
    required this.feature,
    required this.title,
    this.message,
    this.route,
    this.since,
    this.dismissible = false,
  });

  factory Alert.fromJson(JsonMap j) => Alert(
    id: req(readString(j['id']), 'id'),
    severity: AlertSeverity.fromJson(j['severity']),
    source: ServiceId.fromJson(j['source']),
    feature: readString(j['feature']) ?? '',
    title: req(readString(j['title']), 'title'),
    message: readString(j['message']),
    route: readString(j['route']),
    since: readInstant(j['since']),
    dismissible: readBool(j['dismissible']) ?? false,
  );

  /// Stable id, e.g. `sonarr.health.IndexerLongTermStatusCheck`.
  final String id;
  final AlertSeverity severity;
  final ServiceId source;

  /// Feature id the alert belongs to (`indexers`, `system`, ...).
  final String feature;
  final String title;
  final String? message;
  final String? route;
  final DateTime? since;
  final bool dismissible;

  JsonMap toJson() => compactJson({
    'id': id,
    'severity': severity.toJson(),
    'source': source.toJson(),
    'feature': feature,
    'title': title,
    'message': message,
    'route': route,
    'since': optionalInstantToJson(since),
    'dismissible': dismissible,
  });
}

// ---------------------------------------------------------------------------
// Jobs and commands (API.md §1.7)
// ---------------------------------------------------------------------------

/// State of a [Job] or [JobStep].
enum JobStatus {
  queued,
  running,
  succeeded,
  failed,
  unknown;

  /// Queued or running.
  bool get isActive => this == queued || this == running;

  /// Succeeded or failed.
  bool get isFinished => this == succeeded || this == failed;

  static JobStatus fromJson(Object? v) =>
      readEnum(v, JobStatus.values, JobStatus.unknown);

  String toJson() => name;
}

/// One step of a [Job].
@immutable
final class JobStep {
  const JobStep({
    required this.label,
    required this.status,
    this.startedAt,
    this.finishedAt,
  });

  factory JobStep.fromJson(JsonMap j) => JobStep(
    label: readString(j['label']) ?? '',
    status: JobStatus.fromJson(j['status']),
    startedAt: readInstant(j['startedAt']),
    finishedAt: readInstant(j['finishedAt']),
  );

  final String label;
  final JobStatus status;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  JsonMap toJson() => compactJson({
    'label': label,
    'status': status.toJson(),
    'startedAt': optionalInstantToJson(startedAt),
    'finishedAt': optionalInstantToJson(finishedAt),
  });
}

/// A long-running gateway action (ARCHITECTURE §5.9).
@immutable
final class Job {
  const Job({
    required this.id,
    required this.kind,
    required this.status,
    required this.createdAt,
    this.target,
    this.progress,
    this.message,
    this.steps = const [],
    this.log = const [],
    this.result,
    this.error,
    this.startedAt,
    this.finishedAt,
    this.userId,
  });

  factory Job.fromJson(JsonMap j) => Job(
    id: req(readString(j['id']), 'id'),
    kind: req(readString(j['kind']), 'kind'),
    target: readString(j['target']),
    status: JobStatus.fromJson(j['status']),
    progress: readDouble(j['progress']),
    message: readString(j['message']),
    steps: readList(j['steps'], JobStep.fromJson),
    log: readStringList(j['log']),
    result: readMap(j['result']),
    error: _readError(j['error']),
    createdAt: req(readInstant(j['createdAt']), 'createdAt'),
    startedAt: readInstant(j['startedAt']),
    finishedAt: readInstant(j['finishedAt']),
    userId: readString(j['userId']),
  );

  /// `j_<12 hex>`.
  final String id;

  /// `<feature>.<action>`, e.g. `containers.restart`.
  final String kind;
  final String? target;
  final JobStatus status;

  /// 0..1 when known.
  final double? progress;
  final String? message;
  final List<JobStep> steps;

  /// The last 200 log lines.
  final List<String> log;

  /// Kind-specific result, documented per endpoint.
  final JsonMap? result;
  final ApiError? error;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final String? userId;

  JsonMap toJson() => compactJson({
    'id': id,
    'kind': kind,
    'target': target,
    'status': status.toJson(),
    'progress': progress,
    'message': message,
    'steps': [for (final s in steps) s.toJson()],
    'log': log,
    'result': result,
    'error': error?.toJson(),
    'createdAt': instantToJson(createdAt),
    'startedAt': optionalInstantToJson(startedAt),
    'finishedAt': optionalInstantToJson(finishedAt),
    'userId': userId,
  });
}

/// Status of a Sonarr/Radarr command.
enum CommandStatus {
  queued,
  started,
  completed,
  failed,
  aborted,
  cancelled,
  orphaned,
  unknown;

  /// Still queued or running upstream.
  bool get isActive => this == queued || this == started;

  static CommandStatus fromJson(Object? v) =>
      readEnum(v, CommandStatus.values, CommandStatus.unknown);

  String toJson() => name;
}

/// Result of a finished Sonarr/Radarr command.
enum CommandResult {
  unknown,
  successful,
  unsuccessful;

  static CommandResult fromJson(Object? v) =>
      readEnum(v, CommandResult.values, CommandResult.unknown);

  String toJson() => name;
}

/// A reference to a Sonarr/Radarr command the gateway started.
@immutable
final class CommandRef {
  const CommandRef({
    required this.service,
    required this.id,
    required this.name,
    required this.status,
    this.result = CommandResult.unknown,
    this.message,
    this.queuedAt,
    this.startedAt,
    this.endedAt,
  });

  factory CommandRef.fromJson(JsonMap j) => CommandRef(
    service: ServiceId.fromJson(j['service']),
    id: req(readInt(j['id']), 'id'),
    name: readString(j['name']) ?? '',
    status: CommandStatus.fromJson(j['status']),
    result: CommandResult.fromJson(j['result']),
    message: readString(j['message']),
    queuedAt: readInstant(j['queuedAt']),
    startedAt: readInstant(j['startedAt']),
    endedAt: readInstant(j['endedAt']),
  );

  /// `sonarr` or `radarr`.
  final ServiceId service;
  final int id;

  /// Upstream command name, e.g. `SeriesSearch`.
  final String name;
  final CommandStatus status;
  final CommandResult result;
  final String? message;
  final DateTime? queuedAt;
  final DateTime? startedAt;
  final DateTime? endedAt;

  JsonMap toJson() => compactJson({
    'service': service.toJson(),
    'id': id,
    'name': name,
    'status': status.toJson(),
    'result': result.toJson(),
    'message': message,
    'queuedAt': optionalInstantToJson(queuedAt),
    'startedAt': optionalInstantToJson(startedAt),
    'endedAt': optionalInstantToJson(endedAt),
  });
}
