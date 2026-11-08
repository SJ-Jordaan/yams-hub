/// System feature: host metrics and Uptime Kuma (API.md §13).
///
/// Stub created by core-gateway: every route of the feature is registered
/// (regex-constrained parameters, static segments first) and answers
/// `501 not_implemented`; the system slice replaces this body and keeps the
/// class name and constructor.
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';

class SystemModule extends FeatureModule {
  SystemModule(this.ctx);

  final FeatureContext ctx;

  @override
  String get id => 'system';

  @override
  void registerRoutes(ApiRouter router) {
    router
      ..get('/system/host', notImplementedHandler)
      ..get('/system/history', notImplementedHandler)
      ..get('/uptime', notImplementedHandler);
  }

  @override
  Future<DashboardContribution?> dashboard(ApiRequest req) async =>
      throw ApiException.notImplemented();
}
