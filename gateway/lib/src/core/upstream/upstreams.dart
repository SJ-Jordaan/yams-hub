/// One client per upstream service, with its auth strategy
/// (ARCHITECTURE §5.6).
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:yams_models/yams_models.dart';

import '../../config/config.dart';
import '../../version.dart';
import '../clock.dart';
import 'auth_strategies.dart';
import 'qbit_session.dart';
import 'upstream_client.dart';

/// The production HTTP client for upstream calls: `connectionTimeout` 3 s,
/// `idleTimeout` 15 s, at most 6 connections per host, gzip handled.
http.Client createUpstreamHttpClient() {
  final io = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3)
    ..idleTimeout = const Duration(seconds: 15)
    ..maxConnectionsPerHost = 6
    ..autoUncompress = true
    ..userAgent = 'yams-hub/$hubVersion';
  return IOClient(io);
}

/// All upstream clients.
final class Upstreams {
  Upstreams({
    required HubConfig config,
    required http.Client client,
    required Clock clock,
  }) : _httpClient = client {
    for (final id in ServiceId.values) {
      if (id == ServiceId.unknown || id == ServiceId.host) continue;
      final c = config.service(id);
      switch (id) {
        case ServiceId.docker:
          _clients[id] = DockerClient(config: c, client: client);
        case ServiceId.qbittorrent:
          qbitSession = QbitSession(config: c, client: client, clock: clock);
          _clients[id] = UpstreamClient(
            service: id,
            config: c,
            client: client,
            auth: qbitSession,
          );
        default:
          _clients[id] = UpstreamClient(
            service: id,
            config: c,
            client: client,
            auth: authStrategyFor(c),
          );
      }
    }
  }

  final http.Client _httpClient;
  final _clients = <ServiceId, UpstreamClient>{};

  /// The qBittorrent session (credentials state, session generation).
  late final QbitSession qbitSession;

  /// The client of [id]. Throws for `unknown` and `host`.
  UpstreamClient operator [](ServiceId id) =>
      _clients[id] ??
      (throw ArgumentError.value(id, 'id', 'no upstream client'));

  UpstreamClient get sonarr => this[ServiceId.sonarr];
  UpstreamClient get radarr => this[ServiceId.radarr];
  UpstreamClient get prowlarr => this[ServiceId.prowlarr];
  UpstreamClient get bazarr => this[ServiceId.bazarr];
  UpstreamClient get seerr => this[ServiceId.seerr];
  UpstreamClient get jellyfin => this[ServiceId.jellyfin];
  UpstreamClient get jellystat => this[ServiceId.jellystat];
  UpstreamClient get qbittorrent => this[ServiceId.qbittorrent];
  UpstreamClient get gluetun => this[ServiceId.gluetun];
  DockerClient get docker => this[ServiceId.docker] as DockerClient;
  UpstreamClient get watchtower => this[ServiceId.watchtower];
  UpstreamClient get updater => this[ServiceId.updater];
  UpstreamClient get uptimeKuma => this[ServiceId.uptimeKuma];
  UpstreamClient get audiobookshelf => this[ServiceId.audiobookshelf];
  UpstreamClient get kavita => this[ServiceId.kavita];
  UpstreamClient get shelfmark => this[ServiceId.shelfmark];

  /// Sonarr or Radarr.
  UpstreamClient arr(ArrService service) => switch (service) {
    ArrService.sonarr => sonarr,
    ArrService.radarr => radarr,
    ArrService.unknown => throw ArgumentError.value(service, 'service'),
  };

  void close() => _httpClient.close();
}
