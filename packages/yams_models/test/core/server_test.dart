import 'package:test/test.dart';
import 'package:yams_models/yams_models.dart';

import 'round_trip.dart';

final _serverJson = <String, Object?>{
  'version': '1.0.0',
  'instanceId': '3f9c2a71d0e84b5c',
  'publicUrls': [
    'http://192.168.10.183:8090',
    'http://zenith.example.ts.net:8090',
  ],
  'services': [
    {'id': 'sonarr', 'configured': true},
    {'id': 'kavita', 'configured': false},
  ],
  'externalApps': {
    'jellyfin': {'port': 8096},
    'audiobookshelf': {'port': 13378},
    'kavita': {'port': 5000},
    'seerr': {'port': 5055, 'baseUrl': 'https://requests.example.com'},
    'shelfmark': {'port': 8084},
    'sonarr': {'port': 8989},
    'radarr': {'port': 7878},
    'prowlarr': {'port': 9696},
    'bazarr': {'port': 6767},
    'qbittorrent': {'port': 8081},
    'uptimeKuma': {'port': 3001},
    'jellystat': {'port': 3002},
    'portainer': {'port': 9000},
  },
  'jellyfinServerId': '79315eab3c4c401f8391d5c26210b6d7',
  'policy': {
    'allowGlobalSearch': false,
    'allowArrDeleteFiles': true,
    'lockedContainers': ['yams-hub', 'socket-proxy-hub', 'yams-hub-updater'],
    'confirmContainers': ['gluetun', 'jellyfin', 'portainer'],
  },
  'features': {
    'updater': true,
    'watchtowerCheck': false,
    'containerLogs': true,
    'containerActions': true,
  },
  'seerr': {
    'fourKEnabled': false,
    'partialRequestsEnabled': true,
    'specialEpisodesEnabled': false,
  },
};

void main() {
  group('ServerPing', () {
    final ping = <String, Object?>{
      'name': 'yams-hub',
      'version': '1.0.0',
      'apiVersion': 1,
      'minAppVersion': '1.0.0',
      'instanceId': '3f9c2a71d0e84b5c',
      'time': '2026-11-08T09:00:00Z',
    };
    test('round trips without and with a proof', () {
      final p = expectRoundTrip(ping, ServerPing.fromJson, (p) => p.toJson());
      expect(p.proof, isNull);
      expect(p.apiVersion, 1);
      final withProof = expectRoundTrip(
        {...ping, 'proof': 'n3dYgV0W8yqXr3k1u2Pq'},
        ServerPing.fromJson,
        (p) => p.toJson(),
      );
      expect(withProof.proof, 'n3dYgV0W8yqXr3k1u2Pq');
    });
    test('requires apiVersion', () {
      expect(
        () => ServerPing.fromJson({...ping}..remove('apiVersion')),
        throwsFormatException,
      );
    });
  });

  group('ServerConfig', () {
    test('round trips the documented sample', () {
      final c = expectRoundTrip(
        _serverJson,
        ServerConfig.fromJson,
        (c) => c.toJson(),
      );
      expect(c.externalApps[ExternalApp.shelfmark]?.port, 8084);
      expect(
        c.externalApps[ExternalApp.seerr]?.baseUrl,
        'https://requests.example.com',
      );
      expect(c.externalApps, hasLength(13));
      expect(c.isConfigured(ServiceId.sonarr), isTrue);
      expect(c.isConfigured(ServiceId.kavita), isFalse);
      expect(c.isConfigured(ServiceId.bazarr), isFalse);
      expect(c.features.containerActions, isTrue);
      expect(c.policy.lockedContainers, contains('yams-hub'));
      expect(c.seerr.partialRequestsEnabled, isTrue);
    });

    test('drops unknown external apps and tolerates missing sections', () {
      final c = ServerConfig.fromJson({
        'version': '1.1.0',
        'instanceId': 'x',
        'services': [
          {'id': 'plex', 'configured': true},
        ],
        'externalApps': {
          'homepage': {'port': 3000},
          'jellyfin': {'port': 8096, 'baseUrl': null},
          'kavita': 'broken',
        },
      });
      expect(c.externalApps.keys, [ExternalApp.jellyfin]);
      expect(c.services.single.id, ServiceId.unknown);
      expect(c.policy.allowGlobalSearch, isFalse);
      expect(c.features.updater, isFalse);
      expect(c.seerr.fourKEnabled, isFalse);
      expect(c.publicUrls, isEmpty);
    });
  });

  group('HealthReport', () {
    test('round trips the documented sample', () {
      final r = expectRoundTrip(
        {
          'overall': 'degraded',
          'checkedAt': '2026-11-08T09:00:00Z',
          'services': [
            {
              'id': 'sonarr',
              'name': 'Sonarr',
              'status': 'up',
              'latencyMs': 4,
              'version': '4.0.20.3014',
              'checkedAt': '2026-11-08T09:00:00Z',
            },
            {
              'id': 'kavita',
              'name': 'Kavita',
              'status': 'degraded',
              'latencyMs': 12,
              'message': 'Auth key rejected',
              'checkedAt': '2026-11-08T09:00:00Z',
            },
            {
              'id': 'shelfmark',
              'name': 'Shelfmark',
              'status': 'disabled',
              'checkedAt': '2026-11-08T09:00:00Z',
            },
          ],
        },
        HealthReport.fromJson,
        (r) => r.toJson(),
      );
      expect(r.overall, ServiceHealthStatus.degraded);
      expect(r.of(ServiceId.kavita)?.message, 'Auth key rejected');
      expect(r.of(ServiceId.shelfmark)?.status, ServiceHealthStatus.disabled);
      expect(r.of(ServiceId.bazarr), isNull);
    });

    test('unknown statuses parse to unknown; name falls back', () {
      final h = ServiceHealth.fromJson({
        'id': 'uptimeKuma',
        'status': 'flapping',
        'checkedAt': '2026-11-08T09:00:00Z',
      });
      expect(h.status, ServiceHealthStatus.unknown);
      expect(h.name, 'Uptime Kuma');
      final r = HealthReport.fromJson({
        'overall': 'meh',
        'checkedAt': '2026-11-08T09:00:00Z',
      });
      expect(r.overall, ServiceHealthStatus.unknown);
      expect(r.services, isEmpty);
    });
  });
}
