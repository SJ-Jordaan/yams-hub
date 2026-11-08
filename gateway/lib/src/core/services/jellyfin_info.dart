/// Jellyfin server id and admin user (`ctx.jellyfin`, ARCHITECTURE §5.5).
library;

import 'package:logging/logging.dart';
import 'package:yams_models/yams_models.dart';

import '../../config/config.dart';
import '../cache/ttl_cache.dart';
import '../upstream/upstream_client.dart';
import '../upstream/upstream_exception.dart';

final _log = Logger('core.jellyfin');

/// Shared Jellyfin facts used by `/server`, requests and media.
final class JellyfinServerInfo {
  JellyfinServerInfo({
    required this._client,
    required CacheFactory caches,
    String? configuredAdminUserId,
  }) : _configuredAdmin = configuredAdminUserId,
       _serverId = caches.ttl<int, String?>(
         'jellyfin.serverId',
         const Duration(hours: 1),
       ),
       _adminId = caches.ttl<int, String?>(
         'jellyfin.adminUserId',
         const Duration(hours: 1),
       );

  final UpstreamClient _client;
  final String? _configuredAdmin;
  final TtlCache<int, String?> _serverId;
  final TtlCache<int, String?> _adminId;

  /// `GET /System/Info/Public` `Id` (cached 1 h); null when Jellyfin is not
  /// configured or unreachable.
  Future<String?> serverId() async {
    if (!_client.configured) return null;
    try {
      return await _serverId.value(0, () async {
        final j = readMap(
          await _client.getJson(
            '/System/Info/Public',
            timeout: const Duration(seconds: 3),
          ),
        );
        return normaliseJellyfinId(readString(j?['Id'])) ??
            readString(j?['Id']);
      });
    } on UpstreamException catch (e) {
      _log.fine('Jellyfin server id unavailable: $e');
      return null;
    }
  }

  /// `JELLYFIN_ADMIN_USER_ID`, else the first `GET /Users` entry with
  /// `Policy.IsAdministrator && !Policy.IsDisabled` (cached 1 h). Call
  /// [invalidateAdminUserId] after a 401/404 for that user to re-detect.
  Future<String?> adminUserId() async {
    if (_configuredAdmin != null) return _configuredAdmin;
    if (!_client.configured) return null;
    return _adminId.value(0, () async {
      final users = await _client.getJson('/Users');
      if (users is! List) return null;
      for (final u in users) {
        final m = readMap(u);
        final policy = readMap(m?['Policy']);
        if (readBool(policy?['IsAdministrator']) == true &&
            readBool(policy?['IsDisabled']) != true) {
          return normaliseJellyfinId(readString(m?['Id']));
        }
      }
      return null;
    });
  }

  /// Forgets the auto-detected admin user id.
  void invalidateAdminUserId() => _adminId.clear();

  /// `/web/#/details?id=<itemId>&serverId=<serverId>` in the Jellyfin web UI.
  ExternalLink itemLink(String itemId, String serverId) => ExternalLink(
    ExternalApp.jellyfin,
    '/web/#/details?id=$itemId&serverId=$serverId',
  );
}
