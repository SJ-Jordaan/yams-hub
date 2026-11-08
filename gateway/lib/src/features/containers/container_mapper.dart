/// Docker list/inspect → DTOs (API.md §11.1). Raw inspect bodies never leave
/// the gateway: `Config.Env`, `Cmd`, `HostConfig` and mount sources are not
/// mapped.
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'container_events.dart';
import 'container_stats.dart';
import 'docker_entry.dart';

/// Static dependency hints (API.md §11.1): container → dependents.
const containerDependents = <String, List<String>>{
  'gluetun': ['qbittorrent'],
  'jellystat-db': ['jellystat'],
  'sonarr': ['recyclarr', 'decluttarr', 'bazarr'],
  'radarr': ['recyclarr', 'decluttarr', 'bazarr'],
  'socket-proxy': ['homepage', 'uptime-kuma'],
};

/// Containers [name] depends on.
List<String> containerDependsOn(String name) => [
  for (final e in containerDependents.entries)
    if (e.value.contains(name)) e.key,
];

/// The [ExternalApp] whose web UI the service offers (`uptime-kuma` →
/// `uptimeKuma`), or null.
ExternalApp? externalAppForService(String service) {
  final direct = ExternalApp.fromJson(service);
  if (direct != ExternalApp.unknown) return direct;
  final parts = service.split(RegExp('[-_]'));
  final camel = [
    parts.first,
    for (final p in parts.skip(1))
      if (p.isNotEmpty) '${p[0].toUpperCase()}${p.substring(1)}',
  ].join();
  final app = ExternalApp.fromJson(camel);
  return app == ExternalApp.unknown ? null : app;
}

/// Longest health-check output sent to admins.
const healthOutputMaxChars = 200;

/// What [mapContainerSummary] needs besides the list entry.
final class ContainerMappingContext {
  const ContainerMappingContext({
    required this.policy,
    required this.now,
    required this.byId,
    this.stats,
    this.updates = const {},
    this.startedAt = const {},
  });

  final ContainerPolicy policy;
  final DateTime now;

  /// Every listed container by id (to name `container:<id>` network modes).
  final Map<String, DockerContainerEntry> byId;
  final ContainerStatsStore? stats;

  /// Update badge per container name.
  final Map<String, ContainerUpdateFlag> updates;

  /// `State.StartedAt` per container id (from inspect).
  final Map<String, DateTime> startedAt;
}

ContainerProtection containerProtection(ContainerPolicy policy, String name) {
  if (policy.isLocked(name)) return ContainerProtection.locked;
  if (policy.needsConfirm(name)) return ContainerProtection.confirm;
  return ContainerProtection.none;
}

/// The container whose network namespace [e] shares, by name.
String? sharedNetworkOf(
  DockerContainerEntry e,
  Map<String, DockerContainerEntry> byId,
) {
  final id = e.networkContainerId;
  if (id == null || id.isEmpty) return null;
  for (final other in byId.values) {
    if (other.id == id || (id.length >= 12 && other.id.startsWith(id))) {
      return other.name;
    }
  }
  // The netns owner is missing from the list (being recreated): compose's
  // depends_on label still names it.
  return e.firstComposeDependency;
}

ContainerSummary mapContainerSummary(
  DockerContainerEntry e,
  ContainerMappingContext c, {
  DateTime? startedAt,
}) {
  final started = startedAt ?? c.startedAt[e.id];
  final running =
      e.state == ContainerState.running ||
      e.state == ContainerState.paused ||
      e.state == ContainerState.restarting;
  int? uptime;
  if (running && started != null) {
    final s = c.now.difference(started).inSeconds;
    uptime = s < 0 ? 0 : s;
  } else if (running) {
    uptime = e.uptimeFromStatus?.inSeconds;
  }
  final shares = sharedNetworkOf(e, c.byId);
  final figures = running ? c.stats?.of(e.id) : null;
  final app = externalAppForService(e.service);
  return ContainerSummary(
    name: e.name,
    service: e.service,
    group: c.policy.groupOf(e.name) ?? c.policy.groupOf(e.service) ?? 'other',
    image: e.image,
    imageVersion: e.imageVersion,
    state: e.state,
    statusText: e.statusText,
    health: e.health,
    startedAt: running ? started : null,
    uptimeSeconds: uptime,
    cpuPercent: figures?.cpuPercent,
    memBytes: figures?.memBytes,
    memPercent: figures?.memPercent,
    // A shared netns reports the owner's counters: count them only once.
    netRxBps: shares == null ? figures?.netRxBps : null,
    netTxBps: shares == null ? figures?.netTxBps : null,
    sharesNetworkWith: shares,
    autoUpdate: e.autoUpdate,
    pinned: e.pinned,
    update: c.updates[e.name],
    protection: containerProtection(c.policy, e.name),
    ports: e.ports,
    links: [if (app != null) ExternalLink(app, '/')],
  );
}

/// The healthcheck log of an inspect body; [admin] callers get the output,
/// redacted and cut to 200 characters.
List<ContainerHealthLogEntry> mapHealthLog(
  JsonMap inspect, {
  required bool admin,
  required String Function(String) redact,
}) {
  final health = readMap(readMap(inspect['State'])?['Health']);
  final out = <ContainerHealthLogEntry>[];
  for (final h in readList(health?['Log'], (m) => m)) {
    final start = readInstant(h['Start']);
    final end = readInstant(h['End']) ?? start;
    if (start == null || end == null) continue;
    String? output;
    if (admin) {
      final raw = readString(h['Output'])?.trim();
      if (raw != null && raw.isNotEmpty) {
        final clean = redact(raw);
        output = clean.length > healthOutputMaxChars
            ? clean.substring(0, healthOutputMaxChars)
            : clean;
      }
    }
    out.add(
      ContainerHealthLogEntry(
        start: start,
        end: end,
        exitCode: readInt(h['ExitCode']) ?? 0,
        output: output,
      ),
    );
  }
  return out;
}

/// `State.StartedAt` of an inspect body.
DateTime? inspectStartedAt(JsonMap inspect) =>
    readInstant(readMap(inspect['State'])?['StartedAt']);

/// `Config.Tty` of an inspect body.
bool inspectTty(JsonMap inspect) =>
    readBool(readMap(inspect['Config'])?['Tty']) ?? false;

/// `State.Health.Status` (or `none`) and `State.Status` of an inspect body.
(ContainerState, ContainerHealth) inspectStateHealth(JsonMap inspect) {
  final state = readMap(inspect['State']);
  final health = readMap(state?['Health']);
  return (
    ContainerState.fromJson(readString(state?['Status'])),
    health == null
        ? ContainerHealth.none
        : ContainerHealth.fromJson(readString(health['Status'])),
  );
}

ContainerDetail mapContainerDetail(
  DockerContainerEntry e,
  JsonMap inspect,
  ContainerMappingContext c, {
  required bool admin,
  required String Function(String) redact,
  required ContainerEventBuffer events,
}) {
  final state = readMap(inspect['State']) ?? const <String, Object?>{};
  final hostConfig = readMap(inspect['HostConfig']);
  final summary = mapContainerSummary(
    e,
    c,
    startedAt: inspectStartedAt(inspect),
  );
  final finishedAt = readInstant(state['FinishedAt']);
  final error = readString(state['Error'])?.trim();
  final running = readBool(state['Running']) ?? summary.isRunning;
  final figures = c.stats?.of(e.id);
  return ContainerDetail(
    summary: summary,
    restartCount: readInt(inspect['RestartCount']) ?? 0,
    finishedAt: finishedAt,
    // A running container reports ExitCode 0: only stopped ones have one.
    exitCode: running ? null : readInt(state['ExitCode']),
    oomKilled: readBool(state['OOMKilled']) ?? false,
    error: error == null || error.isEmpty ? null : redact(error),
    restartPolicy:
        readString(readMap(hostConfig?['RestartPolicy'])?['Name']) ?? 'no',
    imageId: readString(inspect['Image']) ?? e.imageId,
    createdAt: readInstant(inspect['Created']) ?? e.createdAt ?? c.now,
    healthLog: mapHealthLog(inspect, admin: admin, redact: redact),
    events: events.latest(limit: 20, name: e.name),
    dependents: containerDependents[e.name] ?? const [],
    dependsOn: containerDependsOn(e.name),
    mounts: [
      for (final m in readList(inspect['Mounts'], (m) => m))
        if (readString(m['Destination']) case final d? when d.isNotEmpty)
          ContainerMount(
            destination: d,
            readOnly: !(readBool(m['RW']) ?? true),
          ),
    ]..sort((a, b) => a.destination.compareTo(b.destination)),
    // `container:<64 hex id>` is shown with the owner's name.
    networkMode: summary.sharesNetworkWith != null
        ? 'container:${summary.sharesNetworkWith}'
        : readString(hostConfig?['NetworkMode']) ?? e.networkMode,
    pids: running ? figures?.pids : null,
  );
}
