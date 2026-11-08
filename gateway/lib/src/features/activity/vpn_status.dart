/// `GET /vpn` (API.md §8.6): gluetun's two readable routes, qBittorrent's
/// listen port and connection status, and the gluetun container health.
library;

import 'dart:convert';

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'maindata.dart';

/// Builds [VpnStatus] (cache 30 s).
final class VpnStatusService {
  VpnStatusService(this._ctx, this._maindata, this._preferences)
    : _cache = _ctx.caches.ttl<int, VpnStatus>(
        'activity.vpn',
        const Duration(seconds: 30),
      );

  final FeatureContext _ctx;
  final QbitMaindata _maindata;

  /// Whitelisted qBittorrent preferences (cache 10 min).
  final Future<JsonMap> Function() _preferences;
  final TtlCache<int, VpnStatus> _cache;

  Future<CacheResult<VpnStatus>> status() => _cache.get(0, _load);

  void invalidate() => _cache.clear();

  Future<VpnStatus> _load() async {
    final gluetun = _ctx.upstreams.gluetun;
    if (!gluetun.configured) {
      throw ApiException.serviceNotConfigured(ServiceId.gluetun);
    }
    Future<T?> attempt<T>(Future<T> Function() f) async {
      try {
        return await f();
      } catch (_) {
        return null;
      }
    }

    final results = await Future.wait<Object?>([
      attempt(() => _gluetunJson('/v1/publicip/ip')),
      attempt(() => _gluetunJson('/v1/openvpn/portforwarded')),
      attempt(_preferences),
      attempt(() async => _maindata.peek() ?? await _maindata.read()),
      attempt(_gluetunHealth),
    ]);
    final ip = results[0] as JsonMap?;
    final forwarded = results[1] as JsonMap?;
    final prefs = results[2] as JsonMap?;
    final qbit = results[3] as QbitView?;
    final health = results[4] as VpnGluetunHealth? ?? VpnGluetunHealth.unknown;

    String? text(String key) {
      final v = readString(ip?[key])?.trim();
      return v == null || v.isEmpty ? null : v;
    }

    final publicIp = text('public_ip');
    final port = readInt(forwarded?['port']);
    final forwardedPort = port == null || port <= 0 ? null : port;
    final listenPort = readInt(prefs?['listen_port']);
    final connection =
        readString(qbit?.serverState['connection_status']) ?? 'unknown';
    final inSync = forwardedPort != null && forwardedPort == listenPort;
    final VpnConnectionState state;
    if (ip == null || publicIp == null) {
      state = VpnConnectionState.down;
    } else if (forwardedPort == null || !inSync || connection != 'connected') {
      state = VpnConnectionState.degraded;
    } else {
      state = VpnConnectionState.connected;
    }
    return VpnStatus(
      status: state,
      publicIp: publicIp,
      country: text('country'),
      region: text('region'),
      city: text('city'),
      organization: text('organization'),
      forwardedPort: forwardedPort,
      listenPort: listenPort,
      portInSync: inSync,
      qbitConnection: connection,
      gluetunHealth: health,
      checkedAt: _ctx.clock.now(),
    );
  }

  /// Gluetun answers JSON with a `text/plain` content type.
  Future<JsonMap> _gluetunJson(String path) async {
    final r = (await _ctx.upstreams.gluetun.send('GET', path)).ensureOk();
    return readMap(r.json()) ??
        (throw UpstreamBadResponse(
          service: ServiceId.gluetun,
          method: 'GET',
          path: path,
          reason: 'not a JSON object',
        ));
  }

  Future<VpnGluetunHealth> _gluetunHealth() async {
    final list = await _ctx.upstreams.docker.getJson(
      '/containers/json',
      query: {
        'all': 'true',
        'filters': jsonEncode({
          'name': ['gluetun'],
        }),
      },
    );
    for (final c in list is List ? list : const <Object?>[]) {
      final m = readMap(c);
      if (m == null || !readStringList(m['Names']).contains('/gluetun')) {
        continue;
      }
      return gluetunHealthOf(m);
    }
    return VpnGluetunHealth.unknown;
  }
}

/// The health of a `/containers/json` entry: `Health.Status` (Docker API
/// 1.54), else the `(healthy)` suffix of `Status`. A container that is not
/// running is unhealthy.
VpnGluetunHealth gluetunHealthOf(JsonMap c) {
  if (readString(c['State']) case final s? when s != 'running') {
    return VpnGluetunHealth.unhealthy;
  }
  final status = readString(readMap(c['Health'])?['Status']);
  if (status != null) {
    return VpnGluetunHealth.fromJson(status);
  }
  final text = readString(c['Status']) ?? '';
  if (text.contains('(healthy)')) return VpnGluetunHealth.healthy;
  if (text.contains('(unhealthy)')) return VpnGluetunHealth.unhealthy;
  if (text.contains('health: starting')) return VpnGluetunHealth.starting;
  return VpnGluetunHealth.none;
}
