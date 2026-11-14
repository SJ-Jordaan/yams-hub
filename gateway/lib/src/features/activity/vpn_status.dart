/// `GET /vpn` (API.md §8.6): gluetun's two readable routes, qBittorrent's
/// listen port and connection status, and the gluetun container health.
library;

import 'dart:convert';

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'maindata.dart';

/// The oldest maindata snapshot `/vpn` uses without a fresh read.
const vpnSnapshotMaxAge = Duration(seconds: 10);

/// Builds [VpnStatus] (cache 30 s).
final class VpnStatusService {
  VpnStatusService(
    this._ctx,
    this._maindata,
    this._preferences,
    this._freshPreferences,
  ) : _cache = _ctx.caches.ttl<int, VpnStatus>(
        'activity.vpn',
        const Duration(seconds: 30),
      );

  final FeatureContext _ctx;
  final QbitMaindata _maindata;

  /// Whitelisted qBittorrent preferences (cache 10 min).
  final Future<JsonMap> Function() _preferences;

  /// The same preferences read now (bypassing the cache).
  final Future<JsonMap> Function() _freshPreferences;
  final TtlCache<int, VpnStatus> _cache;

  /// The port route that answered last; tried first so a gluetun that only
  /// allows the legacy route is not asked for a refused one on every read.
  /// Forgotten as soon as it fails.
  String? _portRoute;

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
      _publicIp(),
      _forwarded(),
      attempt(_preferences),
      attempt(_qbitView),
      attempt(_gluetunHealth),
    ]);
    final ipRead = results[0]! as ({JsonMap? ip, bool refused});
    final ip = ipRead.ip;
    final ipReadable = !ipRead.refused;
    final forwarded = results[1]! as GluetunForwardedPort;
    final prefs = results[2] as JsonMap?;
    final qbit = results[3] as QbitView?;
    final health = results[4] as VpnGluetunHealth? ?? VpnGluetunHealth.unknown;

    String? text(String key) {
      final v = readString(ip?[key])?.trim();
      return v == null || v.isEmpty ? null : v;
    }

    final publicIp = text('public_ip');
    final port = forwarded.port;
    final forwardedPort = port == null || port <= 0 ? null : port;
    final readable = !forwarded.refused;
    var listenPort = readInt(prefs?['listen_port']);
    if (forwardedPort != null && listenPort != forwardedPort) {
      // Gluetun's port-forwarding hook updates qBittorrent within seconds
      // of a new port, but the preferences are cached for 10 min: read
      // them again before reporting a mismatch.
      final fresh = await attempt(_freshPreferences);
      if (fresh != null) listenPort = readInt(fresh['listen_port']);
    }
    final connection =
        readString(qbit?.serverState['connection_status']) ?? 'unknown';
    final inSync = forwardedPort != null && forwardedPort == listenPort;
    final VpnConnectionState state;
    if (ipReadable && (ip == null || publicIp == null)) {
      // A network error, a 5xx or an empty address (gluetun reconnecting).
      // A refused route (401/403) is unknown, not down (issue #8).
      state = VpnConnectionState.down;
    } else if (connection != 'connected' ||
        // An unreadable port is unknown, not wrong: it alone does not
        // degrade the VPN (issue #8).
        (readable && (forwardedPort == null || !inSync))) {
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
      portForwardReadable: readable,
      publicIpReadable: ipReadable,
      qbitConnection: connection,
      gluetunHealth: health,
      checkedAt: _ctx.clock.now(),
    );
  }

  /// The qBittorrent snapshot: the poller's own when it is recent, else a
  /// read (which restarts an idle poller and waits for a fresh tick), so an
  /// hours-old snapshot is never reported as the current connection.
  Future<QbitView> _qbitView() async {
    final peeked = _maindata.peek();
    if (peeked != null &&
        !peeked.stale &&
        _ctx.clock.now().difference(peeked.updatedAt) < vpnSnapshotMaxAge) {
      return peeked;
    }
    return _maindata.read();
  }

  /// Gluetun's forwarded port: `GET /v1/portforward` (gluetun ≥ 3.39), else
  /// the legacy `GET /v1/openvpn/portforwarded`. Gluetun's control server
  /// keeps routes private unless its auth config allows them, so either
  /// may answer 401/403; when no route answers and at least one refused
  /// the port is reported as unreadable rather than absent.
  Future<GluetunForwardedPort> _forwarded() async {
    var refused = false;
    final remembered = _portRoute;
    for (final path in [
      ?remembered,
      for (final p in gluetunPortRoutes)
        if (p != remembered) p,
    ]) {
      try {
        final r = await _ctx.upstreams.gluetun.send('GET', path);
        if (r.status == 401 || r.status == 403) {
          refused = true;
        } else if (r.ok) {
          // Gluetun answers JSON with a `text/plain` content type.
          if (readMap(r.json()) case final j?) {
            _portRoute = path;
            return GluetunForwardedPort(readInt(j['port']));
          }
        }
      } catch (_) {
        // Tried the next route.
      }
      if (_portRoute == path) _portRoute = null;
    }
    return GluetunForwardedPort(null, refused: refused);
  }

  /// `GET /v1/publicip/ip`: `refused` on 401/403 (gluetun's auth config
  /// keeps the route private), `ip` null on any other failure.
  Future<({JsonMap? ip, bool refused})> _publicIp() async {
    try {
      final r = await _ctx.upstreams.gluetun.send('GET', '/v1/publicip/ip');
      if (r.status == 401 || r.status == 403) return (ip: null, refused: true);
      if (!r.ok) return (ip: null, refused: false);
      return (ip: readMap(r.json()), refused: false);
    } catch (_) {
      return (ip: null, refused: false);
    }
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

/// Gluetun's forwarded-port routes, current first.
const gluetunPortRoutes = ['/v1/portforward', '/v1/openvpn/portforwarded'];

/// What gluetun told us about its forwarded port.
final class GluetunForwardedPort {
  const GluetunForwardedPort(this.port, {this.refused = false});

  /// `0` or null: no port yet (when not [refused]).
  final int? port;

  /// Gluetun's control server answered 401/403 and no route gave a port.
  final bool refused;
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
