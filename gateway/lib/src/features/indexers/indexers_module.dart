/// Indexers feature: Prowlarr indexers, history, tests and the SSRF-safe
/// manual search + grab (API.md §10).
library;

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart' show Response;
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_hub_gateway/src/core/notify/discord_webhook.dart';
import 'package:yams_models/yams_models.dart';

import 'indexer_alert.dart';
import 'prowlarr_mapping.dart';
import 'prowlarr_repository.dart';
import 'release_grabber.dart';
import 'release_store.dart';

/// App route of the indexers screen (alerts deep-link here).
const _indexersRoute = '/indexers';

/// Health checks that the per-indexer alerts already cover.
const _indexerStatusChecks = {
  'IndexerStatusCheck',
  'IndexerLongTermStatusCheck',
};

class IndexersModule extends FeatureModule {
  IndexersModule(this.ctx)
    : repo = ProwlarrRepository(ctx),
      releases = ReleaseStore(clock: ctx.clock),
      grabber = ReleaseGrabber.fromContext(ctx);

  final FeatureContext ctx;
  final ProwlarrRepository repo;
  final ReleaseStore releases;
  final ReleaseGrabber grabber;

  /// Users with a manual search in flight (one per user).
  final _searching = <String>{};

  /// The Discord "indexers failing" alert (null while off).
  IndexerAlertMonitor? alertMonitor;
  http.Client? _alertClient;

  @override
  String get id => 'indexers';

  @override
  Future<void> start() async {
    final url = ctx.config.discordAlertWebhookUrl;
    if (url == null) {
      ctx.log.info(
        'Discord alerts off (DISCORD_ALERT_WEBHOOK_URL not set or invalid)',
      );
      return;
    }
    if (!ctx.config.isConfigured(ServiceId.prowlarr)) {
      ctx.log.info('Discord indexer alert off: Prowlarr is not configured');
      return;
    }
    final client = _alertClient ??= createDiscordHttpClient();
    alertMonitor ??= IndexerAlertMonitor.create(
      thresholds: ctx.config.alerts,
      store: ctx.stores.open(alertStateStoreName),
      sample: () => sampleProwlarr(repo, ctx.clock, log: ctx.log),
      webhook: DiscordWebhook(url: url, client: client),
      clock: ctx.clock,
      indexersPage: indexersPageUrl(ctx.config.publicUrls),
    );
    alertMonitor!.start();
    final a = ctx.config.alerts;
    ctx.log.info(
      'Discord indexer alert on: ${_percent(a.indexersFailingPercent)}% of '
      'enabled indexers failing for ${a.indexersFailingForMinutes} min',
    );
  }

  @override
  Future<void> stop() async {
    alertMonitor?.stop();
    _alertClient?.close();
    _alertClient = null;
    alertMonitor = null;
  }

  static String _percent(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  void registerRoutes(ApiRouter router) {
    const admin = Role.admin;
    // Static segments before `<id>` (ARCHITECTURE §5.3).
    router
      ..get('/indexers', _list)
      ..patch('/indexers', _bulkUpdate, role: admin, audit: true)
      ..get('/indexers/history', _history)
      ..get('/indexers/categories', _categories)
      ..get('/indexers/search', _search, role: admin)
      ..post('/indexers/grab', _grab, role: admin, audit: true)
      ..post('/indexers/test-all', _testAll, role: admin, audit: true)
      ..get('/indexers/<id|[0-9]+>', _detail)
      ..post('/indexers/<id|[0-9]+>/test', _test, role: admin, audit: true);
  }

  // -------------------------------------------------------------------------
  // Reads
  // -------------------------------------------------------------------------

  Future<Response> _list(ApiRequest req) async =>
      ApiResponse.json(await repo.list());

  Future<Response> _detail(ApiRequest req) async =>
      ApiResponse.json(await repo.detail(req.pathInt('id')));

  Future<Response> _history(ApiRequest req) async {
    final page = req.queryInt('page', defaultValue: 1, min: 1, max: 100000);
    final pageSize = req.queryInt(
      'pageSize',
      defaultValue: 25,
      min: 1,
      max: historyMaxPageSize,
      clamp: true,
    );
    final typeName = req.queryString('type');
    final type = typeName == null
        ? null
        : req.queryEnum('type', IndexerHistoryType.filterable);
    final successful = req.queryString('successful') == null
        ? null
        : req.queryBool('successful');
    final indexerId = req.queryIntOrNull('indexerId', min: 1);
    final result = await repo.history(
      page: page,
      pageSize: pageSize,
      type: type,
      successful: successful,
      indexerId: indexerId,
    );
    return ApiResponse.json(result.toJson((i) => i.toJson()));
  }

  Future<Response> _categories(ApiRequest req) async {
    final items = await repo.categories();
    return ApiResponse.json(ItemList(items).toJson((c) => c.toJson()));
  }

  // -------------------------------------------------------------------------
  // Writes
  // -------------------------------------------------------------------------

  Future<Response> _bulkUpdate(ApiRequest req) async {
    final body = await req.jsonBody();
    final fields = <ApiFieldError>[];
    final rawIds = body['ids'];
    final ids = <int>[];
    if (rawIds is! List || rawIds.isEmpty || rawIds.length > 50) {
      fields.add(
        const ApiFieldError(field: 'ids', message: 'Pass 1 to 50 indexer ids.'),
      );
    } else {
      for (final v in rawIds) {
        final n = v is int ? v : null;
        if (n == null || n <= 0) {
          fields.add(
            const ApiFieldError(
              field: 'ids',
              message: 'Indexer ids must be positive integers.',
            ),
          );
          break;
        }
        if (!ids.contains(n)) ids.add(n);
      }
    }
    final enabledRaw = body['enabled'];
    if (enabledRaw != null && enabledRaw is! bool) {
      fields.add(
        const ApiFieldError(
          field: 'enabled',
          message: 'Must be true or false.',
        ),
      );
    }
    final priorityRaw = body['priority'];
    if (priorityRaw != null &&
        (priorityRaw is! int || priorityRaw < 1 || priorityRaw > 50)) {
      fields.add(
        const ApiFieldError(
          field: 'priority',
          message: 'Priority must be between 1 and 50.',
        ),
      );
    }
    if (enabledRaw == null && priorityRaw == null) {
      fields.add(
        const ApiFieldError(
          field: 'enabled',
          message: 'Pass enabled and/or priority.',
        ),
      );
    }
    if (fields.isNotEmpty) throw ApiException.validation(fields);
    await repo.bulkUpdate(
      ids,
      enabled: enabledRaw as bool?,
      priority: priorityRaw as int?,
    );
    return ApiResponse.json(await repo.list());
  }

  Future<Response> _test(ApiRequest req) async {
    final id = req.pathInt('id');
    // Fetched before the job starts so an unknown id is an immediate 404.
    final resource = await repo.rawIndexer(id);
    final name = readString(resource['name']) ?? '#$id';
    final job = ctx.jobs.start(
      kind: 'indexers.test',
      target: '$id',
      userId: req.user.id,
      run: (h) async {
        h.step('Test $name');
        final result = await repo.test(id, resource);
        repo.invalidateIndexers();
        h.message = result.valid
            ? '$name passed'
            : '$name failed: ${result.failures.join('; ')}';
        for (final f in result.failures) {
          h.log(f);
        }
        return result.toJson();
      },
    );
    return ApiResponse.json({'job': job.toDto().toJson()}, status: 202);
  }

  Future<Response> _testAll(ApiRequest req) async {
    final job = ctx.jobs.start(
      kind: 'indexers.testall',
      target: 'all',
      userId: req.user.id,
      run: (h) async {
        h.step('Test all indexers');
        final results = await repo.testAll();
        repo.invalidateIndexers();
        final names = await repo.names();
        final passed = results.where((r) => r.valid).length;
        for (final r in results.where((r) => !r.valid)) {
          final name = names[r.id] ?? '#${r.id}';
          h.log(
            r.failures.isEmpty
                ? '$name: failed'
                : '$name: ${r.failures.join('; ')}',
          );
        }
        h.message = '$passed of ${results.length} indexers passed';
        return ItemList(results).toJson((r) => r.toJson());
      },
    );
    return ApiResponse.json({'job': job.toDto().toJson()}, status: 202);
  }

  // -------------------------------------------------------------------------
  // Manual search and grab
  // -------------------------------------------------------------------------

  List<int> _ids(ApiRequest req, String name) {
    final out = <int>[];
    for (final v in req.queryList(name)) {
      final n = int.tryParse(v);
      if (n == null || n <= 0) {
        throw ApiException.badRequest('$name must be positive integers');
      }
      if (!out.contains(n)) out.add(n);
    }
    if (out.length > 100) throw ApiException.badRequest('too many $name');
    return out;
  }

  Future<Response> _search(ApiRequest req) async {
    final q = req.queryString('q');
    if (q == null || q.length < 2 || q.length > 200) {
      throw ApiException.badRequest('q must be 2 to 200 characters');
    }
    final type = req.queryEnum(
      'type',
      ReleaseSearchType.selectable,
      defaultValue: ReleaseSearchType.search,
    );
    final indexerIds = _ids(req, 'indexerIds');
    final categories = _ids(req, 'categories');
    final limit = req.queryInt('limit', defaultValue: 100, min: 1, max: 100);

    final userId = req.user.id;
    if (!_searching.add(userId)) {
      throw ApiException.jobRunning(
        'A manual search is already running; wait for it to finish.',
      );
    }
    final List<JsonMap> raw;
    final sw = Stopwatch()..start();
    try {
      raw = await repo.search(
        query: q,
        type: type.name,
        indexerIds: indexerIds,
        categories: categories,
        limit: limit,
      );
    } finally {
      _searching.remove(userId);
    }
    final took = sw.elapsedMilliseconds;
    final names = await repo.names();
    final items = <Release>[];
    for (final r in raw) {
      if (readString(r['title']) == null) continue;
      final token = releases.put(releaseLinks(r));
      items.add(mapRelease(r, token, names));
    }
    ctx.log.info(
      'manual search: ${items.length} results in $took ms '
      '(type ${type.name}, ${indexerIds.isEmpty ? 'all' : indexerIds.length} indexers)',
    );
    return ApiResponse.json(ReleaseList(items: items, tookMs: took));
  }

  Future<Response> _grab(ApiRequest req) async {
    final body = await req.jsonBody();
    final releaseId = body['releaseId'];
    if (releaseId is! String || releaseId.trim().isEmpty) {
      throw ApiException.invalidField('releaseId', 'releaseId is required.');
    }
    final category = _category(body['category']);
    final tags = _tags(body['tags']);
    final links =
        releases.get(releaseId.trim()) ??
        (throw ApiException.notFound('Release expired, search again'));
    await grabber.grab(links, category: category, tags: tags);
    return ApiResponse.json({'ok': true}, status: 201);
  }

  static final _badCategory = RegExp(r'[\\\x00-\x1f]|//|^/|/$');

  String _category(Object? v) {
    if (v == null) return ReleaseGrabRequest.defaultCategory;
    if (v is! String) {
      throw ApiException.invalidField('category', 'Must be a string.');
    }
    final c = v.trim();
    if (c.isEmpty) return ReleaseGrabRequest.defaultCategory;
    if (c.length > 64 || _badCategory.hasMatch(c)) {
      throw ApiException.invalidField('category', 'Invalid category name.');
    }
    return c;
  }

  List<String> _tags(Object? v) {
    if (v == null) return const [];
    if (v is! List || v.length > 10) {
      throw ApiException.invalidField('tags', 'Pass up to 10 tags.');
    }
    final out = <String>[];
    for (final t in v) {
      if (t is! String ||
          t.trim().isEmpty ||
          t.length > 64 ||
          t.contains(',') ||
          t.contains(RegExp(r'[\x00-\x1f]'))) {
        throw ApiException.invalidField('tags', 'Invalid tag.');
      }
      if (!out.contains(t.trim())) out.add(t.trim());
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // Dashboard
  // -------------------------------------------------------------------------

  @override
  Future<DashboardContribution?> dashboard(ApiRequest req) async {
    final hostsAlert = ctx.health.allowedHostsAlert(
      ServiceId.prowlarr,
      feature: id,
      route: _indexersRoute,
    );
    final snap = await guardUpstream(repo.snapshot);
    final stats = await repo.stats24h();
    final now = ctx.clock.now();
    final items = mapIndexers(snap.value, stats: const {}, now: now);
    final failing = [
      for (final i in items)
        if (i.status == IndexerStatus.failing) i,
    ];
    final card = IndexersCard(
      total: items.length,
      enabled: items.where((i) => i.enabled).length,
      failing: [
        for (final i in failing)
          IndexersCardFailing(
            id: i.id,
            name: i.name,
            disabledTill: i.disabledTill,
          ),
      ],
      grabs24h: stats?.totalGrabs,
      queries24h: stats?.totalQueries,
    );
    final alerts = <Alert>[
      ?await hostsAlert,
      for (final i in failing)
        Alert(
          id: 'prowlarr.indexer.${i.id}',
          severity: AlertSeverity.warning,
          source: ServiceId.prowlarr,
          feature: id,
          title:
              'Indexer ${i.name} failing, retry at ${_localTime(i.disabledTill!, now)}',
          message: i.lastFailure == null
              ? null
              : 'Last failure ${_localTime(i.lastFailure!, now)}',
          route: _indexersRoute,
          since: i.failingSince,
        ),
      for (final h in snap.value.health)
        if ((h.type == HealthMessageType.warning ||
                h.type == HealthMessageType.error) &&
            !(failing.isNotEmpty && _indexerStatusChecks.contains(h.source)))
          _healthAlert(h),
    ];
    final error = snap.stale ? _apiError(snap.error, req.requestId) : null;
    return DashboardContribution(
      data: card.toJson(),
      alerts: alerts,
      stale: snap.stale,
      fetchedAt: snap.fetchedAt,
      error: error,
    );
  }

  Alert _healthAlert(HealthMessage h) {
    final allowedHosts = h.source == 'AllowedHostsCheck';
    return Alert(
      id: 'prowlarr.health.${h.source}',
      severity: allowedHosts
          ? AlertSeverity.info
          : (h.type == HealthMessageType.error
                ? AlertSeverity.error
                : AlertSeverity.warning),
      source: ServiceId.prowlarr,
      feature: id,
      title: 'Prowlarr: ${h.message}',
      message: allowedHosts
          ? allowedHostsHint(
              ServiceId.prowlarr,
              ctx.upstreams.prowlarr.baseUrl.host,
            )
          : null,
      route: _indexersRoute,
      dismissible: allowedHosts,
    );
  }

  /// `HH:mm` in the hub's time zone, with the date when not today.
  String _localTime(DateTime instant, DateTime now) {
    final local = instant.toUtc().add(ctx.config.tzOffset);
    final today = now.toUtc().add(ctx.config.tzOffset);
    String two(int n) => n.toString().padLeft(2, '0');
    final time = '${two(local.hour)}:${two(local.minute)}';
    final sameDay =
        local.year == today.year &&
        local.month == today.month &&
        local.day == today.day;
    return sameDay
        ? time
        : '${local.year}-${two(local.month)}-${two(local.day)} $time';
  }

  static ApiError? _apiError(Object? error, String requestId) {
    final api = switch (error) {
      ApiException() => error,
      UpstreamException() => error.toApiException(resourceNotFound: false),
      null => null,
      _ => ApiException.internal(),
    };
    return api?.toApiError(requestId);
  }
}
