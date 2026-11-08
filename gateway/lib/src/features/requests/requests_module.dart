/// Requests feature: Seerr discover, search, titles, requests and issues
/// (API.md §6).
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'discover_handlers.dart';
import 'issue_handlers.dart';
import 'request_handlers.dart';
import 'requests_service.dart';
import 'seerr_client.dart';

class RequestsModule extends FeatureModule {
  RequestsModule(this.ctx) : _svc = RequestsService(ctx) {
    _discover = DiscoverHandlers(_svc);
    _requests = RequestHandlers(_svc);
    _issues = IssueHandlers(_svc);
  }

  final FeatureContext ctx;
  final RequestsService _svc;
  late final DiscoverHandlers _discover;
  late final RequestHandlers _requests;
  late final IssueHandlers _issues;

  @override
  String get id => 'requests';

  @override
  void registerRoutes(ApiRouter router) {
    const admin = Role.admin;
    final d = _discover;
    final r = _requests;
    final i = _issues;
    router
      ..get('/discover/genres', d.genres)
      ..get('/discover/watchlist', d.watchlist)
      ..get('/discover/<slider|[a-z0-9-]+>', d.slider)
      ..get('/search', d.search)
      ..get('/titles/movie/<tmdbId|[0-9]+>', d.movie)
      ..get('/titles/tv/<tmdbId|[0-9]+>', d.tv)
      ..get('/titles/tv/<tmdbId|[0-9]+>/seasons/<n|[0-9]+>', d.season)
      ..get('/titles/<mediaType|movie|tv>/<tmdbId|[0-9]+>/ratings', d.ratings)
      ..get(
        '/titles/<mediaType|movie|tv>/<tmdbId|[0-9]+>/recommendations',
        (req) => d.related(req, 'recommendations'),
      )
      ..get(
        '/titles/<mediaType|movie|tv>/<tmdbId|[0-9]+>/similar',
        (req) => d.related(req, 'similar'),
      )
      ..get('/requests', r.list)
      ..post('/requests', r.create, audit: true, action: 'requests.create')
      ..get('/requests/options', r.options, role: admin)
      ..get('/requests/counts', r.counts)
      ..get('/requests/<id|[0-9]+>', r.detail)
      ..put(
        '/requests/<id|[0-9]+>',
        r.update,
        audit: true,
        action: 'requests.update',
      )
      ..delete(
        '/requests/<id|[0-9]+>',
        r.delete,
        audit: true,
        action: 'requests.delete',
      )
      ..post(
        '/requests/<id|[0-9]+>/approve',
        (req) => r.transition(req, 'approve'),
        role: admin,
        audit: true,
        action: 'requests.approve',
      )
      ..post(
        '/requests/<id|[0-9]+>/decline',
        (req) => r.transition(req, 'decline'),
        role: admin,
        audit: true,
        action: 'requests.decline',
      )
      ..post(
        '/requests/<id|[0-9]+>/retry',
        (req) => r.transition(req, 'retry'),
        role: admin,
        audit: true,
        action: 'requests.retry',
      )
      ..get('/issues', i.list)
      ..post('/issues', i.create, audit: true, action: 'issues.create')
      ..get('/issues/counts', i.counts)
      ..get('/issues/<id|[0-9]+>', i.detail)
      ..post(
        '/issues/<id|[0-9]+>/comments',
        i.comment,
        audit: true,
        action: 'issues.comment',
      )
      ..post(
        '/issues/<id|[0-9]+>/resolve',
        (req) => i.setStatus(req, resolve: true),
        audit: true,
        action: 'issues.resolve',
      )
      ..post(
        '/issues/<id|[0-9]+>/reopen',
        (req) => i.setStatus(req, resolve: false),
        audit: true,
        action: 'issues.reopen',
      );
  }

  /// The `requests` card (API.md §6.9, cache 30 s per caller).
  @override
  Future<DashboardContribution?> dashboard(ApiRequest req) async {
    final actor = await _svc.actor(req);
    final result = await _svc.card.get(actor.cacheKey, () => _card(actor));
    final card = result.value;
    final error = result.error;
    return DashboardContribution(
      data: card.toJson(),
      alerts: actor.isAdmin ? _alerts(card.counts) : const [],
      stale: result.stale,
      fetchedAt: result.fetchedAt,
      error: result.stale && error != null ? _apiError(error, req) : null,
    );
  }

  static ApiError? _apiError(Object error, ApiRequest req) => switch (error) {
    ApiException() => error.toApiError(req.requestId),
    UpstreamException() =>
      error.toApiException(resourceNotFound: false).toApiError(req.requestId),
    _ => null,
  };

  Future<RequestsCard> _card(SeerrActor actor) async {
    const latest = {'take': 5, 'skip': 0, 'sort': 'added'};
    final none = Future.value(const SeerrRequestPage([], 0));
    final (counts, pending, recent, openIssues) = await (
      _svc.requestCounts(),
      actor.isAdmin
          ? _svc.requestPage(
              seerrQuery({
                ...latest,
                'filter': 'pending',
                'sortDirection': 'desc',
              }),
            )
          : none,
      actor.linked
          ? _svc.requestPage(
              seerrQuery({
                ...latest,
                'filter': 'all',
                'sortDirection': 'desc',
                'requestedBy': actor.isAdmin ? null : actor.seerrUserId,
              }),
              asUser: actor.asUser,
            )
          : none,
      _svc.issueCountsValue().then<int>(
        (c) => c.open,
        onError: (Object e) {
          ctx.log.fine('Seerr issue counts unavailable: $e');
          return 0;
        },
      ),
    ).wait;
    final (pendingItems, recentItems) = await (
      _svc.summaries(pending.results, actor),
      _svc.summaries(recent.results, actor),
    ).wait;
    return RequestsCard(
      counts: counts,
      pending: pendingItems,
      recent: recentItems,
      openIssues: openIssues,
    );
  }

  static List<Alert> _alerts(RequestCounts counts) => [
    if (counts.pending > 0)
      Alert(
        id: 'seerr.pending',
        severity: AlertSeverity.info,
        source: ServiceId.seerr,
        feature: 'requests',
        title: counts.pending == 1
            ? '1 request waiting for approval'
            : '${counts.pending} requests waiting for approval',
        route: '/requests/list?tab=pending',
      ),
    if (counts.failed > 0)
      Alert(
        id: 'seerr.failed',
        severity: AlertSeverity.warning,
        source: ServiceId.seerr,
        feature: 'requests',
        title: counts.failed == 1
            ? '1 request failed'
            : '${counts.failed} requests failed',
        message: 'Seerr could not send them to Sonarr/Radarr. Retry them.',
        route: '/requests/list?tab=failed',
      ),
  ];
}
