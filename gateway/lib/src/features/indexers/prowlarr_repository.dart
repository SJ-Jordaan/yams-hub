/// Cached Prowlarr reads and writes for the indexers feature (API.md §10,
/// integrations/downloads.md §3).
library;

import 'dart:async';
import 'dart:convert';

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'prowlarr_mapping.dart';

/// Prowlarr list GETs (downloads.md §5).
const prowlarrListTimeout = Duration(seconds: 15);

/// Tests and searches go out through FlareSolverr (120 s upstream timeout).
const prowlarrLongTimeout = Duration(seconds: 150);

/// Maximum history page size (Prowlarr does not cap it; 17 MB was seen).
const historyMaxPageSize = 100;

/// Rethrows an upstream failure as the API error of a gateway path that did
/// not address the failing upstream resource.
Future<T> guardUpstream<T>(Future<T> Function() f) async {
  try {
    return await f();
  } on UpstreamException catch (e) {
    throw e.toApiException(resourceNotFound: false);
  }
}

/// Reads and writes Prowlarr with the caches of API.md §10.
final class ProwlarrRepository {
  ProwlarrRepository(this.ctx)
    : _snapshot = ctx.caches.ttl(
        'indexers.snapshot',
        const Duration(seconds: 60),
        maxStale: const Duration(minutes: 30),
      ),
      _detail = ctx.caches.ttl(
        'indexers.detail',
        const Duration(seconds: 60),
        maxEntries: 200,
      ),
      _stats30d = ctx.caches.ttl(
        'indexers.stats30d',
        const Duration(minutes: 10),
        maxStale: const Duration(hours: 2),
      ),
      _stats24h = ctx.caches.ttl(
        'indexers.stats24h',
        const Duration(minutes: 10),
        maxStale: const Duration(hours: 1),
      ),
      _history = ctx.caches.ttl(
        'indexers.history',
        const Duration(seconds: 15),
        maxEntries: 200,
      ),
      _categories = ctx.caches.ttl(
        'indexers.categories',
        const Duration(hours: 24),
      );

  final FeatureContext ctx;
  final TtlCache<String, ProwlarrSnapshot> _snapshot;
  final TtlCache<int, JsonMap> _detail;
  final TtlCache<String, ProwlarrStatsWindow> _stats30d;
  final TtlCache<String, ProwlarrStatsWindow> _stats24h;
  final TtlCache<String, PagedList<IndexerHistoryItem>> _history;
  final TtlCache<String, List<IndexerCategory>> _categories;

  /// Failed best-effort loads are not retried before this instant (the stats
  /// call is the slowest Prowlarr call).
  final _retryAfter = <String, DateTime>{};

  UpstreamClient get _prowlarr => ctx.upstreams.prowlarr;

  DateTime get _now => ctx.clock.now();

  // -------------------------------------------------------------------------
  // Snapshot (indexers + status + tags + health)
  // -------------------------------------------------------------------------

  /// The joined indexer list (60 s), stale-on-error.
  Future<CacheResult<ProwlarrSnapshot>> snapshot() =>
      _snapshot.get('all', _loadSnapshot);

  Future<ProwlarrSnapshot> _loadSnapshot() async {
    final indexers = _prowlarr.getJson(
      '/api/v1/indexer',
      timeout: prowlarrListTimeout,
    );
    final statuses = _prowlarr.getJson(
      '/api/v1/indexerstatus',
      timeout: prowlarrListTimeout,
    );
    final tags = _prowlarr.getJson('/api/v1/tag', timeout: prowlarrListTimeout);
    final health = _bestEffort(
      'health',
      () async => parseHealth(
        await _prowlarr.getJson('/api/v1/health', timeout: prowlarrListTimeout),
      ),
    );
    final results = await Future.wait([indexers, statuses, tags]);
    return ProwlarrSnapshot(
      indexers: parseIndexers(results[0]),
      statuses: parseStatuses(results[1]),
      tags: parseTags(results[2]),
      health: await health ?? const [],
    );
  }

  /// Indexer names by id, or an empty map when Prowlarr is unreachable.
  Future<Map<int, String>> names() async {
    try {
      return (await snapshot()).value.names;
    } on Object catch (e) {
      ctx.log.fine('indexer names unavailable (${e.runtimeType})');
      return const {};
    }
  }

  // -------------------------------------------------------------------------
  // Stats
  // -------------------------------------------------------------------------

  /// The last 30 days of `indexerstats` (10 min), or null on failure.
  Future<ProwlarrStatsWindow?> stats30d() => _bestEffort(
    'stats30d',
    () async => (await _stats30d.get(
      'w',
      () => _loadStats(const Duration(days: 30)),
    )).value,
  );

  /// The last 24 hours of `indexerstats` (10 min), or null on failure.
  Future<ProwlarrStatsWindow?> stats24h() => _bestEffort(
    'stats24h',
    () async => (await _stats24h.get(
      'w',
      () => _loadStats(const Duration(hours: 24)),
    )).value,
  );

  Future<ProwlarrStatsWindow> _loadStats(Duration window) async {
    final to = _now;
    final from = to.subtract(window);
    final body = await _prowlarr.getJson(
      '/api/v1/indexerstats',
      query: {'startDate': instantToJson(from), 'endDate': instantToJson(to)},
      timeout: prowlarrListTimeout,
    );
    return ProwlarrStatsWindow(from: from, to: to, byIndexer: parseStats(body));
  }

  Future<T?> _bestEffort<T>(String name, Future<T> Function() load) async {
    final until = _retryAfter[name];
    if (until != null && _now.isBefore(until)) return null;
    try {
      final v = await load();
      _retryAfter.remove(name);
      return v;
    } on Object catch (e) {
      ctx.log.fine('prowlarr $name unavailable (${e.runtimeType})');
      _retryAfter[name] = _now.add(const Duration(seconds: 60));
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // Indexers
  // -------------------------------------------------------------------------

  /// `GET /indexers`.
  Future<IndexerList> list() => guardUpstream(() async {
    final snap = (await snapshot()).value;
    final stats = await stats30d();
    final now = _now;
    return IndexerList(
      items: mapIndexers(snap, stats: stats?.byIndexer ?? const {}, now: now),
      health: snap.health,
      statsFrom: stats?.from ?? now.subtract(const Duration(days: 30)),
      statsTo: stats?.to ?? now,
    );
  });

  /// The full Prowlarr resource of indexer [id] (with `fields`), uncached;
  /// a Prowlarr 404 is `404 not_found`.
  Future<JsonMap> rawIndexer(int id, {bool cached = false}) async {
    Future<JsonMap> load() async {
      try {
        final body = await _prowlarr.getJson(
          '/api/v1/indexer/$id',
          timeout: prowlarrListTimeout,
        );
        return readMap(body) ?? (throw const FormatException('indexer'));
      } on UpstreamException catch (e) {
        if (e.isNotFound) throw ApiException.notFound('Indexer not found.');
        throw e.toApiException(resourceNotFound: false);
      }
    }

    return cached ? (await _detail.get(id, load)).value : load();
  }

  /// `GET /indexers/{id}`.
  Future<Indexer> detail(int id) async {
    final raw = await rawIndexer(id, cached: true);
    return guardUpstream(() async {
      final snap = (await snapshot()).value;
      final stats = await stats30d();
      return mapIndexer(
        raw,
        statuses: snap.statuses,
        tags: snap.tags,
        stats: stats?.byIndexer ?? const {},
        now: _now,
        detail: true,
      );
    });
  }

  /// `PUT /api/v1/indexer/bulk` (Prowlarr answers 202; any 2xx is accepted).
  Future<void> bulkUpdate(List<int> ids, {bool? enabled, int? priority}) =>
      guardUpstream(() async {
        final r = await _prowlarr.send(
          'PUT',
          '/api/v1/indexer/bulk',
          jsonBody: {'ids': ids, 'enable': ?enabled, 'priority': ?priority},
          timeout: const Duration(seconds: 30),
        );
        r.ensureOk();
        invalidateIndexers();
      });

  /// Drops every cached view of indexer state (after writes and tests).
  void invalidateIndexers() {
    _snapshot.clear();
    _detail.clear();
  }

  // -------------------------------------------------------------------------
  // Tests
  // -------------------------------------------------------------------------

  /// `POST /api/v1/indexer/test?forceTest=true` with the full resource.
  Future<IndexerTestResult> test(int id, JsonMap resource) =>
      guardUpstream(() async {
        final r = await _prowlarr.send(
          'POST',
          '/api/v1/indexer/test',
          jsonBody: resource,
          query: {'forceTest': true},
          timeout: prowlarrLongTimeout,
        );
        if (r.ok) return IndexerTestResult(id: id, valid: true);
        if (r.status == 400) {
          return IndexerTestResult(
            id: id,
            valid: false,
            failures: _failures(r.bodyBytes, r.contentType, r.status),
          );
        }
        r.ensureOk();
        throw StateError('unreachable');
      });

  /// `POST /api/v1/indexer/testall` (parsed on 200 and 400).
  Future<List<IndexerTestResult>> testAll() => guardUpstream(() async {
    final r = await _prowlarr.send(
      'POST',
      '/api/v1/indexer/testall',
      timeout: prowlarrLongTimeout,
    );
    if (!r.ok && r.status != 400) r.ensureOk();
    final body = r.json();
    if (body is! List) {
      throw UpstreamBadResponse(
        service: ServiceId.prowlarr,
        method: 'POST',
        path: '/api/v1/indexer/testall',
        status: r.status,
        reason: 'testall body is not a list',
      );
    }
    return [
      for (final e in body)
        if (readMap(e) case final m? when readInt(m['id']) != null)
          IndexerTestResult(
            id: readInt(m['id'])!,
            valid: readBool(m['isValid']) ?? false,
            failures: _messages(m['validationFailures']),
          ),
    ];
  });

  List<String> _failures(List<int> body, String? contentType, int status) {
    Object? json;
    try {
      json = jsonDecode(utf8.decode(body, allowMalformed: true));
    } on FormatException {
      json = null;
    }
    final messages = _messages(json);
    if (messages.isNotEmpty) return messages;
    final extracted = extractUpstreamError(
      status,
      body,
      contentType: contentType,
    );
    return [extracted.message ?? 'Test failed (HTTP $status).'];
  }

  List<String> _messages(Object? validation) {
    final out = <String>[];
    if (validation is! List) return out;
    for (final v in validation) {
      final m = readMap(v);
      final text = readString(m?['errorMessage'])?.trim();
      if (text == null || text.isEmpty) continue;
      final clean = ctx.redact(text);
      out.add(clean.length > 300 ? '${clean.substring(0, 297)}...' : clean);
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // History and categories
  // -------------------------------------------------------------------------

  /// `GET /indexers/history` (15 s per query).
  Future<PagedList<IndexerHistoryItem>> history({
    required int page,
    required int pageSize,
    IndexerHistoryType? type,
    bool? successful,
    int? indexerId,
  }) {
    final key = '$page|$pageSize|${type?.name}|$successful|$indexerId';
    return guardUpstream(() async {
      final result = await _history.get(key, () async {
        final names = this.names();
        final body = readMap(
          await _prowlarr.getJson(
            '/api/v1/history',
            query: {
              'page': page,
              'pageSize': pageSize,
              'sortKey': 'date',
              'sortDirection': 'descending',
              'eventType': type?.upstreamEventType,
              'successful': successful,
              'indexerIds': indexerId,
            },
            timeout: prowlarrListTimeout,
          ),
        );
        if (body == null) throw const FormatException('history');
        final byId = await names;
        return PagedList.of(
          items: [
            for (final r in readList(body['records'], (m) => m))
              if (readInt(r['id']) != null && readInstant(r['date']) != null)
                mapHistoryRecord(r, byId),
          ],
          page: page,
          pageSize: pageSize,
          total: readInt(body['totalRecords']) ?? 0,
        );
      });
      return result.value;
    });
  }

  /// `GET /indexers/categories` (24 h).
  Future<List<IndexerCategory>> categories() => guardUpstream(
    () async => (await _categories.get(
      'all',
      () async => parseCategories(
        await _prowlarr.getJson(
          '/api/v1/indexer/categories',
          timeout: prowlarrListTimeout,
        ),
      ),
    )).value,
  );

  // -------------------------------------------------------------------------
  // Search
  // -------------------------------------------------------------------------

  /// `GET /api/v1/search` (array params as repeated keys).
  Future<List<JsonMap>> search({
    required String query,
    required String type,
    required List<int> indexerIds,
    required List<int> categories,
    required int limit,
  }) => guardUpstream(() async {
    final body = await _prowlarr.getJson(
      '/api/v1/search',
      query: {
        'query': query,
        'type': type,
        if (indexerIds.isNotEmpty) 'indexerIds': indexerIds,
        if (categories.isNotEmpty) 'categories': categories,
        'limit': limit,
      },
      timeout: prowlarrLongTimeout,
    );
    if (body is! List) throw const FormatException('search results');
    return [for (final e in body) ?readMap(e)];
  });
}
