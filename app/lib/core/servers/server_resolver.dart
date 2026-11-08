/// Picks the URL of a server profile to talk to (ARCHITECTURE §7.5):
/// happy-eyeballs pings, instance id match, and the server proof before any
/// token is sent to a non-Tailscale URL.
library;

import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:yams_models/yams_models.dart';

import '../api/api_exception.dart';
import '../app_info.dart';
import 'network_kind.dart';
import 'server_profile.dart';
import 'server_proof.dart';

/// Sends `GET /api/v1/ping` to a hub root URL.
abstract interface class ServerPingClient {
  /// Pings [base] (a hub root such as `http://192.168.10.183:8090`). Throws an
  /// [ApiException] on failure.
  Future<ServerPing> ping(Uri base, {String? nonce, String? sessionId, Duration? timeout});
}

/// [ServerPingClient] over a bare Dio (no auth, no interceptors).
class DioServerPingClient implements ServerPingClient {
  DioServerPingClient({this._adapter});

  final HttpClientAdapter? _adapter;

  @override
  Future<ServerPing> ping(Uri base, {String? nonce, String? sessionId, Duration? timeout}) async {
    final t = timeout ?? const Duration(milliseconds: 1500);
    final dio = Dio(
      BaseOptions(
        connectTimeout: t,
        receiveTimeout: t,
        sendTimeout: t,
        responseType: ResponseType.json,
        headers: {'X-YAMS-Client': hubClientHeader},
      ),
    );
    final adapter = _adapter;
    if (adapter != null) dio.httpClientAdapter = adapter;
    try {
      final res = await dio.getUri<Object?>(
        base.replace(
          path: '/api/v1/ping',
          queryParameters: {'nonce': ?nonce, 'sid': ?sessionId},
        ),
      );
      final body = readMap(res.data);
      if (body == null) throw const FormatException('ping body');
      return ServerPing.fromJson(body);
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    } on FormatException {
      throw const ApiException(
        status: 0,
        code: ClientErrorCode.badResponse,
        message: 'This address does not answer like a YAMS Hub.',
      );
    } finally {
      // A shared test adapter must stay open.
      if (adapter == null) dio.close();
    }
  }
}

/// What the resolver needs to verify the server proof: the session id and
/// the per-session key from the login response.
@immutable
class ProofCredentials {
  const ProofCredentials({required this.sessionId, required this.serverProofKey});

  final String sessionId;
  final String serverProofKey;
}

/// Outcome of [ServerResolver.resolve].
@immutable
class ResolveResult {
  const ResolveResult.success(Uri this.url, ServerPing this.ping, {required this.proofVerified})
    : failures = const {};

  const ResolveResult.failure(this.failures) : url = null, ping = null, proofVerified = false;

  /// The winning hub root URL; null when nothing answered acceptably.
  final Uri? url;
  final ServerPing? ping;

  /// True when [url] passed the server proof (false for Tailscale URLs and
  /// before login, where no proof is required).
  final bool proofVerified;

  /// Why each tried URL was rejected.
  final Map<Uri, String> failures;

  bool get ok => url != null;
}

/// Happy-eyeballs resolution of a [ServerProfile].
class ServerResolver {
  ServerResolver({
    required this._client,
    this.timeout = const Duration(milliseconds: 1500),
    this.stagger = const Duration(milliseconds: 300),
    Random? random,
  }) : _random = random ?? Random.secure();

  final ServerPingClient _client;
  final Duration timeout;
  final Duration stagger;
  final Random _random;

  /// The URLs of [profile] in the order they are tried: [ServerProfile.lastGoodUrl]
  /// first, then the profile order. When the current network is not known to
  /// be home ([preferTailscale]), Tailscale URLs move to the front.
  static List<Uri> candidateOrder(ServerProfile profile, {required bool preferTailscale}) {
    final ordered = <Uri>[];
    void add(Uri? u) {
      if (u != null && !ordered.contains(u)) ordered.add(u);
    }

    add(profile.lastGoodUrl);
    profile.urls.forEach(add);
    if (!preferTailscale) return ordered;
    return [
      ...ordered.where((u) => isTailscaleHost(u.host)),
      ...ordered.where((u) => !isTailscaleHost(u.host)),
    ];
  }

  /// Pings every candidate URL, started [stagger] apart; the first acceptable
  /// answer wins. With [proof], a non-Tailscale URL is accepted only if its
  /// `proof` verifies; a missing or wrong proof counts as unreachable.
  Future<ResolveResult> resolve(
    ServerProfile profile, {
    ProofCredentials? proof,
    bool homeVerified = false,
  }) async {
    final candidates = candidateOrder(profile, preferTailscale: !homeVerified);
    if (candidates.isEmpty) return const ResolveResult.failure({});

    final completer = Completer<ResolveResult>();
    final failures = <Uri, String>{};
    final timers = <Timer>[];
    var outstanding = candidates.length;

    Future<void> probe(Uri url) async {
      final needsProof = proof != null && !isTailscaleHost(url.host);
      final nonce = needsProof ? generateProofNonce(_random) : null;
      try {
        final ping = await _client.ping(
          url,
          nonce: nonce,
          sessionId: needsProof ? proof.sessionId : null,
          timeout: timeout,
        );
        final problem = _check(profile, ping, needsProof ? proof : null, nonce);
        if (problem == null) {
          if (!completer.isCompleted) {
            completer.complete(ResolveResult.success(url, ping, proofVerified: needsProof));
          }
        } else {
          failures[url] = problem;
          if (problem == proofFailedMessage) debugPrint('YAMS Hub: server proof failed for $url');
        }
      } on ApiException catch (e) {
        failures[url] = e.message;
      } catch (e) {
        failures[url] = 'Unexpected answer.';
      } finally {
        outstanding--;
        if (outstanding == 0 && !completer.isCompleted) {
          completer.complete(ResolveResult.failure(Map.of(failures)));
        }
      }
    }

    for (var i = 0; i < candidates.length; i++) {
      final url = candidates[i];
      if (i == 0) {
        unawaited(probe(url));
      } else {
        timers.add(Timer(stagger * i, () => unawaited(probe(url))));
      }
    }
    final result = await completer.future;
    for (final t in timers) {
      t.cancel();
    }
    return result;
  }

  /// The failure recorded for a URL whose server proof was missing or wrong.
  static const proofFailedMessage = 'Server proof failed.';

  String? _check(ServerProfile profile, ServerPing ping, ProofCredentials? proof, String? nonce) {
    if (ping.name != 'yams-hub') return 'Not a YAMS Hub.';
    final expected = profile.instanceId;
    if (expected != null && ping.instanceId != expected) return 'A different hub answered.';
    if (proof != null) {
      final p = ping.proof;
      if (p == null || nonce == null) return proofFailedMessage;
      if (!verifyServerProof(serverProofKey: proof.serverProofKey, nonce: nonce, proof: p)) {
        return proofFailedMessage;
      }
    }
    return null;
  }
}
