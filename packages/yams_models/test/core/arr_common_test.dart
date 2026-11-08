import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yams_models/yams_models.dart';

import 'round_trip.dart';

/// Captured upstream responses (repo-root `fixtures/`, read-only).
Object? _fixture(String name) =>
    jsonDecode(File('../../fixtures/arr/$name').readAsStringSync());

List<JsonMap> _records(Object? body) => [
  for (final r in (body is Map ? body['records'] : body) as List<Object?>)
    readMap(r)!,
];

final _qualityJson = <String, Object?>{
  'name': 'WEBDL-1080p',
  'source': 'web',
  'resolution': 1080,
  'revision': 2,
  'isRepack': true,
};

void main() {
  group('ArrService', () {
    test('parses unknown values and maps to ServiceId', () {
      expect(ArrService.fromJson('sonarr').serviceId, ServiceId.sonarr);
      expect(ArrService.fromJson('radarr').serviceId, ServiceId.radarr);
      expect(ArrService.fromJson('lidarr'), ArrService.unknown);
      expect(ArrService.unknown.serviceId, ServiceId.unknown);
    });
  });

  test('ArrEpisodeLabel follows the anime rule', () {
    expect(ArrEpisodeLabel.format(1, 2), 'S01E02');
    expect(ArrEpisodeLabel.format(3, 1, absoluteEpisodeNumber: 49), 'S03E01');
    expect(
      ArrEpisodeLabel.format(3, 1, absoluteEpisodeNumber: 49, anime: true),
      'S03E01 (049)',
    );
    expect(ArrEpisodeLabel.format(12, 105, anime: true), 'S12E105');
  });

  group('QualityInfo', () {
    test('round trips full and minimal', () {
      expectRoundTrip(_qualityJson, QualityInfo.fromJson, (q) => q.toJson());
      expectRoundTrip(
        {'name': 'Bluray-2160p', 'isRepack': false},
        QualityInfo.fromJson,
        (q) => q.toJson(),
      );
    });
  });

  test('MediaFileInfo round trips', () {
    final f = expectRoundTrip(
      {
        'id': 911,
        'relativePath': 'Season 01/Show - S01E02 - Pilot WEBDL-1080p.mkv',
        'sizeBytes': 1496206957,
        'dateAdded': '2026-11-08T06:12:00Z',
        'quality': _qualityJson,
        'customFormats': ['WEB-DL', 'x264'],
        'customFormatScore': 202,
        'cutoffNotMet': false,
        'releaseGroup': 'GRP',
        'edition': "Director's Cut",
        'languages': ['English'],
        'videoCodec': 'h264',
        'videoDynamicRange': 'HDR10',
        'resolution': '1920x1080',
        'audioCodec': 'EAC3',
        'audioChannels': 5.1,
        'audioLanguages': ['eng', 'jpn'],
        'subtitleLanguages': ['eng'],
        'runTime': '41:55',
      },
      MediaFileInfo.fromJson,
      (f) => f.toJson(),
    );
    expect(f.quality.resolution, 1080);
    expect(f.toJson().containsKey('path'), isFalse);

    expectRoundTrip(
      {
        'id': 1,
        'relativePath': 'a.mkv',
        'sizeBytes': 10,
        'quality': {'name': 'HDTV-720p', 'isRepack': false},
        'customFormats': <Object?>[],
        'customFormatScore': 0,
        'cutoffNotMet': true,
        'languages': <Object?>[],
        'audioLanguages': <Object?>[],
        'subtitleLanguages': <Object?>[],
      },
      MediaFileInfo.fromJson,
      (f) => f.toJson(),
    );
  });

  group('HealthMessage', () {
    test('round trips', () {
      expectRoundTrip(
        {
          'service': 'sonarr',
          'source': 'IndexerLongTermStatusCheck',
          'type': 'warning',
          'message':
              'Indexers unavailable due to failures for more than 6 hours',
          'wikiUrl': 'https://wiki.servarr.com/sonarr/system#indexers-are-unavailable-due-to-failures',
        },
        HealthMessage.fromJson,
        (m) => m.toJson(),
      );
    });
    test('parses every type in the captured health fixtures', () {
      for (final name in ['sonarr_health.json', 'radarr_health.json']) {
        for (final raw in _fixture(name) as List<Object?>) {
          final m = HealthMessage.fromJson({
            ...readMap(raw)!,
            'service': 'sonarr',
          });
          expect(
            m.type,
            isNot(HealthMessageType.unknown),
            reason: '$name ${m.source}',
          );
        }
      }
      expect(HealthMessageType.fromJson('fatal'), HealthMessageType.unknown);
    });
  });

  group('ArrHistoryType', () {
    test('integer mapping matches API.md §5', () {
      const sonarr = {
        1: ArrHistoryType.grabbed,
        2: ArrHistoryType.imported,
        3: ArrHistoryType.imported,
        4: ArrHistoryType.failed,
        5: ArrHistoryType.deleted,
        6: ArrHistoryType.renamed,
        7: ArrHistoryType.ignored,
      };
      const radarr = {
        1: ArrHistoryType.grabbed,
        3: ArrHistoryType.imported,
        7: ArrHistoryType.imported,
        4: ArrHistoryType.failed,
        6: ArrHistoryType.deleted,
        8: ArrHistoryType.renamed,
        9: ArrHistoryType.ignored,
      };
      sonarr.forEach((i, t) {
        expect(
          ArrHistoryType.fromEventType(ArrService.sonarr, i),
          t,
          reason: 'sonarr $i',
        );
      });
      radarr.forEach((i, t) {
        expect(
          ArrHistoryType.fromEventType(ArrService.radarr, i),
          t,
          reason: 'radarr $i',
        );
      });
      expect(
        ArrHistoryType.fromEventType(ArrService.radarr, 2),
        ArrHistoryType.unknown,
      );
      expect(
        ArrHistoryType.fromEventType(ArrService.radarr, 5),
        ArrHistoryType.unknown,
      );
      expect(
        ArrHistoryType.fromEventType(ArrService.sonarr, 8),
        ArrHistoryType.unknown,
      );
      expect(
        ArrHistoryType.fromEventType(ArrService.unknown, 1),
        ArrHistoryType.unknown,
      );
      expect(ArrHistoryType.imported.eventTypesFor(ArrService.sonarr), [2, 3]);
      expect(ArrHistoryType.imported.eventTypesFor(ArrService.radarr), [3, 7]);
      expect(ArrHistoryType.unknown.sonarrEventTypes, isEmpty);
    });

    test('upstream names map consistently with the integers', () {
      const names = {
        'grabbed': ArrHistoryType.grabbed,
        'seriesFolderImported': ArrHistoryType.imported,
        'downloadFolderImported': ArrHistoryType.imported,
        'movieFolderImported': ArrHistoryType.imported,
        'downloadFailed': ArrHistoryType.failed,
        'episodeFileDeleted': ArrHistoryType.deleted,
        'movieFileDeleted': ArrHistoryType.deleted,
        'episodeFileRenamed': ArrHistoryType.renamed,
        'movieFileRenamed': ArrHistoryType.renamed,
        'downloadIgnored': ArrHistoryType.ignored,
      };
      names.forEach(
        (n, t) => expect(ArrHistoryType.fromUpstreamName(n), t, reason: n),
      );
      expect(
        ArrHistoryType.fromUpstreamName('unknown'),
        ArrHistoryType.unknown,
      );
      expect(ArrHistoryType.fromUpstreamName(3), ArrHistoryType.unknown);
    });

    test('every event in the captured history fixtures is recognised', () {
      for (final name in [
        'sonarr_history.json',
        'sonarr_history_grabbed.json',
        'sonarr_history_since.json',
        'radarr_history.json',
        'radarr_history_movie.json',
      ]) {
        for (final r in _records(_fixture(name))) {
          expect(
            ArrHistoryType.fromUpstreamName(r['eventType']),
            isNot(ArrHistoryType.unknown),
            reason: '$name ${r['eventType']}',
          );
          final source = readMap(r['data'])?['releaseSource'];
          if (source != null) {
            expect(
              ArrReleaseSource.fromUpstream(source),
              isNot(ArrReleaseSource.unknown),
            );
          }
        }
      }
    });

    test('JSON names parse; unknown values parse to unknown', () {
      for (final v in ArrHistoryType.values) {
        expect(ArrHistoryType.fromJson(v.toJson()), v);
      }
      expect(
        ArrHistoryType.fromJson('downloadFolderImported'),
        ArrHistoryType.unknown,
      );
    });
  });

  test('ArrReleaseSource maps upstream and JSON values', () {
    expect(ArrReleaseSource.fromUpstream('Rss'), ArrReleaseSource.rss);
    expect(ArrReleaseSource.fromUpstream('Search'), ArrReleaseSource.search);
    expect(
      ArrReleaseSource.fromUpstream('InteractiveSearch'),
      ArrReleaseSource.interactiveSearch,
    );
    expect(
      ArrReleaseSource.fromUpstream('ReleasePush'),
      ArrReleaseSource.unknown,
    );
    expect(
      ArrReleaseSource.fromJson('interactiveSearch'),
      ArrReleaseSource.interactiveSearch,
    );
    expect(ArrReleaseSource.fromJson('Rss'), ArrReleaseSource.unknown);
  });

  group('ArrHistoryItem', () {
    test('round trips the documented Sonarr sample', () {
      final item = expectRoundTrip(
        {
          'id': 'sonarr:98123',
          'service': 'sonarr',
          'type': 'imported',
          'date': '2026-11-08T06:12:00Z',
          'sourceTitle': 'Show.S01E02.1080p.WEB.h264-GRP',
          'mediaTitle': 'Show',
          'seriesId': 2,
          'episode': {
            'id': 76,
            'seasonNumber': 1,
            'episodeNumber': 2,
            'title': 'Pilot',
            'label': 'S01E02',
          },
          'quality': _qualityJson,
          'customFormatScore': 202,
          'indexer': 'Nyaa.si (Prowlarr)',
          'releaseGroup': 'GRP',
          'sizeBytes': 1496206957,
          'downloadClient': 'qBittorrent',
          'downloadId': 'e66aac4c7d8a4f813a4e5b3a63c1bb52beee342e',
          'posterPath': '/api/v1/img/arr/sonarr/2/poster?size=250&v=639000',
        },
        ArrHistoryItem.fromJson,
        (i) => i.toJson(),
      );
      expect(item.type, ArrHistoryType.imported);
      expect(item.episode?.label, 'S01E02');
      expect(item.movieId, isNull);
    });

    test('round trips a Radarr grab and an anime episode', () {
      final grab = expectRoundTrip(
        {
          'id': 'radarr:4410',
          'service': 'radarr',
          'type': 'grabbed',
          'date': '2026-11-07T21:00:00Z',
          'sourceTitle': 'Movie.2026.2160p.WEB-DL',
          'mediaTitle': 'Movie',
          'movieId': 204,
          'quality': {'name': 'WEBDL-2160p', 'isRepack': false},
          'customFormatScore': 0,
          'releaseSource': 'interactiveSearch',
        },
        ArrHistoryItem.fromJson,
        (i) => i.toJson(),
      );
      expect(grab.releaseSource, ArrReleaseSource.interactiveSearch);

      final anime = expectRoundTrip(
        {
          'id': 'sonarr:1',
          'service': 'sonarr',
          'type': 'deleted',
          'date': '2026-11-07T21:00:00Z',
          'sourceTitle': 'x',
          'seriesId': 54,
          'episode': {
            'id': 5580,
            'seasonNumber': 3,
            'episodeNumber': 1,
            'absoluteEpisodeNumber': 49,
            'label': 'S03E01 (049)',
          },
          'quality': {'name': 'WEBDL-1080p', 'isRepack': false},
          'customFormatScore': 0,
          'reason': 'Upgrade',
        },
        ArrHistoryItem.fromJson,
        (i) => i.toJson(),
      );
      expect(anime.episode?.absoluteEpisodeNumber, 49);
    });

    test('unknown enum values parse to unknown', () {
      final item = ArrHistoryItem.fromJson({
        'id': 'x:1',
        'service': 'lidarr',
        'type': 'trackRetagged',
        'date': '2026-11-07T21:00:00Z',
        'sourceTitle': 's',
        'quality': {'name': 'FLAC'},
        'releaseSource': 'push',
      });
      expect(item.service, ArrService.unknown);
      expect(item.type, ArrHistoryType.unknown);
      expect(item.releaseSource, ArrReleaseSource.unknown);
    });

    test('episode label falls back to the plain format', () {
      final e = ArrHistoryEpisode.fromJson({
        'id': 1,
        'seasonNumber': 2,
        'episodeNumber': 3,
      });
      expect(e.label, 'S02E03');
    });
  });
}
