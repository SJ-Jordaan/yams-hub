/// Stored user and session records (ARCHITECTURE §5.4). These contain secrets
/// (password hashes, refresh hashes, proof keys) and never leave the gateway;
/// the DTOs are [User] and [SessionInfo].
library;

import 'package:yams_models/yams_models.dart';

/// A hub account as stored in `users.json`.
final class UserRecord {
  const UserRecord({
    required this.id,
    required this.username,
    required this.displayName,
    required this.role,
    required this.passwordHash,
    required this.createdAt,
    required this.updatedAt,
    this.jellyfinUserId,
    this.disabled = false,
  });

  factory UserRecord.fromJson(JsonMap j) => UserRecord(
    id: req(readString(j['id']), 'id'),
    username: req(readString(j['username']), 'username'),
    displayName: readString(j['displayName']) ?? '',
    role: Role.fromJson(j['role']),
    passwordHash: readString(j['passwordHash']) ?? '',
    jellyfinUserId: readString(j['jellyfinUserId']),
    createdAt: req(readInstant(j['createdAt']), 'createdAt'),
    updatedAt: req(readInstant(j['updatedAt']), 'updatedAt'),
    disabled: readBool(j['disabled']) ?? false,
  );

  /// `u_<12 hex>`.
  final String id;

  /// Lower case, `^[a-z0-9._-]{2,32}$`.
  final String username;
  final String displayName;
  final Role role;

  /// `pbkdf2-sha256$<iterations>$<salt>$<hash>`.
  final String passwordHash;
  final String? jellyfinUserId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool disabled;

  bool get isAdmin => role == Role.admin;
  bool get isActiveAdmin => isAdmin && !disabled;

  UserRecord copyWith({
    String? displayName,
    Role? role,
    String? passwordHash,
    String? jellyfinUserId,
    bool clearJellyfinUserId = false,
    bool? disabled,
    required DateTime updatedAt,
  }) => UserRecord(
    id: id,
    username: username,
    displayName: displayName ?? this.displayName,
    role: role ?? this.role,
    passwordHash: passwordHash ?? this.passwordHash,
    jellyfinUserId: clearJellyfinUserId
        ? null
        : (jellyfinUserId ?? this.jellyfinUserId),
    createdAt: createdAt,
    updatedAt: updatedAt,
    disabled: disabled ?? this.disabled,
  );

  /// The public DTO (no password hash).
  User toDto() => User(
    id: id,
    username: username,
    displayName: displayName,
    role: role,
    jellyfinUserId: jellyfinUserId,
    disabled: disabled,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  JsonMap toJson() => compactJson({
    'id': id,
    'username': username,
    'displayName': displayName,
    'role': role.toJson(),
    'passwordHash': passwordHash,
    'jellyfinUserId': jellyfinUserId,
    'createdAt': instantToJson(createdAt),
    'updatedAt': instantToJson(updatedAt),
    'disabled': disabled,
  });
}

/// A login session as stored in `sessions.json`.
final class SessionRecord {
  SessionRecord({
    required this.id,
    required this.userId,
    required this.deviceName,
    required this.platform,
    required this.createdAt,
    required this.lastSeenAt,
    required this.refreshHash,
    required this.expiresAt,
    required this.proofKey,
    this.lastIp,
    this.prevRefreshHash,
    this.prevValidUntil,
  });

  factory SessionRecord.fromJson(JsonMap j) => SessionRecord(
    id: req(readString(j['id']), 'id'),
    userId: req(readString(j['userId']), 'userId'),
    deviceName: readString(j['deviceName']) ?? '',
    platform: ClientPlatform.fromJson(j['platform']),
    createdAt: req(readInstant(j['createdAt']), 'createdAt'),
    lastSeenAt: req(readInstant(j['lastSeenAt']), 'lastSeenAt'),
    lastIp: readString(j['lastIp']),
    refreshHash: req(readString(j['refreshHash']), 'refreshHash'),
    prevRefreshHash: readString(j['prevRefreshHash']),
    prevValidUntil: readInstant(j['prevValidUntil']),
    expiresAt: req(readInstant(j['expiresAt']), 'expiresAt'),
    proofKey: req(readString(j['proofKey']), 'proofKey'),
  );

  /// `s_<12 hex>`.
  final String id;
  final String userId;
  final String deviceName;
  final ClientPlatform platform;
  final DateTime createdAt;
  DateTime lastSeenAt;
  String? lastIp;

  /// sha256 (hex) of the current refresh token.
  String refreshHash;

  /// sha256 of the previous refresh token, valid until [prevValidUntil].
  String? prevRefreshHash;
  DateTime? prevValidUntil;

  /// Sliding expiry of the refresh token.
  DateTime expiresAt;

  /// Per-session server proof key (32 random bytes, base64url).
  final String proofKey;

  bool isExpired(DateTime now) => !now.isBefore(expiresAt);

  SessionInfo toDto({bool current = false, String? username}) => SessionInfo(
    id: id,
    userId: userId,
    deviceName: deviceName,
    platform: platform,
    createdAt: createdAt,
    lastSeenAt: lastSeenAt,
    lastIp: lastIp,
    expiresAt: expiresAt,
    current: current,
    username: username,
  );

  JsonMap toJson() => compactJson({
    'id': id,
    'userId': userId,
    'deviceName': deviceName,
    'platform': platform.toJson(),
    'createdAt': instantToJson(createdAt),
    'lastSeenAt': instantToJson(lastSeenAt),
    'lastIp': lastIp,
    'refreshHash': refreshHash,
    'prevRefreshHash': prevRefreshHash,
    'prevValidUntil': optionalInstantToJson(prevValidUntil),
    'expiresAt': instantToJson(expiresAt),
    'proofKey': proofKey,
  });
}

/// The authenticated caller of a request.
final class Principal {
  const Principal({
    required this.user,
    required this.session,
    required this.viaCookie,
  });

  /// Loaded from the user store for this request.
  final UserRecord user;
  final SessionRecord session;

  /// Authenticated with the `yh_at` cookie (CSRF rules apply).
  final bool viaCookie;
}
