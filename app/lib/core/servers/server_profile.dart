/// A configured hub server (ARCHITECTURE §7.5). Not secret: stored as JSON in
/// SharedPreferences. Tokens belong to the profile, keyed by [instanceId].
library;

import 'package:flutter/foundation.dart';
import 'package:yams_models/yams_models.dart';

@immutable
class ServerProfile {
  const ServerProfile({
    required this.id,
    required this.name,
    required this.urls,
    this.lastGoodUrl,
    this.instanceId,
  });

  factory ServerProfile.fromJson(JsonMap j) => ServerProfile(
    id: req(readString(j['id']), 'id'),
    name: readString(j['name']) ?? 'Zenith',
    urls: [
      for (final s in readStringList(j['urls'])) ?parseServerUrl(s),
    ],
    lastGoodUrl: parseServerUrl(readString(j['lastGoodUrl'])),
    instanceId: readString(j['instanceId']),
  );

  final String id;
  final String name;

  /// Base URLs in preference order (LAN first, then Tailscale), each a bare
  /// `scheme://host[:port]` root without the `/api/v1` suffix.
  final List<Uri> urls;

  /// The URL that answered last; tried first by the resolver.
  final Uri? lastGoodUrl;

  /// The gateway's public instance id, learned from the first ping.
  final String? instanceId;

  /// Identity of what the resolver depends on (not [lastGoodUrl]/[instanceId],
  /// which the resolver itself updates).
  String get resolutionKey => '$id|${urls.join(',')}';

  ServerProfile copyWith({
    String? name,
    List<Uri>? urls,
    Uri? lastGoodUrl,
    String? instanceId,
  }) => ServerProfile(
    id: id,
    name: name ?? this.name,
    urls: urls ?? this.urls,
    lastGoodUrl: lastGoodUrl ?? this.lastGoodUrl,
    instanceId: instanceId ?? this.instanceId,
  );

  JsonMap toJson() => compactJson({
    'id': id,
    'name': name,
    'urls': [for (final u in urls) u.toString()],
    'lastGoodUrl': lastGoodUrl?.toString(),
    'instanceId': instanceId,
  });

  @override
  String toString() => 'ServerProfile($id, $name, $urls)';
}

/// Parses a user-entered server URL into a root `scheme://host[:port]` URI.
///
/// A missing scheme defaults to `http://`; paths, queries and fragments are
/// dropped. Returns null when the input is not an http(s) URL with a host.
Uri? parseServerUrl(String? input) {
  if (input == null) return null;
  var s = input.trim();
  if (s.isEmpty) return null;
  if (!s.contains('://')) s = 'http://$s';
  final uri = Uri.tryParse(s);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null);
}
