/// The resolved connection to the active hub (`activeServerProvider`,
/// ARCHITECTURE §7.2, §7.5).
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_models/yams_models.dart';

import '../auth/token_manager.dart';
import '../refresh/app_lifecycle_provider.dart';
import 'hosting.dart';
import 'network_kind.dart';
import 'server_profile.dart';
import 'server_resolver.dart';
import 'server_store.dart';

/// Bearer tokens on `/api/v1`, or cookies on `/yh/api/v1` (ARCHITECTURE §5.3).
enum ApiTransport {
  bearer('/api/v1'),
  cookie('/yh/api/v1');

  const ApiTransport(this.apiPrefix);

  /// Mount of the API below the hub root.
  final String apiPrefix;
}

enum ConnectionStatus {
  /// No server profile configured (onboarding).
  noProfile,

  /// Probing the profile's URLs.
  resolving,

  /// [ServerConnection.baseUrl] answers (with a valid proof when signed in).
  connected,

  /// No URL answered acceptably.
  unreachable,
}

/// Snapshot of the connection to the active profile.
@immutable
class ServerConnection {
  const ServerConnection({
    required this.status,
    this.profile,
    this.baseUrl,
    this.transport = ApiTransport.bearer,
    this.ping,
    this.proofVerified = false,
    this.failures = const {},
    this.resolvedAt,
  });

  final ConnectionStatus status;
  final ServerProfile? profile;

  /// The hub root in use (`http://192.168.10.183:8090`). Only set once the URL
  /// passed resolution: no request (and no token) goes anywhere before that.
  final Uri? baseUrl;
  final ApiTransport transport;

  /// The last successful ping of [baseUrl].
  final ServerPing? ping;

  /// Whether [baseUrl] passed the server proof in this resolution.
  final bool proofVerified;

  /// Why each URL failed in the last resolution.
  final Map<Uri, String> failures;
  final DateTime? resolvedAt;

  /// Base URL for Dio: the hub root plus the transport's API prefix.
  String? get apiBase {
    final b = baseUrl;
    if (b == null) return null;
    final root = b.toString();
    return '${root.endsWith('/') ? root.substring(0, root.length - 1) : root}${transport.apiPrefix}';
  }

  NetworkKind? get networkKind => baseUrl == null ? null : networkKindOf(baseUrl!);

  bool get isConnected => status == ConnectionStatus.connected && baseUrl != null;

  /// Every URL answered as this hub but none proved it holds the session:
  /// the session was most likely revoked (the gateway omits `proof` for an
  /// unknown session), or an impostor answered. Tokens stay unsent either way.
  bool get proofFailedOnly =>
      status == ConnectionStatus.unreachable &&
      failures.isNotEmpty &&
      failures.values.every((f) => f == ServerResolver.proofFailedMessage);

  ServerConnection copyWith({
    ConnectionStatus? status,
    Uri? baseUrl,
    bool clearBaseUrl = false,
    ServerPing? ping,
    bool? proofVerified,
    Map<Uri, String>? failures,
    DateTime? resolvedAt,
  }) => ServerConnection(
    status: status ?? this.status,
    profile: profile,
    baseUrl: clearBaseUrl ? null : (baseUrl ?? this.baseUrl),
    transport: transport,
    ping: ping ?? this.ping,
    proofVerified: proofVerified ?? this.proofVerified,
    failures: failures ?? this.failures,
    resolvedAt: resolvedAt ?? this.resolvedAt,
  );
}

/// Cookie transport is used when the page origin is the hub origin (web build
/// served by the gateway, or a dev page on the same origin).
ApiTransport transportFor(Uri hubRoot, HostingMode mode) {
  if (mode == HostingMode.native) return ApiTransport.bearer;
  if (mode == HostingMode.gatewayWeb) return ApiTransport.cookie;
  return hubRoot.origin == Uri.base.origin ? ApiTransport.cookie : ApiTransport.bearer;
}

/// Whether the hub of this build uses cookie transport (decided before any
/// profile is resolved: only the gateway-served web build does by default).
bool usesCookieTransport(HostingMode mode, ServerProfile? profile) {
  if (mode == HostingMode.gatewayWeb) return true;
  final url = profile?.urls.firstOrNull;
  return url != null && transportFor(url, mode) == ApiTransport.cookie;
}

/// The ping client used by onboarding and the resolver (overridden in tests).
final serverPingClientProvider = Provider<ServerPingClient>((ref) => DioServerPingClient());

final serverResolverProvider = Provider<ServerResolver>(
  (ref) => ServerResolver(client: ref.watch(serverPingClientProvider)),
);

/// Resolves the active profile: on start, on app resume, on connection
/// errors ([failover]), every 5 min in the foreground, and with back-off while
/// unreachable.
class ActiveServerController extends Notifier<ServerConnection> {
  /// [fixed] pins the connection (tests): no resolution ever runs.
  ActiveServerController({this.fixed});

  final ServerConnection? fixed;

  static const foregroundInterval = Duration(minutes: 5);
  static const _retryDelays = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];

  Future<void>? _inFlight;
  Timer? _timer;
  int _failures = 0;

  /// Set once a LAN URL passed the server proof in this app session; until
  /// then the network is not known to be home and Tailscale URLs go first.
  static bool _homeVerified = false;

  @override
  ServerConnection build() {
    final pinned = fixed;
    if (pinned != null) return pinned;

    final mode = ref.watch(hostingModeProvider);
    // Rebuild only when the URLs change, not when the resolver records the
    // last good URL.
    ref.watch(serverStoreProvider.select((s) => s.active?.resolutionKey));
    final profile = ref.read(serverStoreProvider).active;
    ref.onDispose(() => _timer?.cancel());

    if (profile == null) return const ServerConnection(status: ConnectionStatus.noProfile);

    if (mode == HostingMode.gatewayWeb) {
      // Same origin: nothing to probe or prove.
      return ServerConnection(
        status: ConnectionStatus.connected,
        profile: profile,
        baseUrl: profile.urls.first,
        transport: ApiTransport.cookie,
      );
    }

    ref.listen<AppLifecycleState>(appLifecycleProvider, (previous, next) {
      if (next == AppLifecycleState.resumed && previous != AppLifecycleState.resumed) {
        unawaited(resolve());
      } else if (next != AppLifecycleState.resumed) {
        _timer?.cancel();
      }
    });

    _failures = 0;
    Future.microtask(resolve);
    return ServerConnection(
      status: ConnectionStatus.resolving,
      profile: profile,
      transport: transportFor(profile.urls.firstOrNull ?? Uri.base, mode),
    );
  }

  /// Re-probes the active profile (single flight).
  Future<void> resolve() {
    if (fixed != null ||
        state.profile == null ||
        ref.read(hostingModeProvider) == HostingMode.gatewayWeb) {
      return Future.value();
    }
    return _inFlight ??= _resolve().whenComplete(() => _inFlight = null);
  }

  /// Called by the failover interceptor: re-probe and return the API base to
  /// retry against (null when nothing is reachable).
  Future<String?> failover() async {
    await resolve();
    return state.apiBase;
  }

  /// The API base once the current resolution has finished: requests made
  /// while the app is still probing (cold start, profile switch) wait for it
  /// instead of failing with `no_server`. Null when no URL is usable.
  Future<String?> settledApiBase() async {
    if (state.status == ConnectionStatus.resolving && state.baseUrl == null) await resolve();
    return state.apiBase;
  }

  Future<void> _resolve() async {
    final profile = state.profile;
    if (profile == null) return;
    if (state.status != ConnectionStatus.connected) {
      state = state.copyWith(status: ConnectionStatus.resolving);
    }
    final tokens = ref.read(tokenManagerProvider);
    // The proof must use this profile's session, never the previous one's.
    // The stored profile may have learned its instance id since this
    // controller was built (first ping, login); without one there is no
    // session to load, and activating "nothing" would drop a fresh sign-in.
    final instanceId = ref.read(serverStoreProvider).byId(profile.id)?.instanceId ?? profile.instanceId;
    if (instanceId != null) await tokens.activate(instanceId);
    if (!ref.mounted || state.profile?.id != profile.id) return;
    final result = await ref
        .read(serverResolverProvider)
        .resolve(profile, proof: tokens.proofCredentials, homeVerified: _homeVerified);
    if (!ref.mounted || state.profile?.id != profile.id) return;

    _timer?.cancel();
    if (result.ok) {
      final url = result.url!;
      if (result.proofVerified && !isTailscaleHost(url.host)) _homeVerified = true;
      _failures = 0;
      state = state.copyWith(
        status: ConnectionStatus.connected,
        baseUrl: url,
        ping: result.ping,
        proofVerified: result.proofVerified,
        failures: result.failures,
        resolvedAt: DateTime.now(),
      );
      ref.read(serverStoreProvider.notifier).recordGoodUrl(profile.id, url, instanceId: result.ping?.instanceId);
      _schedule(foregroundInterval);
    } else {
      // Never keep sending tokens to a URL that failed (possibly the proof).
      state = state.copyWith(
        status: ConnectionStatus.unreachable,
        clearBaseUrl: true,
        proofVerified: false,
        failures: result.failures,
        resolvedAt: DateTime.now(),
      );
      _schedule(_retryDelays[_failures.clamp(0, _retryDelays.length - 1)]);
      _failures++;
    }
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    if (ref.read(appLifecycleProvider) != AppLifecycleState.resumed) return;
    _timer = Timer(delay, () {
      if (ref.mounted) unawaited(resolve());
    });
  }

  /// Forgets the "home network verified" flag (tests).
  @visibleForTesting
  static void resetHomeVerified() => _homeVerified = false;
}

/// The connection to the active hub.
final activeServerProvider = NotifierProvider<ActiveServerController, ServerConnection>(
  ActiveServerController.new,
);
