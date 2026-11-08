import 'package:test/test.dart';
import 'package:yams_models/yams_models.dart';

import '../core/round_trip.dart';

/// Gateway-shaped samples built from the Bazarr captures in
/// `fixtures/downloads/bazarr_*.json` (API.md §12).
final _english = <String, Object?>{
  'code': 'en',
  'name': 'English',
  'forced': false,
  'hi': false,
};

final _wantedEpisode = <String, Object?>{
  'type': 'episode',
  'title': 'Gachiakuta',
  'episodeLabel': 'S01E11',
  'episodeTitle': "Amo's Hospitality",
  'seriesId': 164,
  'episodeId': 7941,
  'missing': [_english],
  'posterPath': '/api/v1/img/arr/sonarr/164/poster?size=250',
  'seriesType': 'anime',
};

final _wantedMovie = <String, Object?>{
  'type': 'movie',
  'title': 'Hotel',
  'movieId': 190,
  'missing': [
    {'code': 'en', 'name': 'English', 'forced': true, 'hi': false},
    {'code': 'pb', 'name': 'Portuguese (Brazil)', 'forced': false, 'hi': true},
  ],
  'posterPath': '/api/v1/img/arr/radarr/190/poster?size=250',
};

final _historyEpisode = <String, Object?>{
  'type': 'episode',
  'title': 'That Time I Got Reincarnated as a Slime',
  'episodeLabel': 'S03E17',
  'action': 'downloaded',
  'language': _english,
  'provider': 'embeddedsubtitles',
  'score': '100.0%',
  'description':
      'English subtitles downloaded from embeddedsubtitles with a score of '
      '100.0%.',
  'at': '2026-11-08T07:53:14Z',
};

final _summary = <String, Object?>{
  'missingEpisodes': 111,
  'missingMovies': 3,
  'throttledProviders': 1,
  'providers': [
    {'name': 'opensubtitlescom', 'status': 'Good', 'ok': true},
    {
      'name': 'tvsubtitles',
      'status': 'TooManyRequests',
      'retry': 'in 2 hours',
      'ok': false,
    },
  ],
  'signalr': {'sonarr': 'live', 'radarr': 'down'},
  'health': [
    {'object': 'Sonarr', 'issue': 'Unable to connect'},
  ],
  'version': '1.6.2',
  'tasks': [
    {
      'id': 'wanted_search_missing_subtitles_movies',
      'name': 'Search for Missing Movies Subtitles',
      'interval': 'every 6 hours',
      'nextRun': 'in 3 hours',
      'running': false,
    },
  ],
};

final _job = <String, Object?>{
  'id': 29,
  'name': 'Synced movies with Radarr',
  'status': 'running',
  'progress': 0.5,
  'message': 'Austin Powers in Goldmember',
  'lastRunAt': '2026-11-08T08:22:37.270754Z',
};

void main() {
  group('SubtitleLanguage', () {
    test('round trips and compares by value', () {
      final l = expectRoundTrip(
        _english,
        SubtitleLanguage.fromJson,
        (l) => l.toJson(),
      );
      expect(l, const SubtitleLanguage(code: 'en', name: 'English'));
      expect(
        l.hashCode,
        const SubtitleLanguage(code: 'en', name: 'English').hashCode,
      );
      expect(
        l == const SubtitleLanguage(code: 'en', name: 'English', hi: true),
        isFalse,
      );
    });

    test('requires a code and defaults the flags', () {
      expect(() => SubtitleLanguage.fromJson({}), throwsFormatException);
      final l = SubtitleLanguage.fromJson({'code': 'fr', 'forced': 'true'});
      expect(l.name, 'fr');
      expect(l.forced, isTrue);
      expect(l.hi, isFalse);
    });
  });

  group('WantedSubtitle', () {
    test('episode round trip', () {
      final w = expectRoundTrip(
        _wantedEpisode,
        WantedSubtitle.fromJson,
        (w) => w.toJson(),
      );
      expect(w.type, SubtitleMediaType.episode);
      expect(w.missing.single.code, 'en');
      expect(w.key, 'episode:7941');
    });

    test('movie round trip omits episode fields', () {
      final w = expectRoundTrip(
        _wantedMovie,
        WantedSubtitle.fromJson,
        (w) => w.toJson(),
      );
      expect(w.key, 'movie:190');
      expect(w.toJson().containsKey('episodeLabel'), isFalse);
      expect(w.missing.first.forced, isTrue);
      expect(w.missing.last.hi, isTrue);
    });

    test('unknown type maps to unknown and missing is never null', () {
      final w = WantedSubtitle.fromJson({'type': 'book', 'title': 'X'});
      expect(w.type, SubtitleMediaType.unknown);
      expect(w.missing, isEmpty);
    });
  });

  group('SubtitleHistoryItem', () {
    test('round trip', () {
      final h = expectRoundTrip(
        _historyEpisode,
        SubtitleHistoryItem.fromJson,
        (h) => h.toJson(),
      );
      expect(h.action, SubtitleHistoryAction.downloaded);
      expect(h.at, DateTime.utc(2026, 11, 8, 7, 53, 14));
    });

    test('unknown actions and missing optionals', () {
      final h = SubtitleHistoryItem.fromJson({
        'type': 'movie',
        'title': 'Dune: Part Two',
        'action': 'teleported',
      });
      expect(h.action, SubtitleHistoryAction.unknown);
      expect(h.language, isNull);
      expect(h.toJson(), {
        'type': 'movie',
        'title': 'Dune: Part Two',
        'action': 'unknown',
      });
    });

    test('every action name is stable', () {
      expect(SubtitleHistoryAction.values.map((a) => a.toJson()), [
        'deleted',
        'downloaded',
        'manual',
        'upgraded',
        'uploaded',
        'synced',
        'translated',
        'extracted',
        'unknown',
      ]);
    });
  });

  group('SubtitlesSummary', () {
    test('round trip', () {
      final s = expectRoundTrip(
        _summary,
        SubtitlesSummary.fromJson,
        (s) => s.toJson(),
      );
      expect(s.signalr.anyDown, isTrue);
      expect(s.providers.last.ok, isFalse);
      expect(s.providers.last.retry, 'in 2 hours');
      expect(s.tasks.single.running, isFalse);
      expect(s.health.single.issue, 'Unable to connect');
    });

    test('tolerates a minimal body', () {
      final s = SubtitlesSummary.fromJson({});
      expect(s.missingEpisodes, 0);
      expect(s.providers, isEmpty);
      expect(s.signalr.sonarr, SubtitleSignalrState.unknown);
      expect(s.signalr.anyDown, isTrue);
    });

    test('both links live', () {
      const s = SubtitleSignalr(
        sonarr: SubtitleSignalrState.live,
        radarr: SubtitleSignalrState.live,
      );
      expect(s.anyDown, isFalse);
    });
  });

  group('SubtitleJob', () {
    test('round trip', () {
      final j = expectRoundTrip(_job, SubtitleJob.fromJson, (j) => j.toJson());
      expect(j.isActive, isTrue);
      expect(j.lastRunAt!.isUtc, isTrue);
    });

    test('in an ItemList', () {
      final list = ItemList.fromJson({
        'items': [
          _job,
          {'id': 30, 'name': 'Search', 'status': 'completed'},
        ],
      }, SubtitleJob.fromJson);
      expect(list.items.map((j) => j.isActive), [true, false]);
      expect(list.items.last.progress, isNull);
    });
  });

  group('SubtitleSearchRequest', () {
    test('from a wanted episode', () {
      final w = WantedSubtitle.fromJson(_wantedEpisode);
      final r = SubtitleSearchRequest.forWanted(w, w.missing.single);
      expect(r.toJson(), {
        'type': 'episode',
        'seriesId': 164,
        'episodeId': 7941,
        'language': 'en',
        'forced': false,
        'hi': false,
      });
      expectRoundTrip(
        r.toJson(),
        SubtitleSearchRequest.fromJson,
        (r) => r.toJson(),
      );
    });

    test('from a wanted movie keeps the flags', () {
      final w = WantedSubtitle.fromJson(_wantedMovie);
      final r = SubtitleSearchRequest.forWanted(w, w.missing.last);
      expect(r.toJson(), {
        'type': 'movie',
        'movieId': 190,
        'language': 'pb',
        'forced': false,
        'hi': true,
      });
    });
  });

  group('SubtitlesCard', () {
    test('round trip with the raw key the shell reads', () {
      final c = expectRoundTrip(
        {
          'missingEpisodes': 111,
          'missingMovies': 3,
          'throttledProviders': 0,
          'signalrDown': false,
        },
        SubtitlesCard.fromJson,
        (c) => c.toJson(),
      );
      expect(c.toJson()['missingEpisodes'], 111);
    });

    test('decodes from a Section', () {
      final section = Section.fromJson({
        'status': 'ok',
        'data': {
          'missingEpisodes': 2,
          'missingMovies': 1,
          'throttledProviders': 1,
          'signalrDown': true,
        },
        'fetchedAt': '2026-11-08T09:00:00Z',
        'stale': false,
      });
      final card = section.decode(SubtitlesCard.fromJson)!;
      expect(card.signalrDown, isTrue);
      expect(card.throttledProviders, 1);
    });
  });

  test('list types', () {
    expect(SubtitleListType.fromJson('episodes'), SubtitleListType.episodes);
    expect(SubtitleListType.fromJson('series'), SubtitleListType.unknown);
    expect(SubtitleListType.movies.toJson(), 'movies');
  });
}
