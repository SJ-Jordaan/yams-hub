/// Activity feature: qBittorrent, VPN, *arr queues and history (API.md §8).
library;

import 'dart:async';

import 'package:yams_hub_gateway/src/core/dashboard/alert_policy.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'activity_services.dart';
import 'queue_routes.dart';
import 'torrent_routes.dart';
import 'unified_queue.dart';

class ActivityModule extends FeatureModule {
  ActivityModule(this.ctx)
    : _services = ActivityServices(ctx),
      _card = ctx.caches.ttl<bool, DashboardContribution>(
        'activity.card',
        const Duration(seconds: 5),
        maxStale: const Duration(minutes: 2),
      );

  final FeatureContext ctx;
  final ActivityServices _services;

  /// Keyed by "is admin" (admins see *arr links and import actions).
  final TtlCache<bool, DashboardContribution> _card;

  @override
  String get id => 'activity';

  @override
  void registerRoutes(ApiRouter router) {
    QueueRoutes(_services).register(router);
    TorrentRoutes(_services).register(router);
  }

  @override
  Future<DashboardContribution?> dashboard(ApiRequest req) async {
    // Every card read touches the poller lease, even from the cache.
    unawaited(
      _services.maindata.read().then<void>((_) {}, onError: (Object _) {}),
    );
    final r = await _card.get(req.isAdmin, () => _buildCard(req));
    final c = r.value;
    return DashboardContribution(
      data: c.data,
      alerts: c.alerts,
      supersedes: c.supersedes,
      fetchedAt: r.fetchedAt,
      stale: r.stale || c.stale,
      error: r.stale
          ? apiExceptionFor(r.error!).toApiError(req.requestId)
          : c.error,
    );
  }

  Future<DashboardContribution> _buildCard(ApiRequest req) async {
    final vpnFuture = _services.vpn.status().then<VpnStatus?>(
      (r) => r.value,
      onError: (Object _) => null,
    );
    final q = await _services.computeQueue(req);
    if (q.allFailed) throw apiExceptionFor(q.qbitError!);
    final vpn = await vpnFuture;
    final summary = queueSummaryOf(q.rows, q.qbit?.serverState);
    final server = q.qbit?.serverState;
    final transfer = server == null
        ? const ActivityCardTransfer()
        : ActivityCardTransfer(
            dlBps: readInt(server['dl_info_speed']) ?? 0,
            upBps: readInt(server['up_info_speed']) ?? 0,
            altSpeedEnabled: readBool(server['use_alt_speed_limits']) ?? false,
            connectionStatus: TransferConnectionStatus.fromJson(
              server['connection_status'],
            ),
          );
    final top =
        q.rows.where((r) => r.item.needsAttention || r.downloading).toList()
          ..sort((a, b) {
            if (a.item.needsAttention != b.item.needsAttention) {
              return a.item.needsAttention ? -1 : 1;
            }
            return (a.item.etaSeconds ?? 1 << 40).compareTo(
              b.item.etaSeconds ?? 1 << 40,
            );
          });
    final card = ActivityCard(
      transfer: transfer,
      counts: ActivityCardCounts(
        downloading: summary.downloading,
        seeding: summary.seeding,
        stalled: summary.stalled,
        attention: summary.attention,
      ),
      top: [for (final r in top.take(3)) r.item],
      vpn: vpn,
    );
    final failed = [
      if (!q.qbitStatus.isOk) q.qbitStatus.error,
      for (final s in q.arr.values)
        if (s.status == SectionState.error) s.error,
    ].whereType<ApiError>();
    return DashboardContribution(
      data: card.toJson(),
      alerts: _alerts(q, vpn),
      supersedes: importOnlyQueueErrors(q),
      stale: q.stale,
      error: failed.firstOrNull,
    );
  }

  List<Alert> _alerts(QueueComputation q, VpnStatus? vpn) {
    final alerts = <Alert>[];
    if (vpn != null && vpn.status == VpnConnectionState.down) {
      alerts.add(
        Alert(
          id: 'vpn.down',
          severity: AlertSeverity.error,
          source: ServiceId.gluetun,
          feature: id,
          title: 'VPN is down',
          message: 'Gluetun reports no public IP; qBittorrent has no network.',
          route: '/activity',
        ),
      );
    }
    if (vpn != null &&
        (!vpn.portForwardReadable || !vpn.publicIpReadable) &&
        vpn.status != VpnConnectionState.down &&
        vpn.status != VpnConnectionState.unknown) {
      // Gluetun ≥ 3.39 keeps control-server routes private unless its auth
      // config allows them (issue #8): say so instead of a false mismatch
      // or a false "VPN down".
      final refused = [
        if (!vpn.publicIpReadable) 'GET /v1/publicip/ip',
        if (!vpn.portForwardReadable) 'GET /v1/portforward',
      ];
      alerts.add(
        Alert(
          id: 'vpn.unreadable',
          severity: AlertSeverity.info,
          source: ServiceId.gluetun,
          feature: id,
          title: "Gluetun didn't allow the hub to read the VPN status",
          message:
              "Gluetun's control server refused ${refused.join(' and ')}. "
              "Allow ${refused.length == 1 ? 'it' : 'them'} for the hub in "
              "Gluetun's auth config.toml (see the YAMS Hub README, "
              '"Troubleshooting").',
          route: '/activity',
          dismissible: true,
          dismissKey: fingerprintedDismissKey('vpn.unreadable', refused),
        ),
      );
    }
    if (vpn != null &&
        vpn.portForwardReadable &&
        !vpn.portInSync &&
        vpn.status != VpnConnectionState.down &&
        vpn.status != VpnConnectionState.unknown) {
      alerts.add(
        Alert(
          id: 'vpn.port',
          severity: AlertSeverity.warning,
          source: ServiceId.gluetun,
          feature: id,
          title: 'Forwarded port not in sync',
          message: vpn.forwardedPort == null
              ? 'Gluetun has no forwarded port yet.'
              : 'Gluetun forwards ${vpn.forwardedPort}, qBittorrent listens on '
                    '${vpn.listenPort ?? 'an unknown port'}.',
          route: '/activity',
        ),
      );
    }
    if (ctx.upstreams.qbitSession.credentialsRejected) {
      alerts.add(
        Alert(
          id: 'qbittorrent.auth',
          severity: AlertSeverity.error,
          source: ServiceId.qbittorrent,
          feature: id,
          title: 'qBittorrent credentials rejected',
          message:
              'The gateway backs off for 10 minutes to avoid an IP ban; '
              'check QBIT_USERNAME/QBIT_PASSWORD.',
          route: '/activity',
        ),
      );
    }
    // One per download; the dashboard collapses several into one alert.
    for (final r in q.rows) {
      final item = r.item;
      if (!(item.attention?.isImport ?? false)) continue;
      final source =
          item.arr.firstOrNull?.service.serviceId ?? ServiceId.sonarr;
      alerts.add(
        Alert(
          id: 'queue.import.${item.key}',
          severity: AlertSeverity.warning,
          source: source,
          feature: id,
          title: 'Manual import needed: ${item.title}',
          message: item.arr.expand((a) => a.messages).firstOrNull,
          route: Uri(
            path: '/activity',
            queryParameters: {'tab': 'queue', 'import': item.key},
          ).toString(),
        ),
      );
    }
    return alerts;
  }

  /// `<svc>.queue.errors` (the library card's "downloads with errors") for
  /// each *arr whose only problem downloads need a manual import: those
  /// already have a `queue.import.*` alert. Kept when the *arr's queue did
  /// not load or another of its downloads failed.
  static Set<String> importOnlyQueueErrors(QueueComputation q) => {
    for (final svc in [ArrService.sonarr, ArrService.radarr])
      if (q.arr[svc]?.isOk ?? false)
        if (_problems(q, svc) case final p when p.isNotEmpty)
          if (p.every((a) => a.isImport)) '${svc.name}.queue.errors',
  };

  static List<QueueAttention> _problems(QueueComputation q, ArrService svc) => [
    for (final r in q.rows)
      if (r.item.attention case final a?)
        if (a != QueueAttention.warning && a != QueueAttention.trackerError)
          if (r.item.arr.any((e) => e.service == svc)) a,
  ];

  @override
  Future<void> stop() async => _services.stop();
}
