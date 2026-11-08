import 'package:test/test.dart';
import 'package:yams_models/yams_models.dart';

import '../core/round_trip.dart';

const _quality = {
  'name': 'WEBDL-1080p',
  'source': 'web',
  'resolution': 1080,
  'isRepack': false,
};

const _file = {
  'id': 10005,
  'relativePath': 'Season 01/Show - S01E01.mkv',
  'sizeBytes': 2636508931,
  'dateAdded': '2026-06-10T21:19:00Z',
  'quality': _quality,
  'customFormats': ['10bit'],
  'customFormatScore': -20000,
  'cutoffNotMet': true,
  'releaseGroup': 'd3g',
  'languages': ['English'],
  'videoCodec': 'HEVC',
  'videoDynamicRange': 'HDR10',
  'resolution': '1920x1080',
  'audioCodec': 'EAC3',
  'audioChannels': 5.1,
  'audioLanguages': ['eng'],
  'subtitleLanguages': ['eng'],
  'runTime': '41:55',
};

const _series = {
  'id': 54,
  'title': 'That Time I Got Reincarnated as a Slime',
  'sortTitle': 'that time i got reincarnated as a slime',
  'year': 2018,
  'status': 'continuing',
  'seriesType': 'anime',
  'isAnime': true,
  'monitored': true,
  'monitorNewItems': 'all',
  'network': 'Tokyo MX',
  'qualityProfileId': 7,
  'qualityProfileName': '[Anime] Remux-1080p',
  'posterPath':
      '/api/v1/img/arr/sonarr/54/poster?size=250&v=639058149420070772',
  'fanartPath': '/api/v1/img/arr/sonarr/54/fanart?size=500&v=1',
  'nextAiring': '2026-11-12T14:45:00Z',
  'seasonCount': 3,
  'episodeCount': 110,
  'episodeFileCount': 62,
  'missingCount': 48,
  'totalEpisodeCount': 120,
  'sizeOnDiskBytes': 123456789012,
  'percentComplete': 56.4,
  'added': '2026-02-04T15:15:28Z',
  'genres': ['Anime', 'Animation'],
  'tvdbId': 336297,
  'tmdbId': 82684,
  'imdbId': 'tt9054364',
  'ratingValue': 8.1,
  'ratingVotes': 1234,
  'tags': ['anime'],
};

const _movie = {
  'id': 1,
  'title': 'Zootopia 2',
  'sortTitle': 'zootopia 2',
  'year': 2025,
  'status': 'released',
  'monitored': true,
  'hasFile': true,
  'isAvailable': true,
  'minimumAvailability': 'released',
  'qualityProfileId': 7,
  'qualityProfileName': 'HD Bluray + WEB',
  'posterPath':
      '/api/v1/img/arr/radarr/1/poster?size=250&v=ee00d06d64cb9c44727a',
  'inCinemasDate': '2025-11-26',
  'digitalReleaseDate': '2026-01-20',
  'releaseDate': '2026-01-20',
  'runtimeMinutes': 108,
  'sizeOnDiskBytes': 4567890123,
  'quality': 'Bluray-1080p',
  'cutoffNotMet': false,
  'added': '2026-02-03T20:25:53Z',
  'genres': <String>[],
  'tmdbId': 1084242,
  'imdbId': 'tt26443597',
  'studio': 'Walt Disney Animation Studios',
  'certification': 'PG',
  'ratingImdb': 7.9,
  'ratingTmdb': 7.6,
  'collection': 'Zootopia Collection',
  'tags': <String>[],
};

const _summary = {
  'configured': true,
  'version': '4.0.20.3014',
  'itemCount': 71,
  'missing': 892,
  'cutoffUnmet': 994,
  'sizeOnDiskBytes': 2780000000000,
  'freeBytes': 4048915103744,
  'queue': {'total': 2, 'errors': true, 'warnings': false},
  'health': [
    {
      'service': 'sonarr',
      'source': 'AllowedHostsCheck',
      'type': 'warning',
      'message': 'Allowed Hosts is not configured',
      'wikiUrl': 'https://wiki.servarr.com/sonarr/system',
    },
  ],
};

void main() {
  group('series', () {
    test('SeriesSummary round trip', () {
      final s = expectRoundTrip(
        _series,
        SeriesSummary.fromJson,
        (s) => s.toJson(),
      );
      expect(s.seriesType, LibrarySeriesType.anime);
      expect(s.tags, ['anime']);
      expect(s.previousAiring, isNull);
      expect(s.copyWithMonitored(false).monitored, isFalse);
    });

    test('unknown enum strings map to unknown', () {
      final s = SeriesSummary.fromJson({
        ..._series,
        'status': 'cancelled',
        'seriesType': 'weekly',
        'monitorNewItems': 'some',
      });
      expect(s.status, LibrarySeriesStatus.unknown);
      expect(s.seriesType, LibrarySeriesType.unknown);
      expect(s.monitorNewItems, LibraryMonitorNewItems.unknown);
    });

    test('SeriesDetail with seasons, episodes, file and queue', () {
      final sample = {
        'series': _series,
        'overview': 'Rimuru...',
        'airTime': '22:00',
        'runtimeMinutes': 24,
        'certification': 'TV-14',
        'rootFolderPath': '/data/tvshows',
        'seasonFolder': true,
        'originalLanguage': 'Japanese',
        'alternateTitles': ['Tensei Shitara Slime Datta Ken'],
        'bannerPath': '/api/v1/img/arr/sonarr/54/banner?size=500',
        'seasons': [
          {
            'seasonNumber': 1,
            'monitored': true,
            'episodeCount': 24,
            'episodeFileCount': 24,
            'totalEpisodeCount': 24,
            'sizeOnDiskBytes': 35937551194,
            'previousAiring': '2019-03-19T14:00:00Z',
            'posterPath': '/api/v1/img/remote?u=x',
          },
          {
            'seasonNumber': 0,
            'monitored': false,
            'episodeCount': 0,
            'episodeFileCount': 0,
            'totalEpisodeCount': 14,
            'sizeOnDiskBytes': 0,
          },
        ],
        'episodes': [
          {
            'id': 2447,
            'seasonNumber': 3,
            'episodeNumber': 1,
            'absoluteEpisodeNumber': 49,
            'label': 'S03E01 (049)',
            'title': 'Demons and Strategies',
            'airDate': '2024-04-05',
            'airDateUtc': '2024-04-05T14:00:00Z',
            'runtimeMinutes': 24,
            'monitored': true,
            'hasFile': true,
            'finaleType': 'season',
            'lastSearchTime': '2026-02-05T04:41:14Z',
            'file': _file,
            'queue': {
              'status': 'downloading',
              'trackedState': 'importPending',
              'progress': 0.66,
              'etaSeconds': 2470,
            },
          },
        ],
        'titleSlug': 'that-time-i-got-reincarnated-as-a-slime',
        'links': {
          'tvdb': 'https://thetvdb.com/?tab=series&id=336297',
          'imdb': 'https://www.imdb.com/title/tt9054364/',
        },
      };
      final d = expectRoundTrip(
        sample,
        SeriesDetail.fromJson,
        (d) => d.toJson(),
      );
      expect(d.episodes.single.file!.quality.name, 'WEBDL-1080p');
      expect(d.episodes.single.queue!.etaSeconds, 2470);
      expect(d.seasons.last.seasonNumber, 0);
      expect(d.links['tvdb'], contains('336297'));
    });

    test('Episode derives a label when the gateway omits it', () {
      final e = Episode.fromJson({
        'id': 1,
        'seasonNumber': 2,
        'episodeNumber': 5,
        'monitored': true,
        'hasFile': false,
      });
      expect(e.label, 'S02E05');
      expect(e.copyWithMonitored(false).monitored, isFalse);
    });

    test('SeriesLookup round trip', () {
      expectRoundTrip(
        {
          'tvdbId': 424536,
          'title': "Frieren: Beyond Journey's End",
          'year': 2023,
          'overview': 'An elf mage...',
          'network': 'Nippon TV',
          'status': 'continuing',
          'genres': ['Anime'],
          'runtimeMinutes': 25,
          'seasonNumbers': [0, 1, 2],
          'posterPath':
              '/api/v1/img/remote?u=https%3A%2F%2Fartworks.thetvdb.com%2Fp.jpg',
          'ratingValue': 8.9,
          'originalLanguage': 'Japanese',
          'isAnime': true,
          'inLibrary': true,
          'libraryId': 25,
          'suggested': {
            'seriesType': 'anime',
            'qualityProfileId': 7,
            'rootFolderPath': '/data/tvshows',
          },
        },
        SeriesLookup.fromJson,
        (s) => s.toJson(),
      );
    });

    test('AddSeriesRequest applies the documented defaults', () {
      final r = AddSeriesRequest.fromJson({
        'tvdbId': 371980,
        'qualityProfileId': 9,
        'rootFolderPath': '/data/tvshows',
        'seriesType': 'standard',
      });
      expect(r.seasonFolder, isTrue);
      expect(r.monitor, LibrarySeriesMonitor.all);
      expect(r.monitorNewItems, LibraryMonitorNewItems.all);
      expect(r.searchForCutoffUnmet, isFalse);
      expectRoundTrip(r.toJson(), AddSeriesRequest.fromJson, (r) => r.toJson());
      expect(
        () => AddSeriesRequest.fromJson({'tvdbId': 1}),
        throwsFormatException,
      );
    });
  });

  group('movies', () {
    test('MovieSummary round trip and copy', () {
      final m = expectRoundTrip(
        _movie,
        MovieSummary.fromJson,
        (m) => m.toJson(),
      );
      expect(m.physicalReleaseDate, isNull);
      expect(m.copyWithMonitored(false).toJson()['monitored'], isFalse);
    });

    test('MovieDetail round trip', () {
      expectRoundTrip(
        {
          'movie': _movie,
          'overview': 'Judy and Nick...',
          'files': [_file],
          'queue': {
            'status': 'queued',
            'trackedState': 'downloading',
            'progress': 0.0,
          },
          'alternateTitles': ['Zootropolis 2'],
          'youTubeTrailerId': 'sEgPQ7HKoBA',
          'links': {'tmdb': 'https://www.themoviedb.org/movie/1084242'},
        },
        MovieDetail.fromJson,
        (m) => m.toJson(),
      );
    });

    test('MovieLookup and AddMovieRequest round trip', () {
      expectRoundTrip(
        {
          'tmdbId': 693134,
          'imdbId': 'tt15239678',
          'title': 'Dune: Part Two',
          'year': 2024,
          'status': 'released',
          'runtimeMinutes': 167,
          'genres': ['Science Fiction'],
          'ratingTmdb': 8.143,
          'studio': 'Legendary Pictures',
          'inLibrary': true,
          'libraryId': 9,
          'hasFile': true,
          'suggested': {
            'qualityProfileId': 7,
            'rootFolderPath': '/data/movies',
            'minimumAvailability': 'released',
          },
        },
        MovieLookup.fromJson,
        (m) => m.toJson(),
      );
      final add = AddMovieRequest.fromJson({
        'tmdbId': 693134,
        'qualityProfileId': 7,
        'rootFolderPath': '/data/movies',
      });
      expect(add.minimumAvailability, LibraryMinimumAvailability.released);
      expect(add.monitor, LibraryMovieMonitor.movieOnly);
      expectRoundTrip(
        add.toJson(),
        AddMovieRequest.fromJson,
        (r) => r.toJson(),
      );
    });
  });

  group('wanted, profiles, summary', () {
    test('WantedItem round trip (both services)', () {
      expectRoundTrip(
        {
          'service': 'sonarr',
          'id': 7668,
          'seriesId': 159,
          'title': 'The Apothecary Diaries',
          'episodeLabel': 'S03E06 (054)',
          'episodeTitle': 'The Paper Village',
          'airDateUtc': '2026-11-06T14:00:00Z',
          'monitored': true,
          'isAvailable': true,
          'currentQuality': 'HDTV-1080p',
          'cutoffQuality': 'Bluray-1080p',
        },
        WantedItem.fromJson,
        (w) => w.toJson(),
      );
      final radarr = expectRoundTrip(
        {
          'service': 'radarr',
          'id': 246,
          'title': 'The Odyssey',
          'releaseDate': '2026-07-17',
          'year': 2026,
          'monitored': true,
          'isAvailable': false,
        },
        WantedItem.fromJson,
        (w) => w.toJson(),
      );
      expect(radarr.service, ArrService.radarr);
    });

    test('LibraryProfiles round trip', () {
      final p = expectRoundTrip(
        {
          'sonarr': {
            'qualityProfiles': [
              {'id': 9, 'name': 'WEB-1080p'},
            ],
            'rootFolders': [
              {
                'id': 1,
                'path': '/data/tvshows',
                'freeBytes': 4050000000000,
                'accessible': true,
              },
            ],
            'defaults': {
              'standardProfileId': 9,
              'animeProfileId': 7,
              'rootFolderPath': '/data/tvshows',
            },
          },
          'radarr': {
            'qualityProfiles': [
              {'id': 7, 'name': 'HD Bluray + WEB'},
            ],
            'rootFolders': <Object>[],
            'defaults': {
              'profileId': 7,
              'rootFolderPath': '/data/movies',
              'minimumAvailability': 'released',
            },
          },
        },
        LibraryProfiles.fromJson,
        (p) => p.toJson(),
      );
      expect(p.sonarr.defaults.animeProfileId, 7);
    });

    test('LibrarySummary and LibraryCard round trip', () {
      final s = expectRoundTrip(
        {
          'sonarr': _summary,
          'radarr': const ArrSummary.notConfigured().toJson(),
        },
        LibrarySummary.fromJson,
        (s) => s.toJson(),
      );
      expect(s.sonarr.problems, hasLength(1));
      expect(s.radarr.configured, isFalse);
      final card = expectRoundTrip(
        LibraryCard.fromSummary(s).toJson(),
        LibraryCard.fromJson,
        (c) => c.toJson(),
      );
      expect(card.sonarr.queue.errors, isTrue);
    });
  });

  group('releases', () {
    const choice = {
      'releaseId': 'rl_abc',
      'service': 'sonarr',
      'title': '[SubsPlease] Slime S4 (01-24) (1080p) [Batch]',
      'indexer': 'Nyaa.si (Prowlarr)',
      'indexerId': 5,
      'quality': _quality,
      'customFormats': ['Anime Web Tier 05'],
      'customFormatScore': 200,
      'sizeBytes': 35111357644,
      'ageHours': 2,
      'publishDate': '2026-11-07T21:51:00Z',
      'seeders': 812,
      'leechers': 40,
      'protocol': 'torrent',
      'languages': ['Japanese'],
      'releaseGroup': 'SubsPlease',
      'fullSeason': true,
      'episodeLabels': <String>[],
      'approved': false,
      'temporarilyRejected': false,
      'rejected': true,
      'rejections': ['Existing file on disk is of equal or higher preference'],
      'infoUrl': 'https://nyaa.si/view/2183642',
    };

    test('ReleaseChoiceList round trip', () {
      final list = expectRoundTrip(
        {
          'items': [choice],
          'tookMs': 4210,
        },
        ReleaseChoiceList.fromJson,
        (l) => l.toJson(),
      );
      expect(list.items.single.protocol, LibraryReleaseProtocol.torrent);
      expect(list.items.single.rejected, isTrue);
    });

    test('a release never carries download secrets', () {
      final json = ReleaseChoice.fromJson({
        ...choice,
        'guid': 'magnet:?xt=urn:btih:abc',
        'downloadUrl': 'http://prowlarr:9696/5/download?apikey=x',
      }).toJson();
      expect(json.keys, isNot(contains('guid')));
      expect(json.keys, isNot(contains('downloadUrl')));
    });

    test('grab result and command response', () {
      expectRoundTrip(
        {'ok': true, 'title': 'Show.S01E01'},
        ReleaseChoiceGrabResult.fromJson,
        (r) => r.toJson(),
      );
      final c = expectRoundTrip(
        {
          'command': {
            'service': 'sonarr',
            'id': 12345,
            'name': 'SeriesSearch',
            'status': 'queued',
            'result': 'unknown',
            'queuedAt': '2026-11-08T09:00:00Z',
          },
        },
        LibraryCommandResponse.fromJson,
        (c) => c.toJson(),
      );
      expect(c.command.status, CommandStatus.queued);
    });
  });
}
