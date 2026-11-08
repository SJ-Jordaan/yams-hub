import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/features/subtitles/bazarr_mapper.dart';

import '../../support/test_hub.dart';

void main() {
  final mapper = BazarrMapper(
    images: ImageUrls(const ['image.tmdb.org']),
    redact: redactSecrets,
  );

  test('episode labels', () {
    expect(BazarrMapper.episodeLabel('1x11'), 'S01E11');
    expect(BazarrMapper.episodeLabel('12x105'), 'S12E105');
    expect(BazarrMapper.episodeLabel(' 0x3 '), 'S00E03');
    expect(BazarrMapper.episodeLabel('special'), 'special');
    expect(BazarrMapper.episodeLabel(''), isNull);
    expect(BazarrMapper.episodeLabel(null), isNull);
  });

  test('parsed_timestamp is MM/dd/yy HH:mm:ss in UTC', () {
    expect(
      BazarrMapper.parsedTimestamp('11/08/26 07:53:14'),
      DateTime.utc(2026, 11, 8, 7, 53, 14),
    );
    expect(
      BazarrMapper.parsedTimestamp('1/2/25 3:04:05'),
      DateTime.utc(2025, 1, 2, 3, 4, 5),
    );
    for (final bad in [
      'an hour ago',
      '13/08/26 07:53:14',
      '11/08/26 25:00:00',
      '2026-11-08T07:53:14Z',
      null,
      42,
    ]) {
      expect(BazarrMapper.parsedTimestamp(bad), isNull, reason: '$bad');
    }
  });

  test('history action codes', () {
    expect(
      [for (var i = 0; i < 8; i++) BazarrMapper.historyAction(i)],
      [
        SubtitleHistoryAction.deleted,
        SubtitleHistoryAction.downloaded,
        SubtitleHistoryAction.manual,
        SubtitleHistoryAction.upgraded,
        SubtitleHistoryAction.uploaded,
        SubtitleHistoryAction.synced,
        SubtitleHistoryAction.translated,
        SubtitleHistoryAction.extracted,
      ],
    );
    expect(BazarrMapper.historyAction(8), SubtitleHistoryAction.unknown);
    expect(BazarrMapper.historyAction(-1), SubtitleHistoryAction.unknown);
    expect(BazarrMapper.historyAction('1'), SubtitleHistoryAction.downloaded);
    expect(BazarrMapper.historyAction(null), SubtitleHistoryAction.unknown);
  });

  test('languages fall back to code3 and skip entries without a code', () {
    expect(
      BazarrMapper.language({
        'name': 'English',
        'code3': 'eng',
        'forced': 'True',
        'hi': false,
      }),
      const SubtitleLanguage(code: 'eng', name: 'English', forced: true),
    );
    expect(BazarrMapper.language({'name': 'English'}), isNull);
    final w = mapper.wantedMovie({
      'title': 'Hotel',
      'radarrId': 190,
      'missing_subtitles': [
        {'name': 'English', 'code2': 'en'},
        {'name': 'Broken'},
        'junk',
      ],
    });
    expect(w.missing.map((l) => l.code), ['en']);
  });

  test('signalr and providers', () {
    expect(BazarrMapper.signalr('LIVE'), SubtitleSignalrState.live);
    expect(BazarrMapper.signalr('live'), SubtitleSignalrState.live);
    expect(BazarrMapper.signalr('DOWN'), SubtitleSignalrState.down);
    expect(BazarrMapper.signalr(null), SubtitleSignalrState.down);
    final p = mapper.provider({'name': 'x', 'status': 'Good', 'retry': '-'});
    expect(p.ok, isTrue);
    expect(p.retry, isNull);
  });

  test('upstream texts are redacted', () {
    final h = mapper.historyMovie({
      'title': 'Hotel',
      'action': 1,
      'description': 'failed http://bazarr:6767/api?apikey=0123456789abcdef',
    });
    expect(h.description, isNot(contains('0123456789abcdef')));
  });

  test('tasks and jobs without ids are skipped', () {
    expect(BazarrMapper.task({'name': 'x'}), isNull);
    expect(mapper.job({'job_name': 'x'}), isNull);
    final t = BazarrMapper.task({
      'job_id': 'backup',
      'next_run_time': 'in 1 day',
    })!;
    expect(t.name, 'backup');
    expect(t.nextRun, 'in 1 day');
  });

  test('wanted episodes from the capture', () {
    final body = fixture('downloads/bazarr_episodes_wanted.json')! as Map;
    final rows = [for (final r in body['data'] as List) readMap(r)!];
    final items = rows.map(mapper.wantedEpisode).toList();
    expect(items.map((w) => w.episodeLabel), [
      'S01E11',
      'S01E13',
      'S01E12',
      'S02E23',
      'S02E22',
    ]);
    expect(items.every((w) => w.posterPath != null), isTrue);
    expect(items[1].seriesType, 'standard');
  });
}
