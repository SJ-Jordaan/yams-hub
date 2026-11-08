/// Uptime Kuma's public status page (API.md §13.3, integrations/system.md
/// §5): `GET /api/status-page/{slug}` + `GET /api/status-page/heartbeat/{slug}`,
/// no auth, cached 30 s.
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

/// Beats returned per monitor.
const uptimeBeatsPerMonitor = 30;

/// Maps the two status-page bodies to the [UptimeResponse] DTO.
///
/// - Groups are ordered by `weight`; monitors keep the page order and are
///   matched to their heartbeats by id (never by name).
/// - Heartbeat `time` is UTC without a zone marker; beats are sorted oldest
///   first and the last [uptimeBeatsPerMonitor] are kept.
/// - A monitor without beats is `unknown`.
/// - The incident is Kuma 1.x/2.x `incident` (object or null) or a pinned entry
///   of an `incidents` list.
UptimeResponse mapUptimeStatusPage(JsonMap page, JsonMap heartbeat) {
  final beatLists = readMap(heartbeat['heartbeatList']) ?? const {};
  final uptimes = readMap(heartbeat['uptimeList']) ?? const {};

  final rawGroups = readList(page['publicGroupList'], (j) => j);
  final indexed = [for (var i = 0; i < rawGroups.length; i++) (i, rawGroups[i])]
    ..sort((a, b) {
      final wa = readDouble(a.$2['weight']) ?? double.infinity;
      final wb = readDouble(b.$2['weight']) ?? double.infinity;
      final c = wa.compareTo(wb);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });

  final counted = <int, UptimeStatus>{};
  final groups = <UptimeGroup>[];
  for (final (_, g) in indexed) {
    final monitors = <UptimeMonitor>[];
    for (final m in readList(g['monitorList'], (j) => j)) {
      final id = readInt(m['id']);
      if (id == null) continue;
      final monitor = _monitor(id, m, beatLists['$id'], uptimes['${id}_24']);
      monitors.add(monitor);
      counted[id] = monitor.status;
    }
    groups.add(
      UptimeGroup(name: readString(g['name']) ?? '', monitors: monitors),
    );
  }

  int count(UptimeStatus s) => counted.values.where((v) => v == s).length;
  final config = readMap(page['config']) ?? const {};
  return UptimeResponse(
    title: readString(config['title']) ?? readString(config['slug']) ?? '',
    incident: _incident(page),
    groups: groups,
    counts: UptimeCounts(
      up: count(UptimeStatus.up),
      down: count(UptimeStatus.down),
      pending: count(UptimeStatus.pending),
      maintenance: count(UptimeStatus.maintenance),
      unknown: count(UptimeStatus.unknown),
    ),
  );
}

UptimeMonitor _monitor(int id, JsonMap m, Object? rawBeats, Object? uptime) {
  final beats = <(DateTime, UptimeStatus, int?)>[];
  for (final b in readList(rawBeats, (j) => j)) {
    final t = readInstant(b['time']);
    if (t == null) continue;
    beats.add((t, UptimeStatus.fromKuma(b['status']), readInt(b['ping'])));
  }
  beats.sort((a, b) => a.$1.compareTo(b.$1));
  final last = beats.isEmpty ? null : beats.last;
  final kept = beats.length > uptimeBeatsPerMonitor
      ? beats.sublist(beats.length - uptimeBeatsPerMonitor)
      : beats;
  final ratio = readDouble(uptime);
  return UptimeMonitor(
    id: id,
    name: readString(m['name']) ?? 'Monitor $id',
    type: readString(m['type']) ?? 'unknown',
    status: last?.$2 ?? UptimeStatus.unknown,
    lastBeatAt: last?.$1,
    uptime24h: ratio?.clamp(0, 1).toDouble(),
    pingMs: last?.$3,
    beats: [for (final b in kept) UptimeBeat(t: b.$1, status: b.$2)],
  );
}

UptimeIncident? _incident(JsonMap page) {
  JsonMap? raw = readMap(page['incident']);
  if (raw == null && page['incidents'] is List) {
    final list = readList(page['incidents'], (j) => j);
    for (final i in list) {
      // Kuma sends `pin` as a bool or 0/1; entries without it count as shown.
      final pin = i['pin'];
      if (pin == null || pin == true || readInt(pin) == 1) {
        raw = i;
        break;
      }
    }
  }
  if (raw == null) return null;
  final title = readString(raw['title'])?.trim() ?? '';
  final content = readString(raw['content'])?.trim() ?? '';
  if (title.isEmpty && content.isEmpty) return null;
  return UptimeIncident(
    title: title.isEmpty ? 'Incident' : title,
    content: content,
    style: readString(raw['style']) ?? 'info',
    createdAt: readInstant(raw['createdDate']) ?? readInstant(raw['createdAt']),
  );
}

/// Loads and caches the status page of `UPTIME_KUMA_SLUG`.
final class UptimeKumaService {
  UptimeKumaService(this._ctx)
    : _cache = _ctx.caches.ttl<String, UptimeResponse>(
        'system.uptime',
        const Duration(seconds: 30),
        maxStale: const Duration(minutes: 10),
        maxEntries: 1,
      );

  final FeatureContext _ctx;
  final TtlCache<String, UptimeResponse> _cache;

  bool get configured => _ctx.config.isConfigured(ServiceId.uptimeKuma);

  /// The cached status page (stale on upstream failure for up to 10 min).
  /// Throws [ApiException] (`service_not_configured`, upstream errors).
  Future<CacheResult<UptimeResponse>> get() async {
    if (!configured) {
      throw ApiException.serviceNotConfigured(ServiceId.uptimeKuma);
    }
    try {
      return await _cache.get('page', _load);
    } on UpstreamException catch (e) {
      throw _mapError(e);
    }
  }

  Future<UptimeResponse> _load() async {
    final client = _ctx.upstreams.uptimeKuma;
    final slug = _ctx.config.uptimeKumaSlug;
    final bodies = await Future.wait<Object?>([
      client.getJson('/api/status-page/$slug'),
      client.getJson('/api/status-page/heartbeat/$slug'),
    ]);
    final page = readMap(bodies[0]);
    final heartbeat = readMap(bodies[1]);
    if (page == null || heartbeat == null) {
      throw UpstreamBadResponse(
        service: ServiceId.uptimeKuma,
        method: 'GET',
        path: '/api/status-page/$slug',
        status: 200,
        reason: 'not a JSON object',
      );
    }
    return mapUptimeStatusPage(page, heartbeat);
  }

  ApiException _mapError(UpstreamException e) {
    if (e.isNotFound) {
      return ApiException(
        502,
        ApiErrorCode.upstreamError,
        'Uptime Kuma has no status page "${_ctx.config.uptimeKumaSlug}" '
        '(check UPTIME_KUMA_SLUG).',
        service: ServiceId.uptimeKuma,
        details: const {'upstreamStatus': 404},
      );
    }
    return e.toApiException(resourceNotFound: false);
  }
}
