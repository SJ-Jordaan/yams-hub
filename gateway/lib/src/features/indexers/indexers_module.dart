/// Indexers feature: Prowlarr indexers, history and manual search (API.md §10).
///
/// Stub created by core-gateway: every route of the feature is registered
/// (regex-constrained parameters, static segments first) and answers
/// `501 not_implemented`; the indexers slice replaces this body and keeps the
/// class name and constructor.
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

class IndexersModule extends FeatureModule {
  IndexersModule(this.ctx);

  final FeatureContext ctx;

  @override
  String get id => 'indexers';

  @override
  void registerRoutes(ApiRouter router) {
    const admin = Role.admin;
    router
      ..get('/indexers', notImplementedHandler)
      ..patch('/indexers', notImplementedHandler, role: admin, audit: true)
      ..get('/indexers/history', notImplementedHandler)
      ..get('/indexers/categories', notImplementedHandler)
      ..get('/indexers/search', notImplementedHandler, role: admin)
      ..post('/indexers/grab', notImplementedHandler, role: admin, audit: true)
      ..post(
        '/indexers/test-all',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..get('/indexers/<id|[0-9]+>', notImplementedHandler)
      ..post(
        '/indexers/<id|[0-9]+>/test',
        notImplementedHandler,
        role: admin,
        audit: true,
      );
  }

  @override
  Future<DashboardContribution?> dashboard(ApiRequest req) async =>
      throw ApiException.notImplemented();
}
