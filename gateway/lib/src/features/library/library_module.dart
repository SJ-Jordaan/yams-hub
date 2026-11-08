/// Library feature: Sonarr and Radarr library management (API.md §7).
///
/// Stub created by core-gateway: every route of the feature is registered
/// (regex-constrained parameters, static segments first) and answers
/// `501 not_implemented`; the library slice replaces this body and keeps the
/// class name and constructor.
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

class LibraryModule extends FeatureModule {
  LibraryModule(this.ctx);

  final FeatureContext ctx;

  @override
  String get id => 'library';

  @override
  void registerRoutes(ApiRouter router) {
    const admin = Role.admin;
    router
      ..get('/library/summary', notImplementedHandler)
      ..get('/library/profiles', notImplementedHandler)
      ..get(
        '/library/commands/<service|sonarr|radarr>/<id|[0-9]+>',
        notImplementedHandler,
      )
      ..get('/library/wanted/<kind|missing|cutoff>', notImplementedHandler)
      ..post(
        '/library/wanted/search',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..post(
        '/library/wanted/search-all',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..post(
        '/library/releases/grab',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..get('/library/tv', notImplementedHandler)
      ..post('/library/tv', notImplementedHandler, role: admin, audit: true)
      ..get('/library/tv/lookup', notImplementedHandler)
      ..patch(
        '/library/tv/episodes',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..get(
        '/library/tv/episodes/<episodeId|[0-9]+>/releases',
        notImplementedHandler,
        role: admin,
      )
      ..get('/library/tv/<id|[0-9]+>', notImplementedHandler)
      ..patch(
        '/library/tv/<id|[0-9]+>',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..delete(
        '/library/tv/<id|[0-9]+>',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..get('/library/tv/<id|[0-9]+>/history', notImplementedHandler)
      ..patch(
        '/library/tv/<id|[0-9]+>/seasons/<seasonNumber|[0-9]+>',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..get(
        '/library/tv/<id|[0-9]+>/seasons/<n|[0-9]+>/releases',
        notImplementedHandler,
        role: admin,
      )
      ..post(
        '/library/tv/<id|[0-9]+>/search',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..post(
        '/library/tv/<id|[0-9]+>/refresh',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..get('/library/movies', notImplementedHandler)
      ..post('/library/movies', notImplementedHandler, role: admin, audit: true)
      ..get('/library/movies/lookup', notImplementedHandler)
      ..get('/library/movies/<id|[0-9]+>', notImplementedHandler)
      ..patch(
        '/library/movies/<id|[0-9]+>',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..delete(
        '/library/movies/<id|[0-9]+>',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..get('/library/movies/<id|[0-9]+>/history', notImplementedHandler)
      ..get(
        '/library/movies/<id|[0-9]+>/releases',
        notImplementedHandler,
        role: admin,
      )
      ..post(
        '/library/movies/<id|[0-9]+>/search',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..post(
        '/library/movies/<id|[0-9]+>/refresh',
        notImplementedHandler,
        role: admin,
        audit: true,
      );
  }

  @override
  Future<DashboardContribution?> dashboard(ApiRequest req) async =>
      throw ApiException.notImplemented();
}
