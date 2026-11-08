/// One entry of Docker's `GET /containers/json?all=true`, parsed for the
/// containers feature (integrations/system.md §1.2).
library;

import 'package:yams_models/yams_models.dart';

/// Label keys the feature reads.
abstract final class DockerLabels {
  static const composeService = 'com.docker.compose.service';
  static const composeDependsOn = 'com.docker.compose.depends_on';
  static const imageVersion = 'org.opencontainers.image.version';
  static const watchtowerMonitorOnly =
      'com.centurylinklabs.watchtower.monitor-only';
}

final _healthSuffix = RegExp(
  r'\s*\((healthy|unhealthy|health: starting)\)\s*$',
);
final _exited = RegExp(r'^Exited \((-?\d+)\)\s*(.*?)\s*ago$');
final _up = RegExp(r'^Up\s+(.+?)(?:\s*\(.*\))?$');
final _humanDuration = RegExp(
  r'^(\d+|an?|About an?|Less than a)\s+(second|minute|hour|day|week|month|year)s?$',
  caseSensitive: false,
);

/// Parses Docker's human durations (`25 minutes`, `About an hour`,
/// `Less than a second`, `3 days`) into an approximate [Duration].
Duration? parseDockerHumanDuration(String text) {
  final m = _humanDuration.firstMatch(text.trim());
  if (m == null) return null;
  final countText = m[1]!.toLowerCase();
  final count = switch (countText) {
    'less than a' => 0,
    'a' || 'an' || 'about a' || 'about an' => 1,
    _ => int.parse(countText),
  };
  final unit = switch (m[2]!.toLowerCase()) {
    'second' => const Duration(seconds: 1),
    'minute' => const Duration(minutes: 1),
    'hour' => const Duration(hours: 1),
    'day' => const Duration(days: 1),
    'week' => const Duration(days: 7),
    'month' => const Duration(days: 30),
    _ => const Duration(days: 365),
  };
  return unit * count;
}

/// A container from the Docker list. Mount sources and other host details
/// are not kept.
final class DockerContainerEntry {
  DockerContainerEntry({
    required this.id,
    required this.name,
    required this.image,
    required this.imageId,
    required this.createdAt,
    required this.state,
    required this.status,
    required this.health,
    required this.labels,
    required this.networkMode,
    required this.ports,
  });

  /// Parses one list entry; null when it has no usable name.
  static DockerContainerEntry? fromJson(JsonMap j) {
    final names = readStringList(j['Names']);
    if (names.isEmpty) return null;
    final name = names.first.startsWith('/')
        ? names.first.substring(1)
        : names.first;
    if (name.isEmpty) return null;
    final labels = <String, String>{
      for (final e
          in (readMap(j['Labels']) ?? const <String, Object?>{}).entries)
        e.key: ?readString(e.value),
    };
    final status = readString(j['Status']) ?? '';
    final healthMap = readMap(j['Health']);
    var health = ContainerHealth.fromJson(readString(healthMap?['Status']));
    if (healthMap == null || health == ContainerHealth.unknown) {
      // Older API versions: parse the `(healthy)` suffix of Status.
      final m = _healthSuffix.firstMatch(status);
      health = switch (m?[1]) {
        'healthy' => ContainerHealth.healthy,
        'unhealthy' => ContainerHealth.unhealthy,
        'health: starting' => ContainerHealth.starting,
        _ => healthMap == null ? ContainerHealth.none : health,
      };
    }
    final created = readInt(j['Created']);
    return DockerContainerEntry(
      id: readString(j['Id']) ?? '',
      name: name,
      image: readString(j['Image']) ?? '',
      imageId: readString(j['ImageID']) ?? '',
      createdAt: created == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(created * 1000, isUtc: true),
      state: ContainerState.fromJson(readString(j['State'])),
      status: status,
      health: health,
      labels: labels,
      networkMode:
          readString(readMap(j['HostConfig'])?['NetworkMode']) ?? 'default',
      ports: _ports(j['Ports']),
    );
  }

  static List<ContainerPort> _ports(Object? raw) {
    final seen = <String>{};
    final out = <ContainerPort>[];
    for (final p in readList(raw, (m) => m)) {
      final public = readInt(p['PublicPort']);
      final private = readInt(p['PrivatePort']);
      if (public == null || private == null) continue;
      final protocol = readString(p['Type']) ?? 'tcp';
      // IPv4 and IPv6 bindings are listed twice.
      if (!seen.add('$public/$protocol')) continue;
      out.add(
        ContainerPort(public: public, private: private, protocol: protocol),
      );
    }
    out.sort((a, b) => a.public.compareTo(b.public));
    return out;
  }

  final String id;
  final String name;
  final String image;
  final String imageId;
  final DateTime? createdAt;
  final ContainerState state;

  /// Docker's raw `Status` text.
  final String status;
  final ContainerHealth health;
  final Map<String, String> labels;
  final String networkMode;
  final List<ContainerPort> ports;

  bool get isRunning => state == ContainerState.running;

  /// Compose service name (fallback: the container name).
  String get service {
    final s = labels[DockerLabels.composeService];
    return s == null || s.isEmpty ? name : s;
  }

  String? get imageVersion {
    final v = labels[DockerLabels.imageVersion];
    return v == null || v.isEmpty ? null : v;
  }

  /// Watchtower updates it automatically (label `monitor-only=false`).
  bool get autoUpdate =>
      labels[DockerLabels.watchtowerMonitorOnly]?.toLowerCase() == 'false';

  /// The image tag (null when absent, i.e. `latest`).
  String? get imageTag {
    var ref = image;
    final at = ref.indexOf('@');
    if (at >= 0) ref = ref.substring(0, at);
    final slash = ref.lastIndexOf('/');
    final colon = ref.lastIndexOf(':');
    if (colon <= slash) return null;
    return ref.substring(colon + 1);
  }

  /// The tag is pinned (not `latest`/absent): Watchtower only reports an
  /// update when that same tag is re-pushed.
  bool get pinned {
    final tag = imageTag;
    return tag != null && tag != 'latest';
  }

  /// `Status` without the `(healthy)` suffix.
  String get statusText => status.replaceFirst(_healthSuffix, '').trim();

  /// The exit code in `Exited (137) 2 hours ago`.
  int? get exitCodeFromStatus {
    final m = _exited.firstMatch(statusText);
    return m == null ? null : int.tryParse(m[1]!);
  }

  /// How long ago an exited container stopped (approximate).
  Duration? get exitedAgo {
    final m = _exited.firstMatch(statusText);
    return m == null ? null : parseDockerHumanDuration(m[2]!);
  }

  /// Approximate uptime from `Up 25 minutes`.
  Duration? get uptimeFromStatus {
    final m = _up.firstMatch(statusText);
    return m == null ? null : parseDockerHumanDuration(m[1]!);
  }

  /// The container id after `container:` in [networkMode].
  String? get networkContainerId => networkMode.startsWith('container:')
      ? networkMode.substring('container:'.length)
      : null;

  /// The first compose `depends_on` service (`gluetun:service_started:true`).
  String? get firstComposeDependency {
    final raw = labels[DockerLabels.composeDependsOn];
    if (raw == null || raw.isEmpty) return null;
    final first = raw.split(',').first.split(':').first.trim();
    return first.isEmpty ? null : first;
  }
}
