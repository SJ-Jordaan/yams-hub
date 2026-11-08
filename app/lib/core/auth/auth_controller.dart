/// Sign-in state, login and logout (ARCHITECTURE §7.2, APP.md §3.2).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_models/yams_models.dart';

import '../api/api_client.dart';
import '../api/core_api.dart';
import '../platform/platform.dart';
import '../servers/server_connection.dart';
import '../servers/server_store.dart';
import 'token_manager.dart';
import 'token_store.dart';

/// Whether the user is signed in to the active server, and as whom.
///
/// Derived from the [TokenManager], which `main()` loads before `runApp`, so
/// the router knows it synchronously. [user] is the last known user (cached
/// across restarts; refreshed by [meProvider]); it can be null right after an
/// upgrade until `/auth/me` answers.
@immutable
class AuthState {
  const AuthState({required this.signedIn, this.user});

  const AuthState.signedOut() : signedIn = false, user = null;

  final bool signedIn;
  final User? user;

  Role get role => user?.role ?? Role.unknown;
  bool get isAdmin => signedIn && role.isAdmin;

  @override
  bool operator ==(Object other) =>
      other is AuthState &&
      other.signedIn == signedIn &&
      other.user?.id == user?.id &&
      other.user?.role == user?.role &&
      other.user?.displayName == user?.displayName;

  @override
  int get hashCode => Object.hash(signedIn, user?.id, user?.role, user?.displayName);
}

class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() {
    final tokens = ref.watch(tokenManagerProvider);
    void sync() => state = _snapshot(tokens);
    tokens.addListener(sync);
    ref.onDispose(() => tokens.removeListener(sync));

    // Switching profiles loads the other profile's session.
    ref.listen(activeProfileProvider.select((p) => p?.instanceId), (previous, next) {
      if (previous != next) unawaited(tokens.activate(next));
    });
    return _snapshot(tokens);
  }

  AuthState _snapshot(TokenManager tokens) =>
      tokens.hasSession ? AuthState(signedIn: true, user: tokens.user) : const AuthState.signedOut();

  /// `POST /auth/login` on the active server. Throws [ApiException]
  /// (`invalid_credentials`, `rate_limited`, network, ...).
  Future<void> login({
    required String username,
    required String password,
    required String deviceName,
  }) async {
    final connection = ref.read(activeServerProvider);
    var server = connection;
    if (!server.isConnected) {
      await ref.read(activeServerProvider.notifier).resolve();
      server = ref.read(activeServerProvider);
    }
    final profile = server.profile;
    if (!server.isConnected || profile == null) throw const ApiException.network();

    final cookie = server.transport == ApiTransport.cookie;
    final response = await ref
        .read(coreApiProvider)
        .login(
          LoginRequest(
            username: username.trim(),
            password: password,
            deviceName: deviceName,
            platform: clientPlatform,
            transport: cookie ? AuthTransport.cookie : AuthTransport.token,
          ),
        );

    final tokenManager = ref.read(tokenManagerProvider);
    final scope = profile.instanceId ?? server.ping?.instanceId ?? profile.id;
    if (cookie) {
      await tokenManager.signIn(scope: scope, user: response.user);
    } else {
      final pair = response.tokens;
      if (pair == null) {
        throw const ApiException(
          status: 0,
          code: ClientErrorCode.badResponse,
          message: 'The hub did not return tokens.',
        );
      }
      await tokenManager.signIn(
        scope: scope,
        user: response.user,
        tokens: StoredTokens.fromPair(
          pair,
          sessionId: response.session.id,
          serverProofKey: response.serverProofKey,
        ),
      );
      // Verify the server proof now that a key exists.
      unawaited(ref.read(activeServerProvider.notifier).resolve());
    }
  }

  /// `POST /auth/logout` (best effort), then forgets the session locally.
  Future<void> logout() async {
    try {
      await ref.read(coreApiProvider).logout();
    } on ApiException {
      // Signed out locally either way.
    }
    await ref.read(tokenManagerProvider).clear();
  }

  /// Applies a fresher copy of the signed-in user.
  Future<void> updateUser(User user) => ref.read(tokenManagerProvider).saveUser(user);
}

final authControllerProvider = NotifierProvider<AuthController, AuthState>(AuthController.new);

/// Whether the signed-in user is an admin (admin-only UI is hidden, not
/// disabled, for members).
final isAdminProvider = Provider<bool>((ref) => ref.watch(authControllerProvider).isAdmin);

/// `GET /auth/me`: user, role, session, Seerr link and quota. Keeps the cached
/// user (and so the role) in sync.
final meProvider = FutureProvider<MeResponse>((ref) async {
  final signedIn = ref.watch(authControllerProvider.select((s) => s.signedIn));
  // Signed out: nothing to ask (and no anonymous 401 to provoke).
  if (!signedIn) {
    throw const ApiException(status: 401, code: ApiErrorCode.unauthorized, message: 'Not signed in.');
  }
  final me = await ref.watch(coreApiProvider).me();
  await ref.read(authControllerProvider.notifier).updateUser(me.user);
  return me;
});
