// Gateway-shaped calendar samples (API.md §9.1) for the calendar tests.

import 'package:dio/dio.dart' as dio;
import 'package:yams_models/yams_models.dart';

import '../../support/fake_api.dart';

/// The device clock of the tests: Sunday 8 Nov 2026, 11:00 local.
final calendarTestNow = DateTime(2026, 11, 8, 11);

DateTime day(int month, int d, [int year = 2026]) => DateTime.utc(year, month, d);

CalendarItem episode(
  int id,
  DateTime date, {
  String title = 'The Apothecary Diaries',
  String subtitle = 'S03E07 · The Bet',
  int seriesId = 159,
  int hour = 14,
  bool hasFile = false,
  bool monitored = true,
  bool downloading = false,
  String? finaleType,
  String? network = 'Nippon TV',
}) => CalendarItem(
  id: 'episode:$id',
  kind: CalendarItemKind.episode,
  date: date,
  airDateUtc: DateTime.utc(date.year, date.month, date.day, hour),
  title: title,
  subtitle: subtitle,
  seriesId: seriesId,
  episodeId: id,
  seasonNumber: 3,
  episodeNumber: 7,
  network: network,
  hasFile: hasFile,
  monitored: monitored,
  downloading: downloading,
  finaleType: finaleType,
);

CalendarItem movie(
  int id,
  DateTime date, {
  String title = 'The Odyssey',
  CalendarReleaseType type = CalendarReleaseType.digital,
  bool hasFile = false,
  bool monitored = true,
}) => CalendarItem(
  id: 'movie:$id:${type.name}',
  kind: CalendarItemKind.movie,
  date: date,
  title: title,
  subtitle: type.subtitle,
  movieId: id,
  releaseType: type,
  hasFile: hasFile,
  monitored: monitored,
);

/// The default agenda: yesterday, today, Tuesday (finale, downloading), an
/// unmonitored special on Thursday and a movie release on 17 Nov.
List<CalendarItem> sampleItems() => [
  episode(
    7563,
    day(11, 7),
    title: 'The Ramparts of Ice',
    subtitle: 'S02E06 (020) · Cultural Festival',
    seriesId: 140,
    hasFile: true,
    network: 'TBS (JP)',
  ),
  episode(7669, day(11, 8)),
  episode(
    7958,
    day(11, 10),
    title: 'The Ramparts of Ice',
    subtitle: 'S02E07 (021) · TBA',
    seriesId: 140,
    downloading: true,
    finaleType: 'season',
    network: 'TBS (JP)',
  ),
  episode(9001, day(11, 12), title: 'Frieren', subtitle: 'S00E03 · Special', seriesId: 61, monitored: false),
  movie(246, day(11, 17)),
];

/// Serves `GET /calendar` from [items], honouring `start`/`end`, and
/// records the windows asked for. [sources] overrides the per-source status.
List<(String, String)> serveCalendar(
  FakeApi api,
  List<CalendarItem> items, {
  CalendarSources sources = const CalendarSources(sonarr: SectionStatus.ok(), radarr: SectionStatus.ok()),
}) {
  final windows = <(String, String)>[];
  api.on('GET', '/calendar', (dio.RequestOptions r) {
    final start = CalendarDates.parse(r.uri.queryParameters['start'])!;
    final end = CalendarDates.parse(r.uri.queryParameters['end'])!;
    windows.add((CalendarDates.format(start), CalendarDates.format(end)));
    return FakeResponse(
      CalendarResponse(
        start: start,
        end: end,
        items: [
          for (final i in items)
            if (!i.date.isBefore(start) && !i.date.isAfter(end)) i,
        ]..sort(CalendarItem.compare),
        sources: sources,
      ).toJson(),
    );
  });
  return windows;
}
