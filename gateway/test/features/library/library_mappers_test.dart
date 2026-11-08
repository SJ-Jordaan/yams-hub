import 'dart:convert';

import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/features/library/library_mappers.dart';

import '../../support/test_hub.dart';
import 'library_fakes.dart';

void main() {
  final images = ImageUrls(defaultRemoteImageHosts);
  final map = LibraryMapper(images);

  List<JsonMap> list(String path) => arrList(fixture(path));

  group('series', () {
    test('slim summary from the list (statistics, images, profile, tags)', () {
      final slime = list('arr/sonarr_series.json')
          .firstWhere((s) => s['id'] == 54);
      final s = map.series(
        {
          ...slime,
          'tags': [1, 99],
        },
        tags: {1: 'anime', 2: 'kids'},
        profiles: {7: '[Anime] Remux-1080p'},
      );
      expect(s.isAnime, isTrue);
      expect(s.seriesType, LibrarySeriesType.anime);
      expect(s.episodeCount, 96);
      expect(s.episodeFileCount, 48);
      expect(s.missingCount, 48);
      expect(s.totalEpisodeCount, 110);
      expect(s.percentComplete, 50.0);
      expect(s.qualityProfileName, '[Anime] Remux-1080p');
      expect(s.tags, ['anime'], reason: 'unknown tag ids are dropped');
      expect(
        s.posterPath,
        startsWith('/api/v1/img/arr/sonarr/54/poster?size=250&v='),
      );
      expect(s.posterPath, contains('639058150412210423'));
      expect(s.nextAiring, isNull);
      expect(s.ratingVotes, 29422);
      expect(jsonEncode(s.toJson()), isNot(contains('/data/tvshows')));
    });

    test('Frieren is anime by genre although its type is standard', () {
      final frieren = list('arr/sonarr_series.json')
          .firstWhere((s) => s['id'] == 25);
      final s = map.series(frieren);
      expect(s.seriesType, LibrarySeriesType.standard);
      expect(s.isAnime, isTrue);
    });

    test('detail: seasons with specials last, anime labels, queue state', () {
      final d = map.seriesDetail(
        arrMap(fixture('arr/sonarr_series_id.json')),
        list('arr/sonarr_episode_anime.json'),
        arrList(syntheticJson('sonarr_queue_details.synthetic.json')),
      );
      expect(d.seasons.map((s) => s.seasonNumber), [1, 2, 3, 4, 0]);
      expect(d.seasons.first.posterPath, startsWith('/api/v1/img/remote?'));
      final e = d.episodes.firstWhere((e) => e.id == 2447);
      expect(e.label, 'S03E01 (049)');
      expect(e.queue, isNotNull);
      expect(e.queue!.trackedState, 'importPending');
      expect(e.queue!.progress, closeTo(0.658, 0.001));
      expect(e.queue!.etaSeconds, 41 * 60 + 10);
      expect(d.originalLanguage, 'Japanese');
      expect(d.titleSlug, 'that-time-i-got-reincarnated-as-a-slime');
      expect(d.links['tvdb'], 'https://thetvdb.com/?tab=series&id=352408');
      expect(d.links['imdb'], 'https://www.imdb.com/title/tt9054364/');
      expect(d.alternateTitles, isNotEmpty);
      expect(jsonEncode(d.toJson()), isNot(contains('"path"')));
    });

    test('a standard series keeps plain labels', () {
      final e = map.episode(
        list('arr/sonarr_episode_include_file.json').first,
        anime: false,
      );
      expect(e.label, 'S01E01');
      final f = e.file!;
      expect(f.quality.name, 'Bluray-1080p');
      expect(f.videoDynamicRange, 'HDR10');
      expect(f.subtitleLanguages, ['eng'], reason: 'eng/eng/eng/eng deduped');
      expect(f.customFormats, ['10bit', 'LQ', 'x265 (HD)']);
      expect(f.cutoffNotMet, isTrue);
      expect(f.relativePath, startsWith('Season 01/'));
      expect(jsonEncode(f.toJson()), isNot(contains('/data/tvshows')));
    });
  });

  group('movies', () {
    test('hasFile from movieFileId, dates without TZ conversion', () {
      final movies = [
        for (final m in list('arr/radarr_movie.json')) map.movie(m),
      ];
      final zoo = movies.firstWhere((m) => m.id == 1);
      expect(zoo.hasFile, isTrue);
      expect(zoo.inCinemasDate, '2025-11-26');
      expect(zoo.digitalReleaseDate, '2026-01-26');
      expect(zoo.quality, 'WEBRip-1080p');
      expect(zoo.cutoffNotMet, isTrue);
      expect(zoo.collection, 'Zootopia Collection');
      expect(zoo.ratingImdb, 7.3);
      expect(zoo.posterPath, contains('v=ee00d06d64cb9c44727a'));
      final odyssey = movies.firstWhere((m) => m.id == 246);
      expect(odyssey.hasFile, isFalse);
      expect(odyssey.isAvailable, isFalse);
      expect(odyssey.status, LibraryMovieStatus.inCinemas);
    });

    test('detail files from moviefile, queue from queue/details', () {
      final d = map.movieDetail(
        arrMap(fixture('arr/radarr_movie_id.json')),
        list('arr/radarr_moviefile.json'),
        arrList(syntheticJson('radarr_queue_details.synthetic.json')),
      );
      expect(d.files.single.id, 947);
      expect(d.files.single.languages, ['English']);
      expect(d.files.single.customFormatScore, -10000);
      expect(d.queue!.etaSeconds, 86400 + 2 * 3600 + 3 * 60 + 4);
      expect(d.queue!.progress, 0.75);
      expect(d.links['tmdb'], 'https://www.themoviedb.org/movie/1084242');
      expect(d.youTubeTrailerId, 'sEgPQ7HKoBA');
    });
  });

  group('lookup', () {
    const sonarrDefaults = LibrarySonarrDefaults(
      standardProfileId: 9,
      animeProfileId: 7,
      rootFolderPath: '/data/tvshows',
    );

    test('series lookup: in-library detection, anime suggestion, posters', () {
      final results = [
        for (final s in list('arr/sonarr_series_lookup.json'))
          map.seriesLookup(s, defaults: sonarrDefaults),
      ];
      final frieren = results.first;
      expect(frieren.inLibrary, isTrue);
      expect(frieren.libraryId, 25);
      expect(frieren.isAnime, isTrue);
      expect(frieren.suggested.seriesType, LibrarySeriesType.anime);
      expect(frieren.suggested.qualityProfileId, 7);
      expect(frieren.posterPath, startsWith('/api/v1/img/remote?u='));
      final other = results[1];
      expect(other.inLibrary, isFalse);
      expect(other.libraryId, isNull);
      expect(other.suggested.qualityProfileId, 9);
      expect(other.suggested.rootFolderPath, '/data/tvshows');
      expect(results.last.posterPath, isNull, reason: 'no images at all');
      expect(results.last.ratingValue, isNull, reason: '0 votes');
    });

    test('movie lookup: hasFile from movieFileId (hasFile is absent)', () {
      final results = [
        for (final m in list('arr/radarr_movie_lookup.json'))
          map.movieLookup(
            m,
            defaults: const LibraryRadarrDefaults(
              profileId: 7,
              rootFolderPath: '/data/movies',
            ),
          ),
      ];
      expect(results.first.inLibrary, isTrue);
      expect(results.first.hasFile, isTrue);
      expect(results[2].inLibrary, isFalse);
      expect(results[2].hasFile, isFalse);
      expect(
        results[2].posterPath,
        endsWith('&w=342'),
        reason: 'the image route rewrites TMDB originals to w342',
      );
    });
  });

  group('wanted and history', () {
    test('sonarr wanted rows use the embedded series', () {
      final rows = ArrPage(arrMap(fixture('arr/sonarr_wanted_cutoff.json')));
      final w = map.wantedEpisode(rows.records.first, cutoffQuality: 'X');
      expect(w.service, ArrService.sonarr);
      expect(w.id, 7668);
      expect(w.seriesId, 159);
      expect(w.title, 'The Apothecary Diaries');
      expect(w.episodeLabel, startsWith('S03E06'));
      expect(w.cutoffQuality, 'X');
      expect(rows.total, 994);
    });

    test('radarr wanted rows: release date, availability', () {
      final rows = ArrPage(arrMap(fixture('arr/radarr_wanted_missing.json')));
      final w = map.wantedMovie(rows.records.first);
      expect(w.releaseDate, '1999-11-08');
      expect(w.year, 1999);
      expect(w.isAvailable, isTrue);
    });

    test('grabbed history never carries downloadUrl or guid', () {
      final page = ArrPage(arrMap(fixture('arr/sonarr_history_grabbed.json')));
      final items = [
        for (final r in page.records)
          map.history(ArrService.sonarr, r, anime: true),
      ];
      final g = items.first;
      expect(g.type, ArrHistoryType.grabbed);
      expect(g.indexer, 'Nyaa.si (Prowlarr)');
      expect(g.sizeBytes, 35111357644);
      expect(g.releaseSource, isNotNull);
      expect(g.downloadId, g.downloadId!.toLowerCase());
      final json = jsonEncode([for (final i in items) i.toJson()]);
      expect(json, isNot(contains('apikey')));
      expect(json, isNot(contains('downloadUrl')));
      expect(json, isNot(contains('nyaa.si/view')));
    });

    test('import history maps the camelCase event names', () {
      final page = ArrPage(arrMap(fixture('arr/radarr_history.json')));
      final i = map.history(ArrService.radarr, page.records.first);
      expect(i.type, ArrHistoryType.imported);
      expect(i.id, 'radarr:955');
      expect(i.movieId, 9);
      expect(i.mediaTitle, 'Dune: Part Two');
      expect(i.quality.name, 'WEBRip-2160p');
    });
  });

  group('profiles, commands, helpers', () {
    test('cutoff names resolve quality groups and single qualities', () {
      final sonarr = {
        for (final p in list('arr/sonarr_qualityprofile.json'))
          p['id']: LibraryMapper.cutoffName(p),
      };
      expect(sonarr[7], 'Bluray-1080p');
      expect(sonarr[9], 'WEB 1080p');
      final radarr = {
        for (final p in list('arr/radarr_qualityprofile.json'))
          p['id']: LibraryMapper.cutoffName(p),
      };
      expect(radarr[7], 'Bluray-1080p');
    });

    test('commands map the Servarr resource', () {
      final c = map.command(
        ArrService.sonarr,
        list('arr/sonarr_command.json').first,
      );
      expect(c.service, ServiceId.sonarr);
      expect(c.id, 937782);
      expect(c.name, 'ProcessMonitoredDownloads');
      expect(c.status, CommandStatus.completed);
      expect(c.result, CommandResult.successful);
      expect(c.endedAt, DateTime.utc(2026, 11, 8, 8, 44));
    });

    test('TimeSpan and date helpers', () {
      expect(arrTimeSpanSeconds('00:41:10'), 2470);
      expect(arrTimeSpanSeconds('2.00:00:01'), 172801);
      expect(arrTimeSpanSeconds('00:00:00.0008733'), 0);
      expect(arrTimeSpanSeconds('garbage'), isNull);
      expect(arrDatePart('2026-11-17T00:00:00Z'), '2026-11-17');
      expect(arrDatePart('0001-01-01T00:00:00Z'), isNull);
      expect(arrImageVersion('/MediaCover/1/poster.jpg?h=abc'), 'abc');
    });

    test('releases hide secrets and label anime episodes', () {
      final raw = arrList(syntheticJson('sonarr_release.synthetic.json'));
      final r = map.release(
        ArrService.sonarr,
        raw.first,
        releaseId: 'rl_x',
        anime: true,
      );
      expect(r.episodeLabels, ['S03E01 (049)']);
      expect(r.rejected, isTrue);
      expect(r.rejections.single, contains('equal or higher preference'));
      expect(r.ageHours, 2);
      expect(r.protocol, LibraryReleaseProtocol.torrent);
      expect(r.languages, ['Japanese']);
      final json = jsonEncode(r.toJson());
      for (final secret in [
        'SECRETKEY',
        'magnet:',
        'REJECTEDHASH',
        'comments',
      ]) {
        expect(json, isNot(contains(secret)));
      }
      final usenet = map.release(
        ArrService.sonarr,
        raw.last,
        releaseId: 'rl_y',
      );
      expect(usenet.protocol, LibraryReleaseProtocol.usenet);
      expect(usenet.fullSeason, isTrue);
      expect(usenet.ageHours, isNull);
      final repack = map.release(ArrService.sonarr, raw[1], releaseId: 'rl_z');
      expect(repack.quality.revision, 2);
      expect(repack.quality.isRepack, isTrue);
    });

    test('release labels use the library (mapped) absolute numbers', () {
      final raw = arrList(syntheticJson('sonarr_release.synthetic.json'));
      // The title says scene absolute 1; Sonarr mapped it to library 49.
      expect(readIntList(raw.first['absoluteEpisodeNumbers']), [1]);
      final viaInfo = map.release(
        ArrService.sonarr,
        raw.first,
        releaseId: 'rl_a',
        anime: true,
      );
      expect(viaInfo.episodeLabels, ['S03E01 (049)']);
      final viaMapped = map.release(
        ArrService.sonarr,
        {...raw.first, 'mappedEpisodeInfo': null},
        releaseId: 'rl_b',
        anime: true,
      );
      expect(viaMapped.episodeLabels, ['S03E01 (049)']);
      // Only the parsed numbers: no absolute number rather than a wrong one.
      final parsedOnly = map.release(
        ArrService.sonarr,
        {
          ...raw.first,
          'mappedEpisodeInfo': null,
          'mappedAbsoluteEpisodeNumbers': null,
        },
        releaseId: 'rl_c',
        anime: true,
      );
      expect(parsedOnly.episodeLabels.single, isNot(contains('001')));
      expect(parsedOnly.episodeLabels.single, startsWith('S03E01'));
    });
  });
}
