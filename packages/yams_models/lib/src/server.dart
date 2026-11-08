/// Gateway identity, app-wide configuration and health (API.md §2.1, §2.4,
/// §2.5).
library;

import 'package:meta/meta.dart';

import 'common.dart';
import 'json.dart';

/// 200 body of `GET /ping` [public].
@immutable
final class ServerPing {
  const ServerPing({
    required this.name,
    required this.version,
    required this.apiVersion,
    required this.minAppVersion,
    required this.instanceId,
    required this.time,
    this.proof,
  });

  factory ServerPing.fromJson(JsonMap j) => ServerPing(
    name: req(readString(j['name']), 'name'),
    version: req(readString(j['version']), 'version'),
    apiVersion: req(readInt(j['apiVersion']), 'apiVersion'),
    minAppVersion: req(readString(j['minAppVersion']), 'minAppVersion'),
    instanceId: req(readString(j['instanceId']), 'instanceId'),
    time: req(readInstant(j['time']), 'time'),
    proof: readString(j['proof']),
  );

  /// Always `yams-hub`.
  final String name;

  /// Gateway version (semver).
  final String version;
  final int apiVersion;

  /// Oldest app version this gateway supports (semver).
  final String minAppVersion;

  /// Random id generated once per installation (public; not a credential).
  final String instanceId;
  final DateTime time;

  /// `base64url(HMAC-SHA256(serverProofKey, nonce))` when `nonce` and a live
  /// `sid` were sent.
  final String? proof;

  JsonMap toJson() => compactJson({
    'name': name,
    'version': version,
    'apiVersion': apiVersion,
    'minAppVersion': minAppVersion,
    'instanceId': instanceId,
    'time': instantToJson(time),
    'proof': proof,
  });
}

// ---------------------------------------------------------------------------
// GET /server
// ---------------------------------------------------------------------------

/// Whether one service has a URL/key in the gateway config.
@immutable
final class ServerServiceInfo {
  const ServerServiceInfo({required this.id, required this.configured});

  factory ServerServiceInfo.fromJson(JsonMap j) => ServerServiceInfo(
    id: ServiceId.fromJson(j['id']),
    configured: readBool(j['configured']) ?? false,
  );

  final ServiceId id;
  final bool configured;

  JsonMap toJson() => {'id': id.toJson(), 'configured': configured};
}

/// Where an [ExternalApp]'s web UI lives: the app uses [baseUrl] when set,
/// otherwise the active hub host with [port] (ARCHITECTURE §7.10).
@immutable
final class ExternalAppConfig {
  const ExternalAppConfig({required this.port, this.baseUrl});

  factory ExternalAppConfig.fromJson(JsonMap j) => ExternalAppConfig(
    port: req(readInt(j['port']), 'port'),
    baseUrl: readString(j['baseUrl']),
  );

  final int port;
  final String? baseUrl;

  JsonMap toJson() => compactJson({'port': port, 'baseUrl': baseUrl});
}

/// Gateway policy switches the app needs to shape its UI.
@immutable
final class ServerPolicy {
  const ServerPolicy({
    this.allowGlobalSearch = false,
    this.allowArrDeleteFiles = false,
    this.lockedContainers = const [],
    this.confirmContainers = const [],
  });

  factory ServerPolicy.fromJson(JsonMap j) => ServerPolicy(
    allowGlobalSearch: readBool(j['allowGlobalSearch']) ?? false,
    allowArrDeleteFiles: readBool(j['allowArrDeleteFiles']) ?? false,
    lockedContainers: readStringList(j['lockedContainers']),
    confirmContainers: readStringList(j['confirmContainers']),
  );

  final bool allowGlobalSearch;
  final bool allowArrDeleteFiles;

  /// Containers the hub never controls.
  final List<String> lockedContainers;

  /// Containers whose actions require confirmation.
  final List<String> confirmContainers;

  JsonMap toJson() => {
    'allowGlobalSearch': allowGlobalSearch,
    'allowArrDeleteFiles': allowArrDeleteFiles,
    'lockedContainers': lockedContainers,
    'confirmContainers': confirmContainers,
  };
}

/// Optional capabilities probed by the gateway.
@immutable
final class ServerFeatures {
  const ServerFeatures({
    this.updater = false,
    this.watchtowerCheck = false,
    this.containerLogs = false,
    this.containerActions = false,
  });

  factory ServerFeatures.fromJson(JsonMap j) => ServerFeatures(
    updater: readBool(j['updater']) ?? false,
    watchtowerCheck: readBool(j['watchtowerCheck']) ?? false,
    containerLogs: readBool(j['containerLogs']) ?? false,
    containerActions: readBool(j['containerActions']) ?? false,
  );

  /// The updater sidecar is configured and answers.
  final bool updater;

  /// Watchtower exposes its check/containers endpoints.
  final bool watchtowerCheck;

  /// The docker proxy allows container logs.
  final bool containerLogs;

  /// The docker proxy self-test passed; restart/start/stop are available.
  final bool containerActions;

  JsonMap toJson() => {
    'updater': updater,
    'watchtowerCheck': watchtowerCheck,
    'containerLogs': containerLogs,
    'containerActions': containerActions,
  };
}

/// Seerr's public settings relevant to the request screens.
@immutable
final class ServerSeerrSettings {
  const ServerSeerrSettings({
    this.fourKEnabled = false,
    this.partialRequestsEnabled = false,
    this.specialEpisodesEnabled = false,
  });

  factory ServerSeerrSettings.fromJson(JsonMap j) => ServerSeerrSettings(
    fourKEnabled: readBool(j['fourKEnabled']) ?? false,
    partialRequestsEnabled: readBool(j['partialRequestsEnabled']) ?? false,
    specialEpisodesEnabled: readBool(j['specialEpisodesEnabled']) ?? false,
  );

  final bool fourKEnabled;
  final bool partialRequestsEnabled;
  final bool specialEpisodesEnabled;

  JsonMap toJson() => {
    'fourKEnabled': fourKEnabled,
    'partialRequestsEnabled': partialRequestsEnabled,
    'specialEpisodesEnabled': specialEpisodesEnabled,
  };
}

/// 200 body of `GET /server`: app-wide configuration.
@immutable
final class ServerConfig {
  const ServerConfig({
    required this.version,
    required this.instanceId,
    this.publicUrls = const [],
    this.services = const [],
    this.externalApps = const {},
    this.jellyfinServerId,
    this.policy = const ServerPolicy(),
    this.features = const ServerFeatures(),
    this.seerr = const ServerSeerrSettings(),
  });

  factory ServerConfig.fromJson(JsonMap j) => ServerConfig(
    version: req(readString(j['version']), 'version'),
    instanceId: req(readString(j['instanceId']), 'instanceId'),
    publicUrls: readStringList(j['publicUrls']),
    services: readList(j['services'], ServerServiceInfo.fromJson),
    externalApps: _readExternalApps(j['externalApps']),
    jellyfinServerId: readString(j['jellyfinServerId']),
    policy: ServerPolicy.fromJson(readMap(j['policy']) ?? const {}),
    features: ServerFeatures.fromJson(readMap(j['features']) ?? const {}),
    seerr: ServerSeerrSettings.fromJson(readMap(j['seerr']) ?? const {}),
  );

  final String version;
  final String instanceId;

  /// Base URLs the hub is reachable on (LAN, Tailscale).
  final List<String> publicUrls;
  final List<ServerServiceInfo> services;

  /// Launcher targets. Apps this version does not know are dropped.
  final Map<ExternalApp, ExternalAppConfig> externalApps;
  final String? jellyfinServerId;
  final ServerPolicy policy;
  final ServerFeatures features;
  final ServerSeerrSettings seerr;

  /// Whether [id] has a URL/key in the gateway config.
  bool isConfigured(ServiceId id) {
    for (final s in services) {
      if (s.id == id) return s.configured;
    }
    return false;
  }

  JsonMap toJson() => compactJson({
    'version': version,
    'instanceId': instanceId,
    'publicUrls': publicUrls,
    'services': [for (final s in services) s.toJson()],
    'externalApps': {
      for (final e in externalApps.entries) e.key.toJson(): e.value.toJson(),
    },
    'jellyfinServerId': jellyfinServerId,
    'policy': policy.toJson(),
    'features': features.toJson(),
    'seerr': seerr.toJson(),
  });

  static Map<ExternalApp, ExternalAppConfig> _readExternalApps(Object? v) {
    final m = readMap(v);
    if (m == null) return const {};
    final out = <ExternalApp, ExternalAppConfig>{};
    for (final e in m.entries) {
      final app = ExternalApp.fromJson(e.key);
      final config = readMap(e.value);
      if (app == ExternalApp.unknown || config == null) continue;
      if (readInt(config['port']) == null) continue;
      out[app] = ExternalAppConfig.fromJson(config);
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// GET /health
// ---------------------------------------------------------------------------

/// Health of one service, and the overall [HealthReport.overall].
enum ServiceHealthStatus {
  up,
  degraded,
  down,
  disabled,
  unknown;

  static ServiceHealthStatus fromJson(Object? v) =>
      readEnum(v, ServiceHealthStatus.values, ServiceHealthStatus.unknown);

  String toJson() => name;
}

/// The result of one health probe.
@immutable
final class ServiceHealth {
  const ServiceHealth({
    required this.id,
    required this.name,
    required this.status,
    required this.checkedAt,
    this.latencyMs,
    this.version,
    this.message,
  });

  factory ServiceHealth.fromJson(JsonMap j) {
    final id = ServiceId.fromJson(j['id']);
    return ServiceHealth(
      id: id,
      name: readString(j['name']) ?? id.displayName,
      status: ServiceHealthStatus.fromJson(j['status']),
      latencyMs: readInt(j['latencyMs']),
      version: readString(j['version']),
      message: readString(j['message']),
      checkedAt: req(readInstant(j['checkedAt']), 'checkedAt'),
    );
  }

  final ServiceId id;

  /// Display name, e.g. `Sonarr`.
  final String name;
  final ServiceHealthStatus status;
  final int? latencyMs;
  final String? version;

  /// Redacted reason for a non-up status.
  final String? message;
  final DateTime checkedAt;

  JsonMap toJson() => compactJson({
    'id': id.toJson(),
    'name': name,
    'status': status.toJson(),
    'latencyMs': latencyMs,
    'version': version,
    'message': message,
    'checkedAt': instantToJson(checkedAt),
  });
}

/// 200 body of `GET /health`.
@immutable
final class HealthReport {
  const HealthReport({
    required this.overall,
    required this.checkedAt,
    this.services = const [],
  });

  factory HealthReport.fromJson(JsonMap j) => HealthReport(
    overall: ServiceHealthStatus.fromJson(j['overall']),
    checkedAt: req(readInstant(j['checkedAt']), 'checkedAt'),
    services: readList(j['services'], ServiceHealth.fromJson),
  );

  /// `up`, `degraded` or `down`.
  final ServiceHealthStatus overall;
  final DateTime checkedAt;
  final List<ServiceHealth> services;

  /// The probe result for [id], if it is part of the report.
  ServiceHealth? of(ServiceId id) {
    for (final s in services) {
      if (s.id == id) return s;
    }
    return null;
  }

  JsonMap toJson() => {
    'overall': overall.toJson(),
    'checkedAt': instantToJson(checkedAt),
    'services': [for (final s in services) s.toJson()],
  };
}
