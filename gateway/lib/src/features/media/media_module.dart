/// Media feature: Jellyfin, Jellystat, Audiobookshelf, Kavita and Shelfmark
/// (API.md §14).
///
/// Reads are [member], writes [admin] and audited. Every Jellyfin link and
/// user-scoped call goes through `ctx.jellyfin`; tile status/version comes
/// from `ctx.health`.
library;

import 'package:shelf/shelf.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'audiobooks_service.dart';
import 'jellyfin_service.dart';
import 'jellystat_service.dart';
import 'kavita_service.dart';
import 'media_apps_service.dart';
import 'media_util.dart';
import 'shelfmark_service.dart';

class MediaModule extends FeatureModule {
  MediaModule(this.ctx)
    : jellyfin = JellyfinService(ctx),
      jellystat = JellystatService(ctx),
      audiobooks = AudiobooksService(ctx),
      kavita = KavitaService(ctx),
      shelfmark = ShelfmarkService(ctx) {
    apps = MediaAppsService(
      ctx,
      jellyfin: jellyfin,
      audiobooks: audiobooks,
      kavita: kavita,
      shelfmark: shelfmark,
    );
  }

  final FeatureContext ctx;
  final JellyfinService jellyfin;
  final JellystatService jellystat;
  final AudiobooksService audiobooks;
  final KavitaService kavita;
  final ShelfmarkService shelfmark;
  late final MediaAppsService apps;

  @override
  String get id => 'media';

  @override
  void registerRoutes(ApiRouter router) {
    const admin = Role.admin;
    router
      ..get('/media/now-playing', _nowPlaying)
      ..post(
        '/media/sessions/<id|[0-9a-fA-F]{32}>/playback',
        _playback,
        role: admin,
        audit: true,
      )
      ..post(
        '/media/sessions/<id|[0-9a-fA-F]{32}>/message',
        _message,
        role: admin,
        audit: true,
      )
      ..get('/media/jellyfin', _jellyfin)
      ..post(
        '/media/jellyfin/library/refresh',
        _refreshLibrary,
        role: admin,
        audit: true,
      )
      ..get('/media/stats', _stats)
      ..get('/media/stats/users', _statsUsers)
      ..get('/media/stats/history', _statsHistory)
      ..get('/media/audiobooks', _audiobooks)
      ..get('/media/books', _books)
      ..get('/media/shelfmark', _shelfmark)
      ..get('/media/apps', _apps);
  }

  // -------------------------------------------------------------------------
  // Handlers
  // -------------------------------------------------------------------------

  Future<Response> _nowPlaying(ApiRequest req) async {
    final np = await upstreamGuard(
      () => jellyfin.nowPlaying(isAdmin: req.isAdmin),
    );
    return ApiResponse.json(np.value.toJson());
  }

  Future<Response> _playback(ApiRequest req) async {
    final sessionId = req.pathParam('id').toLowerCase();
    final body = await req.jsonBody();
    final raw = readString(body['command']);
    final command = MediaPlaybackCommand.fromJson(raw);
    if (command == MediaPlaybackCommand.unknown) {
      throw ApiException.badRequest(
        'command must be one of pause, unpause, stop',
      );
    }
    await jellyfin.playback(sessionId, command);
    return ApiResponse.noContent();
  }

  Future<Response> _message(ApiRequest req) async {
    final sessionId = req.pathParam('id').toLowerCase();
    final body = await req.jsonBody();
    final text = readString(body['text'])?.trim() ?? '';
    final errors = <ApiFieldError>[];
    if (text.isEmpty || text.length > 200) {
      errors.add(
        const ApiFieldError(
          field: 'text',
          message: 'Text must be 1 to 200 characters.',
        ),
      );
    }
    final header = body['header'] == null
        ? 'YAMS Hub'
        : readString(body['header'])?.trim();
    if (header == null || header.isEmpty || header.length > 100) {
      errors.add(
        const ApiFieldError(
          field: 'header',
          message: 'Header must be 1 to 100 characters.',
        ),
      );
    }
    final timeoutMs = body['timeoutMs'] == null
        ? 10000
        : readInt(body['timeoutMs']);
    if (timeoutMs == null || timeoutMs < 1000 || timeoutMs > 120000) {
      errors.add(
        const ApiFieldError(
          field: 'timeoutMs',
          message: 'timeoutMs must be between 1000 and 120000.',
        ),
      );
    }
    if (errors.isNotEmpty) throw ApiException.validation(errors);
    await jellyfin.message(
      sessionId,
      text: text,
      header: header!,
      timeoutMs: timeoutMs!,
    );
    return ApiResponse.noContent();
  }

  Future<Response> _jellyfin(ApiRequest req) async {
    final linked = normaliseJellyfinId(req.user.jellyfinUserId);
    final o = await upstreamGuard(
      () => jellyfin.overview(jellyfinUserId: linked),
    );
    return ApiResponse.json(o.toJson());
  }

  Future<Response> _refreshLibrary(ApiRequest req) async {
    await jellyfin.refreshLibraries();
    return ApiResponse.json({'queued': true}, status: 202);
  }

  Future<Response> _stats(ApiRequest req) async {
    final days = int.parse(
      req.queryChoice('days', [
        for (final d in WatchStats.periods) '$d',
      ], defaultValue: '30'),
    );
    final s = await upstreamGuard(() => jellystat.stats(days));
    return ApiResponse.json(s.toJson());
  }

  Future<Response> _statsUsers(ApiRequest req) async {
    final users = await upstreamGuard(jellystat.users);
    return ApiResponse.items(users, (u) => u.toJson());
  }

  Future<Response> _statsHistory(ApiRequest req) async {
    final page = req.queryInt('page', defaultValue: 1, min: 1);
    final pageSize = req.queryInt(
      'pageSize',
      defaultValue: 25,
      min: 1,
      max: 50,
    );
    String? userId;
    if (req.isAdmin) {
      final raw = req.queryString('userId');
      if (raw != null) {
        userId = normaliseJellyfinId(raw);
        if (userId == null) {
          throw ApiException.badRequest('userId must be a Jellyfin user id');
        }
      }
    } else {
      // Members only ever see their own plays; a supplied userId is ignored.
      userId = normaliseJellyfinId(req.user.jellyfinUserId);
      if (userId == null) {
        final empty = PagedList<PlaybackRecord>.of(
          items: const [],
          page: page,
          pageSize: pageSize,
          total: 0,
        );
        return ApiResponse.json(empty.toJson((r) => r.toJson()));
      }
    }
    final history = await upstreamGuard(
      () => jellystat.history(page: page, pageSize: pageSize, userId: userId),
    );
    return ApiResponse.json(history.toJson((r) => r.toJson()));
  }

  Future<Response> _audiobooks(ApiRequest req) async {
    final o = await upstreamGuard(audiobooks.overview);
    return ApiResponse.json(o.toJson());
  }

  Future<Response> _books(ApiRequest req) async {
    final o = await upstreamGuard(kavita.overview);
    return ApiResponse.json(o.toJson());
  }

  Future<Response> _shelfmark(ApiRequest req) async {
    final s = await upstreamGuard(shelfmark.status);
    return ApiResponse.json(s.toJson());
  }

  Future<Response> _apps(ApiRequest req) async {
    final list = await apps.apps();
    return ApiResponse.items(list, (a) => a.toJson());
  }

  // -------------------------------------------------------------------------
  // Dashboard card `media` (API.md §14.8)
  // -------------------------------------------------------------------------

  @override
  Future<DashboardContribution?> dashboard(ApiRequest req) async {
    final npF = jellyfin.nowPlaying(isAdmin: req.isAdmin);
    void log(Object e) => ctx.log.fine('media card part failed: $e');
    final sharedF = optional(jellyfin.shared(), onError: log);
    final restartF = optional(jellyfin.hasPendingRestart(), onError: log);
    final absF = _configured(ServiceId.audiobookshelf)
        ? optional(audiobooks.overview(), onError: log)
        : Future<AudiobooksOverview?>.value();
    final booksF = ctx.config.service(ServiceId.kavita).url != null
        ? optional(kavita.overview(), onError: log)
        : Future<BooksOverview?>.value();
    final shelfF = _configured(ServiceId.shelfmark)
        ? optional(shelfmark.status(), onError: log)
        : Future<ShelfmarkStatus?>.value();

    // Now playing is the card: its failure fails the card, but the optional
    // parts still load (warming their caches) and still raise their alerts.
    final CacheResult<NowPlaying> np;
    try {
      np = await npF;
    } catch (e) {
      final books = await booksF;
      final shelf = await shelfF;
      await Future.wait([sharedF, absF, restartF]);
      return DashboardContribution.failed(
        e,
        alerts: mediaAlerts(books: books, shelfmark: shelf),
      );
    }
    final shared = await sharedF;
    final abs = await absF;
    final books = await booksF;
    final shelf = await shelfF;
    final restart = await restartF ?? false;

    final card = MediaCard(
      nowPlaying: np.value.sessions.take(4).toList(),
      transcoding: np.value.transcoding,
      counts: shared == null
          ? null
          : MediaCardCounts(
              movies: shared.counts.movies,
              series: shared.counts.series,
              episodes: shared.counts.episodes,
            ),
      audiobooks: abs == null
          ? null
          : MediaCardAudiobooks(
              items: abs.totalItems,
              inProgress: abs.continueListening.length,
            ),
      books: books == null
          ? null
          : MediaCardBooks(series: books.stats?.series ?? 0, auth: books.auth),
      shelfmark: shelf == null
          ? null
          : MediaCardShelfmark(
              active: shelf.queue.active,
              queued: shelf.queue.queued,
              failed7d: shelf.failed7d,
            ),
      recentlyAdded: shared?.recentlyAdded.take(8).toList() ?? const [],
    );
    return DashboardContribution(
      data: card.toJson(),
      alerts: mediaAlerts(
        books: books,
        pendingRestart: restart,
        shelfmark: shelf,
      ),
      stale: np.stale,
      fetchedAt: np.fetchedAt,
      error: np.stale && np.error != null
          ? apiErrorOf(np.error!, req.requestId)
          : null,
    );
  }

  bool _configured(ServiceId id) => ctx.config.isConfigured(id);
}

/// The media alerts (API.md §14.8).
List<Alert> mediaAlerts({
  BooksOverview? books,
  bool pendingRestart = false,
  ShelfmarkStatus? shelfmark,
}) => [
  if (books != null &&
      (books.auth == BooksAuth.missingKey || books.auth == BooksAuth.rejected))
    Alert(
      id: 'kavita.auth',
      severity: AlertSeverity.warning,
      source: ServiceId.kavita,
      feature: 'media',
      title: 'Kavita needs an Auth Key',
      message: books.auth == BooksAuth.rejected
          ? 'Kavita rejected the hub\'s Auth Key. Create a new one in Kavita '
                '(User settings → Auth Keys) and update KAVITA_API_KEY.'
          : 'Create an Auth Key in Kavita (User settings → Auth Keys) and add '
                'it to the hub as KAVITA_API_KEY.',
      route: '/media/books',
    ),
  if (pendingRestart)
    const Alert(
      id: 'jellyfin.restart',
      severity: AlertSeverity.info,
      source: ServiceId.jellyfin,
      feature: 'media',
      title: 'Jellyfin needs a restart',
      message: 'Jellyfin has a pending restart to apply updates or settings.',
      route: '/containers/jellyfin',
      dismissible: true,
    ),
  if (shelfmark?.coordinator == ShelfmarkCoordinator.stopped)
    const Alert(
      id: 'shelfmark.coordinator',
      severity: AlertSeverity.warning,
      source: ServiceId.shelfmark,
      feature: 'media',
      title: 'Shelfmark downloads are stopped',
      message: 'Shelfmark\'s download coordinator is not running.',
      route: '/media/shelfmark',
    ),
];
