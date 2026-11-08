/// Subtitles feature: Bazarr subtitles (API.md §12).
///
/// Stub created by core-gateway: every route of the feature is registered
/// (regex-constrained parameters, static segments first) and answers
/// `501 not_implemented`; the subtitles slice replaces this body and keeps the
/// class name and constructor.
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

class SubtitlesModule extends FeatureModule {
  SubtitlesModule(this.ctx);

  final FeatureContext ctx;

  @override
  String get id => 'subtitles';

  @override
  void registerRoutes(ApiRouter router) {
    const admin = Role.admin;
    router
      ..get('/subtitles/summary', notImplementedHandler)
      ..get('/subtitles/wanted', notImplementedHandler)
      ..get('/subtitles/history', notImplementedHandler)
      ..get('/subtitles/jobs', notImplementedHandler)
      ..post(
        '/subtitles/search',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..post(
        '/subtitles/search-item',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..post(
        '/subtitles/search-all',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..post(
        '/subtitles/providers/reset',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..post(
        '/subtitles/tasks/<taskId|[A-Za-z0-9_-]+>/run',
        notImplementedHandler,
        role: admin,
        audit: true,
      );
  }

  @override
  Future<DashboardContribution?> dashboard(ApiRequest req) async =>
      throw ApiException.notImplemented();
}
