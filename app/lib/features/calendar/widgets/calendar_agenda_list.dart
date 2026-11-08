/// The agenda: day groups with sticky headers (APP.md §7).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:yams_hub/core/widgets/error_view.dart';

import '../providers/calendar_providers.dart';
import 'calendar_item_tile.dart';

/// Fixed extents of the agenda, so scroll offsets of any day can be computed
/// without building it ("Today" button, month grid taps). They grow with the
/// text scale so rows never clip.
@immutable
final class CalendarAgendaLayout {
  const CalendarAgendaLayout({
    this.rowExtent = CalendarItemTile.defaultExtent,
    this.headerExtent = 40,
    this.emptyDayExtent = 52,
  });

  /// The extents for the text scale of [context].
  factory CalendarAgendaLayout.of(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    // Each extent = padding + its text lines; only the text part scales.
    double grow(double base, double text) => math.max(base, (base - text + scaler.scale(text)).ceilToDouble());
    return CalendarAgendaLayout(rowExtent: grow(76, 52), headerExtent: grow(40, 20), emptyDayExtent: grow(52, 20));
  }

  final double rowExtent;
  final double headerExtent;
  final double emptyDayExtent;

  double dayExtent(CalendarDay day) =>
      headerExtent + (day.items.isEmpty ? emptyDayExtent : day.items.length * rowExtent);

  /// The scroll offset of the first group on or after [date].
  double offsetOf(List<CalendarDay> days, DateTime date) {
    var offset = 0.0;
    for (final d in days) {
      if (!d.date.isBefore(date)) return offset;
      offset += dayExtent(d);
    }
    return offset;
  }

  @override
  bool operator ==(Object other) =>
      other is CalendarAgendaLayout &&
      other.rowExtent == rowExtent &&
      other.headerExtent == headerExtent &&
      other.emptyDayExtent == emptyDayExtent;

  @override
  int get hashCode => Object.hash(rowExtent, headerExtent, emptyDayExtent);
}

class CalendarAgendaList extends StatelessWidget {
  const CalendarAgendaList({
    super.key,
    required this.agenda,
    required this.layout,
    required this.controller,
    required this.now,
    required this.onLoadMore,
    required this.onRetryMore,
  });

  final CalendarAgenda agenda;
  final CalendarAgendaLayout layout;
  final ScrollController controller;
  final DateTime now;
  final VoidCallback onLoadMore;
  final VoidCallback onRetryMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CustomScrollView(
      controller: controller,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        for (final day in agenda.days)
          SliverMainAxisGroup(
            key: ValueKey('calendar-group-${day.date.toIso8601String()}'),
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: _DayHeaderDelegate(
                  extent: layout.headerExtent,
                  label: calendarDayLabel(day.date, agenda.today),
                  isToday: day.date == agenda.today,
                ),
              ),
              if (day.items.isEmpty)
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: layout.emptyDayExtent,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Nothing scheduled today',
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                  ),
                )
              else
                SliverFixedExtentList(
                  itemExtent: layout.rowExtent,
                  delegate: SliverChildBuilderDelegate((context, i) {
                    final item = day.items[i];
                    return CalendarItemTile(
                      key: ValueKey(item.id),
                      item: item,
                      now: now,
                      onTap: () => openCalendarItem(context, item),
                    );
                  }, childCount: day.items.length),
                ),
            ],
          ),
        SliverToBoxAdapter(
          child: _Footer(agenda: agenda, onLoadMore: onLoadMore, onRetry: onRetryMore),
        ),
        // Room for the "Today" button.
        const SliverToBoxAdapter(child: SizedBox(height: 88)),
      ],
    );
  }
}

class _DayHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _DayHeaderDelegate({required this.extent, required this.label, required this.isToday});

  final double extent;
  final String label;
  final bool isToday;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      elevation: overlapsContent ? 1 : 0,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Semantics(
            header: true,
            child: Text(
              label,
              style: theme.textTheme.titleSmall?.copyWith(
                color: isToday ? scheme.primary : scheme.onSurface,
                fontWeight: isToday ? FontWeight.w700 : null,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_DayHeaderDelegate old) => old.extent != extent || old.label != label || old.isToday != isToday;
}

class _Footer extends StatelessWidget {
  const _Footer({required this.agenda, required this.onLoadMore, required this.onRetry});

  final CalendarAgenda agenda;
  final VoidCallback onLoadMore;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final until = 'Showing until ${calendarDayLabel(agenda.loadedEnd, agenda.today)}';
    final Widget child;
    if (agenda.loadingMore) {
      child = const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 12),
          Flexible(child: Text('Loading the next 2 weeks…', overflow: TextOverflow.ellipsis)),
        ],
      );
    } else if (agenda.moreError case final error?) {
      child = ErrorView(error: error, compact: true, onRetry: onRetry);
    } else if (agenda.canLoadMore) {
      child = Column(
        children: [
          Text(until, style: muted),
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: onLoadMore,
            icon: const Icon(Icons.expand_more),
            label: const Text('Load 2 more weeks'),
          ),
        ],
      );
    } else {
      child = Text('End of the calendar · ${calendarDayLabel(agenda.loadedEnd, agenda.today)}', style: muted);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Center(child: child),
    );
  }
}
