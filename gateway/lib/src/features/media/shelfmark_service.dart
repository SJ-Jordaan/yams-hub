/// Shelfmark status (API.md §14.7; integrations/system.md §12).
///
/// Only `GET /api/health` and `GET /api/stats` are called. Never
/// `/api/status` (it writes delivery states and emits socket events),
/// `/api/restart`, `/api/debug`, `/api/localdownload`, `/api/releases`,
/// `/api/metadata/search`, or any write. Shelfmark runs with
/// `auth_mode: none`, so no credentials are sent.
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

/// The two Shelfmark paths the hub may call.
const shelfmarkAllowedPaths = {'/api/health', '/api/stats'};

/// Reads Shelfmark.
final class ShelfmarkService {
  ShelfmarkService(this._ctx)
    : _status = _ctx.caches.ttl<int, ShelfmarkStatus>(
        'media.shelfmark.status',
        const Duration(seconds: 30),
      );

  final FeatureContext _ctx;
  final TtlCache<int, ShelfmarkStatus> _status;

  UpstreamClient get _sm => _ctx.upstreams.shelfmark;

  /// `GET /media/shelfmark` (cache 30 s).
  Future<ShelfmarkStatus> status() => _status.value(0, _load);

  Future<ShelfmarkStatus> _load() async {
    final r = await Future.wait<Object?>([
      _health(),
      _sm.getJson('/api/stats'),
    ], eagerError: true);
    final health = r[0]! as ({JsonMap? body, int? status});
    return mapShelfmarkStatus(
      health: health.body,
      healthStatus: health.status,
      stats: readMap(r[1]),
    );
  }

  /// The health answer and its HTTP status (503 when the coordinator is
  /// stopped); `status: null` when Shelfmark could not be reached.
  Future<({JsonMap? body, int? status})> _health() async {
    try {
      final res = await _sm.send(
        'GET',
        '/api/health',
        timeout: const Duration(seconds: 5),
      );
      JsonMap? body;
      try {
        body = readMap(res.json());
      } on UpstreamException {
        body = null;
      }
      return (body: body, status: res.status);
    } on UpstreamException catch (e) {
      if (e is UpstreamNotConfigured) rethrow;
      _ctx.log.fine('Shelfmark health unavailable: $e');
      return (body: null, status: null);
    }
  }
}

/// Assembles [ShelfmarkStatus] from `/api/health` (body and HTTP status;
/// null status = unreachable) and `/api/stats`.
ShelfmarkStatus mapShelfmarkStatus({
  required JsonMap? health,
  required int? healthStatus,
  required JsonMap? stats,
}) {
  final coordinator = switch (readString(health?['coordinator'])
      ?.toLowerCase()) {
    'running' => ShelfmarkCoordinator.running,
    'stopped' => ShelfmarkCoordinator.stopped,
    _ => ShelfmarkCoordinator.unknown,
  };
  final ShelfmarkServiceState state;
  if (healthStatus == null) {
    // Stats answered, health did not: reachable but not healthy.
    state = stats == null
        ? ShelfmarkServiceState.down
        : ShelfmarkServiceState.degraded;
  } else if (healthStatus >= 200 &&
      healthStatus < 300 &&
      readString(health?['status'])?.toLowerCase() == 'ok' &&
      health?['degraded'] == null &&
      coordinator != ShelfmarkCoordinator.stopped) {
    state = ShelfmarkServiceState.ok;
  } else {
    state = ShelfmarkServiceState.degraded;
  }
  final queue = readMap(stats?['queue']) ?? const {};
  final requests = readMap(stats?['requests']) ?? const {};
  final added = readMap(stats?['added']) ?? const {};
  final errors = readMap(stats?['errors']) ?? const {};
  int n(JsonMap m, String k) => readInt(m[k]) ?? 0;
  return ShelfmarkStatus(
    status: state,
    coordinator: coordinator,
    queue: ShelfmarkQueue(
      active: n(queue, 'active'),
      queued: n(queue, 'queued'),
      awaitingPickup: n(queue, 'awaiting_pickup'),
    ),
    requests: ShelfmarkRequests(
      pending: n(requests, 'pending'),
      delivered: n(requests, 'delivered'),
      failed: n(requests, 'failed'),
      cancelled: n(requests, 'cancelled'),
      rejected: n(requests, 'rejected'),
    ),
    added: ShelfmarkAdded(
      ebook7d: n(added, 'ebook_7d'),
      ebook30d: n(added, 'ebook_30d'),
      audiobook7d: n(added, 'audiobook_7d'),
      audiobook30d: n(added, 'audiobook_30d'),
      total7d: n(added, 'total_7d'),
      total30d: n(added, 'total_30d'),
    ),
    failed7d: n(errors, 'failed_7d'),
    generatedAt: readInstant(stats?['generated_at']),
    web: const ExternalLink(ExternalApp.shelfmark, '/'),
  );
}
