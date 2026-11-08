/// Calendar feature: the merged Sonarr/Radarr agenda (API.md §9).
library;

import 'dart:async';

import 'package:shelf/shelf.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'calendar_mapper.dart';

/// Longest window one `GET /calendar` may span (`end - start`).
const calendarMaxWindowDays = 62;

/// `GET /calendar` and the `calendar` dashboard card.
///
/// Upstream calls per source and window: Sonarr
/// `GET /api/v3/calendar?start&end&unmonitored&includeSeries=true` (bounds are
/// local midnight → UTC with `YAMS_HUB_TZ_OFFSET`), Radarr
/// `GET /api/v3/calendar?start&end&unmonitored` (bounds on the UTC date, since
/// Radarr release dates are midnight-UTC dates). Each window is cached 5 min
/// per source. The `downloading` flags come from the Sonarr queue
/// (`episodeId`) and the Radarr queue (`movieId`), each cached 5 s and
/// re-applied on every request; queue failures are ignored.
class CalendarModule extends FeatureModule {
  CalendarModule(this.ctx)
    : _mapper = CalendarMapper(
        images: ctx.images,
        tzOffset: ctx.config.tzOffset,
      ),
      _sonarrWindows = ctx.caches.ttl<CalendarWindow, List<CalendarItem>>(
        'calendar.sonarr',
        const Duration(minutes: 5),
        maxStale: const Duration(hours: 1),
        maxEntries: 64,
      ),
      _radarrWindows = ctx.caches.ttl<CalendarWindow, List<CalendarItem>>(
        'calendar.radarr',
        const Duration(minutes: 5),
        maxStale: const Duration(hours: 1),
        maxEntries: 64,
      ),
      _queues = ctx.caches.ttl<ArrService, Set<int>>(
        'calendar.queue',
        const Duration(seconds: 5),
        maxStale: const Duration(seconds: 30),
        maxEntries: 2,
      );

  final FeatureContext ctx;
  final CalendarMapper _mapper;
  final TtlCache<CalendarWindow, List<CalendarItem>> _sonarrWindows;
  final TtlCache<CalendarWindow, List<CalendarItem>> _radarrWindows;
  final TtlCache<ArrService, Set<int>> _queues;

  static const _queueTimeout = Duration(seconds: 5);
  static final _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  @override
  String get id => 'calendar';

  @override
  void registerRoutes(ApiRouter router) {
    router.get('/calendar', _calendar);
  }

  // -------------------------------------------------------------------------
  // GET /calendar
  // -------------------------------------------------------------------------

  Future<Response> _calendar(ApiRequest req) async {
    final start = _queryDate(req, 'start');
    final end = _queryDate(req, 'end');
    if (end.isBefore(start)) {
      throw ApiException.badRequest('end must not be before start.');
    }
    if (end.difference(start).inDays > calendarMaxWindowDays) {
      throw ApiException.badRequest(
        'The window may span at most $calendarMaxWindowDays days.',
      );
    }
    final unmonitored = req.queryBool('unmonitored');
    final kinds = _queryTypes(req);

    final result = await _load(
      (start: start, end: end, unmonitored: unmonitored),
      episodes: kinds.contains(CalendarItemKind.episode),
      movies: kinds.contains(CalendarItemKind.movie),
    );
    result.throwIfNothingLoaded();
    return ApiResponse.json(result.toResponse(req.requestId).toJson());
  }

  DateTime _queryDate(ApiRequest req, String name) {
    final raw = req.queryString(name);
    if (raw == null) throw ApiException.badRequest('$name is required.');
    final date = _datePattern.hasMatch(raw) ? CalendarDates.parse(raw) : null;
    if (date == null) {
      throw ApiException.badRequest('$name must be a date (YYYY-MM-DD).');
    }
    return date;
  }

  Set<CalendarItemKind> _queryTypes(ApiRequest req) {
    final raw = req.queryList('types');
    if (raw.isEmpty) return {CalendarItemKind.episode, CalendarItemKind.movie};
    return {
      for (final t in raw)
        switch (t) {
          'episode' => CalendarItemKind.episode,
          'movie' => CalendarItemKind.movie,
          _ => throw ApiException.badRequest(
            'types must be a comma list of episode, movie.',
          ),
        },
    };
  }

  // -------------------------------------------------------------------------
  // Dashboard card (API.md §9.2)
  // -------------------------------------------------------------------------

  @override
  Future<DashboardContribution?> dashboard(ApiRequest req) async {
    final today = _mapper.localDateOf(ctx.clock.now());
    final end = today.add(const Duration(days: CalendarCard.days - 1));
    final result = await _load(
      (start: today, end: end, unmonitored: false),
      episodes: true,
      movies: true,
    );
    result.throwIfNothingLoaded();
    final items = result.items();
    final card = CalendarCard(
      items: items.take(CalendarCard.maxItems).toList(),
      countNext7Days: items.length,
    );
    final staleError = result.staleError;
    // A source that failed outright (Radarr down while Sonarr answered) is
    // reported on the card too, so a short list is not mistaken for a quiet
    // week; `stale` stays tied to cached data only.
    final error = result.partialFailure ?? staleError;
    return DashboardContribution(
      data: card.toJson(),
      stale: staleError != null,
      fetchedAt: result.fetchedAt,
      error: error?.toApiError(req.requestId),
    );
  }

  // -------------------------------------------------------------------------
  // Loading
  // -------------------------------------------------------------------------

  Future<_CalendarResult> _load(
    CalendarWindow window, {
    required bool episodes,
    required bool movies,
  }) async {
    Future<_SourceResult?> skip() => Future.value();
    final (sonarr, radarr) = await (
      episodes ? _source(ArrService.sonarr, window) : skip(),
      movies ? _source(ArrService.radarr, window) : skip(),
    ).wait;
    return _CalendarResult(window, sonarr: sonarr, radarr: radarr);
  }

  /// One source's items for [window] with the queue flags applied; failures
  /// become a [_SourceResult] with an error instead of throwing.
  Future<_SourceResult> _source(ArrService svc, CalendarWindow window) async {
    final cache = svc == ArrService.sonarr ? _sonarrWindows : _radarrWindows;
    final CacheResult<List<CalendarItem>> cached;
    try {
      cached = await cache.get(window, () => _fetchWindow(svc, window));
    } catch (e, st) {
      return _SourceResult.failed(_toApiException(e, svc, st));
    }
    var items = cached.value;
    if (items.isNotEmpty) {
      final downloading = await _queueIds(svc);
      items = [
        for (final i in items)
          i.withDownloading(
            downloading.contains(
              svc == ArrService.sonarr ? i.episodeId : i.movieId,
            ),
          ),
      ];
    }
    return _SourceResult(
      items,
      fetchedAt: cached.fetchedAt,
      staleError: cached.stale
          ? _toApiException(cached.error ?? StateError('stale'), svc)
          : null,
    );
  }

  Future<List<CalendarItem>> _fetchWindow(
    ArrService svc,
    CalendarWindow window,
  ) async {
    const path = '/api/v3/calendar';
    final client = ctx.upstreams.arr(svc);
    if (svc == ArrService.sonarr) {
      final json = await client.getJson(
        path,
        query: {
          'start': instantToJson(_mapper.localStartUtc(window.start)),
          'end': instantToJson(_mapper.localEndUtc(window.end)),
          'unmonitored': window.unmonitored,
          'includeSeries': true,
        },
      );
      _expectList(json, svc, path);
      return _mapper.episodes(json, start: window.start, end: window.end);
    }
    final json = await client.getJson(
      path,
      query: {
        'start': instantToJson(window.start),
        'end': instantToJson(
          window.end.add(const Duration(hours: 23, minutes: 59, seconds: 59)),
        ),
        'unmonitored': window.unmonitored,
      },
    );
    _expectList(json, svc, path);
    return _mapper.movies(json, start: window.start, end: window.end);
  }

  /// Queue ids (`episodeId` for Sonarr, `movieId` for Radarr), cached 5 s.
  /// Any failure yields an empty set: `downloading` is then false.
  Future<Set<int>> _queueIds(ArrService svc) async {
    try {
      return await _queues.value(svc, () async {
        final json = await ctx.upstreams
            .arr(svc)
            .getJson(
              '/api/v3/queue',
              query: {'page': 1, 'pageSize': 200},
              timeout: _queueTimeout,
            );
        return CalendarMapper.queueIds(
          json,
          svc == ArrService.sonarr ? 'episodeId' : 'movieId',
        );
      });
    } catch (e) {
      ctx.log.fine('${svc.name} queue unavailable for calendar flags: $e');
      return const {};
    }
  }

  static void _expectList(Object? json, ArrService svc, String path) {
    if (json is List) return;
    throw UpstreamBadResponse(
      service: svc.serviceId,
      method: 'GET',
      path: path,
      reason: 'calendar is not a JSON array',
    );
  }

  ApiException _toApiException(Object e, ArrService svc, [StackTrace? st]) {
    switch (e) {
      case ApiException():
        return e;
      case UpstreamException():
        ctx.log.warning('${svc.name} calendar failed: $e');
        // The gateway path addresses no Sonarr/Radarr resource: a 404 means
        // the upstream is misconfigured, not that something is missing.
        return e.toApiException(resourceNotFound: false);
      default:
        ctx.log.severe('${svc.name} calendar mapping failed', e, st);
        return ApiException.internal();
    }
  }
}

/// One source of a calendar load.
final class _SourceResult {
  const _SourceResult(this.items, {required this.fetchedAt, this.staleError})
    : error = null;

  const _SourceResult.failed(ApiException this.error)
    : items = const [],
      fetchedAt = null,
      staleError = null;

  final List<CalendarItem> items;
  final DateTime? fetchedAt;

  /// Why the source has no items.
  final ApiException? error;

  /// Why a refresh failed while cached [items] were served.
  final ApiException? staleError;

  bool get ok => error == null;
  bool get disabled => error?.code == ApiErrorCode.serviceNotConfigured;

  SectionStatus status(String requestId) {
    final e = error;
    if (e == null) {
      return SectionStatus(
        status: SectionState.ok,
        error: staleError?.toApiError(requestId),
      );
    }
    final apiError = e.toApiError(requestId);
    return disabled
        ? SectionStatus.disabled(apiError)
        : SectionStatus.failure(apiError);
  }
}

/// The merged result of both sources.
final class _CalendarResult {
  _CalendarResult(this.window, {this.sonarr, this.radarr});

  final CalendarWindow window;

  /// Null when the source was not queried (`types`).
  final _SourceResult? sonarr;
  final _SourceResult? radarr;

  List<_SourceResult> get _queried => [?sonarr, ?radarr];

  /// Every item of the sources that loaded, in agenda order.
  List<CalendarItem> items() =>
      [for (final s in _queried) ...s.items]..sort(CalendarItem.compare);

  /// The oldest fetch time of the sources that loaded.
  DateTime? get fetchedAt {
    DateTime? oldest;
    for (final s in _queried) {
      final t = s.fetchedAt;
      if (t != null && (oldest == null || t.isBefore(oldest))) oldest = t;
    }
    return oldest;
  }

  /// The first refresh failure behind cached data.
  ApiException? get staleError {
    for (final s in _queried) {
      if (s.staleError case final e?) return e;
    }
    return null;
  }

  /// The error of a queried source that failed (not one that is merely not
  /// configured) while another loaded.
  ApiException? get partialFailure {
    for (final s in _queried) {
      if (!s.ok && !s.disabled) return s.error;
    }
    return null;
  }

  /// When no queried source loaded, throws its error so the client shows an
  /// error view rather than an empty agenda: a real failure wins over
  /// `service_not_configured` (which the dashboard reports as disabled).
  void throwIfNothingLoaded() {
    final queried = _queried;
    if (queried.isEmpty || queried.any((s) => s.ok)) return;
    final failure = queried.firstWhere(
      (s) => !s.disabled,
      orElse: () => queried.first,
    );
    throw failure.error!;
  }

  CalendarResponse toResponse(String requestId) => CalendarResponse(
    start: window.start,
    end: window.end,
    items: items(),
    sources: CalendarSources(
      sonarr: sonarr?.status(requestId),
      radarr: radarr?.status(requestId),
    ),
  );
}
