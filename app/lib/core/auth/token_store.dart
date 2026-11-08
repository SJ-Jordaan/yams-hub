/// Token persistence (ARCHITECTURE §7.6).
///
/// Native: flutter_secure_storage 11 (Keychain `first_unlock_this_device`,
/// Android's custom cipher) under `tokens.<instanceId>`. Web: a no-op store
/// with cookie transport, or memory + sessionStorage in dev.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:yams_models/yams_models.dart';

import 'token_store_io.dart' if (dart.library.js_interop) 'token_store_web.dart' as platform;

/// The tokens of one session, stored as JSON
/// `{accessToken, accessTokenExpiresAt, refreshToken, refreshTokenExpiresAt, sessionId, serverProofKey}`.
@immutable
class StoredTokens {
  const StoredTokens({
    required this.accessToken,
    required this.accessTokenExpiresAt,
    required this.refreshToken,
    required this.refreshTokenExpiresAt,
    required this.sessionId,
    this.serverProofKey,
  });

  factory StoredTokens.fromPair(TokenPair pair, {required String sessionId, String? serverProofKey}) =>
      StoredTokens(
        accessToken: pair.accessToken,
        accessTokenExpiresAt: pair.accessTokenExpiresAt,
        refreshToken: pair.refreshToken,
        refreshTokenExpiresAt: pair.refreshTokenExpiresAt,
        sessionId: sessionId,
        serverProofKey: serverProofKey,
      );

  factory StoredTokens.fromJson(JsonMap j) => StoredTokens(
    accessToken: req(readString(j['accessToken']), 'accessToken'),
    accessTokenExpiresAt: req(readInstant(j['accessTokenExpiresAt']), 'accessTokenExpiresAt'),
    refreshToken: req(readString(j['refreshToken']), 'refreshToken'),
    refreshTokenExpiresAt: req(readInstant(j['refreshTokenExpiresAt']), 'refreshTokenExpiresAt'),
    sessionId: req(readString(j['sessionId']), 'sessionId'),
    serverProofKey: readString(j['serverProofKey']),
  );

  final String accessToken;
  final DateTime accessTokenExpiresAt;
  final String refreshToken;
  final DateTime refreshTokenExpiresAt;
  final String sessionId;

  /// Per-session server proof key (bearer transport only).
  final String? serverProofKey;

  /// Whether the refresh token can still be used at [now].
  bool canRefreshAt(DateTime now) => refreshTokenExpiresAt.isAfter(now);

  /// A copy with a rotated token pair (session and proof key unchanged).
  StoredTokens rotated(TokenPair pair) =>
      StoredTokens.fromPair(pair, sessionId: sessionId, serverProofKey: serverProofKey);

  JsonMap toJson() => compactJson({
    'accessToken': accessToken,
    'accessTokenExpiresAt': instantToJson(accessTokenExpiresAt),
    'refreshToken': refreshToken,
    'refreshTokenExpiresAt': instantToJson(refreshTokenExpiresAt),
    'sessionId': sessionId,
    'serverProofKey': serverProofKey,
  });
}

/// Reads and writes [StoredTokens] per gateway instance.
abstract interface class TokenStore {
  Future<StoredTokens?> read(String instanceId);
  Future<void> write(String instanceId, StoredTokens tokens);
  Future<void> delete(String instanceId);
}

/// A string key-value backend (secure storage, sessionStorage, memory).
abstract interface class TokenBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// [TokenStore] over a [TokenBackend]: key `tokens.<instanceId>`, JSON value.
/// A corrupt value reads as "no tokens" (and is removed).
class BackendTokenStore implements TokenStore {
  BackendTokenStore(this.backend);

  final TokenBackend backend;

  static String keyFor(String instanceId) => 'tokens.$instanceId';

  @override
  Future<StoredTokens?> read(String instanceId) async {
    final key = keyFor(instanceId);
    final raw = await backend.read(key);
    if (raw == null) return null;
    try {
      final map = readMap(jsonDecode(raw));
      if (map != null) return StoredTokens.fromJson(map);
    } on FormatException {
      // fall through
    }
    await backend.delete(key);
    return null;
  }

  @override
  Future<void> write(String instanceId, StoredTokens tokens) =>
      backend.write(keyFor(instanceId), jsonEncode(tokens.toJson()));

  @override
  Future<void> delete(String instanceId) => backend.delete(keyFor(instanceId));
}

/// In-memory backend (tests, and the memory half of the dev web store).
class MemoryTokenBackend implements TokenBackend {
  MemoryTokenBackend([Map<String, String>? initial]) : values = {...?initial};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Stores nothing: the gateway-served web build keeps its session in
/// HttpOnly cookies the app cannot (and need not) read.
class NoopTokenStore implements TokenStore {
  const NoopTokenStore();

  @override
  Future<StoredTokens?> read(String instanceId) async => null;

  @override
  Future<void> write(String instanceId, StoredTokens tokens) async {}

  @override
  Future<void> delete(String instanceId) async {}
}

/// The platform token store: [NoopTokenStore] for cookie transport, else
/// secure storage (native) or memory + sessionStorage (dev web).
TokenStore createTokenStore({required bool cookieTransport}) =>
    cookieTransport ? const NoopTokenStore() : platform.createPlatformTokenStore();
