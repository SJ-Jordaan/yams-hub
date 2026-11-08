/// Hub user → Seerr user resolution (`ctx.seerrIdentity`, ARCHITECTURE §5.5,
/// API.md §6 identity rule).
library;

import 'package:yams_models/yams_models.dart';

import '../../config/config.dart';
import '../cache/ttl_cache.dart';
import '../upstream/upstream_client.dart';
import '../upstream/upstream_exception.dart';

/// Seerr permission bits used by the hub.
abstract final class SeerrPermissions {
  static const admin = 2;
  static const manageUsers = 8;
  static const manageRequests = 16;
  static const request = 32;
  static const autoApprove = 128;
  static const autoApproveMovie = 256;
  static const autoApproveTv = 512;
  static const manageIssues = 1048576;

  static bool has(int permissions, int bit) =>
      (permissions & admin) != 0 || (permissions & bit) != 0;
}

/// The Seerr account a hub user acts as.
final class SeerrLink {
  const SeerrLink({
    required this.seerrUserId,
    required this.displayName,
    required this.permissions,
    this.avatar,
  });

  final int seerrUserId;
  final String displayName;

  /// Seerr's avatar value (`/avatarproxy/<id>?v=...` or an absolute URL).
  final String? avatar;
  final int permissions;

  bool get canAutoApprove =>
      SeerrPermissions.has(permissions, SeerrPermissions.autoApprove);
  bool get isAdmin => (permissions & SeerrPermissions.admin) != 0;
}

/// One Seerr user from `GET /user?take=100`.
final class SeerrUserRef {
  const SeerrUserRef({
    required this.id,
    required this.displayName,
    required this.permissions,
    this.avatar,
    this.jellyfinUserId,
  });

  factory SeerrUserRef.fromSeerr(JsonMap j) => SeerrUserRef(
    id: req(readInt(j['id']), 'id'),
    displayName:
        readString(j['displayName']) ??
        readString(j['jellyfinUsername']) ??
        readString(j['username']) ??
        'User ${readInt(j['id'])}',
    avatar: readString(j['avatar']),
    jellyfinUserId: normaliseJellyfinId(readString(j['jellyfinUserId'])),
    permissions: readInt(j['permissions']) ?? 0,
  );

  final int id;
  final String displayName;
  final String? avatar;

  /// Normalised (lower case, no dashes).
  final String? jellyfinUserId;
  final int permissions;

  SeerrLink toLink() => SeerrLink(
    seerrUserId: id,
    displayName: displayName,
    avatar: avatar,
    permissions: permissions,
  );

  /// The `v` query value of a Seerr avatar path, if any.
  String? get avatarVersion {
    final a = avatar;
    if (a == null) return null;
    return Uri.tryParse(a)?.queryParameters['v'];
  }
}

/// The single resolver shared by `/auth/me`, `/admin/jellyfin-users`,
/// `/img/seerr-avatar` and the requests feature, so they never disagree.
final class SeerrIdentityResolver {
  SeerrIdentityResolver({required this._seerr, required CacheFactory caches})
    : _links = caches.ttl<String, SeerrLink?>(
        'seerr.links',
        const Duration(hours: 1),
        maxEntries: 500,
      ),
      _users = caches.ttl<int, List<SeerrUserRef>>(
        'seerr.users',
        const Duration(minutes: 10),
      ),
      _quota = caches.ttl<int, JsonMap>(
        'seerr.quota',
        const Duration(seconds: 60),
        maxEntries: 500,
      );

  final UpstreamClient _seerr;
  final TtlCache<String, SeerrLink?> _links;
  final TtlCache<int, List<SeerrUserRef>> _users;
  final TtlCache<int, JsonMap> _quota;

  /// hub user id → the Jellyfin id last resolved for them.
  final _resolvedFor = <String, String>{};

  static const _adminKey = '#admin';

  bool get configured => _seerr.configured;

  /// The Seerr user [u] acts as: the user linked through `jellyfinUserId`
  /// (`GET /user/jellyfin/{id}`, cached 1 h). Admins without a link act as
  /// Seerr user 1. Null for unlinked members and when Seerr is not
  /// configured. Upstream failures propagate.
  Future<SeerrLink?> forUser(User u) async {
    if (!_seerr.configured) return null;
    final jf = normaliseJellyfinId(u.jellyfinUserId);
    SeerrLink? link;
    if (jf != null) {
      _resolvedFor[u.id] = jf;
      link = await _links.value(jf, () async {
        try {
          final j = readMap(await _seerr.getJson('/api/v1/user/jellyfin/$jf'));
          return j == null ? null : SeerrUserRef.fromSeerr(j).toLink();
        } on UpstreamException catch (e) {
          if (e.status == 404) return null;
          rethrow;
        }
      });
    }
    if (link == null && u.role == Role.admin) {
      link = await _links.value(_adminKey, () async {
        try {
          final j = readMap(await _seerr.getJson('/api/v1/user/1'));
          return j == null ? null : SeerrUserRef.fromSeerr(j).toLink();
        } on UpstreamException catch (e) {
          if (e.status == 404) return null;
          rethrow;
        }
      });
      link ??= const SeerrLink(
        seerrUserId: 1,
        displayName: 'Seerr admin',
        permissions: SeerrPermissions.admin,
      );
    }
    return link;
  }

  /// Every Seerr user (`GET /user?take=100`, cached 10 min).
  Future<List<SeerrUserRef>> users() async {
    if (!_seerr.configured) return const [];
    return _users.value(0, () async {
      final j = readMap(
        await _seerr.getJson('/api/v1/user', query: {'take': 100, 'skip': 0}),
      );
      return readList(j?['results'], SeerrUserRef.fromSeerr);
    });
  }

  /// The Seerr user [seerrUserId] from [users], or null.
  Future<SeerrUserRef?> userById(int seerrUserId) async {
    for (final u in await users()) {
      if (u.id == seerrUserId) return u;
    }
    return null;
  }

  /// The raw Seerr quota of [seerrUserId] (`GET /user/{id}/quota`, as admin,
  /// cached 60 s).
  Future<JsonMap> quota(int seerrUserId) => _quota.value(seerrUserId, () async {
    return readMap(await _seerr.getJson('/api/v1/user/$seerrUserId/quota')) ??
        const {};
  });

  /// Drops the cached quota (after `POST /requests`).
  void invalidateQuota(int seerrUserId) => _quota.invalidate(seerrUserId);

  /// Drops the cached link of [hubUserId] (its `jellyfinUserId` changed).
  void invalidate(String hubUserId) {
    final jf = _resolvedFor.remove(hubUserId);
    if (jf != null) _links.invalidate(jf);
  }

  /// Drops every cached link and the user list (after an import).
  void invalidateAll() {
    _links.clear();
    _users.clear();
    _resolvedFor.clear();
  }
}

/// Seerr's public settings relevant to the request screens.
final class SeerrFlags {
  const SeerrFlags({
    this.fourKEnabled = false,
    this.partialRequestsEnabled = false,
    this.specialEpisodesEnabled = false,
  });

  final bool fourKEnabled;
  final bool partialRequestsEnabled;
  final bool specialEpisodesEnabled;

  ServerSeerrSettings toDto() => ServerSeerrSettings(
    fourKEnabled: fourKEnabled,
    partialRequestsEnabled: partialRequestsEnabled,
    specialEpisodesEnabled: specialEpisodesEnabled,
  );
}

/// `ctx.seerrSettings`: `GET /settings/public`, cached 1 h.
final class SeerrPublicSettings {
  SeerrPublicSettings({required this._seerr, required CacheFactory caches})
    : _cache = caches.ttl<int, SeerrFlags>(
        'seerr.settings',
        const Duration(hours: 1),
        maxStale: const Duration(days: 7),
      );

  final UpstreamClient _seerr;
  final TtlCache<int, SeerrFlags> _cache;

  /// The flags; defaults when Seerr is not configured. Upstream failures
  /// propagate unless a cached value exists.
  Future<SeerrFlags> flags() async {
    if (!_seerr.configured) return const SeerrFlags();
    return _cache.value(0, () async {
      final j =
          readMap(await _seerr.getJson('/api/v1/settings/public')) ?? const {};
      return SeerrFlags(
        fourKEnabled:
            (readBool(j['movie4kEnabled']) ?? false) ||
            (readBool(j['series4kEnabled']) ?? false),
        partialRequestsEnabled: readBool(j['partialRequestsEnabled']) ?? false,
        specialEpisodesEnabled: readBool(j['enableSpecialEpisodes']) ?? false,
      );
    });
  }
}
