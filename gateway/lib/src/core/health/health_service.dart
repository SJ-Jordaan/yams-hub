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
import '../upstream/allowed_hosts.dart';
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

/// What the hub knows about an *arr's Allowed Hosts setting (issue #2).
enum AllowedHostsState {
  /// Empty, or lists the hub's hostname (or the setting is not readable).
  ok,

  /// Saved without the hub's hostname but not active yet: the *arr rejects
  /// the hub after its next restart.
  pending,

  /// Active: the *arr answers the hub with `400 Invalid Hostname`.
  rejected,
}

/// The result of an Allowed Hosts check of [service] for [host] (the hostname
/// of the hub's URL for it).
final class AllowedHostsCheck {
  const AllowedHostsCheck(
    this.service,
    this.host,
    this.state, {
    this.allowedHosts = '',
  });

  final ServiceId service;
  final String host;
  final AllowedHostsState state;

  /// The saved value (for [AllowedHostsState.pending]).
  final String allowedHosts;

  /// The user-facing explanation, null when [state] is ok.
  String? get message => switch (state) {
    AllowedHostsState.ok => null,
    AllowedHostsState.pending => hostPendingMessage(
      service,
      host,
      allowedHosts,
    ),
    AllowedHostsState.rejected => hostRejectedMessage(service, host),
  };

  /// The dashboard alert (`<service>.allowedHosts`), null when ok.
  Alert? alert({required String feature, required String route}) {
    final text = message;
    if (text == null) return null;
    final name = service.displayName;
    final rejected = state == AllowedHostsState.rejected;
    return Alert(
      id: '${service.name}.allowedHosts',
      severity: rejected ? AlertSeverity.error : AlertSeverity.warning,
      source: service,
      feature: feature,
      title: rejected
          ? "$name rejects the hub's hostname"
          : '$name will reject the hub after its next restart',
      message: text,
      route: route,
    );
  }
}

final class _Probe {
  const _Probe(this.status, {this.version, this.message, this.latency});

  final ServiceHealthStatus status;
  final String? version;
  final String? message;

  /// The time of the call that answers "is it up" when the probe makes
  /// others too (the *arrs' `/ping`); null means the whole probe.
  final Duration? latency;
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
       ),
       _allowedHosts = caches.ttl<ServiceId, AllowedHostsCheck>(
         'health.allowedHosts',
         allowedHostsTtl,
       );

  /// How long an Allowed Hosts check is reused (the health probe and the
  /// dashboard cards share it: at most one `config/host` read per *arr per
  /// minute).
  static const allowedHostsTtl = Duration(minutes: 1);

  final HubConfig _config;
  final Upstreams _up;
  final Clock _clock;
  final TtlCache<int, HealthReport> _report;
  final TtlCache<ServiceId, String?> _versions;
  final TtlCache<ServiceId, AllowedHostsCheck> _allowedHosts;

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

  /// The Allowed Hosts check of Sonarr, Radarr or Prowlarr (cached
  /// [allowedHostsTtl]; never throws). Reads `allowedHosts` from
  /// `config/host` with the gateway's key: a saved list without the hub's
  /// hostname is [AllowedHostsState.pending] (the *arr applies it at its next
  /// restart), a `400 Invalid Hostname` answer [AllowedHostsState.rejected].
  /// Anything else (not configured, other errors, an *arr without the
  /// setting) counts as ok: the other probes report those.
  Future<AllowedHostsCheck> allowedHosts(ServiceId id) {
    if (!allowedHostsServices.contains(id)) {
      return Future.value(AllowedHostsCheck(id, '', AllowedHostsState.ok));
    }
    final c = _up[id];
    final host = c.baseUrl.host;
    final ok = AllowedHostsCheck(id, host, AllowedHostsState.ok);
    if (!c.configured) return Future.value(ok);
    return _allowedHosts.value(id, () async {
      try {
        final prefix = id == ServiceId.prowlarr ? '/api/v1' : '/api/v3';
        // The body also holds the API key and passwords: only allowedHosts
        // is read, and the body is never logged.
        final r = await c.send(
          'GET',
          '$prefix/config/host',
          timeout: _probeTimeout,
          maxBytes: 256 * 1024,
        );
        if (r.isHostRejected) {
          return AllowedHostsCheck(id, host, AllowedHostsState.rejected);
        }
        if (!r.ok) return ok;
        final saved = readString(readMap(_tryJson(r))?['allowedHosts']);
        if (saved == null || allowedHostsAccepts(saved, host)) return ok;
        return AllowedHostsCheck(
          id,
          host,
          AllowedHostsState.pending,
          allowedHosts: saved,
        );
      } on Object catch (e) {
        _log.fine('allowed hosts check of ${id.name} failed: $e');
        return ok;
      }
    });
  }

  /// The dashboard alert of [allowedHosts] for [id] (null when ok; never
  /// throws).
  Future<Alert?> allowedHostsAlert(
    ServiceId id, {
    required String feature,
    required String route,
  }) async => (await allowedHosts(id)).alert(feature: feature, route: route);

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
    final latency = result.latency ?? sw.elapsed;
    if (result.status == ServiceHealthStatus.up && latency > _slow) {
      result = _Probe(
        ServiceHealthStatus.degraded,
        version: result.version,
        message: 'Slow response (${latency.inMilliseconds} ms)',
      );
    }
    final message = result.message;
    return ServiceHealth(
      id: id,
      name: id.displayName,
      status: result.status,
      latencyMs: result.status == ServiceHealthStatus.disabled
          ? null
          : latency.inMilliseconds,
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

  /// Sonarr, Radarr, Prowlarr: `/ping`, the version, and the Allowed Hosts
  /// check (issue #2), which turns a rejected or soon-rejected hostname into
  /// `degraded` with a message that says how to fix it.
  ///
  /// The latency (and the slow threshold) is the `/ping` time alone. The
  /// probe waits for the Allowed Hosts read only until [_probeTimeout] has
  /// passed since it started; a slower read finishes in the background and
  /// the probe uses the last known result, so the check never makes a slow
  /// *arr look slower or time out.
  Future<_Probe> _probeArr(ServiceId id) async {
    final c = _up[id];
    final sw = Stopwatch()..start();
    final ping = await c.send(
      'GET',
      '/ping',
      timeout: _probeTimeout,
      maxBytes: 1 << 20,
    );
    final latency = sw.elapsed;
    if (ping.isHostRejected) {
      final check = AllowedHostsCheck(
        id,
        c.baseUrl.host,
        AllowedHostsState.rejected,
      );
      _allowedHosts.put(id, check);
      return _Probe(
        ServiceHealthStatus.degraded,
        message: check.message,
        latency: latency,
      );
    }
    // Accepted again (fixed and restarted): forget the rejection.
    if (_allowedHosts.peek(id)?.state == AllowedHostsState.rejected) {
      _allowedHosts.invalidate(id);
    }
    if (ping.status == 401 || ping.status == 403) {
      return _Probe(
        ServiceHealthStatus.degraded,
        message: 'Credentials rejected',
        latency: latency,
      );
    }
    if (!ping.ok) {
      return _Probe(
        ServiceHealthStatus.down,
        message: 'HTTP ${ping.status}',
        latency: latency,
      );
    }
    final prefix = id == ServiceId.prowlarr ? '/api/v1' : '/api/v3';
    final budget = _probeTimeout - sw.elapsed;
    final hostsCheck = allowedHosts(id).timeout(
      budget.isNegative ? Duration.zero : budget,
      onTimeout: () =>
          _allowedHosts.peek(id) ??
          AllowedHostsCheck(id, c.baseUrl.host, AllowedHostsState.ok),
    ); // never throws
    final probe = await _withVersion(
      id,
      () => _jsonVersion(
        c,
        '$prefix/system/status',
        (j) => readString(j['version']),
      ),
    );
    final hosts = await hostsCheck;
    if (probe.status == ServiceHealthStatus.up &&
        hosts.state != AllowedHostsState.ok) {
      return _Probe(
        ServiceHealthStatus.degraded,
        version: probe.version,
        message: hosts.message,
        latency: latency,
      );
    }
    return _Probe(
      probe.status,
      version: probe.version,
      message: probe.message,
      latency: latency,
    );
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
        return _probeArr(id);
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
