/// Subtitles feature: Bazarr subtitles (API.md §12).
///
/// Reads are [member], writes [admin]. Bazarr write parameters travel in the
/// query string with no body (integrations/downloads.md §4); every trigger is
/// queued by Bazarr and answers 204 at once, which the hub reports as
/// `202 {"queued": true}`.
library;

import 'dart:async';

import 'package:shelf/shelf.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'bazarr_mapper.dart';

/// App route of the Subtitles screen (alert deep links).
const _subtitlesRoute = '/subtitles';

/// Task ids behind "Search all wanted" (`POST /api/system/tasks?taskid=`).
const _searchAllTasks = {
  SubtitleListType.episodes: 'wanted_search_missing_subtitles_series',
  SubtitleListType.movies: 'wanted_search_missing_subtitles_movies',
};

final _languageCode = RegExp(r'^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})?$');

const _summaryKey = 'summary';
const _tasksKey = 'tasks';

class SubtitlesModule extends FeatureModule {
  SubtitlesModule(this.ctx)
    : _mapper = BazarrMapper(images: ctx.images, redact: ctx.redact),
      _summary = ctx.caches.ttl<String, SubtitlesSummary>(
        'subtitles.summary',
        const Duration(seconds: 60),
        maxEntries: 1,
      ),
      _tasks = ctx.caches.ttl<String, List<SubtitleTask>>(
        'subtitles.tasks',
        const Duration(seconds: 60),
        maxEntries: 1,
      ),
      _wanted = ctx.caches.ttl<String, PagedList<WantedSubtitle>>(
        'subtitles.wanted',
        const Duration(seconds: 30),
        maxEntries: 64,
      ),
      _history = ctx.caches.ttl<String, PagedList<SubtitleHistoryItem>>(
        'subtitles.history',
        const Duration(seconds: 60),
        maxEntries: 64,
      );

  final FeatureContext ctx;
  final BazarrMapper _mapper;
  final TtlCache<String, SubtitlesSummary> _summary;
  final TtlCache<String, List<SubtitleTask>> _tasks;
  final TtlCache<String, PagedList<WantedSubtitle>> _wanted;
  final TtlCache<String, PagedList<SubtitleHistoryItem>> _history;

  UpstreamClient get _bazarr => ctx.upstreams.bazarr;

  @override
  String get id => 'subtitles';

  @override
  void registerRoutes(ApiRouter router) {
    const admin = Role.admin;
    router
      ..get('/subtitles/summary', _getSummary)
      ..get('/subtitles/wanted', _getWanted)
      ..get('/subtitles/history', _getHistory)
      ..get('/subtitles/jobs', _getJobs)
      ..post('/subtitles/search', _search, role: admin, audit: true)
      ..post('/subtitles/search-item', _searchItem, role: admin, audit: true)
      ..post('/subtitles/search-all', _searchAll, role: admin, audit: true)
      ..post(
        '/subtitles/providers/reset',
        _resetProviders,
        role: admin,
        audit: true,
      )
      ..post(
        '/subtitles/tasks/<taskId|[A-Za-z0-9_-]+>/run',
        _runTask,
        role: admin,
        audit: true,
      );
  }

  // -------------------------------------------------------------------------
  // Dashboard
  // -------------------------------------------------------------------------

  @override
  Future<DashboardContribution?> dashboard(ApiRequest req) async {
    final r = await _summary.get(_summaryKey, _loadSummary);
    final s = r.value;
    final card = SubtitlesCard(
      missingEpisodes: s.missingEpisodes,
      missingMovies: s.missingMovies,
      throttledProviders: s.throttledProviders,
      signalrDown: s.signalr.anyDown,
    );
    return DashboardContribution(
      data: card.toJson(),
      alerts: subtitlesAlerts(s),
      stale: r.stale,
      fetchedAt: r.fetchedAt,
      error: r.stale ? _apiErrorOf(r.error, req) : null,
    );
  }

  /// `bazarr.signalr` (either link down) and one `bazarr.health.<n>` per
  /// health issue (API.md §12.6).
  static List<Alert> subtitlesAlerts(SubtitlesSummary s) {
    final down = [
      if (s.signalr.sonarr != SubtitleSignalrState.live) 'Sonarr',
      if (s.signalr.radarr != SubtitleSignalrState.live) 'Radarr',
    ];
    return [
      if (down.isNotEmpty)
        Alert(
          id: 'bazarr.signalr',
          severity: AlertSeverity.warning,
          source: ServiceId.bazarr,
          feature: 'subtitles',
          title: 'Bazarr lost its live link to ${down.join(' and ')}',
          message:
              'New imports are missed until the next hourly sync with '
              '${down.join(' and ')}.',
          route: _subtitlesRoute,
        ),
      for (final (i, h) in s.health.indexed)
        Alert(
          id: 'bazarr.health.$i',
          severity: AlertSeverity.warning,
          source: ServiceId.bazarr,
          feature: 'subtitles',
          title: h.issue.isEmpty ? 'Bazarr health issue' : h.issue,
          message: h.object.isEmpty ? null : 'Bazarr · ${h.object}',
          route: _subtitlesRoute,
        ),
    ];
  }

  ApiError? _apiErrorOf(Object? error, ApiRequest req) => switch (error) {
    null => null,
    ApiException() => error.toApiError(req.requestId),
    UpstreamException() =>
      error.toApiException(resourceNotFound: false).toApiError(req.requestId),
    _ => ApiException.internal().toApiError(req.requestId),
  };

  // -------------------------------------------------------------------------
  // Reads
  // -------------------------------------------------------------------------

  Future<Response> _getSummary(ApiRequest req) async {
    final s = await _upstream(() => _summary.value(_summaryKey, _loadSummary));
    return ApiResponse.json(s.toJson());
  }

  Future<SubtitlesSummary> _loadSummary() async {
    final results = await Future.wait<Object?>([
      _bazarr.getJson('/api/badges'),
      _bazarr.getJson('/api/providers'),
      _bazarr.getJson('/api/system/health'),
      _taskList(),
      _version(),
    ]);
    final badges =
        readMap(results[0]) ?? (throw _bad('GET', '/api/badges', 'not a map'));
    final providers = [
      for (final p in _dataList(results[1], '/api/providers'))
        _mapper.provider(p),
    ];
    final health = [
      for (final h in _dataList(results[2], '/api/system/health'))
        _mapper.healthIssue(h),
    ];
    return SubtitlesSummary(
      missingEpisodes: readInt(badges['episodes']) ?? 0,
      missingMovies: readInt(badges['movies']) ?? 0,
      // The badge counts throttled providers loosely (API.md §12.5).
      throttledProviders: providers.where((p) => !p.ok).length,
      providers: providers,
      signalr: SubtitleSignalr(
        sonarr: BazarrMapper.signalr(badges['sonarr_signalr']),
        radarr: BazarrMapper.signalr(badges['radarr_signalr']),
      ),
      health: health,
      version: results[4] as String?,
      tasks: results[3]! as List<SubtitleTask>,
    );
  }

  /// The scheduled tasks (cached 60 s; also the allow-list for "Run now").
  Future<List<SubtitleTask>> _taskList() => _tasks.value(_tasksKey, () async {
    final body = await _bazarr.getJson('/api/system/tasks');
    return [
      for (final t in _dataList(body, '/api/system/tasks'))
        ?BazarrMapper.task(t),
    ];
  });

  /// The Bazarr version; a failing status call does not fail the summary.
  Future<String?> _version() async {
    try {
      final body = await _bazarr.getJson('/api/system/status');
      return readString(readMap(readMap(body)?['data'])?['bazarr_version']);
    } on UpstreamException {
      return null;
    }
  }

  Future<Response> _getWanted(ApiRequest req) async {
    final type = _listType(req);
    final (page, pageSize) = _paging(req);
    final result = await _upstream(
      () => _wanted.value('${type.name}|$page|$pageSize', () async {
        final path = '/api/${type.name}/wanted';
        final (rows, total) = await _page(path, page, pageSize);
        return PagedList.of(
          items: [
            for (final r in rows)
              type == SubtitleListType.episodes
                  ? _mapper.wantedEpisode(r)
                  : _mapper.wantedMovie(r),
          ],
          page: page,
          pageSize: pageSize,
          total: total,
        );
      }),
    );
    return ApiResponse.json(result.toJson((w) => w.toJson()));
  }

  Future<Response> _getHistory(ApiRequest req) async {
    // Unlike wanted, `type` is optional here (API.md §12.2): episodes.
    final type = _listType(req, defaultValue: SubtitleListType.episodes);
    final (page, pageSize) = _paging(req);
    final result = await _upstream(
      () => _history.value('${type.name}|$page|$pageSize', () async {
        final path = '/api/${type.name}/history';
        final (rows, total) = await _page(path, page, pageSize);
        return PagedList.of(
          items: [
            for (final r in rows)
              type == SubtitleListType.episodes
                  ? _mapper.historyEpisode(r)
                  : _mapper.historyMovie(r),
          ],
          page: page,
          pageSize: pageSize,
          total: total,
        );
      }),
    );
    return ApiResponse.json(result.toJson((h) => h.toJson()));
  }

  Future<Response> _getJobs(ApiRequest req) async {
    final status = req.queryChoice('status', const [
      'running',
      'pending',
      'failed',
      'completed',
    ], defaultValue: 'running');
    final jobs = await _upstream(() async {
      final body = await _bazarr.getJson(
        '/api/system/jobs',
        query: {'status': status},
      );
      return [
        for (final j in _dataList(body, '/api/system/jobs')) ?_mapper.job(j),
      ];
    });
    return ApiResponse.items(jobs, (j) => j.toJson());
  }

  /// One page of a Bazarr `{data, total}` list. `length` is always sent:
  /// without it Bazarr returns the whole table.
  Future<(List<JsonMap>, int)> _page(String path, int page, int size) async {
    final body = await _bazarr.getJson(
      path,
      query: {'start': (page - 1) * size, 'length': size},
    );
    final rows = _dataList(body, path);
    final total = readInt(readMap(body)?['total']) ?? rows.length;
    return (rows, total);
  }

  // -------------------------------------------------------------------------
  // Writes
  // -------------------------------------------------------------------------

  Future<Response> _search(ApiRequest req) async {
    final body = await req.jsonBody();
    final r = SubtitleSearchRequest.fromJson(body);
    final fields = <ApiFieldError>[];
    void need(String field, int? v) {
      if (v == null || v < 1) {
        fields.add(ApiFieldError(field: field, message: '$field is required'));
      }
    }

    final query = <String, Object?>{};
    final String path;
    switch (r.type) {
      case SubtitleMediaType.episode:
        need('seriesId', r.seriesId);
        need('episodeId', r.episodeId);
        path = '/api/episodes/subtitles';
        query['seriesid'] = r.seriesId;
        query['episodeid'] = r.episodeId;
      case SubtitleMediaType.movie:
        need('movieId', r.movieId);
        path = '/api/movies/subtitles';
        query['radarrid'] = r.movieId;
      case SubtitleMediaType.unknown:
        throw ApiException.badRequest('type must be one of episode, movie');
    }
    if (!_languageCode.hasMatch(r.language)) {
      fields.add(
        const ApiFieldError(
          field: 'language',
          message: 'language must be a subtitle language code such as "en"',
        ),
      );
    }
    for (final key in const ['forced', 'hi']) {
      if (body[key] != null && readBool(body[key]) == null) {
        fields.add(ApiFieldError(field: key, message: '$key must be a bool'));
      }
    }
    if (fields.isNotEmpty) throw ApiException.validation(fields);
    query
      ..['language'] = r.language
      // Bazarr reads these as strings and capitalises them server-side.
      ..['forced'] = r.forced ? 'true' : 'false'
      ..['hi'] = r.hi ? 'true' : 'false';
    await _write('PATCH', path, query, resourceNotFound: true);
    _invalidateLists();
    return _queued();
  }

  Future<Response> _searchItem(ApiRequest req) async {
    final body = await req.jsonBody();
    final type = readString(body['type']);
    final id = readInt(body['id']);
    final (path, key) = switch (type) {
      'series' => ('/api/series', 'seriesid'),
      'movie' => ('/api/movies', 'radarrid'),
      _ => throw ApiException.badRequest('type must be one of series, movie'),
    };
    if (id == null || id < 1) {
      throw ApiException.invalidField('id', 'id must be a positive integer');
    }
    await _write('PATCH', path, {
      key: id,
      'action': 'search-missing',
    }, resourceNotFound: true);
    _invalidateLists();
    return _queued();
  }

  Future<Response> _searchAll(ApiRequest req) async {
    final body = await req.jsonBody();
    final type = SubtitleListType.fromJson(body['type']);
    final taskId =
        _searchAllTasks[type] ??
        (throw ApiException.badRequest('type must be one of episodes, movies'));
    await req.requireConfirm(_searchAllImpact(type));
    await _write('POST', '/api/system/tasks', {'taskid': taskId});
    _tasks.invalidate(_tasksKey);
    _invalidateLists();
    return _queued();
  }

  String _searchAllImpact(SubtitleListType type) {
    final s = _summary.peek(_summaryKey);
    final noun = type == SubtitleListType.episodes ? 'episodes' : 'movies';
    final count = s == null
        ? null
        : (type == SubtitleListType.episodes
              ? s.missingEpisodes
              : s.missingMovies);
    return count == null
        ? 'Bazarr searches its providers for every $noun with missing '
              'subtitles.'
        : 'Bazarr searches its providers for $count $noun with missing '
              'subtitles.';
  }

  Future<Response> _resetProviders(ApiRequest req) async {
    await _write('POST', '/api/providers', {'action': 'reset'});
    _summary.invalidate(_summaryKey);
    return ApiResponse.noContent();
  }

  Future<Response> _runTask(ApiRequest req) async {
    final taskId = req.pathParam('taskId');
    final tasks = await _upstream(_taskList);
    if (!tasks.any((t) => t.id == taskId)) {
      throw ApiException.notFound('Bazarr has no task "$taskId".');
    }
    await _write('POST', '/api/system/tasks', {'taskid': taskId});
    _tasks.invalidate(_tasksKey);
    _summary.invalidate(_summaryKey);
    return _queued();
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  Response _queued() => ApiResponse.json({'queued': true}, status: 202);

  /// A Bazarr write: parameters in the query string, no body.
  Future<void> _write(
    String method,
    String path,
    Map<String, Object?> query, {
    bool resourceNotFound = false,
  }) => _upstream(() async {
    (await _bazarr.send(method, path, query: query)).ensureOk();
  }, resourceNotFound: resourceNotFound);

  /// Runs [f], mapping upstream failures. Bazarr list and system paths never
  /// address a hub resource, so their 404 is a 502 unless [resourceNotFound].
  Future<T> _upstream<T>(
    Future<T> Function() f, {
    bool resourceNotFound = false,
  }) async {
    try {
      return await f();
    } on UpstreamException catch (e) {
      throw e.toApiException(resourceNotFound: resourceNotFound);
    }
  }

  void _invalidateLists() {
    _wanted.clear();
    _history.clear();
    _summary.invalidate(_summaryKey);
  }

  static SubtitleListType _listType(
    ApiRequest req, {
    SubtitleListType? defaultValue,
  }) => req.queryEnum('type', const [
    SubtitleListType.episodes,
    SubtitleListType.movies,
  ], defaultValue: defaultValue);

  static (int, int) _paging(ApiRequest req) => (
    req.queryInt('page', defaultValue: 1, min: 1, max: 100000),
    req.queryInt('pageSize', defaultValue: 25, min: 1, max: 100, clamp: true),
  );

  List<JsonMap> _dataList(Object? body, String path) {
    final data = readMap(body)?['data'];
    if (data is! List) throw _bad('GET', path, 'no data list');
    return [for (final e in data) ?readMap(e)];
  }

  UpstreamBadResponse _bad(String method, String path, String reason) =>
      UpstreamBadResponse(
        service: ServiceId.bazarr,
        method: method,
        path: path,
        reason: reason,
      );
}
