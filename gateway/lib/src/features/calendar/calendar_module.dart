/// Calendar feature: the Sonarr/Radarr calendar (API.md §9).
///
/// Stub created by core-gateway: every route of the feature is registered
/// (regex-constrained parameters, static segments first) and answers
/// `501 not_implemented`; the calendar slice replaces this body and keeps the
/// class name and constructor.
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';

class CalendarModule extends FeatureModule {
  CalendarModule(this.ctx);

  final FeatureContext ctx;

  @override
  String get id => 'calendar';

  @override
  void registerRoutes(ApiRouter router) {
    router.get('/calendar', notImplementedHandler);
  }

  @override
  Future<DashboardContribution?> dashboard(ApiRequest req) async =>
      throw ApiException.notImplemented();
}
