/// `/calendar`: the Sonarr/Radarr agenda (APP.md §7).
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/widgets/async_value_view.dart';
import 'package:yams_hub/core/widgets/empty_view.dart';
import 'package:yams_hub/core/widgets/filter_chips_bar.dart';
import 'package:yams_hub/core/widgets/skeleton.dart';
import 'package:yams_hub/core/widgets/stale_banner.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/calendar_providers.dart';
import '../widgets/calendar_agenda_list.dart';
import '../widgets/calendar_item_tile.dart';
import '../widgets/calendar_month_grid.dart';

/// Body width (beside the navigation rail) from which the month grid is
/// shown next to the agenda: a tablet or a desktop window.
const double calendarWideBreakpoint = 720;

class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  final _scroll = ScrollController();
  final _showToday = ValueNotifier(false);

  /// The agenda and row extents of the last build (scroll listeners read
  /// them).
  CalendarAgenda? _agenda;
  CalendarAgendaLayout _layout = const CalendarAgendaLayout();

  /// The month shown by the grid (wide layout); null = today's month.
  DateTime? _month;
  DateTime? _selected;

  /// A day to scroll to once the windows covering it have loaded.
  DateTime? _pendingJump;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _showToday.dispose();
    super.dispose();
  }

  void _onScroll() {
    _updateTodayButton();
    final agenda = _agenda;
    if (agenda == null || !_scroll.hasClients) return;
    if (_scroll.position.extentAfter < 600) _loadMore(agenda);
  }

  void _updateTodayButton() {
    final agenda = _agenda;
    var show = false;
    if (agenda != null && _scroll.hasClients && agenda.days.any((d) => d.date == agenda.today)) {
      final target = _layout.offsetOf(agenda.days, agenda.today);
      show = (_scroll.offset - target).abs() > _layout.rowExtent * 2;
    }
    if (_showToday.value != show) _showToday.value = show;
  }

  void _loadMore(CalendarAgenda agenda) {
    if (!agenda.canLoadMore || agenda.loadingMore || agenda.moreError != null) return;
    // Scroll positions also notify during layout; providers must not change
    // while the tree builds.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(_agenda, agenda)) ref.read(calendarRangeProvider.notifier).loadMore();
      });
      return;
    }
    ref.read(calendarRangeProvider.notifier).loadMore();
  }

  void _retryMore() {
    final range = ref.read(calendarRangeProvider);
    for (final w in range.windows.skip(1)) {
      if (ref.read(calendarWindowProvider(w)).hasError) ref.invalidate(calendarWindowProvider(w));
    }
  }

  Future<void> _refresh() async {
    ref.invalidate(calendarWindowProvider);
    final first = ref.read(calendarRangeProvider).windows.first;
    try {
      await ref.read(calendarWindowProvider(first).future);
    } catch (_) {
      // The error is shown by the screen.
    }
  }

  /// Scrolls the agenda to [day] (the first day on or after it with items),
  /// loading more windows first when [day] is not covered yet.
  void _jumpTo(DateTime day) {
    final agenda = _agenda;
    if (agenda == null) return;
    if (!agenda.covers(day)) {
      _pendingJump = day;
      ref.read(calendarRangeProvider.notifier).ensureIncludes(day);
      return;
    }
    _pendingJump = null;
    if (!_scroll.hasClients) return;
    final target = _layout.offsetOf(agenda.days, day).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(target, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
  }

  void _afterBuild(CalendarAgenda? agenda) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateTodayButton();
      final pending = _pendingJump;
      if (pending != null && agenda != null && agenda.covers(pending)) _jumpTo(pending);
    });
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(calendarAgendaProvider);
    final filters = ref.watch(calendarFiltersProvider);
    final range = ref.watch(calendarRangeProvider);
    final now = ref.watch(calendarClockProvider)();
    _agenda = value.value;
    _layout = CalendarAgendaLayout.of(context);
    _afterBuild(_agenda);

    final body = AsyncValueView<CalendarAgenda>(
      value: value,
      showStaleBanner: false,
      onRetry: _refresh,
      loading: const SkeletonList(count: 8, leadingSize: 48),
      data: (context, agenda) => _agendaBody(context, agenda, filters, now),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendar'),
        actions: [IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _refresh)],
      ),
      floatingActionButton: ValueListenableBuilder<bool>(
        valueListenable: _showToday,
        builder: (context, show, _) => show
            ? FloatingActionButton.extended(
                onPressed: () {
                  final agenda = _agenda;
                  if (agenda == null) return;
                  setState(() {
                    _selected = agenda.today;
                    _month = agenda.today;
                  });
                  _jumpTo(agenda.today);
                },
                icon: const Icon(Icons.today),
                label: const Text('Today'),
              )
            : const SizedBox.shrink(),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: FilterChipsBar<CalendarFilter>(
              options: CalendarFilter.values,
              selected: filters,
              multi: true,
              labelOf: (f) => f.label,
              onSelected: (f) {
                if (f != null) ref.read(calendarFiltersProvider.notifier).toggle(f);
              },
            ),
          ),
          if (value.value case final agenda?) ..._banners(agenda),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < calendarWideBreakpoint) return body;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 360, child: SingleChildScrollView(child: _monthGrid(value.value, range, now))),
                    const VerticalDivider(width: 1),
                    Expanded(child: body),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _banners(CalendarAgenda agenda) {
    final unexplained = [
      for (final s in agenda.failedSources)
        if (!agenda.sourceHints.containsKey(s)) s,
    ];
    return [
      if (agenda.refreshError != null) StaleBanner(onRetry: _refresh),
      for (final hint in agenda.sourceHints.values) StaleBanner(message: hint, onRetry: _refresh),
      if (unexplained.isNotEmpty)
        StaleBanner(message: "${unexplained.join(' and ')} couldn't be loaded · their items are missing", onRetry: _refresh),
    ];
  }

  Widget _monthGrid(CalendarAgenda? agenda, CalendarRange range, DateTime now) {
    final today = agenda?.today ?? CalendarDates.of(now);
    return CalendarMonthGrid(
      month: _month ?? today,
      today: today,
      selected: _selected,
      marks: agenda?.marks ?? const {},
      firstDay: range.start,
      lastDay: range.maxEnd,
      onMonthChanged: (m) => setState(() => _month = m),
      onDaySelected: (day) {
        setState(() => _selected = day);
        _jumpTo(day);
      },
    );
  }

  Widget _agendaBody(BuildContext context, CalendarAgenda agenda, Set<CalendarFilter> filters, DateTime now) {
    if (agenda.isEmpty) {
      final noKinds = !filters.contains(CalendarFilter.episodes) && !filters.contains(CalendarFilter.movies);
      return RefreshIndicator(
        onRefresh: _refresh,
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: SizedBox(
              height: constraints.maxHeight,
              child: EmptyView(
                icon: Icons.event_available_outlined,
                title: 'Nothing airing in this period',
                message: noKinds
                    ? 'Turn on Episodes or Movies to see the agenda.'
                    : 'Until ${calendarDayLabel(agenda.loadedEnd, agenda.today)}.',
                action: agenda.loadingMore
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : agenda.canLoadMore && !noKinds
                    ? OutlinedButton.icon(
                        onPressed: () => _loadMore(agenda),
                        icon: const Icon(Icons.expand_more),
                        label: const Text('Look 2 weeks further'),
                      )
                    : null,
              ),
            ),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: CalendarAgendaList(
        agenda: agenda,
        layout: _layout,
        controller: _scroll,
        now: now,
        onLoadMore: () => _loadMore(agenda),
        onRetryMore: _retryMore,
      ),
    );
  }
}
