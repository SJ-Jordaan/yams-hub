/// `/admin/**` (API.md §2.3).
library;

import 'package:shelf/shelf.dart';
import 'package:yams_models/yams_models.dart';

import '../../config/config.dart';
import '../audit/audit_log.dart';
import '../auth/auth_routes.dart';
import '../auth/auth_service.dart';
import '../auth/records.dart';
import '../auth/user_store.dart';
import '../clock.dart';
import '../http/api_exception.dart';
import '../http/api_request.dart';
import '../http/api_response.dart';
import '../http/api_router.dart';
import '../images/image_urls.dart';
import '../services/seerr_identity.dart';
import '../upstream/upstream_exception.dart';
import '../upstream/upstreams.dart';

/// User administration, Jellyfin/Seerr linking and the audit log.
final class AdminRoutes {
  AdminRoutes({
    required this.auth,
    required this.audit,
    required this.upstreams,
    required this.seerrIdentity,
    required this.images,
    required this.clock,
  });

  final AuthService auth;
  final AuditLog audit;
  final Upstreams upstreams;
  final SeerrIdentityResolver seerrIdentity;
  final ImageUrls images;
  final Clock clock;

  UserStore get _users => auth.users;

  void register(ApiRouter r) {
    const admin = Role.admin;
    r
      ..get('/admin/users', _listUsers, role: admin)
      ..post('/admin/users', _createUser, role: admin)
      ..patch('/admin/users/<id|u_[0-9a-f]{12}>', _updateUser, role: admin)
      ..delete('/admin/users/<id|u_[0-9a-f]{12}>', _deleteUser, role: admin)
      ..get('/admin/jellyfin-users', _jellyfinUsers, role: admin)
      ..post(
        '/admin/jellyfin-users/<jellyfinUserId|[0-9A-Fa-f-]{32,36}>/import-to-seerr',
        _importToSeerr,
        role: admin,
      )
      ..get('/admin/audit', _audit, role: admin);
  }

  Future<Response> _listUsers(ApiRequest req) async =>
      ApiResponse.items(_users.all.map((u) => u.toDto()), (u) => u.toJson());

  String? _validJellyfinId(Object? v, List<ApiFieldError> fields) {
    if (v == null) return null;
    if (v is! String) {
      fields.add(
        const ApiFieldError(
          field: 'jellyfinUserId',
          message: 'Must be a Jellyfin user id',
        ),
      );
      return null;
    }
    if (v.isEmpty) return '';
    final n = normaliseJellyfinId(v);
    if (n == null) {
      fields.add(
        const ApiFieldError(
          field: 'jellyfinUserId',
          message: 'Must be a Jellyfin user id',
        ),
      );
    }
    return n;
  }

  Future<Response> _createUser(ApiRequest req) async {
    final body = await req.jsonBody();
    final fields = <ApiFieldError>[];
    final usernameRaw = body['username'];
    final username = usernameRaw is String
        ? usernameRaw.trim().toLowerCase()
        : '';
    if (!usernamePattern.hasMatch(username)) {
      fields.add(
        const ApiFieldError(
          field: 'username',
          message: '2 to 32 of a-z, 0-9, ., _ and -',
        ),
      );
    }
    final displayName = body['displayName'];
    if (displayName is! String ||
        displayName.trim().isEmpty ||
        displayName.trim().length > 64) {
      fields.add(
        const ApiFieldError(
          field: 'displayName',
          message: '1 to 64 characters',
        ),
      );
    }
    final password = body['password'];
    if (password is! String || password.length < minPasswordLength) {
      fields.add(
        const ApiFieldError(
          field: 'password',
          message: 'At least $minPasswordLength characters',
        ),
      );
    }
    final role = Role.fromJson(body['role']);
    if (role == Role.unknown) {
      fields.add(
        const ApiFieldError(field: 'role', message: 'admin or member'),
      );
    }
    final jf = _validJellyfinId(body['jellyfinUserId'], fields);
    if (fields.isNotEmpty) throw ApiException.validation(fields);
    if (_users.byUsername(username) != null) {
      throw ApiException.alreadyExists(
        'A user named $username already exists.',
      );
    }
    return audit.run(
      req,
      'admin.user.create',
      username,
      {'role': role.name, 'jellyfinUserId': jf},
      () async {
        final hash = await auth.hasher.hash(password as String);
        final now = clock.now();
        final user = UserRecord(
          id: _users.newId(),
          username: username,
          displayName: (displayName as String).trim(),
          role: role,
          passwordHash: hash,
          jellyfinUserId: (jf == null || jf.isEmpty) ? null : jf,
          createdAt: now,
          updatedAt: now,
        );
        await _users.put(user);
        return ApiResponse.json(user.toDto(), status: 201);
      },
    );
  }

  Future<Response> _updateUser(ApiRequest req) async {
    final id = req.pathParam('id');
    final target =
        _users.byId(id) ?? (throw ApiException.notFound('User not found.'));
    final body = await req.jsonBody();
    final fields = <ApiFieldError>[];
    final displayName = body['displayName'];
    if (displayName != null &&
        (displayName is! String ||
            displayName.trim().isEmpty ||
            displayName.trim().length > 64)) {
      fields.add(
        const ApiFieldError(
          field: 'displayName',
          message: '1 to 64 characters',
        ),
      );
    }
    Role? role;
    if (body['role'] != null) {
      role = Role.fromJson(body['role']);
      if (role == Role.unknown) {
        fields.add(
          const ApiFieldError(field: 'role', message: 'admin or member'),
        );
      }
    }
    final jf = _validJellyfinId(body['jellyfinUserId'], fields);
    final disabled = body['disabled'];
    if (disabled != null && disabled is! bool) {
      fields.add(
        const ApiFieldError(field: 'disabled', message: 'true or false'),
      );
    }
    final password = body['password'];
    if (password != null &&
        (password is! String || password.length < minPasswordLength)) {
      fields.add(
        const ApiFieldError(
          field: 'password',
          message: 'At least $minPasswordLength characters',
        ),
      );
    }
    if (fields.isNotEmpty) throw ApiException.validation(fields);

    final willBeActiveAdmin =
        (role ?? target.role) == Role.admin &&
        !((disabled as bool?) ?? target.disabled);
    if (target.isActiveAdmin &&
        !willBeActiveAdmin &&
        _users.activeAdminCount <= 1) {
      throw ApiException.invalidState(
        'The last active admin cannot be demoted or disabled.',
      );
    }

    return audit.run(req, 'admin.user.update', target.username, body, () async {
      final hash = password is String ? await auth.hasher.hash(password) : null;
      final now = clock.now();
      final fresh = _users.byId(id) ?? target;
      final updated = fresh.copyWith(
        displayName: (displayName as String?)?.trim(),
        role: role,
        passwordHash: hash,
        jellyfinUserId: (jf == null || jf.isEmpty) ? null : jf,
        clearJellyfinUserId: jf != null && jf.isEmpty,
        disabled: disabled as bool?,
        updatedAt: now,
      );
      await _users.put(updated);
      if (updated.disabled && !fresh.disabled) {
        await auth.revokeUserSessions(id);
      } else if (hash != null) {
        // Resetting someone else's password revokes all their sessions; an
        // admin resetting their own keeps the current session.
        await auth.revokeUserSessions(
          id,
          exceptSessionId: id == req.user.id ? req.sessionId : null,
        );
      }
      if (updated.jellyfinUserId != fresh.jellyfinUserId) {
        seerrIdentity.invalidate(id);
      }
      return ApiResponse.json(updated.toDto());
    });
  }

  Future<Response> _deleteUser(ApiRequest req) async {
    final id = req.pathParam('id');
    final target =
        _users.byId(id) ?? (throw ApiException.notFound('User not found.'));
    if (id == req.user.id) {
      throw ApiException.invalidState('You cannot delete your own account.');
    }
    if (target.isActiveAdmin && _users.activeAdminCount <= 1) {
      throw ApiException.invalidState(
        'The last active admin cannot be deleted.',
      );
    }
    await req.requireConfirm(
      'Deletes the hub account ${target.username} and ends all of its sessions',
    );
    return audit.run(req, 'admin.user.delete', target.username, null, () async {
      await auth.revokeUserSessions(id);
      await _users.remove(id);
      auth.limiter.forgetUser(id);
      seerrIdentity.invalidate(id);
      return ApiResponse.noContent();
    });
  }

  Future<List<JellyfinUserOption>> _jellyfinOptions() async {
    final jellyfin = upstreams.jellyfin;
    if (!jellyfin.configured) {
      throw ApiException.serviceNotConfigured(ServiceId.jellyfin);
    }
    final raw = await jellyfin.getJson('/Users');
    if (raw is! List) {
      throw UpstreamBadResponse(
        service: ServiceId.jellyfin,
        method: 'GET',
        path: '/Users',
        reason: 'not a list',
      );
    }
    List<SeerrUserRef> seerrUsers = const [];
    if (seerrIdentity.configured) {
      try {
        seerrUsers = await seerrIdentity.users();
      } on UpstreamException {
        seerrUsers = const [];
      }
    }
    final bySeerrJf = {
      for (final s in seerrUsers)
        if (s.jellyfinUserId != null) s.jellyfinUserId!: s,
    };
    final out = <JellyfinUserOption>[];
    for (final e in raw) {
      final m = readMap(e);
      final id = normaliseJellyfinId(readString(m?['Id']));
      if (m == null || id == null) continue;
      final policy = readMap(m['Policy']);
      final seerr = bySeerrJf[id];
      out.add(
        JellyfinUserOption(
          jellyfinUserId: id,
          name: readString(m['Name']) ?? id,
          isAdministrator: readBool(policy?['IsAdministrator']) ?? false,
          seerrUserId: seerr?.id,
          seerrDisplayName: seerr?.displayName,
          linkedHubUserId: _users.byJellyfinUserId(id)?.id,
          avatarPath: readString(m['PrimaryImageTag']) == null
              ? null
              : images.jellyfinUser(id, tag: readString(m['PrimaryImageTag'])),
        ),
      );
    }
    return out;
  }

  Future<Response> _jellyfinUsers(ApiRequest req) async {
    final options = await _jellyfinOptions();
    return ApiResponse.items(options, (o) => o.toJson());
  }

  Future<Response> _importToSeerr(ApiRequest req) async {
    final id = normaliseJellyfinId(req.pathParam('jellyfinUserId'));
    if (id == null) throw ApiException.notFound('Unknown Jellyfin user.');
    final seerr = upstreams.seerr;
    if (!seerr.configured) {
      throw ApiException.serviceNotConfigured(ServiceId.seerr);
    }
    final before = await _jellyfinOptions();
    if (!before.any((o) => o.jellyfinUserId == id)) {
      throw ApiException.notFound('Unknown Jellyfin user.');
    }
    return audit.run(req, 'admin.seerr_import', id, null, () async {
      await seerr.sendJson(
        'POST',
        '/api/v1/user/import-from-jellyfin',
        body: {
          'jellyfinUserIds': [id],
        },
        timeout: const Duration(seconds: 30),
      );
      seerrIdentity.invalidateAll();
      final after = await _jellyfinOptions();
      final option = after.firstWhere(
        (o) => o.jellyfinUserId == id,
        orElse: () => throw ApiException.notFound('Unknown Jellyfin user.'),
      );
      return ApiResponse.json(option);
    });
  }

  Future<Response> _audit(ApiRequest req) async {
    final page = req.queryInt('page', defaultValue: 1, min: 1, max: 100000);
    final pageSize = req.queryInt(
      'pageSize',
      defaultValue: 50,
      min: 1,
      max: 200,
      clamp: true,
    );
    final outcomeRaw = req.queryString('outcome');
    AuditOutcome? outcome;
    if (outcomeRaw != null) {
      outcome = AuditOutcome.fromJson(outcomeRaw);
      if (outcome == AuditOutcome.unknown) {
        throw ApiException.badRequest('outcome must be ok or error');
      }
    }
    final result = await audit.query(
      page: page,
      pageSize: pageSize,
      userId: req.queryString('userId'),
      actionPrefix: req.queryString('action'),
      outcome: outcome,
    );
    return ApiResponse.json(result.toJson((e) => e.toJson()));
  }
}
