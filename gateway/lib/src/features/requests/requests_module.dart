/// Requests feature: Seerr discover, search, titles, requests and issues (API.md §6).
///
/// Stub created by core-gateway: every route of the feature is registered
/// (regex-constrained parameters, static segments first) and answers
/// `501 not_implemented`; the requests slice replaces this body and keeps the
/// class name and constructor.
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

class RequestsModule extends FeatureModule {
  RequestsModule(this.ctx);

  final FeatureContext ctx;

  @override
  String get id => 'requests';

  @override
  void registerRoutes(ApiRouter router) {
    const admin = Role.admin;
    router
      ..get('/discover/genres', notImplementedHandler)
      ..get('/discover/watchlist', notImplementedHandler)
      ..get('/discover/<slider|[a-z0-9-]+>', notImplementedHandler)
      ..get('/search', notImplementedHandler)
      ..get('/titles/movie/<tmdbId|[0-9]+>', notImplementedHandler)
      ..get('/titles/tv/<tmdbId|[0-9]+>', notImplementedHandler)
      ..get(
        '/titles/tv/<tmdbId|[0-9]+>/seasons/<n|[0-9]+>',
        notImplementedHandler,
      )
      ..get(
        '/titles/<mediaType|movie|tv>/<tmdbId|[0-9]+>/ratings',
        notImplementedHandler,
      )
      ..get(
        '/titles/<mediaType|movie|tv>/<tmdbId|[0-9]+>/recommendations',
        notImplementedHandler,
      )
      ..get(
        '/titles/<mediaType|movie|tv>/<tmdbId|[0-9]+>/similar',
        notImplementedHandler,
      )
      ..get('/requests', notImplementedHandler)
      ..post('/requests', notImplementedHandler, audit: true)
      ..get('/requests/options', notImplementedHandler, role: admin)
      ..get('/requests/counts', notImplementedHandler)
      ..get('/requests/<id|[0-9]+>', notImplementedHandler)
      ..put('/requests/<id|[0-9]+>', notImplementedHandler, audit: true)
      ..delete('/requests/<id|[0-9]+>', notImplementedHandler, audit: true)
      ..post(
        '/requests/<id|[0-9]+>/approve',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..post(
        '/requests/<id|[0-9]+>/decline',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..post(
        '/requests/<id|[0-9]+>/retry',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..get('/issues', notImplementedHandler)
      ..post('/issues', notImplementedHandler, audit: true)
      ..get('/issues/counts', notImplementedHandler)
      ..get('/issues/<id|[0-9]+>', notImplementedHandler)
      ..post('/issues/<id|[0-9]+>/comments', notImplementedHandler, audit: true)
      ..post('/issues/<id|[0-9]+>/resolve', notImplementedHandler, audit: true)
      ..post('/issues/<id|[0-9]+>/reopen', notImplementedHandler, audit: true);
  }

  @override
  Future<DashboardContribution?> dashboard(ApiRequest req) async =>
      throw ApiException.notImplemented();
}
