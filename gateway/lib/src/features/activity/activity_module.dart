/// Activity feature: qBittorrent, VPN, *arr queues and history (API.md §8).
///
/// Stub created by core-gateway: every route of the feature is registered
/// (regex-constrained parameters, static segments first) and answers
/// `501 not_implemented`; the activity slice replaces this body and keeps the
/// class name and constructor.
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

class ActivityModule extends FeatureModule {
  ActivityModule(this.ctx);

  final FeatureContext ctx;

  @override
  String get id => 'activity';

  @override
  void registerRoutes(ApiRouter router) {
    const admin = Role.admin;
    router
      ..get('/activity/queue', notImplementedHandler)
      ..post(
        '/activity/queue/remove',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..post(
        '/activity/queue/grab',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..post(
        '/activity/queue/refresh',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..post(
        '/activity/queue/import',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..get(
        '/activity/queue/<service|sonarr|radarr>/<queueId|[0-9]+>/import',
        notImplementedHandler,
        role: admin,
      )
      ..get('/activity/history', notImplementedHandler)
      ..get('/torrents', notImplementedHandler)
      ..post(
        '/torrents/actions',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..post('/torrents/add', notImplementedHandler, role: admin, audit: true)
      ..get('/torrents/<hash|[0-9a-fA-F]{40}>', notImplementedHandler)
      ..put(
        '/torrents/<hash|[0-9a-fA-F]{40}>/share-limits',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..put(
        '/torrents/<hash|[0-9a-fA-F]{40}>/files/priority',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..get('/transfer', notImplementedHandler)
      ..get('/transfer/categories', notImplementedHandler)
      ..put(
        '/transfer/alt-speed',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..put('/transfer/limits', notImplementedHandler, role: admin, audit: true)
      ..put(
        '/transfer/session',
        notImplementedHandler,
        role: admin,
        audit: true,
      )
      ..get('/vpn', notImplementedHandler);
  }

  @override
  Future<DashboardContribution?> dashboard(ApiRequest req) async =>
      throw ApiException.notImplemented();
}
