/// Builds the gateway: services, routers and the shelf pipeline
/// (ARCHITECTURE §5.3).
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

import 'core/admin/admin_routes.dart';
import 'core/auth/access_tokens.dart';
import 'core/auth/auth_routes.dart';
import 'core/auth/auth_service.dart';
import 'core/auth/login_limiter.dart';
import 'core/auth/password_hasher.dart';
import 'core/auth/session_store.dart';
import 'core/auth/user_store.dart';
import 'core/core_routes.dart';
import 'core/dashboard/dashboard_service.dart';
import 'core/feature_context.dart';
import 'core/feature_registry.dart';
import 'core/http/middleware.dart';
import 'core/images/image_cache.dart';
import 'core/images/image_routes.dart';
import 'core/static/static_handler.dart';

final _log = Logger('hub');

/// Builds the feature modules from the shared context.
typedef ModuleBuilder = List<FeatureModule> Function(FeatureContext ctx);

/// The assembled gateway. [handler] is the full shelf pipeline.
final class Hub {
  Hub._({
    required this.config,
    required this.clock,
    required this.stores,
    required this.upstreams,
    required this.audit,
    required this.auth,
    required this.jobs,
    required this.health,
    required this.images,
    required this.imageService,
    required this.context,
    required this.modules,
    required this.router,
    required this.handler,
    required this.instanceId,
    required this._pollers,
  });

  final HubConfig config;
  final Clock clock;
  final StoreFactory stores;
  final Upstreams upstreams;
  final AuditLog audit;
  final AuthService auth;
  final JobRegistry jobs;
  final HealthService health;
  final ImageUrls images;
  final ImageService imageService;
  final FeatureContext context;
  final List<FeatureModule> modules;
  final ApiRouter router;
  final Handler handler;
  final String instanceId;
  final PollerFactory _pollers;
  final _started = <FeatureModule>[];
  bool _coreStarted = false;

  /// Builds the gateway. Tests pass a fake [upstreamClient], a
  /// [remoteFetcher], a [clock] and a cheap [hasher]; with [autoTune] the
  /// PBKDF2 cost is measured first (production).
  static Future<Hub> create(
    HubConfig config, {
    http.Client? upstreamClient,
    RemoteFetcher? remoteFetcher,
    Clock clock = const SystemClock(),
    PasswordHasher? hasher,
    ModuleBuilder modules = buildFeatureModules,
    bool autoTune = false,
  }) async {
    await Directory(config.dataDir).create(recursive: true);
    final stores = StoreFactory(config.dataDir);
    final caches = CacheFactory(clock);
    final pollers = PollerFactory(clock);
    final upstreams = Upstreams(
      config: config,
      client: upstreamClient ?? createUpstreamHttpClient(),
      clock: clock,
    );
    final users = UserStore(stores.open('users.json'));
    final audit = AuditLog(
      dataDir: config.dataDir,
      clock: clock,
      usernameOf: (id) => users.byId(id)?.username,
    );
    final sessions = SessionStore(stores.open('sessions.json'), clock);
    final tokens = AccessTokenIndex(clock);
    final passwordHasher =
        hasher ?? PasswordHasher(iterations: config.auth.pbkdf2Iterations);
    if (autoTune) {
      final took = await passwordHasher.autoTune();
      _log.info(
        'PBKDF2: one verification took ${took.inMilliseconds} ms; new hashes use '
        '${passwordHasher.iterations} iterations',
      );
    }
    final knownIps = KnownIps(stores.open('known_ips.json'), clock);
    final auth = AuthService(
      config: config,
      users: users,
      sessions: sessions,
      tokens: tokens,
      hasher: passwordHasher,
      limiter: LoginLimiter(clock, knownIps),
      audit: audit,
      clock: clock,
    );
    await auth.ensureBootstrapAdmin();

    final jobs = JobRegistry(clock: clock, audit: audit);
    final selfTest = ProxySelfTest(upstreams.docker, clock);
    final health = HealthService(
      config: config,
      upstreams: upstreams,
      clock: clock,
      caches: caches,
      dockerProxy: selfTest,
    );
    final images = ImageUrls.fromConfig(config);
    final remote = remoteFetcher ?? RemoteFetcher.production();
    final seerrIdentity = SeerrIdentityResolver(
      seerr: upstreams.seerr,
      caches: caches,
    );
    final seerrSettings = SeerrPublicSettings(
      seerr: upstreams.seerr,
      caches: caches,
    );
    final jellyfin = JellyfinServerInfo(
      client: upstreams.jellyfin,
      caches: caches,
      configuredAdminUserId: config.jellyfinAdminUserId,
    );
    final imageCache = ImageDiskCache(
      dir: config.imageCacheDir,
      maxBytes: config.imageCache.maxBytes,
      clock: clock,
    );
    await imageCache.scan();
    final imageService = ImageService(
      config: config,
      upstreams: upstreams,
      remote: remote,
      seerrIdentity: seerrIdentity,
      cache: imageCache,
      clock: clock,
    );
    final instanceId = await loadInstanceId(stores);

    final ctx = FeatureContext(
      config: config,
      upstreams: upstreams,
      caches: caches,
      pollers: pollers,
      jobs: jobs,
      audit: audit,
      images: images,
      remoteHttp: remote,
      jellyfin: jellyfin,
      seerrIdentity: seerrIdentity,
      seerrSettings: seerrSettings,
      health: health,
      stores: stores,
      clock: clock,
    );
    final featureModules = modules(ctx);

    final router = ApiRouter(authenticator: auth, auditLog: audit);
    CoreRoutes(
      config: config,
      instanceId: instanceId,
      auth: auth,
      health: health,
      jobs: jobs,
      jellyfin: jellyfin,
      seerrSettings: seerrSettings,
      clock: clock,
    ).register(router);
    AuthRoutes(
      auth: auth,
      seerrIdentity: seerrIdentity,
      audit: audit,
      clock: clock,
    ).register(router);
    AdminRoutes(
      auth: auth,
      audit: audit,
      upstreams: upstreams,
      seerrIdentity: seerrIdentity,
      images: images,
      clock: clock,
    ).register(router);
    imageService.registerRoutes(router);
    DashboardService(
      modules: featureModules,
      clock: clock,
    ).registerRoutes(router);
    for (final m in featureModules) {
      m.registerRoutes(router);
    }

    final handler = buildPipeline(
      config,
      router.handler,
      createWebHandler(config.webDir),
    );
    return Hub._(
      config: config,
      clock: clock,
      stores: stores,
      upstreams: upstreams,
      audit: audit,
      auth: auth,
      jobs: jobs,
      health: health,
      images: images,
      imageService: imageService,
      context: ctx,
      modules: featureModules,
      router: router,
      handler: handler,
      instanceId: instanceId,
      pollers: pollers,
    );
  }

  /// Starts the core background work (proxy self-test, capability probes,
  /// image-cache prune) and the modules' `start()` (only those in [only]
  /// when given).
  Future<void> start({Set<String>? only, bool core = true}) async {
    if (core && !_coreStarted) {
      _coreStarted = true;
      imageService.start();
      unawaited(
        health.start().catchError(
          (Object e) => _log.warning('start-up probes failed', e),
        ),
      );
    }
    for (final m in modules) {
      if (only != null && !only.contains(m.id)) continue;
      if (_started.contains(m)) continue;
      try {
        await m.start();
        _started.add(m);
      } catch (e, st) {
        _log.severe('module ${m.id} failed to start', e, st);
      }
    }
  }

  /// Stops modules and pollers and flushes every store.
  Future<void> stop() async {
    for (final m in _started.reversed) {
      try {
        await m.stop();
      } catch (e, st) {
        _log.warning('module ${m.id} failed to stop', e, st);
      }
    }
    _started.clear();
    _pollers.stopAll();
    health.stop();
    imageService.stop();
    await auth.sessions.flush();
    await stores.closeAll();
    await audit.flush();
    upstreams.close();
  }
}

/// `requestId → hostCheck → accessLog → securityHeaders → cors →
/// errorHandler → router`, with the API router mounted at `/api/v1` (bearer)
/// and `/yh/api/v1` (cookie transport), other `/api/**` and `/yh/**` paths
/// answering JSON 404 and everything else served from the web build.
Handler buildPipeline(HubConfig config, Handler apiRouter, Handler web) {
  final api = const Pipeline()
      .addMiddleware(jsonFinisher())
      .addHandler(apiRouter);
  FutureOr<Response> root(Request r) {
    final path = r.url.path;
    if (path == 'api/v1' || path.startsWith('api/v1/')) {
      return api(r.change(path: 'api/v1'));
    }
    if (path == 'yh/api/v1' || path.startsWith('yh/api/v1/')) {
      return api(
        r.change(path: 'yh/api/v1', context: {ContextKeys.cookieMount: true}),
      );
    }
    if (path == 'api' ||
        path.startsWith('api/') ||
        path == 'yh' ||
        path.startsWith('yh/')) {
      return jsonNotFound(r);
    }
    return web(r);
  }

  return const Pipeline()
      .addMiddleware(requestIdMiddleware(trustProxy: config.trustProxy))
      .addMiddleware(
        hostCheckMiddleware(
          HostAllowList(
            extraHosts: config.allowedHosts,
            publicUrls: config.publicUrls,
          ),
        ),
      )
      .addMiddleware(accessLogMiddleware())
      .addMiddleware(securityHeadersMiddleware())
      .addMiddleware(corsMiddleware(config.corsOrigins))
      .addMiddleware(errorHandlerMiddleware())
      .addHandler(root);
}
