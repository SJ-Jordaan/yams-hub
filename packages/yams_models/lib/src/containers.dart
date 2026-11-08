/// Containers, updates and maintenance DTOs (API.md §11).
library;

import 'package:meta/meta.dart';

import 'common.dart';
import 'json.dart';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Docker container state (`State` of `/containers/json`).
enum ContainerState {
  created,
  running,
  paused,
  restarting,
  removing,
  exited,
  dead,
  unknown;

  static ContainerState fromJson(Object? v) =>
      readEnum(v, ContainerState.values, ContainerState.unknown);

  String toJson() => name;
}

/// Healthcheck status; [none] when the image has no healthcheck.
enum ContainerHealth {
  healthy,
  unhealthy,
  starting,
  none,
  unknown;

  static ContainerHealth fromJson(Object? v) =>
      readEnum(v, ContainerHealth.values, ContainerHealth.unknown);

  String toJson() => name;
}

/// Gateway guardrail for a container (policy `locked` / `confirm` lists).
enum ContainerProtection {
  none,
  confirm,
  locked,
  unknown;

  static ContainerProtection fromJson(Object? v) =>
      readEnum(v, ContainerProtection.values, ContainerProtection.unknown);

  String toJson() => name;
}

/// What a [ContainerEvent] reports.
enum ContainerEventAction {
  start,
  stop,
  die,
  kill,
  restart,
  oom,
  health,
  create,
  destroy,
  unknown;

  static ContainerEventAction fromJson(Object? v) =>
      readEnum(v, ContainerEventAction.values, ContainerEventAction.unknown);

  String toJson() => name;
}

/// Output stream of a [LogLine].
enum ContainerLogStream {
  stdout,
  stderr,
  unknown;

  static ContainerLogStream fromJson(Object? v) =>
      readEnum(v, ContainerLogStream.values, ContainerLogStream.unknown);

  String toJson() => name;
}

/// `POST /containers/{name}/actions` action.
enum ContainerAction {
  restart,
  stop,
  start,
  unknown;

  static ContainerAction fromJson(Object? v) =>
      readEnum(v, ContainerAction.values, ContainerAction.unknown);

  String toJson() => name;
}

/// How Decluttarr removed a download.
enum DecluttarrRemovalKind {
  removal,
  queueRemoval,
  unknown;

  static DecluttarrRemovalKind fromJson(Object? v) =>
      readEnum(v, DecluttarrRemovalKind.values, DecluttarrRemovalKind.unknown);

  String toJson() => name;
}

/// The *arr a Recyclarr instance syncs.
enum RecyclarrInstanceType {
  sonarr,
  radarr,
  unknown;

  static RecyclarrInstanceType fromJson(Object? v) =>
      readEnum(v, RecyclarrInstanceType.values, RecyclarrInstanceType.unknown);

  String toJson() => name;
}

// ---------------------------------------------------------------------------
// Container list and detail (API.md §11.1, §11.2)
// ---------------------------------------------------------------------------

/// A published port (de-duplicated on [public]).
@immutable
final class ContainerPort {
  const ContainerPort({
    required this.public,
    required this.private,
    this.protocol = 'tcp',
  });

  factory ContainerPort.fromJson(JsonMap j) => ContainerPort(
    public: req(readInt(j['public']), 'public'),
    private: req(readInt(j['private']), 'private'),
    protocol: readString(j['protocol']) ?? 'tcp',
  );

  final int public;
  final int private;

  /// `tcp` or `udp`.
  final String protocol;

  JsonMap toJson() => {
    'public': public,
    'private': private,
    'protocol': protocol,
  };
}

/// The update badge of a [ContainerSummary].
@immutable
final class ContainerUpdateFlag {
  const ContainerUpdateFlag({required this.available, this.checkedAt});

  factory ContainerUpdateFlag.fromJson(JsonMap j) => ContainerUpdateFlag(
    available: readBool(j['available']) ?? false,
    checkedAt: readInstant(j['checkedAt']),
  );

  final bool available;
  final DateTime? checkedAt;

  JsonMap toJson() => compactJson({
    'available': available,
    'checkedAt': optionalInstantToJson(checkedAt),
  });
}

/// One row of `GET /containers`.
@immutable
final class ContainerSummary {
  const ContainerSummary({
    required this.name,
    required this.service,
    required this.group,
    required this.image,
    required this.state,
    required this.statusText,
    required this.health,
    this.imageVersion,
    this.startedAt,
    this.uptimeSeconds,
    this.cpuPercent,
    this.memBytes,
    this.memPercent,
    this.netRxBps,
    this.netTxBps,
    this.sharesNetworkWith,
    this.autoUpdate = false,
    this.pinned = false,
    this.update,
    this.protection = ContainerProtection.none,
    this.ports = const [],
    this.links = const [],
  });

  factory ContainerSummary.fromJson(JsonMap j) => ContainerSummary(
    name: req(readString(j['name']), 'name'),
    service: readString(j['service']) ?? readString(j['name'])!,
    group: readString(j['group']) ?? 'other',
    image: readString(j['image']) ?? '',
    imageVersion: readString(j['imageVersion']),
    state: ContainerState.fromJson(j['state']),
    statusText: readString(j['statusText']) ?? '',
    health: ContainerHealth.fromJson(j['health']),
    startedAt: readInstant(j['startedAt']),
    uptimeSeconds: readInt(j['uptimeSeconds']),
    cpuPercent: readDouble(j['cpuPercent']),
    memBytes: readInt(j['memBytes']),
    memPercent: readDouble(j['memPercent']),
    netRxBps: readInt(j['netRxBps']),
    netTxBps: readInt(j['netTxBps']),
    sharesNetworkWith: readString(j['sharesNetworkWith']),
    autoUpdate: readBool(j['autoUpdate']) ?? false,
    pinned: readBool(j['pinned']) ?? false,
    update: switch (readMap(j['update'])) {
      final m? => ContainerUpdateFlag.fromJson(m),
      null => null,
    },
    protection: ContainerProtection.fromJson(j['protection']),
    ports: readList(j['ports'], ContainerPort.fromJson),
    links: readList(j['links'], ExternalLink.fromJson),
  );

  /// Container name (`Names[0]` without the leading slash).
  final String name;

  /// Compose service (label `com.docker.compose.service`).
  final String service;

  /// Display group: `media`, `automation`, `downloads`, `system` or `other`.
  final String group;
  final String image;

  /// Label `org.opencontainers.image.version`.
  final String? imageVersion;
  final ContainerState state;

  /// Docker's status text without the `(healthy)` suffix.
  final String statusText;
  final ContainerHealth health;
  final DateTime? startedAt;
  final int? uptimeSeconds;

  /// 0..(100 × cores); absent until the stats poller has two samples.
  final double? cpuPercent;
  final int? memBytes;
  final double? memPercent;
  final int? netRxBps;
  final int? netTxBps;

  /// `gluetun` when the container uses `network_mode: service:gluetun` (its
  /// net counters are then omitted).
  final String? sharesNetworkWith;

  /// Updated by Watchtower automatically (`monitor-only=false` label).
  final bool autoUpdate;

  /// The image tag is not `latest`.
  final bool pinned;
  final ContainerUpdateFlag? update;
  final ContainerProtection protection;
  final List<ContainerPort> ports;

  /// Native web UI when the service is an [ExternalApp].
  final List<ExternalLink> links;

  bool get isRunning => state == ContainerState.running;
  bool get isLocked => protection == ContainerProtection.locked;
  bool get updateAvailable => update?.available ?? false;

  JsonMap toJson() => compactJson({
    'name': name,
    'service': service,
    'group': group,
    'image': image,
    'imageVersion': imageVersion,
    'state': state.toJson(),
    'statusText': statusText,
    'health': health.toJson(),
    'startedAt': optionalInstantToJson(startedAt),
    'uptimeSeconds': uptimeSeconds,
    'cpuPercent': cpuPercent,
    'memBytes': memBytes,
    'memPercent': memPercent,
    'netRxBps': netRxBps,
    'netTxBps': netTxBps,
    'sharesNetworkWith': sharesNetworkWith,
    'autoUpdate': autoUpdate,
    'pinned': pinned,
    'update': update?.toJson(),
    'protection': protection.toJson(),
    'ports': [for (final p in ports) p.toJson()],
    'links': [for (final l in links) l.toJson()],
  });
}

/// One healthcheck run (`State.Health.Log[]`). [output] is only sent to
/// admins, redacted and cut to 200 characters.
@immutable
final class ContainerHealthLogEntry {
  const ContainerHealthLogEntry({
    required this.start,
    required this.end,
    required this.exitCode,
    this.output,
  });

  factory ContainerHealthLogEntry.fromJson(JsonMap j) =>
      ContainerHealthLogEntry(
        start: req(readInstant(j['start']), 'start'),
        end: req(readInstant(j['end']), 'end'),
        exitCode: readInt(j['exitCode']) ?? 0,
        output: readString(j['output']),
      );

  final DateTime start;
  final DateTime end;
  final int exitCode;
  final String? output;

  JsonMap toJson() => compactJson({
    'start': instantToJson(start),
    'end': instantToJson(end),
    'exitCode': exitCode,
    'output': output,
  });
}

/// A Docker container event kept by the gateway's event stream.
@immutable
final class ContainerEvent {
  const ContainerEvent({
    required this.at,
    required this.name,
    required this.action,
    this.health,
    this.exitCode,
  });

  factory ContainerEvent.fromJson(JsonMap j) => ContainerEvent(
    at: req(readInstant(j['at']), 'at'),
    name: req(readString(j['name']), 'name'),
    action: ContainerEventAction.fromJson(j['action']),
    health: readString(j['health']),
    exitCode: readInt(j['exitCode']),
  );

  final DateTime at;
  final String name;
  final ContainerEventAction action;

  /// The new health status of a `health` event (`healthy`, `unhealthy`).
  final String? health;

  /// Exit code of a `die` event.
  final int? exitCode;

  JsonMap toJson() => compactJson({
    'at': instantToJson(at),
    'name': name,
    'action': action.toJson(),
    'health': health,
    'exitCode': exitCode,
  });
}

/// A mount of a container (never the host source path).
@immutable
final class ContainerMount {
  const ContainerMount({required this.destination, required this.readOnly});

  factory ContainerMount.fromJson(JsonMap j) => ContainerMount(
    destination: readString(j['destination']) ?? '',
    readOnly: readBool(j['readOnly']) ?? false,
  );

  final String destination;
  final bool readOnly;

  JsonMap toJson() => {'destination': destination, 'readOnly': readOnly};
}

/// `GET /containers/{name}`: the [summary] fields plus inspect details
/// (serialised flat, as one object).
@immutable
final class ContainerDetail {
  const ContainerDetail({
    required this.summary,
    required this.restartCount,
    required this.restartPolicy,
    required this.imageId,
    required this.createdAt,
    required this.networkMode,
    this.finishedAt,
    this.exitCode,
    this.oomKilled = false,
    this.error,
    this.healthLog = const [],
    this.events = const [],
    this.dependents = const [],
    this.dependsOn = const [],
    this.mounts = const [],
    this.pids,
  });

  factory ContainerDetail.fromJson(JsonMap j) => ContainerDetail(
    summary: ContainerSummary.fromJson(j),
    restartCount: readInt(j['restartCount']) ?? 0,
    finishedAt: readInstant(j['finishedAt']),
    exitCode: readInt(j['exitCode']),
    oomKilled: readBool(j['oomKilled']) ?? false,
    error: readString(j['error']),
    restartPolicy: readString(j['restartPolicy']) ?? '',
    imageId: readString(j['imageId']) ?? '',
    createdAt: req(readInstant(j['createdAt']), 'createdAt'),
    healthLog: readList(j['healthLog'], ContainerHealthLogEntry.fromJson),
    events: readList(j['events'], ContainerEvent.fromJson),
    dependents: readStringList(j['dependents']),
    dependsOn: readStringList(j['dependsOn']),
    mounts: readList(j['mounts'], ContainerMount.fromJson),
    networkMode: readString(j['networkMode']) ?? '',
    pids: readInt(j['pids']),
  );

  final ContainerSummary summary;
  final int restartCount;
  final DateTime? finishedAt;
  final int? exitCode;
  final bool oomKilled;

  /// Docker's `State.Error` (redacted).
  final String? error;
  final String restartPolicy;

  /// `sha256:...`.
  final String imageId;
  final DateTime createdAt;

  /// The last healthcheck runs (oldest first).
  final List<ContainerHealthLogEntry> healthLog;

  /// The last 20 events, newest first.
  final List<ContainerEvent> events;

  /// Containers affected when this one restarts (static map).
  final List<String> dependents;

  /// Containers this one depends on.
  final List<String> dependsOn;
  final List<ContainerMount> mounts;
  final String networkMode;
  final int? pids;

  String get name => summary.name;

  JsonMap toJson() => compactJson({
    ...summary.toJson(),
    'restartCount': restartCount,
    'finishedAt': optionalInstantToJson(finishedAt),
    'exitCode': exitCode,
    'oomKilled': oomKilled,
    'error': error,
    'restartPolicy': restartPolicy,
    'imageId': imageId,
    'createdAt': instantToJson(createdAt),
    'healthLog': [for (final h in healthLog) h.toJson()],
    'events': [for (final e in events) e.toJson()],
    'dependents': dependents,
    'dependsOn': dependsOn,
    'mounts': [for (final m in mounts) m.toJson()],
    'networkMode': networkMode,
    'pids': pids,
  });
}

/// Docker engine summary of [ContainerList].
@immutable
final class ContainerEngineInfo {
  const ContainerEngineInfo({
    required this.version,
    required this.running,
    required this.stopped,
    required this.total,
    required this.images,
  });

  factory ContainerEngineInfo.fromJson(JsonMap j) => ContainerEngineInfo(
    version: readString(j['version']) ?? '',
    running: readInt(j['running']) ?? 0,
    stopped: readInt(j['stopped']) ?? 0,
    total: readInt(j['total']) ?? 0,
    images: readInt(j['images']) ?? 0,
  );

  final String version;
  final int running;
  final int stopped;
  final int total;
  final int images;

  JsonMap toJson() => {
    'version': version,
    'running': running,
    'stopped': stopped,
    'total': total,
    'images': images,
  };
}

/// `GET /containers`.
@immutable
final class ContainerList {
  const ContainerList({required this.items, required this.engine, this.statsAt});

  factory ContainerList.fromJson(JsonMap j) => ContainerList(
    items: readList(j['items'], ContainerSummary.fromJson),
    engine: ContainerEngineInfo.fromJson(readMap(j['engine']) ?? const {}),
    statsAt: readInstant(j['statsAt']),
  );

  final List<ContainerSummary> items;
  final ContainerEngineInfo engine;

  /// When the CPU/memory figures were sampled.
  final DateTime? statsAt;

  JsonMap toJson() => compactJson({
    'items': [for (final i in items) i.toJson()],
    'engine': engine.toJson(),
    'statsAt': optionalInstantToJson(statsAt),
  });
}

/// One container log line ([text] redacted by the gateway).
@immutable
final class LogLine {
  const LogLine({required this.stream, required this.text, this.at});

  factory LogLine.fromJson(JsonMap j) => LogLine(
    at: readInstant(j['at']),
    stream: ContainerLogStream.fromJson(j['stream']),
    text: readString(j['text']) ?? '',
  );

  final DateTime? at;
  final ContainerLogStream stream;
  final String text;

  JsonMap toJson() => compactJson({
    'at': optionalInstantToJson(at),
    'stream': stream.toJson(),
    'text': text,
  });
}

/// `GET /containers/{name}/logs`.
@immutable
final class LogResponse {
  const LogResponse({required this.lines, this.truncated = false});

  factory LogResponse.fromJson(JsonMap j) => LogResponse(
    lines: readList(j['lines'], LogLine.fromJson),
    truncated: readBool(j['truncated']) ?? false,
  );

  /// Oldest first.
  final List<LogLine> lines;

  /// More lines exist before the first one (the `tail` limit was reached).
  final bool truncated;

  JsonMap toJson() => {
    'lines': [for (final l in lines) l.toJson()],
    'truncated': truncated,
  };
}

/// `POST /containers/{name}/actions` body.
@immutable
final class ContainerActionRequest {
  const ContainerActionRequest({required this.action, this.confirm});

  factory ContainerActionRequest.fromJson(JsonMap j) => ContainerActionRequest(
    action: ContainerAction.fromJson(j['action']),
    confirm: readBool(j['confirm']),
  );

  final ContainerAction action;
  final bool? confirm;

  JsonMap toJson() =>
      compactJson({'action': action.toJson(), 'confirm': confirm});
}

// ---------------------------------------------------------------------------
// Updates (API.md §11.4)
// ---------------------------------------------------------------------------

/// The last Watchtower scan, from `/v1/metrics` (+ `/v1/status` time).
@immutable
final class WatchtowerScan {
  const WatchtowerScan({
    required this.scanned,
    required this.updated,
    required this.failed,
    required this.skipped,
    required this.restarted,
    required this.scansTotal,
    this.at,
  });

  factory WatchtowerScan.fromJson(JsonMap j) => WatchtowerScan(
    scanned: readInt(j['scanned']) ?? 0,
    updated: readInt(j['updated']) ?? 0,
    failed: readInt(j['failed']) ?? 0,
    skipped: readInt(j['skipped']) ?? 0,
    restarted: readInt(j['restarted']) ?? 0,
    scansTotal: readInt(j['scansTotal']) ?? 0,
    at: readInstant(j['at']),
  );

  final int scanned;
  final int updated;
  final int failed;
  final int skipped;
  final int restarted;

  /// Scans since Watchtower started (0: none yet).
  final int scansTotal;

  /// When the last scan ran (absent before the first scan).
  final DateTime? at;

  JsonMap toJson() => compactJson({
    'scanned': scanned,
    'updated': updated,
    'failed': failed,
    'skipped': skipped,
    'restarted': restarted,
    'scansTotal': scansTotal,
    'at': optionalInstantToJson(at),
  });
}

/// One row of `GET /updates`.
@immutable
final class UpdateInfo {
  const UpdateInfo({
    required this.name,
    required this.image,
    this.updateAvailable,
    this.pinned = false,
    this.currentVersion,
    this.currentDigest,
    this.latestDigest,
    this.error,
    this.autoUpdate = false,
    this.canUpdate = false,
  });

  factory UpdateInfo.fromJson(JsonMap j) => UpdateInfo(
    name: req(readString(j['name']), 'name'),
    image: readString(j['image']) ?? '',
    updateAvailable: readBool(j['updateAvailable']),
    pinned: readBool(j['pinned']) ?? false,
    currentVersion: readString(j['currentVersion']),
    currentDigest: readString(j['currentDigest']),
    latestDigest: readString(j['latestDigest']),
    error: readString(j['error']),
    autoUpdate: readBool(j['autoUpdate']) ?? false,
    canUpdate: readBool(j['canUpdate']) ?? false,
  );

  final String name;
  final String image;

  /// Null until a check covered this container.
  final bool? updateAvailable;
  final bool pinned;
  final String? currentVersion;
  final String? currentDigest;
  final String? latestDigest;

  /// The registry check failed for this container.
  final String? error;
  final bool autoUpdate;

  /// The updater is configured, the service is in its allow-list and the
  /// container is not locked.
  final bool canUpdate;

  JsonMap toJson() => compactJson({
    'name': name,
    'image': image,
    'updateAvailable': updateAvailable,
    'pinned': pinned,
    'currentVersion': currentVersion,
    'currentDigest': currentDigest,
    'latestDigest': latestDigest,
    'error': error,
    'autoUpdate': autoUpdate,
    'canUpdate': canUpdate,
  });
}

/// `GET /updates`.
@immutable
final class UpdatesResponse {
  const UpdatesResponse({
    required this.items,
    this.checkedAt,
    this.checking = false,
    this.available = false,
    this.updaterAvailable = false,
    this.lastScan,
  });

  factory UpdatesResponse.fromJson(JsonMap j) => UpdatesResponse(
    checkedAt: readInstant(j['checkedAt']),
    checking: readBool(j['checking']) ?? false,
    available: readBool(j['available']) ?? false,
    items: readList(j['items'], UpdateInfo.fromJson),
    updaterAvailable: readBool(j['updaterAvailable']) ?? false,
    lastScan: switch (readMap(j['lastScan'])) {
      final m? => WatchtowerScan.fromJson(m),
      null => null,
    },
  );

  final DateTime? checkedAt;

  /// A check job is running.
  final bool checking;

  /// Watchtower's `check` endpoint is enabled.
  final bool available;
  final List<UpdateInfo> items;
  final bool updaterAvailable;
  final WatchtowerScan? lastScan;

  int get updatesAvailable =>
      items.where((i) => i.updateAvailable ?? false).length;

  JsonMap toJson() => compactJson({
    'checkedAt': optionalInstantToJson(checkedAt),
    'checking': checking,
    'available': available,
    'items': [for (final i in items) i.toJson()],
    'updaterAvailable': updaterAvailable,
    'lastScan': lastScan?.toJson(),
  });
}

/// `POST /updates/check` body.
@immutable
final class UpdateCheckRequest {
  const UpdateCheckRequest({this.containers});

  factory UpdateCheckRequest.fromJson(JsonMap j) => UpdateCheckRequest(
    containers: j['containers'] == null
        ? null
        : readStringList(j['containers']),
  );

  /// Null: check every container.
  final List<String>? containers;

  JsonMap toJson() => compactJson({'containers': containers});
}

// ---------------------------------------------------------------------------
// Maintenance (API.md §11.5)
// ---------------------------------------------------------------------------

/// State and health of the container behind a maintenance tool.
@immutable
final class MaintenanceContainerState {
  const MaintenanceContainerState({required this.state, required this.health});

  factory MaintenanceContainerState.fromJson(JsonMap j) =>
      MaintenanceContainerState(
        state: ContainerState.fromJson(j['state']),
        health: ContainerHealth.fromJson(j['health']),
      );

  final ContainerState state;
  final ContainerHealth health;

  JsonMap toJson() => {'state': state.toJson(), 'health': health.toJson()};
}

/// A download Decluttarr removed.
@immutable
final class DecluttarrRemoval {
  const DecluttarrRemoval({
    required this.at,
    required this.job,
    required this.title,
    required this.kind,
  });

  factory DecluttarrRemoval.fromJson(JsonMap j) => DecluttarrRemoval(
    at: req(readInstant(j['at']), 'at'),
    job: readString(j['job']) ?? '',
    title: readString(j['title']) ?? '',
    kind: DecluttarrRemovalKind.fromJson(j['kind']),
  );

  final DateTime at;
  final String job;
  final String title;
  final DecluttarrRemovalKind kind;

  JsonMap toJson() => {
    'at': instantToJson(at),
    'job': job,
    'title': title,
    'kind': kind.toJson(),
  };
}

/// A download Decluttarr flagged (strike [count] of [max]).
@immutable
final class DecluttarrStrike {
  const DecluttarrStrike({
    required this.at,
    required this.job,
    required this.title,
    required this.count,
    required this.max,
  });

  factory DecluttarrStrike.fromJson(JsonMap j) => DecluttarrStrike(
    at: req(readInstant(j['at']), 'at'),
    job: readString(j['job']) ?? '',
    title: readString(j['title']) ?? '',
    count: readInt(j['count']) ?? 0,
    max: readInt(j['max']) ?? 0,
  );

  final DateTime at;
  final String job;
  final String title;
  final int count;
  final int max;

  JsonMap toJson() => {
    'at': instantToJson(at),
    'job': job,
    'title': title,
    'count': count,
    'max': max,
  };
}

/// A warning or error line of a maintenance tool (redacted).
@immutable
final class MaintenanceLogEntry {
  const MaintenanceLogEntry({required this.at, required this.text});

  factory MaintenanceLogEntry.fromJson(JsonMap j) => MaintenanceLogEntry(
    at: req(readInstant(j['at']), 'at'),
    text: readString(j['text']) ?? '',
  );

  final DateTime at;
  final String text;

  JsonMap toJson() => {'at': instantToJson(at), 'text': text};
}

/// Decluttarr activity over the last 24 hours.
@immutable
final class DecluttarrLast24h {
  const DecluttarrLast24h({
    this.runs = 0,
    this.removed = const [],
    this.strikes = const [],
    this.searches = 0,
    this.obsoleteTagged = 0,
  });

  factory DecluttarrLast24h.fromJson(JsonMap j) => DecluttarrLast24h(
    runs: readInt(j['runs']) ?? 0,
    removed: readList(j['removed'], DecluttarrRemoval.fromJson),
    strikes: readList(j['strikes'], DecluttarrStrike.fromJson),
    searches: readInt(j['searches']) ?? 0,
    obsoleteTagged: readInt(j['obsoleteTagged']) ?? 0,
  );

  final int runs;

  /// Newest first.
  final List<DecluttarrRemoval> removed;

  /// Newest first.
  final List<DecluttarrStrike> strikes;

  /// Items Decluttarr asked the *arrs to search for.
  final int searches;
  final int obsoleteTagged;

  JsonMap toJson() => {
    'runs': runs,
    'removed': [for (final r in removed) r.toJson()],
    'strikes': [for (final s in strikes) s.toJson()],
    'searches': searches,
    'obsoleteTagged': obsoleteTagged,
  };
}

/// `GET /maintenance/decluttarr`.
@immutable
final class DecluttarrStatus {
  const DecluttarrStatus({
    required this.container,
    this.lastRunAt,
    this.intervalMinutes = 10,
    this.nextRunAt,
    this.testMode = false,
    this.last24h = const DecluttarrLast24h(),
    this.warnings = const [],
    this.errors = const [],
  });

  factory DecluttarrStatus.fromJson(JsonMap j) => DecluttarrStatus(
    container: MaintenanceContainerState.fromJson(
      readMap(j['container']) ?? const {},
    ),
    lastRunAt: readInstant(j['lastRunAt']),
    intervalMinutes: readInt(j['intervalMinutes']) ?? 10,
    nextRunAt: readInstant(j['nextRunAt']),
    testMode: readBool(j['testMode']) ?? false,
    last24h: DecluttarrLast24h.fromJson(readMap(j['last24h']) ?? const {}),
    warnings: readList(j['warnings'], MaintenanceLogEntry.fromJson),
    errors: readList(j['errors'], MaintenanceLogEntry.fromJson),
  );

  final MaintenanceContainerState container;
  final DateTime? lastRunAt;
  final int intervalMinutes;
  final DateTime? nextRunAt;

  /// Decluttarr runs with `test_run` (nothing is really removed).
  final bool testMode;
  final DecluttarrLast24h last24h;

  /// Newest first.
  final List<MaintenanceLogEntry> warnings;

  /// Newest first.
  final List<MaintenanceLogEntry> errors;

  JsonMap toJson() => compactJson({
    'container': container.toJson(),
    'lastRunAt': optionalInstantToJson(lastRunAt),
    'intervalMinutes': intervalMinutes,
    'nextRunAt': optionalInstantToJson(nextRunAt),
    'testMode': testMode,
    'last24h': last24h.toJson(),
    'warnings': [for (final w in warnings) w.toJson()],
    'errors': [for (final e in errors) e.toJson()],
  });
}

/// One Recyclarr instance of the last run.
@immutable
final class RecyclarrInstance {
  const RecyclarrInstance({
    required this.name,
    required this.type,
    this.customFormatsCreated = 0,
    this.customFormatsUpdated = 0,
    this.customFormatsSkipped = 0,
    this.profilesSynced,
    this.qualitySizesSynced = false,
    this.completedAt,
  });

  factory RecyclarrInstance.fromJson(JsonMap j) => RecyclarrInstance(
    name: req(readString(j['name']), 'name'),
    type: RecyclarrInstanceType.fromJson(j['type']),
    customFormatsCreated: readInt(j['customFormatsCreated']) ?? 0,
    customFormatsUpdated: readInt(j['customFormatsUpdated']) ?? 0,
    customFormatsSkipped: readInt(j['customFormatsSkipped']) ?? 0,
    profilesSynced: readInt(j['profilesSynced']),
    qualitySizesSynced: readBool(j['qualitySizesSynced']) ?? false,
    completedAt: readInstant(j['completedAt']),
  );

  final String name;
  final RecyclarrInstanceType type;
  final int customFormatsCreated;
  final int customFormatsUpdated;
  final int customFormatsSkipped;
  final int? profilesSynced;
  final bool qualitySizesSynced;

  /// Absent when the instance did not complete.
  final DateTime? completedAt;

  bool get completed => completedAt != null;

  JsonMap toJson() => compactJson({
    'name': name,
    'type': type.toJson(),
    'customFormatsCreated': customFormatsCreated,
    'customFormatsUpdated': customFormatsUpdated,
    'customFormatsSkipped': customFormatsSkipped,
    'profilesSynced': profilesSynced,
    'qualitySizesSynced': qualitySizesSynced,
    'completedAt': optionalInstantToJson(completedAt),
  });
}

/// The last Recyclarr run (newest `*.debug.log`).
@immutable
final class RecyclarrRun {
  const RecyclarrRun({
    required this.startedAt,
    required this.ok,
    this.instances = const [],
    this.warnings = const [],
    this.errors = const [],
  });

  factory RecyclarrRun.fromJson(JsonMap j) => RecyclarrRun(
    startedAt: req(readInstant(j['startedAt']), 'startedAt'),
    ok: readBool(j['ok']) ?? false,
    instances: readList(j['instances'], RecyclarrInstance.fromJson),
    warnings: readStringList(j['warnings']),
    errors: readStringList(j['errors']),
  );

  final DateTime startedAt;
  final bool ok;
  final List<RecyclarrInstance> instances;
  final List<String> warnings;
  final List<String> errors;

  JsonMap toJson() => {
    'startedAt': instantToJson(startedAt),
    'ok': ok,
    'instances': [for (final i in instances) i.toJson()],
    'warnings': warnings,
    'errors': errors,
  };
}

/// `GET /maintenance/recyclarr`.
@immutable
final class RecyclarrStatus {
  const RecyclarrStatus({
    required this.container,
    required this.schedule,
    this.nextRunAt,
    this.lastRun,
    this.canSyncNow = false,
  });

  factory RecyclarrStatus.fromJson(JsonMap j) => RecyclarrStatus(
    container: MaintenanceContainerState.fromJson(
      readMap(j['container']) ?? const {},
    ),
    schedule: readString(j['schedule']) ?? '',
    nextRunAt: readInstant(j['nextRunAt']),
    lastRun: switch (readMap(j['lastRun'])) {
      final m? => RecyclarrRun.fromJson(m),
      null => null,
    },
    canSyncNow: readBool(j['canSyncNow']) ?? false,
  );

  final MaintenanceContainerState container;

  /// Cron expression (`0 4 * * 0`).
  final String schedule;
  final DateTime? nextRunAt;
  final RecyclarrRun? lastRun;

  /// "Sync now" is possible (the updater sidecar is available).
  final bool canSyncNow;

  JsonMap toJson() => compactJson({
    'container': container.toJson(),
    'schedule': schedule,
    'nextRunAt': optionalInstantToJson(nextRunAt),
    'lastRun': lastRun?.toJson(),
    'canSyncNow': canSyncNow,
  });
}

// ---------------------------------------------------------------------------
// Dashboard card (API.md §11.8)
// ---------------------------------------------------------------------------

/// A container and its CPU use (dashboard top list).
@immutable
final class ContainerCpuUsage {
  const ContainerCpuUsage({required this.name, required this.cpuPercent});

  factory ContainerCpuUsage.fromJson(JsonMap j) => ContainerCpuUsage(
    name: req(readString(j['name']), 'name'),
    cpuPercent: readDouble(j['cpuPercent']) ?? 0,
  );

  final String name;
  final double cpuPercent;

  JsonMap toJson() => {'name': name, 'cpuPercent': cpuPercent};
}

/// Decluttarr summary on the containers card.
@immutable
final class ContainersCardDecluttarr {
  const ContainersCardDecluttarr({this.lastRunAt, this.removed24h = 0});

  factory ContainersCardDecluttarr.fromJson(JsonMap j) =>
      ContainersCardDecluttarr(
        lastRunAt: readInstant(j['lastRunAt']),
        removed24h: readInt(j['removed24h']) ?? 0,
      );

  final DateTime? lastRunAt;
  final int removed24h;

  JsonMap toJson() => compactJson({
    'lastRunAt': optionalInstantToJson(lastRunAt),
    'removed24h': removed24h,
  });
}

/// Dashboard card `containers`. The raw keys `running` and `total` are read
/// by core (API.md §4) and must keep their names and int type.
@immutable
final class ContainersCard {
  const ContainersCard({
    required this.total,
    required this.running,
    this.unhealthy = const [],
    this.stopped = const [],
    this.updatesAvailable = 0,
    this.lastScan,
    this.topCpu = const [],
    this.decluttarr,
  });

  factory ContainersCard.fromJson(JsonMap j) => ContainersCard(
    total: readInt(j['total']) ?? 0,
    running: readInt(j['running']) ?? 0,
    unhealthy: readStringList(j['unhealthy']),
    stopped: readStringList(j['stopped']),
    updatesAvailable: readInt(j['updatesAvailable']) ?? 0,
    lastScan: switch (readMap(j['lastScan'])) {
      final m? => WatchtowerScan.fromJson(m),
      null => null,
    },
    topCpu: readList(j['topCpu'], ContainerCpuUsage.fromJson),
    decluttarr: switch (readMap(j['decluttarr'])) {
      final m? => ContainersCardDecluttarr.fromJson(m),
      null => null,
    },
  );

  final int total;
  final int running;
  final List<String> unhealthy;
  final List<String> stopped;
  final int updatesAvailable;
  final WatchtowerScan? lastScan;

  /// At most 3, highest first.
  final List<ContainerCpuUsage> topCpu;
  final ContainersCardDecluttarr? decluttarr;

  JsonMap toJson() => compactJson({
    'total': total,
    'running': running,
    'unhealthy': unhealthy,
    'stopped': stopped,
    'updatesAvailable': updatesAvailable,
    'lastScan': lastScan?.toJson(),
    'topCpu': [for (final c in topCpu) c.toJson()],
    'decluttarr': decluttarr?.toJson(),
  });
}
