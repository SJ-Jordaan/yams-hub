/// System feature: host metrics and Uptime Kuma (API.md §13).
///
/// - `GET /system/host`: the newest sample of the always-on [HostSampler]
///   (no upstream call).
/// - `GET /system/history?metric=&range=`: the sampler's ring buffers.
/// - `GET /uptime`: Uptime Kuma's public status page, cached 30 s.
/// - Dashboard card `system` ([SystemCard]) with the RAID, temperature,
///   volume and Uptime Kuma alerts.
library;

import 'dart:async';

import 'package:shelf/shelf.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'host/host_sampler.dart';
import 'system_alerts.dart';
import 'uptime/uptime_kuma.dart';

/// Samples in the dashboard sparkline (5 min at 5 s).
const systemSparklineSamples = 60;

/// Combined rx+tx on `tailscale0` above which the tailnet counts as in use
/// (keep-alives stay well below it).
const tailscaleActiveBps = 2048;

class SystemModule extends FeatureModule {
  SystemModule(this.ctx, {HostSampler? sampler})
    : sampler =
          sampler ??
          HostSampler(
            procDir: ctx.config.procDir,
            sysDir: ctx.config.hostSys,
            netDevPath: ctx.config.hostNetDev,
            volumePath: ctx.config.dataDir,
            clock: ctx.clock,
            log: ctx.log,
          ),
      uptime = UptimeKumaService(ctx);

  final FeatureContext ctx;

  /// The host sampler (started by [start]).
  final HostSampler sampler;
  final UptimeKumaService uptime;

  /// Budget of the Uptime Kuma part of the dashboard card.
  static const _uptimeCardBudget = Duration(seconds: 3);

  Timer? _hostnameTimer;

  @override
  String get id => 'system';

  @override
  void registerRoutes(ApiRouter router) {
    router
      ..get('/system/host', _host)
      ..get('/system/history', _history)
      ..get('/uptime', _uptime);
  }

  @override
  Future<void> start() async {
    await sampler.start();
    unawaited(_resolveHostname());
  }

  @override
  Future<void> stop() async {
    _hostnameTimer?.cancel();
    _hostnameTimer = null;
    await sampler.stop();
  }

  Future<Response> _host(ApiRequest req) async =>
      ApiResponse.json((await sampler.current()).toJson());

  Future<Response> _history(ApiRequest req) async {
    final metric = req.queryEnum('metric', HostMetricKind.queryable);
    final rangeWire = req.queryChoice('range', [
      for (final r in HostHistoryRange.values) r.wire,
    ], defaultValue: HostHistoryRange.hour.wire);
    final range = HostHistoryRange.tryParse(rangeWire)!;
    // Ensures at least the current point when the sampler is not running.
    await sampler.current();
    final series = MetricSeries(
      metric: metric,
      unit: metric.unit,
      points: sampler.history.series(metric, range, ctx.clock.now()),
    );
    return ApiResponse.json(series.toJson());
  }

  Future<Response> _uptime(ApiRequest req) async =>
      ApiResponse.json((await uptime.get()).value.toJson());

  @override
  Future<DashboardContribution?> dashboard(ApiRequest req) async {
    // Kuma runs alongside the host sample; [_uptimeForCard] never throws, so
    // its future cannot surface as an unhandled error while the host is read.
    final kumaFuture = _uptimeForCard();
    final host = await sampler.current();
    final kumaResult = await kumaFuture;
    final kuma = kumaResult?.value;

    final storage = host.storage.isEmpty ? null : host.storage.first;
    final raid = host.raid.isEmpty
        ? null
        : host.raid.firstWhere(
            (r) => !r.healthy,
            orElse: () => host.raid.first,
          );
    final primary = HostSampler.primaryInterface(host);
    final tailscale = host.interfaceNamed(tailscaleInterface);
    final counts = kuma?.counts;

    final card = SystemCard(
      cpuPercent: host.cpu?.percent,
      packageTempC: host.cpu?.packageTempC,
      memUsedBytes: host.memory?.usedBytes ?? 0,
      memTotalBytes: host.memory?.totalBytes ?? 0,
      uptimeSeconds: host.uptimeSeconds ?? 0,
      volume: storage == null
          ? null
          : SystemCardVolume(
              totalBytes: storage.totalBytes,
              usedBytes: storage.usedBytes,
              usedPercent: storage.usedPercent,
            ),
      raid: raid == null
          ? null
          : SystemCardRaid(
              level: raid.level,
              state: raid.state,
              redundant: raid.redundant,
              healthy: raid.healthy,
            ),
      net: primary == null
          ? null
          : SystemCardNet(
              rxBps: primary.rxBps,
              txBps: primary.txBps,
              tailscaleActive:
                  tailscale != null &&
                  tailscale.rxBps + tailscale.txBps >= tailscaleActiveBps,
            ),
      monitors: counts == null
          ? null
          : SystemCardMonitors(
              up: counts.up,
              down: counts.down,
              pending: counts.pending,
              total: counts.total,
            ),
      cpuSparkline: sampler.history.recent(
        HostMetricKind.cpu,
        systemSparklineSamples,
      ),
    );

    // The monitor counts may come from a cached status page after a failed
    // refresh: the card says so.
    final kumaStale = kumaResult != null && kumaResult.stale;
    final kumaError = kumaResult?.error;
    return DashboardContribution(
      data: card.toJson(),
      fetchedAt: host.sampledAt,
      stale: kumaStale,
      error: kumaStale && kumaError != null
          ? _apiErrorOf(kumaError, req.requestId)
          : null,
      alerts: [
        ...hostAlerts(host, ctx.config.alerts),
        if (kuma != null) ...uptimeAlerts(kuma),
      ],
    );
  }

  /// The status page for the card, or null when Uptime Kuma is not
  /// configured, failing or slow: the host part of the card never waits for
  /// it longer than [_uptimeCardBudget].
  Future<CacheResult<UptimeResponse>?> _uptimeForCard() async {
    if (!uptime.configured) return null;
    try {
      return await uptime.get().timeout(_uptimeCardBudget);
    } on TimeoutException {
      return null;
    } on ApiException catch (e) {
      ctx.log.fine('uptime for the dashboard card failed: ${e.code}');
      return null;
    } on UpstreamException catch (e) {
      ctx.log.fine('uptime for the dashboard card failed: ${e.runtimeType}');
      return null;
    } catch (e, st) {
      // An unexpected status-page shape must not break the host card.
      ctx.log.warning('uptime for the dashboard card failed', e, st);
      return null;
    }
  }

  static ApiError _apiErrorOf(Object error, String requestId) =>
      switch (error) {
        ApiException() => error.toApiError(requestId),
        UpstreamException() =>
          error.toApiException(resourceNotFound: false).toApiError(requestId),
        _ => ApiException.internal().toApiError(requestId),
      };

  /// The host's name from Docker `GET /info` (`Name`, e.g. "Zenith"); the
  /// container's own hostname is its id. Retried every 10 min until known.
  Future<void> _resolveHostname() async {
    if (!ctx.config.isConfigured(ServiceId.docker)) return;
    try {
      final info = readMap(await ctx.upstreams.docker.getJson('/info'));
      final name = readString(info?['Name'])?.trim();
      if (name != null && name.isNotEmpty) {
        sampler.hostname = name;
        return;
      }
    } on UpstreamException catch (e) {
      ctx.log.fine('docker /info for the hostname failed: ${e.runtimeType}');
    } on FormatException {
      // Unparsable body: retry later.
    } catch (e, st) {
      // Runs unawaited (start() and a timer): never let it escape.
      ctx.log.warning('docker /info for the hostname failed', e, st);
    }
    if (!sampler.running) return;
    _hostnameTimer = Timer(
      const Duration(minutes: 10),
      () => unawaited(_resolveHostname()),
    );
  }
}
