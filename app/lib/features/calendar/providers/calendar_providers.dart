/// Calendar state (APP.md §7): the loaded window, the filters and the
/// merged agenda.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/refresh/auto_refresh.dart';
import 'package:yams_models/yams_models.dart';

import '../data/calendar_api.dart';

/// The device clock (tests pin it).
final calendarClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Today's date on the device, as a calendar date ([CalendarDates]).
DateTime calendarToday(Ref ref) => CalendarDates.of(ref.watch(calendarClockProvider)());

// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------

/// The filter chips of the calendar screen.
enum CalendarFilter {
  episodes('Episodes'),
  movies('Movies'),
  unmonitored('Show unmonitored');

  const CalendarFilter(this.label);

  final String label;
}

/// The active filter chips. Episodes and movies are on and unmonitored items
/// hidden by default; the choice lasts for the app session.
final calendarFiltersProvider = NotifierProvider<CalendarFiltersController, Set<CalendarFilter>>(
  CalendarFiltersController.new,
);

class CalendarFiltersController extends Notifier<Set<CalendarFilter>> {
  @override
  Set<CalendarFilter> build() => const {CalendarFilter.episodes, CalendarFilter.movies};

  void toggle(CalendarFilter filter) {
    state = state.contains(filter) ? ({...state}..remove(filter)) : {...state, filter};
  }
}

/// Whether [item] passes [filters].
bool calendarItemVisible(CalendarItem item, Set<CalendarFilter> filters) {
  if (!item.monitored && !filters.contains(CalendarFilter.unmonitored)) return false;
  return switch (item.kind) {
    CalendarItemKind.episode => filters.contains(CalendarFilter.episodes),
    CalendarItemKind.movie => filters.contains(CalendarFilter.movies),
    CalendarItemKind.unknown => filters.contains(CalendarFilter.episodes) && filters.contains(CalendarFilter.movies),
  };
}

// ---------------------------------------------------------------------------
// Loaded range
// ---------------------------------------------------------------------------

/// One `GET /calendar` request window (calendar dates, both inclusive).
typedef CalendarWindow = ({DateTime start, DateTime end});

/// The days the agenda covers: a 3-week window from yesterday, extended by
/// 2 weeks each time the end of the list is reached (APP.md §7). Each
/// window is its own request, so loading more never refetches what is shown.
class CalendarRange {
  const CalendarRange({required this.start, this.extraWindows = 0});

  /// Yesterday when the screen opened.
  final DateTime start;

  /// Windows loaded after the first one.
  final int extraWindows;

  static const firstWindowDays = 21;
  static const moreWindowDays = 14;

  /// How far ahead the agenda may be extended (days after [start]).
  static const maxDays = 366;

  List<CalendarWindow> get windows {
    final out = <CalendarWindow>[(start: start, end: _day(start, firstWindowDays - 1))];
    for (var i = 0; i < extraWindows; i++) {
      final from = _day(out.last.end, 1);
      out.add((start: from, end: _day(from, moreWindowDays - 1)));
    }
    return out;
  }

  /// The last day covered once every window has loaded.
  DateTime get end => windows.last.end;

  /// The last day the agenda can ever reach.
  DateTime get maxEnd => _day(start, maxDays - 1);

  bool get canLoadMore => end.isBefore(maxEnd);

  CalendarRange withExtraWindows(int n) => CalendarRange(start: start, extraWindows: n);

  static DateTime _day(DateTime d, int days) => DateTime.utc(d.year, d.month, d.day + days);
}

final calendarRangeProvider = NotifierProvider.autoDispose<CalendarRangeController, CalendarRange>(
  CalendarRangeController.new,
);

class CalendarRangeController extends Notifier<CalendarRange> {
  @override
  CalendarRange build() {
    final today = CalendarDates.of(ref.read(calendarClockProvider)());
    return CalendarRange(start: DateTime.utc(today.year, today.month, today.day - 1));
  }

  /// Adds the next 2-week window.
  void loadMore() {
    if (state.canLoadMore) state = state.withExtraWindows(state.extraWindows + 1);
  }

  /// Adds windows until [day] is covered (as far as [CalendarRange.maxEnd]).
  void ensureIncludes(DateTime day) {
    var next = state;
    while (next.end.isBefore(day) && next.canLoadMore) {
      next = next.withExtraWindows(next.extraWindows + 1);
    }
    if (next.extraWindows != state.extraWindows) state = next;
  }
}

/// One window. Unmonitored items are always requested and filtered on the
/// device, so the "Show unmonitored" chip needs no reload. Refreshed every
/// 5 min (APP.md §14).
final calendarWindowProvider = FutureProvider.autoDispose.family<CalendarResponse, CalendarWindow>((ref, window) async {
  autoRefresh(ref, RefreshIntervals.calendar);
  return ref.watch(calendarApiProvider).calendar(start: window.start, end: window.end, unmonitored: true);
});

// ---------------------------------------------------------------------------
// Agenda
// ---------------------------------------------------------------------------

/// The items of one day.
class CalendarDay {
  const CalendarDay(this.date, this.items);

  final DateTime date;
  final List<CalendarItem> items;
}

/// Per-day markers for the month grid.
class CalendarDayMarks {
  const CalendarDayMarks({this.episodes = 0, this.movies = 0});

  final int episodes;
  final int movies;

  int get total => episodes + movies;
}

/// The merged, filtered agenda of the loaded windows.
class CalendarAgenda {
  const CalendarAgenda({
    required this.today,
    required this.start,
    required this.loadedEnd,
    required this.items,
    required this.days,
    this.loadingMore = false,
    this.moreError,
    this.canLoadMore = false,
    this.failedSources = const [],
    this.sourceHints = const {},
    this.refreshError,
  });

  final DateTime today;
  final DateTime start;

  /// The last day of the windows that have loaded.
  final DateTime loadedEnd;

  /// Filtered items in agenda order.
  final List<CalendarItem> items;

  /// Days with items, plus today (possibly empty) when it is covered.
  final List<CalendarDay> days;

  /// The next window is loading.
  final bool loadingMore;

  /// The next window failed (retry with [CalendarRangeController.loadMore]
  /// after invalidating it).
  final Object? moreError;
  final bool canLoadMore;

  /// Services whose part of the agenda is missing ("Radarr").
  final List<String> failedSources;

  /// For failed sources whose error says how to fix it (Allowed Hosts,
  /// `upstream_host_rejected`): service name → that message.
  final Map<String, String> sourceHints;

  /// A background refresh failed; the data shown is older.
  final Object? refreshError;

  bool get isEmpty => items.isEmpty;

  bool covers(DateTime day) => !day.isBefore(start) && !day.isAfter(loadedEnd);

  /// Markers per day for the month grid (filtered items only).
  Map<DateTime, CalendarDayMarks> get marks {
    final out = <DateTime, CalendarDayMarks>{};
    for (final i in items) {
      final m = out[i.date] ?? const CalendarDayMarks();
      out[i.date] = i.isMovie
          ? CalendarDayMarks(episodes: m.episodes, movies: m.movies + 1)
          : CalendarDayMarks(episodes: m.episodes + 1, movies: m.movies);
    }
    return out;
  }
}

/// The agenda for the calendar screen: loading/error follow the first
/// window; later windows only add items (or a footer spinner/error).
final calendarAgendaProvider = Provider.autoDispose<AsyncValue<CalendarAgenda>>((ref) {
  final range = ref.watch(calendarRangeProvider);
  final filters = ref.watch(calendarFiltersProvider);
  final today = calendarToday(ref);
  final windows = range.windows;
  final values = [for (final w in windows) ref.watch(calendarWindowProvider(w))];

  final first = values.first;
  if (!first.hasValue) {
    if (first.hasError) return AsyncValue.error(first.error!, first.stackTrace ?? StackTrace.empty);
    return const AsyncValue.loading();
  }
  return AsyncValue.data(buildCalendarAgenda(today: today, range: range, windows: values, filters: filters));
});

/// Merges the window results (in range order) into a [CalendarAgenda].
/// Only the leading windows that have data are shown, so the agenda never
/// has a gap.
CalendarAgenda buildCalendarAgenda({
  required DateTime today,
  required CalendarRange range,
  required List<AsyncValue<CalendarResponse>> windows,
  required Set<CalendarFilter> filters,
}) {
  final loaded = <CalendarResponse>[];
  Object? refreshError;
  for (final v in windows) {
    if (!v.hasValue) break;
    loaded.add(v.requireValue);
    if (v.hasError) refreshError ??= v.error;
  }
  final next = loaded.length < windows.length ? windows[loaded.length] : null;

  final failed = <String>{};
  final hints = <String, String>{};
  var staleUpstream = false;
  final items = <CalendarItem>[];
  for (final r in loaded) {
    for (final (name, status) in [('Sonarr', r.sources.sonarr), ('Radarr', r.sources.radarr)]) {
      if (status == null) continue;
      if (status.status == SectionState.error) {
        failed.add(name);
        final error = status.error;
        if (error != null && error.code == ApiErrorCode.upstreamHostRejected) hints[name] = error.message;
      }
      if (status.isOk && status.error != null) staleUpstream = true;
    }
    for (final i in r.items) {
      if (calendarItemVisible(i, filters)) items.add(i);
    }
  }
  items.sort(CalendarItem.compare);

  final loadedEnd = loaded.isEmpty ? range.start : loaded.last.end;
  final days = <CalendarDay>[];
  for (final i in items) {
    if (days.isEmpty || days.last.date != i.date) {
      days.add(CalendarDay(i.date, [i]));
    } else {
      days.last.items.add(i);
    }
  }
  final todayCovered = !today.isBefore(range.start) && !today.isAfter(loadedEnd);
  if (todayCovered && items.isNotEmpty && !days.any((d) => d.date == today)) {
    final at = days.indexWhere((d) => d.date.isAfter(today));
    days.insert(at < 0 ? days.length : at, CalendarDay(today, const []));
  }

  return CalendarAgenda(
    today: today,
    start: range.start,
    loadedEnd: loadedEnd,
    items: items,
    days: days,
    loadingMore: next != null && !next.hasError,
    moreError: next != null && next.hasError ? next.error : null,
    canLoadMore: range.canLoadMore,
    failedSources: failed.toList(),
    sourceHints: hints,
    refreshError: refreshError ?? (staleUpstream ? const _UpstreamStale() : null),
  );
}

/// Marker for "the hub served cached upstream data".
class _UpstreamStale {
  const _UpstreamStale();
}
