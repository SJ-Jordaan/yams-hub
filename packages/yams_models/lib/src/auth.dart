/// Hub users, sessions, tokens, Seerr identity and the audit log
/// (API.md §2.2, §2.3).
library;

import 'package:meta/meta.dart';

import 'json.dart';

/// Hub role. Role and `disabled` are read from the user store per request.
enum Role {
  admin,
  member,
  unknown;

  bool get isAdmin => this == admin;

  /// Whether a user with this role may call a route that requires [minimum].
  /// [unknown] satisfies nothing.
  bool satisfies(Role minimum) => switch (this) {
    admin => minimum != unknown,
    member => minimum == member,
    unknown => false,
  };

  static Role fromJson(Object? v) => readEnum(v, Role.values, Role.unknown);

  String toJson() => name;
}

/// The platform a session was created from.
enum ClientPlatform {
  android,
  ios,
  web,
  other,
  unknown;

  static ClientPlatform fromJson(Object? v) =>
      readEnum(v, ClientPlatform.values, ClientPlatform.unknown);

  String toJson() => name;
}

/// How a client receives its tokens: in the body or as cookies.
enum AuthTransport {
  token,
  cookie,
  unknown;

  static AuthTransport fromJson(Object? v) =>
      readEnum(v, AuthTransport.values, AuthTransport.unknown);

  String toJson() => name;
}

// ---------------------------------------------------------------------------
// Login and tokens
// ---------------------------------------------------------------------------

/// Body of `POST /auth/login`.
@immutable
final class LoginRequest {
  const LoginRequest({
    required this.username,
    required this.password,
    required this.deviceName,
    required this.platform,
    this.transport = AuthTransport.token,
  });

  factory LoginRequest.fromJson(JsonMap j) => LoginRequest(
    username: req(readString(j['username']), 'username'),
    password: req(readString(j['password']), 'password'),
    deviceName: req(readString(j['deviceName']), 'deviceName'),
    platform: ClientPlatform.fromJson(j['platform']),
    // Missing means the default bearer transport; an unrecognised value
    // stays [AuthTransport.unknown] so the gateway can reject it (400)
    // instead of silently handing out tokens.
    transport: j['transport'] == null
        ? AuthTransport.token
        : AuthTransport.fromJson(j['transport']),
  );

  final String username;
  final String password;

  /// 1..64 characters.
  final String deviceName;
  final ClientPlatform platform;
  final AuthTransport transport;

  JsonMap toJson() => {
    'username': username,
    'password': password,
    'deviceName': deviceName,
    'platform': platform.toJson(),
    'transport': transport.toJson(),
  };

  @override
  String toString() =>
      'LoginRequest(username: $username, deviceName: $deviceName, '
      'platform: ${platform.name}, transport: ${transport.name})';
}

/// An access/refresh token pair. Tokens are opaque to clients.
@immutable
final class TokenPair {
  const TokenPair({
    required this.accessToken,
    required this.accessTokenExpiresAt,
    required this.refreshToken,
    required this.refreshTokenExpiresAt,
  });

  factory TokenPair.fromJson(JsonMap j) => TokenPair(
    accessToken: req(readString(j['accessToken']), 'accessToken'),
    accessTokenExpiresAt: req(
      readInstant(j['accessTokenExpiresAt']),
      'accessTokenExpiresAt',
    ),
    refreshToken: req(readString(j['refreshToken']), 'refreshToken'),
    refreshTokenExpiresAt: req(
      readInstant(j['refreshTokenExpiresAt']),
      'refreshTokenExpiresAt',
    ),
  );

  /// `yha_...`
  final String accessToken;
  final DateTime accessTokenExpiresAt;

  /// `yhr_<sessionId>.<random>`
  final String refreshToken;
  final DateTime refreshTokenExpiresAt;

  JsonMap toJson() => {
    'accessToken': accessToken,
    'accessTokenExpiresAt': instantToJson(accessTokenExpiresAt),
    'refreshToken': refreshToken,
    'refreshTokenExpiresAt': instantToJson(refreshTokenExpiresAt),
  };

  @override
  String toString() =>
      'TokenPair(accessTokenExpiresAt: $accessTokenExpiresAt, '
      'refreshTokenExpiresAt: $refreshTokenExpiresAt)';
}

/// 200 body of `POST /auth/login`.
///
/// [tokens] and [serverProofKey] are present for the bearer transport only.
@immutable
final class LoginResponse {
  const LoginResponse({
    required this.user,
    required this.session,
    this.tokens,
    this.serverProofKey,
  });

  factory LoginResponse.fromJson(JsonMap j) => LoginResponse(
    user: User.fromJson(req(readMap(j['user']), 'user')),
    session: SessionInfo.fromJson(req(readMap(j['session']), 'session')),
    tokens: switch (readMap(j['tokens'])) {
      final m? => TokenPair.fromJson(m),
      null => null,
    },
    serverProofKey: readString(j['serverProofKey']),
  );

  final User user;
  final SessionInfo session;
  final TokenPair? tokens;

  /// 32 random bytes, base64url; verifies `GET /ping` proofs.
  final String? serverProofKey;

  JsonMap toJson() => compactJson({
    'user': user.toJson(),
    'session': session.toJson(),
    'tokens': tokens?.toJson(),
    'serverProofKey': serverProofKey,
  });
}

/// Body of `POST /auth/refresh` (bearer transport; cookie clients send an
/// empty body).
@immutable
final class RefreshRequest {
  const RefreshRequest({this.refreshToken});

  factory RefreshRequest.fromJson(JsonMap j) =>
      RefreshRequest(refreshToken: readString(j['refreshToken']));

  final String? refreshToken;

  JsonMap toJson() => compactJson({'refreshToken': refreshToken});
}

/// 200 body of `POST /auth/refresh` (bearer transport).
@immutable
final class RefreshResponse {
  const RefreshResponse({required this.tokens});

  factory RefreshResponse.fromJson(JsonMap j) => RefreshResponse(
    tokens: TokenPair.fromJson(req(readMap(j['tokens']), 'tokens')),
  );

  final TokenPair tokens;

  JsonMap toJson() => {'tokens': tokens.toJson()};
}

/// Body of `POST /auth/password`.
@immutable
final class ChangePasswordRequest {
  const ChangePasswordRequest({
    required this.currentPassword,
    required this.newPassword,
  });

  factory ChangePasswordRequest.fromJson(JsonMap j) => ChangePasswordRequest(
    currentPassword: req(readString(j['currentPassword']), 'currentPassword'),
    newPassword: req(readString(j['newPassword']), 'newPassword'),
  );

  final String currentPassword;

  /// At least 10 characters.
  final String newPassword;

  JsonMap toJson() => {
    'currentPassword': currentPassword,
    'newPassword': newPassword,
  };

  @override
  String toString() => 'ChangePasswordRequest(<redacted>)';
}

// ---------------------------------------------------------------------------
// Users and sessions
// ---------------------------------------------------------------------------

/// A hub account (never contains the password hash).
@immutable
final class User {
  const User({
    required this.id,
    required this.username,
    required this.displayName,
    required this.role,
    required this.createdAt,
    required this.updatedAt,
    this.jellyfinUserId,
    this.disabled = false,
  });

  factory User.fromJson(JsonMap j) => User(
    id: req(readString(j['id']), 'id'),
    username: req(readString(j['username']), 'username'),
    displayName: readString(j['displayName']) ?? '',
    role: Role.fromJson(j['role']),
    jellyfinUserId: readString(j['jellyfinUserId']),
    disabled: readBool(j['disabled']) ?? false,
    createdAt: req(readInstant(j['createdAt']), 'createdAt'),
    updatedAt: req(readInstant(j['updatedAt']), 'updatedAt'),
  );

  /// `u_<12 hex>`.
  final String id;
  final String username;
  final String displayName;
  final Role role;
  final String? jellyfinUserId;
  final bool disabled;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isAdmin => role.isAdmin;

  JsonMap toJson() => compactJson({
    'id': id,
    'username': username,
    'displayName': displayName,
    'role': role.toJson(),
    'jellyfinUserId': jellyfinUserId,
    'disabled': disabled,
    'createdAt': instantToJson(createdAt),
    'updatedAt': instantToJson(updatedAt),
  });
}

/// A login session (one per device).
@immutable
final class SessionInfo {
  const SessionInfo({
    required this.id,
    required this.userId,
    required this.deviceName,
    required this.platform,
    required this.createdAt,
    required this.lastSeenAt,
    required this.expiresAt,
    this.lastIp,
    this.current = false,
    this.username,
  });

  factory SessionInfo.fromJson(JsonMap j) => SessionInfo(
    id: req(readString(j['id']), 'id'),
    userId: req(readString(j['userId']), 'userId'),
    deviceName: readString(j['deviceName']) ?? '',
    platform: ClientPlatform.fromJson(j['platform']),
    createdAt: req(readInstant(j['createdAt']), 'createdAt'),
    lastSeenAt: req(readInstant(j['lastSeenAt']), 'lastSeenAt'),
    lastIp: readString(j['lastIp']),
    expiresAt: req(readInstant(j['expiresAt']), 'expiresAt'),
    current: readBool(j['current']) ?? false,
    username: readString(j['username']),
  );

  /// `s_<12 hex>`.
  final String id;
  final String userId;
  final String deviceName;
  final ClientPlatform platform;
  final DateTime createdAt;
  final DateTime lastSeenAt;
  final String? lastIp;
  final DateTime expiresAt;

  /// True for the session making the request.
  final bool current;

  /// Only in the admin `?all=true` listing.
  final String? username;

  JsonMap toJson() => compactJson({
    'id': id,
    'userId': userId,
    'deviceName': deviceName,
    'platform': platform.toJson(),
    'createdAt': instantToJson(createdAt),
    'lastSeenAt': instantToJson(lastSeenAt),
    'lastIp': lastIp,
    'expiresAt': instantToJson(expiresAt),
    'current': current,
    'username': username,
  });
}

// ---------------------------------------------------------------------------
// GET /auth/me
// ---------------------------------------------------------------------------

/// One media type's Seerr request quota. A null [limit] means unlimited
/// ([remaining] is then null too).
@immutable
final class QuotaInfo {
  const QuotaInfo({
    this.limit,
    this.days,
    this.used = 0,
    this.remaining,
    this.restricted = false,
  });

  factory QuotaInfo.fromJson(JsonMap j) => QuotaInfo(
    limit: readInt(j['limit']),
    days: readInt(j['days']),
    used: readInt(j['used']) ?? 0,
    remaining: readInt(j['remaining']),
    restricted: readBool(j['restricted']) ?? false,
  );

  final int? limit;
  final int? days;
  final int used;
  final int? remaining;
  final bool restricted;

  bool get isUnlimited => limit == null;

  JsonMap toJson() => compactJson({
    'limit': limit,
    'days': days,
    'used': used,
    'remaining': remaining,
    'restricted': restricted,
  });
}

/// The caller's Seerr quotas.
@immutable
final class SeerrQuota {
  const SeerrQuota({required this.movie, required this.tv});

  factory SeerrQuota.fromJson(JsonMap j) => SeerrQuota(
    movie: QuotaInfo.fromJson(readMap(j['movie']) ?? const {}),
    tv: QuotaInfo.fromJson(readMap(j['tv']) ?? const {}),
  );

  final QuotaInfo movie;
  final QuotaInfo tv;

  JsonMap toJson() => {'movie': movie.toJson(), 'tv': tv.toJson()};
}

/// The `seerr` part of [MeResponse]: the caller's Seerr account link.
@immutable
final class MeSeerrInfo {
  const MeSeerrInfo({
    required this.linked,
    this.seerrUserId,
    this.displayName,
    this.canAutoApprove = false,
    this.quota,
  });

  /// Not linked to any Seerr user.
  const MeSeerrInfo.unlinked()
    : linked = false,
      seerrUserId = null,
      displayName = null,
      canAutoApprove = false,
      quota = null;

  factory MeSeerrInfo.fromJson(JsonMap j) => MeSeerrInfo(
    linked: readBool(j['linked']) ?? false,
    seerrUserId: readInt(j['seerrUserId']),
    displayName: readString(j['displayName']),
    canAutoApprove: readBool(j['canAutoApprove']) ?? false,
    quota: switch (readMap(j['quota'])) {
      final m? => SeerrQuota.fromJson(m),
      null => null,
    },
  );

  final bool linked;
  final int? seerrUserId;
  final String? displayName;
  final bool canAutoApprove;

  /// Absent when unlinked or when the quota call failed.
  final SeerrQuota? quota;

  JsonMap toJson() => compactJson({
    'linked': linked,
    'seerrUserId': seerrUserId,
    'displayName': displayName,
    'canAutoApprove': canAutoApprove,
    'quota': quota?.toJson(),
  });
}

/// 200 body of `GET /auth/me`.
@immutable
final class MeResponse {
  const MeResponse({
    required this.user,
    required this.session,
    this.seerr = const MeSeerrInfo.unlinked(),
  });

  factory MeResponse.fromJson(JsonMap j) => MeResponse(
    user: User.fromJson(req(readMap(j['user']), 'user')),
    session: SessionInfo.fromJson(req(readMap(j['session']), 'session')),
    seerr: switch (readMap(j['seerr'])) {
      final m? => MeSeerrInfo.fromJson(m),
      null => const MeSeerrInfo.unlinked(),
    },
  );

  final User user;
  final SessionInfo session;
  final MeSeerrInfo seerr;

  JsonMap toJson() => {
    'user': user.toJson(),
    'session': session.toJson(),
    'seerr': seerr.toJson(),
  };
}

// ---------------------------------------------------------------------------
// Admin
// ---------------------------------------------------------------------------

/// Body of `POST /admin/users`.
@immutable
final class CreateUserRequest {
  const CreateUserRequest({
    required this.username,
    required this.displayName,
    required this.password,
    required this.role,
    this.jellyfinUserId,
  });

  factory CreateUserRequest.fromJson(JsonMap j) => CreateUserRequest(
    username: req(readString(j['username']), 'username'),
    displayName: req(readString(j['displayName']), 'displayName'),
    password: req(readString(j['password']), 'password'),
    role: Role.fromJson(j['role']),
    jellyfinUserId: readString(j['jellyfinUserId']),
  );

  final String username;
  final String displayName;

  /// At least 10 characters.
  final String password;
  final Role role;
  final String? jellyfinUserId;

  JsonMap toJson() => compactJson({
    'username': username,
    'displayName': displayName,
    'password': password,
    'role': role.toJson(),
    'jellyfinUserId': jellyfinUserId,
  });

  @override
  String toString() =>
      'CreateUserRequest(username: $username, role: ${role.name})';
}

/// Body of `PATCH /admin/users/{id}`; only the fields present are changed.
/// An empty [jellyfinUserId] clears the link.
@immutable
final class UpdateUserRequest {
  const UpdateUserRequest({
    this.displayName,
    this.role,
    this.jellyfinUserId,
    this.disabled,
    this.password,
  });

  factory UpdateUserRequest.fromJson(JsonMap j) => UpdateUserRequest(
    displayName: readString(j['displayName']),
    role: j['role'] == null ? null : Role.fromJson(j['role']),
    jellyfinUserId: readString(j['jellyfinUserId']),
    disabled: readBool(j['disabled']),
    password: readString(j['password']),
  );

  final String? displayName;

  /// [Role.unknown] when the client sent a role this version does not know.
  final Role? role;
  final String? jellyfinUserId;
  final bool? disabled;
  final String? password;

  bool get isEmpty =>
      displayName == null &&
      role == null &&
      jellyfinUserId == null &&
      disabled == null &&
      password == null;

  JsonMap toJson() => compactJson({
    'displayName': displayName,
    'role': role?.toJson(),
    'jellyfinUserId': jellyfinUserId,
    'disabled': disabled,
    'password': password,
  });

  @override
  String toString() =>
      'UpdateUserRequest(displayName: $displayName, role: ${role?.name}, '
      'jellyfinUserId: $jellyfinUserId, disabled: $disabled, '
      'password: ${password == null ? 'unchanged' : '<redacted>'})';
}

/// A Jellyfin user that a hub user can be linked to (`GET /admin/jellyfin-users`).
@immutable
final class JellyfinUserOption {
  const JellyfinUserOption({
    required this.jellyfinUserId,
    required this.name,
    this.isAdministrator = false,
    this.seerrUserId,
    this.seerrDisplayName,
    this.linkedHubUserId,
    this.avatarPath,
  });

  factory JellyfinUserOption.fromJson(JsonMap j) => JellyfinUserOption(
    jellyfinUserId: req(readString(j['jellyfinUserId']), 'jellyfinUserId'),
    name: readString(j['name']) ?? '',
    isAdministrator: readBool(j['isAdministrator']) ?? false,
    seerrUserId: readInt(j['seerrUserId']),
    seerrDisplayName: readString(j['seerrDisplayName']),
    linkedHubUserId: readString(j['linkedHubUserId']),
    avatarPath: readString(j['avatarPath']),
  );

  /// 32 lowercase hex characters.
  final String jellyfinUserId;
  final String name;
  final bool isAdministrator;
  final int? seerrUserId;
  final String? seerrDisplayName;
  final String? linkedHubUserId;

  /// Gateway-relative image path.
  final String? avatarPath;

  JsonMap toJson() => compactJson({
    'jellyfinUserId': jellyfinUserId,
    'name': name,
    'isAdministrator': isAdministrator,
    'seerrUserId': seerrUserId,
    'seerrDisplayName': seerrDisplayName,
    'linkedHubUserId': linkedHubUserId,
    'avatarPath': avatarPath,
  });
}

/// Outcome of an audited action.
enum AuditOutcome {
  ok,
  error,
  unknown;

  static AuditOutcome fromJson(Object? v) =>
      readEnum(v, AuditOutcome.values, AuditOutcome.unknown);

  String toJson() => name;
}

/// One audit log record (`GET /admin/audit`).
@immutable
final class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.at,
    required this.action,
    required this.outcome,
    required this.durationMs,
    this.userId,
    this.username,
    this.sessionId,
    this.ip,
    this.target,
    this.params,
    this.errorCode,
  });

  factory AuditEntry.fromJson(JsonMap j) => AuditEntry(
    id: req(readString(j['id']), 'id'),
    at: req(readInstant(j['at']), 'at'),
    userId: readString(j['userId']),
    username: readString(j['username']),
    sessionId: readString(j['sessionId']),
    ip: readString(j['ip']),
    action: req(readString(j['action']), 'action'),
    target: readString(j['target']),
    params: readMap(j['params']),
    outcome: AuditOutcome.fromJson(j['outcome']),
    errorCode: readString(j['errorCode']),
    durationMs: readInt(j['durationMs']) ?? 0,
  );

  final String id;
  final DateTime at;
  final String? userId;
  final String? username;
  final String? sessionId;
  final String? ip;

  /// `<feature>.<action>`, e.g. `library.series_delete`.
  final String action;
  final String? target;

  /// Sanitised request parameters.
  final JsonMap? params;
  final AuditOutcome outcome;
  final String? errorCode;
  final int durationMs;

  JsonMap toJson() => compactJson({
    'id': id,
    'at': instantToJson(at),
    'userId': userId,
    'username': username,
    'sessionId': sessionId,
    'ip': ip,
    'action': action,
    'target': target,
    'params': params,
    'outcome': outcome.toJson(),
    'errorCode': errorCode,
    'durationMs': durationMs,
  });
}
