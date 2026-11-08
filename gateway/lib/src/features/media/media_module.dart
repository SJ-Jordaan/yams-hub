/// Media feature: Jellyfin, Jellystat, Audiobookshelf, Kavita and Shelfmark (API.md §14).
///
/// Stub created by core-gateway: every route of the feature is registered
/// (regex-constrained parameters, static segments first) and answers
/// `501 not_implemented`; the media slice replaces this body and keeps the
/// class name and constructor.
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

class MediaModule extends FeatureModule {
  MediaModule(this.ctx);

  final FeatureContext ctx;

  @override
  String get id => 'media';

  @override
  void registerRoutes(ApiRouter router) {
    const admin = Role.admin;
    router
      ..get('/media/now-playing', notImplementedHandler)
      ..post(
        '/media/sessions/<id|[0-9a-fA-F]{32}>/playback',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..post(
        '/media/sessions/<id|[0-9a-fA-F]{32}>/message',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..get('/media/jellyfin', notImplementedHandler)
      ..post(
        '/media/jellyfin/library/refresh',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..get('/media/stats', notImplementedHandler)
      ..get('/media/stats/users', notImplementedHandler)
      ..get('/media/stats/history', notImplementedHandler)
      ..get('/media/audiobooks', notImplementedHandler)
      ..get('/media/books', notImplementedHandler)
      ..get('/media/shelfmark', notImplementedHandler)
      ..get('/media/apps', notImplementedHandler);
  }

  @override
  Future<DashboardContribution?> dashboard(ApiRequest req) async =>
      throw ApiException.notImplemented();
}
