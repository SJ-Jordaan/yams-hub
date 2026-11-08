import 'package:test/test.dart';
import 'package:yams_models/yams_models.dart';

import '../core/round_trip.dart';

/// The samples of API.md §9.1, filled in.
final _episodeJson = <String, Object?>{
  'id': 'episode:5600',
  'kind': 'episode',
  'airDateUtc': '2026-11-10T15:00:00Z',
  'date': '2026-11-10',
  'title': 'The Apothecary Diaries',
  'subtitle': 'S02E17 · Title',
  'seriesId': 159,
  'episodeId': 5600,
  'seasonNumber': 2,
  'episodeNumber': 17,
  'finaleType': 'season',
  'network': 'Nippon TV',
  'hasFile': false,
  'monitored': true,
  'downloading': true,
  'posterPath': '/api/v1/img/arr/sonarr/159/poster?size=250',
};

final _movieJson = <String, Object?>{
  'id': 'movie:204:digital',
  'kind': 'movie',
  'date': '2026-11-17',
  'title': 'The Odyssey',
  'subtitle': 'Digital release',
  'movieId': 204,
  'releaseType': 'digital',
  'hasFile': false,
  'monitored': true,
  'downloading': false,
};

void main() {
  group('CalendarItem', () {
    test('episode round trip', () {
      final e = expectRoundTrip(
        _episodeJson,
        CalendarItem.fromJson,
        (i) => i.toJson(),
      );
      expect(e.kind, CalendarItemKind.episode);
      expect(e.isEpisode, isTrue);
      expect(e.date, DateTime.utc(2026, 11, 10));
      expect(e.airDateUtc, DateTime.utc(2026, 11, 10, 15));
      expect(e.releaseType, isNull);
      expect(e.downloading, isTrue);
    });

    test('movie round trip', () {
      final m = expectRoundTrip(
        _movieJson,
        CalendarItem.fromJson,
        (i) => i.toJson(),
      );
      expect(m.kind, CalendarItemKind.movie);
      expect(m.releaseType, CalendarReleaseType.digital);
      expect(m.airDateUtc, isNull);
      expect(m.toJson().containsKey('airDateUtc'), isFalse);
      expect(m.toJson().containsKey('posterPath'), isFalse);
    });

    test('unknown enums map to unknown and absent flags get defaults', () {
      final i = CalendarItem.fromJson({
        'id': 'x',
        'kind': 'concert',
        'date': '2026-11-10',
        'releaseType': 'streaming',
      });
      expect(i.kind, CalendarItemKind.unknown);
      expect(i.releaseType, CalendarReleaseType.unknown);
      expect(i.hasFile, isFalse);
      expect(i.monitored, isTrue);
      expect(i.downloading, isFalse);
      expect(i.title, '');
    });

    test('date is required and never time-zone converted', () {
      expect(
        () => CalendarItem.fromJson({'id': 'x', 'kind': 'movie'}),
        throwsFormatException,
      );
      expect(
        () => CalendarItem.fromJson({'id': 'x', 'date': '2026-02-31'}),
        throwsFormatException,
      );
      final i = CalendarItem.fromJson({
        'id': 'x',
        'date': '2026-11-17T00:00:00Z',
      });
      expect(i.toJson()['date'], '2026-11-17');
    });

    test('withDownloading keeps every other field', () {
      final e = CalendarItem.fromJson(wire(_episodeJson));
      final copy = e.withDownloading(false);
      expect(copy.downloading, isFalse);
      expect(copy.toJson(), equals({..._episodeJson, 'downloading': false}));
    });

    test('compare orders by date, then time (all-day first), then title', () {
      CalendarItem item(String id, String date, String title, [String? at]) =>
          CalendarItem.fromJson({
            'id': id,
            'date': date,
            'title': title,
            'airDateUtc': ?at,
          });
      final items = [
        item('e3', '2026-11-11', 'Alpha', '2026-11-11T08:00:00Z'),
        item('e2', '2026-11-10', 'Zeta', '2026-11-10T15:00:00Z'),
        item('e1', '2026-11-10', 'Beta', '2026-11-10T14:00:00Z'),
        item('m1', '2026-11-10', 'the odyssey'),
        item('m0', '2026-11-10', 'Avatar'),
      ]..sort(CalendarItem.compare);
      expect(items.map((i) => i.id), ['m0', 'm1', 'e1', 'e2', 'e3']);
    });
  });

  group('CalendarResponse', () {
    final sample = <String, Object?>{
      'start': '2026-11-07',
      'end': '2026-11-21',
      'items': [_episodeJson, _movieJson],
      'sources': {
        'sonarr': {'status': 'ok'},
        'radarr': {
          'status': 'error',
          'error': {
            'code': 'upstream_unavailable',
            'message': 'Radarr is not reachable.',
            'status': 503,
            'service': 'radarr',
            'requestId': 'a1b2c3d4e5f60718',
            'fields': <Object?>[],
          },
        },
      },
    };

    test('round trip', () {
      final r = expectRoundTrip(
        sample,
        CalendarResponse.fromJson,
        (r) => r.toJson(),
      );
      expect(r.start, DateTime.utc(2026, 11, 7));
      expect(r.end, DateTime.utc(2026, 11, 21));
      expect(r.items, hasLength(2));
      expect(r.sources.sonarr!.isOk, isTrue);
      expect(r.sources.radarr!.error!.code, 'upstream_unavailable');
      expect(r.sources.anyFailed, isTrue);
      expect(r.sources.all, hasLength(2));
    });

    test('a source that was not queried is omitted', () {
      final r = expectRoundTrip(
        {
          'start': '2026-11-07',
          'end': '2026-11-07',
          'items': <Object?>[],
          'sources': {
            'radarr': {'status': 'ok'},
          },
        },
        CalendarResponse.fromJson,
        (r) => r.toJson(),
      );
      expect(r.sources.sonarr, isNull);
      expect(r.sources.anyFailed, isFalse);
    });
  });

  group('CalendarCard', () {
    test('round trip keeps the raw countNext7Days key', () {
      final c = expectRoundTrip(
        {
          'items': [_episodeJson],
          'countNext7Days': 6,
        },
        CalendarCard.fromJson,
        (c) => c.toJson(),
      );
      expect(c.countNext7Days, 6);
      expect(c.toJson()['countNext7Days'], 6);
    });

    test('decodes from a dashboard Section', () {
      final s = Section.ok(const {
        'items': <Object?>[],
        'countNext7Days': 0,
      }, fetchedAt: DateTime.utc(2026, 11, 8, 9));
      final c = s.decode(CalendarCard.fromJson)!;
      expect(c.items, isEmpty);
      expect(c.countNext7Days, 0);
    });
  });

  group('CalendarDates', () {
    test('parse/format/of', () {
      expect(CalendarDates.parse('2026-11-08'), DateTime.utc(2026, 11, 8));
      expect(CalendarDates.parse('2026-13-01'), isNull);
      expect(CalendarDates.parse('garbage'), isNull);
      expect(CalendarDates.parse(20261108), isNull);
      expect(CalendarDates.format(DateTime.utc(2026, 1, 5)), '2026-01-05');
      expect(
        CalendarDates.of(DateTime(2026, 11, 8, 23, 59)),
        DateTime.utc(2026, 11, 8),
      );
    });
  });

  test('release type labels', () {
    expect(CalendarReleaseType.cinema.subtitle, 'In cinemas');
    expect(CalendarReleaseType.digital.subtitle, 'Digital release');
    expect(CalendarReleaseType.physical.subtitle, 'Physical release');
    expect(CalendarReleaseType.physical.label, 'Physical');
  });
}
