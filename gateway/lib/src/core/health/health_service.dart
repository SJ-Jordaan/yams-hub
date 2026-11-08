/// Health aggregation and capability probes (ARCHITECTURE §5.10, API.md §2.4).
library;

import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:yams_models/yams_models.dart';

import '../../config/config.dart';
import '../cache/ttl_cache.dart';
import '../clock.dart';
import '../docker/proxy_self_test.dart';
import '../log/redact.dart';
import '../upstream/upstream_client.dart';
import '../upstream/upstream_exception.dart';
import '../upstream/upstreams.dart';

final _log = Logger('core.health');

const _probeTimeout = Duration(seconds: 3);
const _slow = Duration(seconds: 2);

/// Optional capabilities probed at start-up and every 6 h (`/server`
/// `features`).
final class ServerFeatureFlags {
  bool updater = false;
  bool watchtowerCheck = false;
  bool containerLogs = false;

  ServerFeatures toDto(ProxySelfTest selfTest) => ServerFeatures(
    updater: updater,
    watchtowerCheck: watchtowerCheck,
    containerLogs: containerLogs,
    containerActions: selfTest.actionsAllowed,
  );
}

final class _Probe {
  const _Probe(this.status, {this.version, this.message});

  final ServiceHealthStatus status;
  final String? version;
  final String? message;
}

/// Probes every service in parallel (3 s timeout each) and caches the report
/// for 30 s.
final class HealthService {
  HealthService({
    required this._config,
    required Upstreams upstreams,
    required this._clock,
    required CacheFactory caches,
    required this.dockerProxy,
    this.selfTestRetryInterval = const Duration(minutes: 1),
  }) : _up = upstreams,
       _report = caches.ttl<int, HealthReport>(
         'health.report',
         const Duration(seconds: 30),
       ),
       _versions = caches.ttl<ServiceId, String?>(
         'health.versions',
         const Duration(minutes: 10),
       );

  final HubConfig _config;
  final Upstreams _up;
  final Clock _clock;
  final TtlCache<int, HealthReport> _report;
  final TtlCache<ServiceId, String?> _versions;

  /// The Docker proxy self-test (container actions are disabled until it
  /// passes).
  final ProxySelfTest dockerProxy;

  /// Probed capabilities.
  final features = ServerFeatureFlags();

  HealthReport? _last;
  Timer? _timer;
  Timer? _selfTestRetry;
  bool _started = false;

  /// How soon an unreachable Docker proxy is self-tested again (the proxy may
  /// simply start after the gateway; waiting 6 h would keep container actions
  /// disabled for no reason).
  final Duration selfTestRetryInterval;

  /// Services included in the report, in display order.
  static const reportedServices = [
    ServiceId.sonarr,
    ServiceId.radarr,
    ServiceId.prowlarr,
    ServiceId.bazarr,
    ServiceId.seerr,
    ServiceId.jellyfin,
    ServiceId.jellystat,
    ServiceId.qbittorrent,
    ServiceId.gluetun,
    ServiceId.docker,
    ServiceId.watchtower,
    ServiceId.updater,
    ServiceId.uptimeKuma,
    ServiceId.audiobookshelf,
    ServiceId.kavita,
    ServiceId.shelfmark,
    ServiceId.host,
  ];

  /// The cached report (probes again after 30 s).
  Future<HealthReport> report() async {
    final r = await _report.value(0, _probeAll);
    _last = r;
    return r;
  }

  /// The last known health of [id] (from the most recent report), or null.
  ServiceHealth? of(ServiceId id) => (_last ?? _report.peek(0))?.of(id);

  /// Drops the cached report.
  void invalidate() => _report.clear();

  /// Runs the self-test and the capability probes now, then every 6 h. While
  /// the Docker proxy is unreachable the self-test is retried every
  /// [selfTestRetryInterval].
  Future<void> start() async {
    _started = true;
    await refreshProbes();
    if (!_started) return;
    _scheduleSelfTestRetry();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(hours: 6), (_) {
      unawaited(
        refreshProbes().then((_) => _scheduleSelfTestRetry()).catchError((
          Object e,
        ) {
          _log.warning('periodic probes failed', e);
        }),
      );
    });
  }

  void stop() {
    _started = false;
    _timer?.cancel();
    _timer = null;
    _selfTestRetry?.cancel();
    _selfTestRetry = null;
  }

  void _scheduleSelfTestRetry() {
    _selfTestRetry?.cancel();
    _selfTestRetry = null;
    if (!_started ||
        !_up.docker.configured ||
        dockerProxy.state != ProxySelfTestState.unreachable) {
      return;
    }
    _selfTestRetry = Timer(selfTestRetryInterval, () async {
      _selfTestRetry = null;
      try {
        await dockerProxy.run();
      } catch (e) {
        _log.warning('Docker proxy self-test retry failed', e);
      }
      _report.clear();
      _scheduleSelfTestRetry();
    });
  }

  /// Docker proxy self-test plus `features.*` probes.
  Future<void> refreshProbes() async {
    await Future.wait([
      dockerProxy.run(),
      _probeWatchtowerCheck(),
      _probeUpdater(),
      _probeContainerLogs(),
    ]);
    _report.clear();
  }

  Future<void> _probeWatchtowerCheck() async {
    final c = _up.watchtower;
    if (!c.configured) {
      features.watchtowerCheck = false;
      return;
    }
    try {
      // Never /v1/check: that runs a real registry check.
      final r = await c.send(
        'GET',
        '/v1/containers/details',
        timeout: _probeTimeout,
        maxBytes: 1 << 20,
      );
      features.watchtowerCheck = r.status == 200;
    } on UpstreamException {
      features.watchtowerCheck = false;
    }
  }

  Future<void> _probeUpdater() async {
    final c = _up.updater;
    if (!c.configured) {
      features.updater = false;
      return;
    }
    try {
      final r = await c.send(
        'GET',
        '/healthz',
        timeout: _probeTimeout,
        maxBytes: 64 * 1024,
      );
      features.updater = r.ok;
    } on UpstreamException {
      features.updater = false;
    }
  }

  Future<void> _probeContainerLogs() async {
    final c = _up.docker;
    if (!c.configured) {
      features.containerLogs = false;
      return;
    }
    try {
      final r = await c.send(
        'GET',
        '/containers/yams-hub/logs',
        query: {'stdout': 1, 'tail': 1},
        timeout: _probeTimeout,
        maxBytes: 64 * 1024,
      );
      // 404 (no such container) still means the proxy allows the route.
      features.containerLogs = r.status != 403 && (r.ok || r.status == 404);
    } on UpstreamException {
      features.containerLogs = false;
    }
  }

  Future<HealthReport> _probeAll() async {
    final results = await Future.wait([
      for (final id in reportedServices) _probeOne(id),
    ]);
    final configured = results
        .where((s) => s.status != ServiceHealthStatus.disabled)
        .toList();
    final down = configured
        .where((s) => s.status == ServiceHealthStatus.down)
        .length;
    final ServiceHealthStatus overall;
    if (configured.every((s) => s.status == ServiceHealthStatus.up)) {
      overall = ServiceHealthStatus.up;
    } else if (down * 2 > configured.length) {
      overall = ServiceHealthStatus.down;
    } else {
      overall = ServiceHealthStatus.degraded;
    }
    return HealthReport(
      overall: overall,
      checkedAt: _clock.now(),
      services: results,
    );
  }

  Future<ServiceHealth> _probeOne(ServiceId id) async {
    final sw = Stopwatch()..start();
    _Probe result;
    if (!_config.isConfigured(id)) {
      result = const _Probe(
        ServiceHealthStatus.disabled,
        message: 'Not configured',
      );
    } else {
      try {
        result = await _probe(id)
            .timeout(_probeTimeout + const Duration(seconds: 1));
      } on TimeoutException {
        result = const _Probe(ServiceHealthStatus.down, message: 'Timed out');
      } on UpstreamNotConfigured {
        result = const _Probe(
          ServiceHealthStatus.disabled,
          message: 'Not configured',
        );
      } on UpstreamCredentialsRejected {
        result = const _Probe(
          ServiceHealthStatus.degraded,
          message: 'Credentials rejected',
        );
      } on UpstreamTimeout {
        result = const _Probe(ServiceHealthStatus.down, message: 'Timed out');
      } on UpstreamUnavailable {
        result = const _Probe(
          ServiceHealthStatus.down,
          message: 'Not reachable',
        );
      } on UpstreamException catch (e) {
        result = _Probe(
          ServiceHealthStatus.down,
          message: e.message ?? 'Unexpected answer',
        );
      } catch (e, st) {
        _log.warning('health probe for ${id.name} failed', e, st);
        result = const _Probe(
          ServiceHealthStatus.down,
          message: 'Probe failed',
        );
      }
    }
    sw.stop();
    if (result.status == ServiceHealthStatus.up && sw.elapsed > _slow) {
      result = _Probe(
        ServiceHealthStatus.degraded,
        version: result.version,
        message: 'Slow response (${sw.elapsedMilliseconds} ms)',
      );
    }
    final message = result.message;
    return ServiceHealth(
      id: id,
      name: id.displayName,
      status: result.status,
      latencyMs: result.status == ServiceHealthStatus.disabled
          ? null
          : sw.elapsedMilliseconds,
      version: result.version,
      message: message == null ? null : redactSecrets(message),
      checkedAt: _clock.now(),
    );
  }

  /// A `GET` whose status decides up/down; 401/403 is degraded.
  Future<_Probe?> _get(
    UpstreamClient c,
    String path, {
    Map<String, Object?>? query,
  }) async {
    final r = await c.send(
      'GET',
      path,
      query: query,
      timeout: _probeTimeout,
      maxBytes: 1 << 20,
    );
    if (r.status == 401 || r.status == 403) {
      return const _Probe(
        ServiceHealthStatus.degraded,
        message: 'Credentials rejected',
      );
    }
    if (!r.ok) {
      return _Probe(ServiceHealthStatus.down, message: 'HTTP ${r.status}');
    }
    return null;
  }

  Future<String?> _version(
    ServiceId id,
    Future<String?> Function() load,
  ) async {
    try {
      return await _versions.value(id, load);
    } on Exception {
      return null;
    }
  }

  /// Reads a JSON field of a GET answer for the version (null on failure).
  Future<String?> _jsonVersion(
    UpstreamClient c,
    String path,
    String? Function(JsonMap j) pick,
  ) async {
    final r = await c.send(
      'GET',
      path,
      timeout: _probeTimeout,
      maxBytes: 1 << 20,
    );
    if (r.status == 401 || r.status == 403) throw _CredentialsRejected();
    if (!r.ok) return null;
    final j = readMap(r.json());
    return j == null ? null : pick(j);
  }

  Future<_Probe> _probe(ServiceId id) async {
    switch (id) {
      case ServiceId.sonarr || ServiceId.radarr || ServiceId.prowlarr:
        final c = _up[id];
        final fail = await _get(c, '/ping');
        if (fail != null) return fail;
        final prefix = id == ServiceId.prowlarr ? '/api/v1' : '/api/v3';
        return _withVersion(
          id,
          () => _jsonVersion(
            c,
            '$prefix/system/status',
            (j) => readString(j['version']),
          ),
        );
      case ServiceId.bazarr:
        final c = _up.bazarr;
        final fail = await _get(c, '/api/system/ping');
        if (fail != null) return fail;
        return _withVersion(
          id,
          () => _jsonVersion(
            c,
            '/api/system/status',
            (j) => readString(readMap(j['data'])?['bazarr_version']),
          ),
        );
      case ServiceId.seerr:
        return _upWithJsonVersion(
          _up.seerr,
          '/api/v1/status',
          (j) => readString(j['version']),
        );
      case ServiceId.jellyfin:
        return _upWithJsonVersion(
          _up.jellyfin,
          '/System/Info/Public',
          (j) => readString(j['Version']),
        );
      case ServiceId.jellystat:
        return _upWithJsonVersion(
          _up.jellystat,
          '/auth/isConfigured',
          (j) => readString(j['version']),
        );
      case ServiceId.qbittorrent:
        final r = await _up.qbittorrent.send(
          'GET',
          '/api/v2/app/version',
          timeout: _probeTimeout,
          maxBytes: 4096,
        );
        if (r.status == 401 || r.status == 403) {
          return const _Probe(
            ServiceHealthStatus.degraded,
            message: 'Credentials rejected',
          );
        }
        if (!r.ok) {
          return _Probe(ServiceHealthStatus.down, message: 'HTTP ${r.status}');
        }
        final v = r.text().trim();
        return _Probe(
          ServiceHealthStatus.up,
          version: v.isEmpty ? null : (v.startsWith('v') ? v.substring(1) : v),
        );
      case ServiceId.gluetun:
        return await _get(_up.gluetun, '/v1/openvpn/portforwarded') ??
            const _Probe(ServiceHealthStatus.up);
      case ServiceId.docker:
        final c = _up.docker;
        final fail = await _get(c, '/_ping');
        if (fail != null) return fail;
        final version = await _version(
          id,
          () => _jsonVersion(c, '/version', (j) => readString(j['Version'])),
        );
        final selfTestMessage = dockerProxy.healthMessage;
        if (selfTestMessage != null) {
          return _Probe(
            ServiceHealthStatus.degraded,
            version: version,
            message: selfTestMessage,
          );
        }
        return _Probe(ServiceHealthStatus.up, version: version);
      case ServiceId.watchtower:
        return await _get(_up.watchtower, '/v1/metrics') ??
            const _Probe(ServiceHealthStatus.up);
      case ServiceId.updater:
        return _upWithJsonVersion(
          _up.updater,
          '/healthz',
          (j) => readString(j['version']),
        );
      case ServiceId.uptimeKuma:
        return await _get(
              _up.uptimeKuma,
              '/api/status-page/${_config.uptimeKumaSlug}',
            ) ??
            const _Probe(ServiceHealthStatus.up);
      case ServiceId.audiobookshelf:
        return _upWithJsonVersion(
          _up.audiobookshelf,
          '/status',
          (j) => readString(j['serverVersion']),
        );
      case ServiceId.kavita:
        final c = _up.kavita;
        final fail = await _get(c, '/api/health');
        if (fail != null) return fail;
        final r = await c.send(
          'GET',
          '/api/Server/server-info-slim',
          timeout: _probeTimeout,
          maxBytes: 1 << 20,
        );
        if (r.status == 401 || r.status == 403) {
          return const _Probe(
            ServiceHealthStatus.degraded,
            message: 'Auth key rejected',
          );
        }
        final j = r.ok ? readMap(r.json()) : null;
        return _Probe(
          ServiceHealthStatus.up,
          version: readString(j?['kavitaVersion']),
        );
      case ServiceId.shelfmark:
        final r = await _up.shelfmark.send(
          'GET',
          '/api/health',
          timeout: _probeTimeout,
          maxBytes: 64 * 1024,
        );
        if (r.ok) return const _Probe(ServiceHealthStatus.up);
        if (r.status == 503) {
          final j = readMap(_tryJson(r));
          if (readString(j?['status']) == 'error') {
            return const _Probe(
              ServiceHealthStatus.degraded,
              message: 'Download coordinator stopped',
            );
          }
        }
        return _Probe(ServiceHealthStatus.down, message: 'HTTP ${r.status}');
      case ServiceId.host:
        final netDev = File(_config.hostNetDev);
        final stat = File(p.join(_config.procDir, 'stat'));
        final ok = await netDev.exists() && await stat.exists();
        if (!ok) {
          return const _Probe(
            ServiceHealthStatus.down,
            message: 'Host metrics files are not readable',
          );
        }
        return const _Probe(ServiceHealthStatus.up);
      case ServiceId.unknown:
        return const _Probe(ServiceHealthStatus.disabled);
    }
  }

  Object? _tryJson(UpstreamResponse r) {
    try {
      return r.json();
    } on UpstreamException {
      return null;
    }
  }

  Future<_Probe> _withVersion(
    ServiceId id,
    Future<String?> Function() load,
  ) async {
    try {
      return _Probe(
        ServiceHealthStatus.up,
        version: await _versions.value(id, load),
      );
    } on _CredentialsRejected {
      return const _Probe(
        ServiceHealthStatus.degraded,
        message: 'API key rejected',
      );
    } on UpstreamException {
      return const _Probe(ServiceHealthStatus.up);
    }
  }

  Future<_Probe> _upWithJsonVersion(
    UpstreamClient c,
    String path,
    String? Function(JsonMap j) pick,
  ) async {
    final r = await c.send(
      'GET',
      path,
      timeout: _probeTimeout,
      maxBytes: 1 << 20,
    );
    if (r.status == 401 || r.status == 403) {
      return const _Probe(
        ServiceHealthStatus.degraded,
        message: 'Credentials rejected',
      );
    }
    if (!r.ok) {
      return _Probe(ServiceHealthStatus.down, message: 'HTTP ${r.status}');
    }
    final j = readMap(_tryJson(r));
    return _Probe(ServiceHealthStatus.up, version: j == null ? null : pick(j));
  }
}

final class _CredentialsRejected implements Exception {}
