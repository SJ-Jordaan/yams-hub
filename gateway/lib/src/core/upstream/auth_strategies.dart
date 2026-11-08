/// Per-service upstream authentication (ARCHITECTURE §5.6 table).
library;

import 'package:yams_models/yams_models.dart';

import '../../config/config.dart';
import '../../version.dart';
import 'upstream_client.dart';

/// The auth strategy of each service (ARCHITECTURE §5.6 table).
UpstreamAuth authStrategyFor(ServiceConfig c) {
  final key = c.secret ?? '';
  return switch (c.id) {
    ServiceId.sonarr ||
    ServiceId.radarr ||
    ServiceId.prowlarr => HeaderAuth({'x-api-key': key}),
    ServiceId.bazarr => HeaderAuth({'x-api-key': key}),
    ServiceId.seerr => HeaderAuth({'x-api-key': key}),
    ServiceId.jellyfin => HeaderAuth({
      'authorization': jellyfinAuthorization(key),
    }),
    ServiceId.jellystat => HeaderAuth({'x-api-token': key}),
    ServiceId.watchtower ||
    ServiceId.audiobookshelf ||
    ServiceId.updater => HeaderAuth({'authorization': 'Bearer $key'}),
    ServiceId.kavita => HeaderAuth({'x-api-key': key}),
    _ => const NoAuth(),
  };
}

/// Jellyfin's `Authorization: MediaBrowser ...` header value.
String jellyfinAuthorization(String token) =>
    'MediaBrowser Client="YAMS Hub", Device="yams-hub", '
    'DeviceId="yams-hub-gateway", Version="$hubVersion", Token="$token"';
