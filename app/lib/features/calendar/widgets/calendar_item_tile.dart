/// One agenda row (APP.md §7) and the small helpers the calendar screen and
/// the dashboard card share.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/formatters.dart';
import 'package:yams_hub/core/widgets/hub_image.dart';
import 'package:yams_models/yams_models.dart';

/// A [CalendarItem.date] as a device-local [DateTime] (for [DateFormat]).
DateTime _local(DateTime date) => DateTime(date.year, date.month, date.day);

/// "Today · Sun 8 Nov", "Tomorrow · Mon 9 Nov", "Yesterday · Sat 7 Nov",
/// "Tue 10 Nov" (with the year when it is not [today]'s year).
String calendarDayLabel(DateTime date, DateTime today) {
  final pattern = date.year == today.year ? 'EEE d MMM' : 'EEE d MMM y';
  final text = DateFormat(pattern).format(_local(date));
  return switch (date.difference(today).inDays) {
    0 => 'Today · $text',
    1 => 'Tomorrow · $text',
    -1 => 'Yesterday · $text',
    _ => text,
  };
}

/// "Today", "Tomorrow", else the weekday ("Tuesday"): the dashboard card
/// headings (APP.md §3.3).
String calendarShortDayLabel(DateTime date, DateTime today) => switch (date.difference(today).inDays) {
  0 => 'Today',
  1 => 'Tomorrow',
  -1 => 'Yesterday',
  _ => DateFormat('EEEE').format(_local(date)),
};

/// "Season finale" etc. for Sonarr's `finaleType`.
String? calendarFinaleLabel(String? finaleType) => switch (finaleType) {
  null || '' => null,
  'series' => 'Series finale',
  'season' => 'Season finale',
  'midseason' => 'Midseason finale',
  _ => 'Finale',
};

/// Opens the series or movie of [item] in the library.
void openCalendarItem(BuildContext context, CalendarItem item) {
  final target = switch (item) {
    CalendarItem(isEpisode: true, seriesId: final id?) => AppPaths.seriesDetail(id),
    CalendarItem(isMovie: true, movieId: final id?) => AppPaths.movieDetail(id),
    _ => null,
  };
  if (target != null) context.go(target);
}

/// The download state of an item.
enum CalendarItemState {
  downloaded('Downloaded', Icons.check_circle, StatusTone.ok),
  downloading('Downloading', Icons.downloading, StatusTone.info),
  missing('Missing', Icons.radio_button_unchecked, StatusTone.warning),
  upcoming('Not aired yet', Icons.radio_button_unchecked, StatusTone.neutral);

  const CalendarItemState(this.label, this.icon, this.tone);

  final String label;
  final IconData icon;
  final StatusTone tone;

  static CalendarItemState of(CalendarItem item, {required DateTime now}) {
    if (item.hasFile) return downloaded;
    if (item.downloading) return downloading;
    final aired = switch (item.airDateUtc) {
      final at? => !at.isAfter(now.toUtc()),
      null => !item.date.isAfter(CalendarDates.of(now)),
    };
    return aired ? missing : upcoming;
  }
}

Color _toneColor(BuildContext context, StatusTone tone) {
  final c = StatusColors.of(context);
  return switch (tone) {
    StatusTone.ok => c.ok,
    StatusTone.warning => c.warning,
    StatusTone.error => c.error,
    StatusTone.info => c.info,
    StatusTone.neutral => c.neutral,
  };
}

/// The status icon (✓ downloaded, ↓ downloading, ◯ missing/unaired).
class CalendarStatusIcon extends StatelessWidget {
  const CalendarStatusIcon({super.key, required this.item, required this.now, this.size = 20});

  final CalendarItem item;
  final DateTime now;
  final double size;

  @override
  Widget build(BuildContext context) {
    final state = CalendarItemState.of(item, now: now);
    final label = item.isMovie && state == CalendarItemState.upcoming ? 'Not released yet' : state.label;
    final text = item.monitored ? label : '$label · unmonitored';
    return Tooltip(
      message: text,
      child: Icon(state.icon, size: size, color: _toneColor(context, state.tone), semanticLabel: text),
    );
  }
}

/// The left column of a row: the air time of an episode, or the release type
/// of a movie.
class CalendarWhen extends StatelessWidget {
  const CalendarWhen({super.key, required this.item});

  final CalendarItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final at = item.airDateUtc;
    if (item.isMovie || at == null) {
      final label = item.releaseType?.label ?? 'All day';
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: theme.colorScheme.tertiaryContainer, borderRadius: BorderRadius.circular(6)),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.fade,
          softWrap: false,
          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onTertiaryContainer),
        ),
      );
    }
    return Text(formatTime(at), style: theme.textTheme.labelLarge);
  }
}

/// A small finale badge.
class CalendarFinaleBadge extends StatelessWidget {
  const CalendarFinaleBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(6)),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSecondaryContainer),
      ),
    );
  }
}

/// One agenda row, exactly [extent] high (the agenda computes scroll offsets
/// from it, see `CalendarAgendaLayout`).
class CalendarItemTile extends StatelessWidget {
  const CalendarItemTile({super.key, required this.item, required this.now, this.onTap, this.extent = defaultExtent});

  /// The height at text scale 1.
  static const double defaultExtent = 76;

  final double extent;

  final CalendarItem item;
  final DateTime now;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final finale = calendarFinaleLabel(item.finaleType);
    final detail = item.isEpisode ? item.network : null;
    final content = Row(
      children: [
        SizedBox(
          width: 64,
          child: Align(
            alignment: Alignment.centerLeft,
            // Large text: shrink the time/chip rather than overflow.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: CalendarWhen(item: item),
            ),
          ),
        ),
        HubImage(
          item.posterPath,
          width: 40,
          height: 60,
          borderRadius: BorderRadius.circular(6),
          placeholderIcon: item.isMovie ? Icons.movie_outlined : Icons.tv_outlined,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  if (finale != null) ...[
                    const SizedBox(width: 6),
                    Flexible(child: CalendarFinaleBadge(label: finale)),
                  ],
                ],
              ),
              Text(
                item.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
              if (detail != null)
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: muted),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        CalendarStatusIcon(item: item, now: now),
      ],
    );
    return SizedBox(
      height: extent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: item.monitored ? content : Opacity(opacity: 0.5, child: content),
        ),
      ),
    );
  }
}
