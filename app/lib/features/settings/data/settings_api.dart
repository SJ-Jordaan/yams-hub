/// Typed wrapper over the account and admin endpoints used by Settings
/// (API.md §2.2, §2.3). Widgets never touch Dio directly.
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_models/yams_models.dart';

/// Query filters of `GET /admin/audit`.
class AuditFilter {
  const AuditFilter({this.userId, this.actionPrefix, this.outcome});

  final String? userId;

  /// Prefix match on `action` (`library.`, `auth.login`).
  final String? actionPrefix;
  final AuditOutcome? outcome;

  bool get isEmpty => userId == null && (actionPrefix ?? '').isEmpty && outcome == null;

  AuditFilter copyWith({
    String? Function()? userId,
    String? Function()? actionPrefix,
    AuditOutcome? Function()? outcome,
  }) => AuditFilter(
    userId: userId == null ? this.userId : userId(),
    actionPrefix: actionPrefix == null ? this.actionPrefix : actionPrefix(),
    outcome: outcome == null ? this.outcome : outcome(),
  );

  @override
  bool operator ==(Object other) =>
      other is AuditFilter &&
      other.userId == userId &&
      other.actionPrefix == actionPrefix &&
      other.outcome == outcome;

  @override
  int get hashCode => Object.hash(userId, actionPrefix, outcome);
}

class SettingsApi {
  SettingsApi(this.dio);

  final Dio dio;

  /// Page size of the audit log (the gateway allows up to 200).
  static const auditPageSize = 50;

  // --- account ----------------------------------------------------------------

  /// `POST /auth/password`. Revokes the user's other sessions.
  Future<void> changePassword({required String currentPassword, required String newPassword}) async {
    await dio.postMap(
      '/auth/password',
      body: ChangePasswordRequest(currentPassword: currentPassword, newPassword: newPassword).toJson(),
    );
  }

  /// `GET /auth/sessions` (own), or every session with `?all=true` (admins).
  Future<List<SessionInfo>> sessions({bool all = false}) => dio.getModel(
    '/auth/sessions',
    (j) => ItemList.fromJson(j, SessionInfo.fromJson).items,
    query: {'all': all ? 'true' : null},
  );

  /// `DELETE /auth/sessions/{id}`.
  Future<void> revokeSession(String id) async {
    await dio.deleteMap('/auth/sessions/${Uri.encodeComponent(id)}');
  }

  // --- users (admin) ------------------------------------------------------------

  /// `GET /admin/users`.
  Future<List<User>> users() =>
      dio.getModel('/admin/users', (j) => ItemList.fromJson(j, User.fromJson).items);

  /// `POST /admin/users`.
  Future<User> createUser(CreateUserRequest request) async =>
      User.fromJson(await dio.postMap('/admin/users', body: request.toJson()));

  /// `PATCH /admin/users/{id}`.
  Future<User> updateUser(String id, UpdateUserRequest request) async =>
      User.fromJson(await dio.patchMap('/admin/users/${Uri.encodeComponent(id)}', body: request.toJson()));

  /// `DELETE /admin/users/{id}?confirm=true` (sent after the user confirmed).
  Future<void> deleteUser(String id) async {
    await dio.deleteMap('/admin/users/${Uri.encodeComponent(id)}', query: {'confirm': 'true'});
  }

  /// `GET /admin/jellyfin-users`.
  Future<List<JellyfinUserOption>> jellyfinUsers() => dio.getModel(
    '/admin/jellyfin-users',
    (j) => ItemList.fromJson(j, JellyfinUserOption.fromJson).items,
  );

  /// `POST /admin/jellyfin-users/{id}/import-to-seerr`: the re-read option
  /// (with `seerrUserId` now set).
  Future<JellyfinUserOption> importToSeerr(String jellyfinUserId) async => JellyfinUserOption.fromJson(
    await dio.postMap('/admin/jellyfin-users/${Uri.encodeComponent(jellyfinUserId)}/import-to-seerr'),
  );

  // --- audit (admin) ------------------------------------------------------------

  /// `GET /admin/audit`, newest first.
  Future<PagedList<AuditEntry>> audit({required int page, AuditFilter filter = const AuditFilter()}) =>
      dio.getModel(
        '/admin/audit',
        (j) => PagedList.fromJson(j, AuditEntry.fromJson),
        query: {
          'page': page,
          'pageSize': auditPageSize,
          'userId': filter.userId,
          'action': (filter.actionPrefix ?? '').trim().isEmpty ? null : filter.actionPrefix!.trim(),
          'outcome': filter.outcome?.toJson(),
        },
      );
}

final settingsApiProvider = Provider<SettingsApi>((ref) => SettingsApi(ref.watch(dioProvider)));
