/// Everything a feature module needs (ARCHITECTURE §5.5).
library;

import 'package:logging/logging.dart';

import '../config/config.dart';
import 'audit/audit_log.dart';
import 'cache/demand_poller.dart';
import 'cache/ttl_cache.dart';
import 'clock.dart';
import 'health/health_service.dart';
import 'images/image_urls.dart';
import 'jobs/job_registry.dart';
import 'log/redact.dart';
import 'services/jellyfin_info.dart';
import 'services/seerr_identity.dart';
import 'store/json_file_store.dart';
import 'upstream/remote_fetcher.dart';
import 'upstream/upstreams.dart';

export '../config/config.dart';
export 'audit/audit_log.dart';
export 'cache/demand_poller.dart';
export 'cache/ttl_cache.dart';
export 'clock.dart';
export 'docker/proxy_self_test.dart';
export 'feature_module.dart';
export 'health/health_service.dart';
export 'http/api_exception.dart';
export 'http/api_request.dart';
export 'http/api_response.dart';
export 'http/api_router.dart';
export 'http/merged_cursor.dart';
export 'images/image_urls.dart';
export 'jobs/job_registry.dart';
export 'log/redact.dart';
export 'services/jellyfin_info.dart';
export 'services/seerr_identity.dart';
export 'store/json_file_store.dart';
export 'upstream/allowed_hosts.dart';
export 'upstream/arr_queue_reader.dart';
export 'upstream/qbit_session.dart';
export 'upstream/remote_fetcher.dart';
export 'upstream/upstream_client.dart';
export 'upstream/upstream_exception.dart';
export 'upstream/upstreams.dart';

/// The services shared by every feature. Modules receive it through their
/// constructor (`LibraryModule(FeatureContext ctx)`). Importing this file
/// also exports every core type a feature uses.
final class FeatureContext {
  FeatureContext({
    required this.config,
    required this.upstreams,
    required this.caches,
    required this.pollers,
    required this.jobs,
    required this.audit,
    required this.images,
    required this.remoteHttp,
    required this.jellyfin,
    required this.seerrIdentity,
    required this.seerrSettings,
    required this.health,
    required this.stores,
    required this.clock,
    Logger? log,
    this.redact = redactSecrets,
  }) : log = log ?? Logger('feature');

  /// URLs, policy, external apps, alert thresholds.
  final HubConfig config;

  /// One client per service (ARCHITECTURE §5.6).
  final Upstreams upstreams;

  /// `ctx.caches.ttl<K, V>(name, ttl, {maxStale, maxEntries})`.
  final CacheFactory caches;

  /// Demand-driven background loops.
  final PollerFactory pollers;

  /// Long-running actions.
  final JobRegistry jobs;

  /// `await ctx.audit.run(req, action, target, params, () async {...})`.
  final AuditLog audit;

  /// Builds gateway image paths (features never hand-build `/img` paths).
  final ImageUrls images;

  /// Outbound internet with manual redirects and the public-address check.
  final RemoteFetcher remoteHttp;

  /// Jellyfin server id, admin user id and item links.
  final JellyfinServerInfo jellyfin;

  /// Hub user → Seerr user (shared with core).
  final SeerrIdentityResolver seerrIdentity;

  /// Seerr public settings (4K, partial requests, special episodes).
  final SeerrPublicSettings seerrSettings;

  /// The cached health report, the Docker proxy self-test and capabilities.
  final HealthService health;

  /// Atomic JSON files under `$DATA`.
  final StoreFactory stores;

  /// `redactSecrets` for every upstream-derived message.
  final String Function(String) redact;

  /// UTC time source.
  final Clock clock;

  /// `Logger('feature.<id>')` (see [forFeature]).
  final Logger log;

  /// The same context with `log = Logger('feature.<id>')`.
  FeatureContext forFeature(String id) => FeatureContext(
    config: config,
    upstreams: upstreams,
    caches: caches,
    pollers: pollers,
    jobs: jobs,
    audit: audit,
    images: images,
    remoteHttp: remoteHttp,
    jellyfin: jellyfin,
    seerrIdentity: seerrIdentity,
    seerrSettings: seerrSettings,
    health: health,
    stores: stores,
    clock: clock,
    log: Logger('feature.$id'),
    redact: redact,
  );
}
