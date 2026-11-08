/// `GET /server` and `GET /health` (ARCHITECTURE §7.2).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_models/yams_models.dart';

import '../api/core_api.dart';
import '../refresh/auto_refresh.dart';

/// App-wide configuration from the gateway: version, public URLs, external
/// apps, policy, feature flags. Refetched when the server changes.
final serverConfigProvider = FutureProvider<ServerConfig>(
  (ref) => ref.watch(coreApiProvider).server(),
);

/// Service health (`GET /health`), refreshed every 30 s while watched.
final healthProvider = FutureProvider.autoDispose<HealthReport>((ref) {
  autoRefresh(ref, RefreshIntervals.health);
  return ref.watch(coreApiProvider).health();
});
