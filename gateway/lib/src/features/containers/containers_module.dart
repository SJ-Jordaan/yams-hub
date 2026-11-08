/// Containers feature: containers, updates and maintenance (API.md §11).
///
/// Stub created by core-gateway: every route of the feature is registered
/// (regex-constrained parameters, static segments first) and answers
/// `501 not_implemented`; the containers slice replaces this body and keeps the
/// class name and constructor.
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

class ContainersModule extends FeatureModule {
  ContainersModule(this.ctx);

  final FeatureContext ctx;

  @override
  String get id => 'containers';

  @override
  void registerRoutes(ApiRouter router) {
    const admin = Role.admin;
    router
      ..get('/containers', notImplementedHandler)
      ..get('/containers/events', notImplementedHandler)
      ..get(
        '/containers/<name|[a-zA-Z0-9][a-zA-Z0-9_.-]*>',
        notImplementedHandler,
      )
      ..get(
        '/containers/<name|[a-zA-Z0-9][a-zA-Z0-9_.-]*>/logs',
        notImplementedHandler,
        role: admin,
      )
      ..post(
        '/containers/<name|[a-zA-Z0-9][a-zA-Z0-9_.-]*>/actions',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..get('/updates', notImplementedHandler)
      ..post('/updates/check', notImplementedHandler, role: admin, audit: true)
      ..post(
        '/updates/<service|[a-z0-9][a-z0-9_.-]*>',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..get('/maintenance/decluttarr', notImplementedHandler)
      ..get('/maintenance/recyclarr', notImplementedHandler)
      ..post(
        '/maintenance/recyclarr/sync',
        notImplementedHandler,
        role: admin,
        audit: true,
      );
  }

  @override
  Future<DashboardContribution?> dashboard(ApiRequest req) async =>
      throw ApiException.notImplemented();
}
