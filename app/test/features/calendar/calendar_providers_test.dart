import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/features/calendar/providers/calendar_providers.dart';
import 'package:yams_hub/features/calendar/widgets/calendar_agenda_list.dart';
import 'package:yams_hub/features/calendar/widgets/calendar_item_tile.dart';
import 'package:yams_models/yams_models.dart';

import 'calendar_samples.dart';

CalendarResponse _response(DateTime start, DateTime end, List<CalendarItem> items, {CalendarSources? sources}) =>
    CalendarResponse(
      start: start,
      end: end,
      items: items,
      sources: sources ?? const CalendarSources(sonarr: SectionStatus.ok(), radarr: SectionStatus.ok()),
    );

const _defaultFilters = {CalendarFilter.episodes, CalendarFilter.movies};

void main() {
  group('CalendarRange', () {
    test('a 3-week window from yesterday, then 2-week windows', () {
      final range = CalendarRange(start: day(11, 7));
      expect(range.windows, [(start: day(11, 7), end: day(11, 27))]);
      final more = range.withExtraWindows(2);
      expect(more.windows.map((w) => (CalendarDates.format(w.start), CalendarDates.format(w.end))), [
        ('2026-11-07', '2026-11-27'),
        ('2026-11-28', '2026-12-11'),
        ('2026-12-12', '2026-12-25'),
      ]);
      expect(more.end, day(12, 25));
      for (final w in more.windows) {
        expect(w.end.difference(w.start).inDays, lessThanOrEqualTo(62));
      }
    });

    test('stops at maxEnd', () {
      var range = CalendarRange(start: day(11, 7));
      while (range.canLoadMore) {
        range = range.withExtraWindows(range.extraWindows + 1);
      }
      expect(range.end.isBefore(range.maxEnd), isFalse);
      expect(range.end.difference(range.maxEnd).inDays, lessThan(CalendarRange.moreWindowDays));
    });

    test('the controller starts yesterday and extends to include a day', () {
      final container = ProviderContainer(overrides: [calendarClockProvider.overrideWithValue(() => calendarTestNow)]);
      addTearDown(container.dispose);
      final sub = container.listen(calendarRangeProvider, (_, _) {});
      addTearDown(sub.close);
      expect(container.read(calendarRangeProvider).start, day(11, 7));
      container.read(calendarRangeProvider.notifier).ensureIncludes(day(12, 20));
      expect(container.read(calendarRangeProvider).end, day(12, 25));
      container.read(calendarRangeProvider.notifier).loadMore();
      expect(container.read(calendarRangeProvider).extraWindows, 3);
    });
  });

  group('filters', () {
    test('toggle and visibility', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(calendarFiltersProvider), _defaultFilters);
      container.read(calendarFiltersProvider.notifier).toggle(CalendarFilter.unmonitored);
      expect(container.read(calendarFiltersProvider), contains(CalendarFilter.unmonitored));
      container.read(calendarFiltersProvider.notifier).toggle(CalendarFilter.unmonitored);
      expect(container.read(calendarFiltersProvider), isNot(contains(CalendarFilter.unmonitored)));

      final special = episode(1, day(11, 8), monitored: false);
      expect(calendarItemVisible(special, _defaultFilters), isFalse);
      expect(calendarItemVisible(special, {..._defaultFilters, CalendarFilter.unmonitored}), isTrue);
      expect(calendarItemVisible(movie(2, day(11, 8)), {CalendarFilter.episodes}), isFalse);
      expect(calendarItemVisible(episode(3, day(11, 8)), {CalendarFilter.movies}), isFalse);
    });
  });

  group('buildCalendarAgenda', () {
    final range = CalendarRange(start: day(11, 7)).withExtraWindows(1);
    final windows = range.windows;

    test('groups by day, inserts an empty today and filters', () {
      final agenda = buildCalendarAgenda(
        today: day(11, 9),
        range: range,
        windows: [
          AsyncValue.data(_response(windows[0].start, windows[0].end, sampleItems())),
          AsyncValue.data(_response(windows[1].start, windows[1].end, [movie(7, day(11, 30))])),
        ],
        filters: _defaultFilters,
      );
      expect(agenda.days.map((d) => CalendarDates.format(d.date)), [
        '2026-11-07',
        '2026-11-08',
        '2026-11-09', // today, empty
        '2026-11-10',
        '2026-11-17',
        '2026-11-30',
      ]);
      expect(agenda.days[2].items, isEmpty);
      expect(agenda.items.any((i) => !i.monitored), isFalse);
      expect(agenda.loadedEnd, day(12, 11));
      expect(agenda.loadingMore, isFalse);
      expect(agenda.failedSources, isEmpty);
      expect(agenda.refreshError, isNull);
      expect(agenda.marks[day(11, 17)]!.movies, 1);
      expect(agenda.marks[day(11, 10)]!.episodes, 1);
      expect(agenda.covers(day(12, 11)), isTrue);
      expect(agenda.covers(day(12, 12)), isFalse);
    });

    test('later windows only add a footer state; gaps are never shown', () {
      final loading = buildCalendarAgenda(
        today: day(11, 8),
        range: range,
        windows: [
          AsyncValue.data(_response(windows[0].start, windows[0].end, sampleItems())),
          const AsyncValue.loading(),
        ],
        filters: _defaultFilters,
      );
      expect(loading.loadingMore, isTrue);
      expect(loading.loadedEnd, day(11, 27));

      final failed = buildCalendarAgenda(
        today: day(11, 8),
        range: range,
        windows: [
          AsyncValue.data(_response(windows[0].start, windows[0].end, sampleItems())),
          AsyncValue.error(StateError('offline'), StackTrace.empty),
        ],
        filters: _defaultFilters,
      );
      expect(failed.loadingMore, isFalse);
      expect(failed.moreError, isA<StateError>());
    });

    test('reports failed and stale sources', () {
      final agenda = buildCalendarAgenda(
        today: day(11, 8),
        range: CalendarRange(start: day(11, 7)),
        windows: [
          AsyncValue.data(
            _response(
              windows[0].start,
              windows[0].end,
              sampleItems(),
              sources: const CalendarSources(
                sonarr: SectionStatus(
                  status: SectionState.ok,
                  error: ApiError(code: 'upstream_error', message: 'x', status: 502),
                ),
                radarr: SectionStatus.failure(ApiError(code: 'upstream_unavailable', message: 'x', status: 503)),
              ),
            ),
          ),
        ],
        filters: _defaultFilters,
      );
      expect(agenda.failedSources, ['Radarr']);
      expect(agenda.refreshError, isNotNull);
    });

    test('keeps the fix of a source refused by Allowed Hosts (issue #2)', () {
      const message = "Sonarr rejects the hub's hostname 'sonarr'. In Sonarr → Settings → General → Allowed Hosts, add sonarr (or clear the list), then restart Sonarr.";
      final agenda = buildCalendarAgenda(
        today: day(11, 8),
        range: CalendarRange(start: day(11, 7)),
        windows: [
          AsyncValue.data(
            _response(
              windows[0].start,
              windows[0].end,
              sampleItems(),
              sources: const CalendarSources(
                sonarr: SectionStatus.failure(
                  ApiError(code: ApiErrorCode.upstreamHostRejected, message: message, status: 502),
                ),
                radarr: SectionStatus.failure(ApiError(code: 'upstream_unavailable', message: 'x', status: 503)),
              ),
            ),
          ),
        ],
        filters: _defaultFilters,
      );
      expect(agenda.failedSources, ['Sonarr', 'Radarr']);
      expect(agenda.sourceHints, {'Sonarr': message});
    });
  });

  group('layout', () {
    test('offsets add header and row extents', () {
      final days = [
        CalendarDay(day(11, 7), [episode(1, day(11, 7)), episode(2, day(11, 7))]),
        CalendarDay(day(11, 8), const []),
        CalendarDay(day(11, 10), [episode(3, day(11, 10))]),
      ];
      const layout = CalendarAgendaLayout();
      final h = layout.headerExtent;
      const row = CalendarItemTile.defaultExtent;
      expect(layout.rowExtent, row);
      expect(layout.offsetOf(days, day(11, 7)), 0);
      expect(layout.offsetOf(days, day(11, 8)), h + 2 * row);
      // A day without a group scrolls to the next one.
      expect(layout.offsetOf(days, day(11, 9)), 2 * h + 2 * row + layout.emptyDayExtent);
    });
  });

  group('labels and states', () {
    test('day labels', () {
      final today = day(11, 8);
      expect(calendarDayLabel(day(11, 8), today), 'Today · Sun 8 Nov');
      expect(calendarDayLabel(day(11, 9), today), 'Tomorrow · Mon 9 Nov');
      expect(calendarDayLabel(day(11, 7), today), 'Yesterday · Sat 7 Nov');
      expect(calendarDayLabel(day(11, 10), today), 'Tue 10 Nov');
      expect(calendarDayLabel(day(1, 2, 2027), today), 'Sat 2 Jan 2027');
      expect(calendarShortDayLabel(day(11, 8), today), 'Today');
      expect(calendarShortDayLabel(day(11, 9), today), 'Tomorrow');
      expect(calendarShortDayLabel(day(11, 10), today), 'Tuesday');
      expect(calendarFinaleLabel('season'), 'Season finale');
      expect(calendarFinaleLabel('series'), 'Series finale');
      expect(calendarFinaleLabel(null), isNull);
    });

    test('item state', () {
      final now = DateTime.utc(2026, 11, 8, 12);
      expect(CalendarItemState.of(episode(1, day(11, 8), hasFile: true), now: now), CalendarItemState.downloaded);
      expect(CalendarItemState.of(episode(1, day(11, 8), downloading: true), now: now), CalendarItemState.downloading);
      expect(CalendarItemState.of(episode(1, day(11, 8), hour: 10), now: now), CalendarItemState.missing);
      expect(CalendarItemState.of(episode(1, day(11, 8), hour: 14), now: now), CalendarItemState.upcoming);
      expect(CalendarItemState.of(movie(1, day(11, 8)), now: now), CalendarItemState.missing);
      expect(CalendarItemState.of(movie(1, day(11, 9)), now: now), CalendarItemState.upcoming);
    });
  });
}
