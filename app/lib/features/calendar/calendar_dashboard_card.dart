/// The `calendar` card on the dashboard, "Upcoming" (APP.md §3.3, API.md
/// §9.2): the next 7 days, at most 8 rows grouped by day. Core's
/// `DashboardCardFrame` supplies the title, the tap to `/calendar` and the
/// error/disabled/stale states.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/dashboard/section_decode.dart';
import 'package:yams_hub/core/widgets/hub_image.dart';
import 'package:yams_models/yams_models.dart';

import 'providers/calendar_providers.dart';
import 'widgets/calendar_item_tile.dart';

/// The `calendar` card on the dashboard (API.md §4).
class CalendarDashboardCard extends ConsumerWidget {
  const CalendarDashboardCard({super.key, required this.section});

  final Section section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final CalendarCard card;
    try {
      card = decodeCached(section, CalendarCard.fromJson) ?? const CalendarCard(items: [], countNext7Days: 0);
    } on FormatException {
      return Text('Unexpected data from the hub', style: theme.textTheme.bodyMedium?.copyWith(color: muted));
    }
    // An ok card with an error but no stale flag: one source failed and its
    // items are missing (the frame only shows stale data itself).
    final partial = section.stale ? null : section.error;
    final Widget? partialNote = partial == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Icon(Icons.cloud_off_outlined, size: 16, color: theme.colorScheme.error),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    partial.code == ApiErrorCode.upstreamHostRejected
                        ? partial.message
                        : "${partial.service?.displayName ?? 'A source'} couldn't be loaded · its items are missing",
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ),
              ],
            ),
          );
    if (card.items.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.event_available_outlined, size: 18, color: muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Nothing scheduled this week', style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
              ),
            ],
          ),
          ?partialNote,
        ],
      );
    }

    final now = ref.watch(calendarClockProvider)();
    final today = CalendarDates.of(now);
    final more = card.countNext7Days - card.items.length;
    final children = <Widget>[];
    DateTime? day;
    for (final item in card.items) {
      if (item.date != day) {
        day = item.date;
        children.add(
          Padding(
            padding: EdgeInsets.only(top: children.isEmpty ? 0 : 8, bottom: 4),
            child: Text(
              calendarShortDayLabel(item.date, today),
              style: theme.textTheme.labelLarge?.copyWith(
                color: item.date == today ? theme.colorScheme.primary : muted,
              ),
            ),
          ),
        );
      }
      children.add(_CardRow(item: item, now: now));
    }
    if (more > 0) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('+$more more this week', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...children, ?partialNote]);
  }
}

class _CardRow extends StatelessWidget {
  const _CardRow({required this.item, required this.now});

  final CalendarItem item;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    // Unmonitored: dimmed poster and muted text, without an Opacity layer.
    final dimmed = !item.monitored;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          HubImage(
            item.posterPath,
            width: 28,
            height: 42,
            borderRadius: BorderRadius.circular(4),
            placeholderIcon: item.isMovie ? Icons.movie_outlined : Icons.tv_outlined,
            opacity: dimmed ? calendarDimmedOpacity : 1,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: dimmed ? theme.textTheme.bodyMedium?.copyWith(color: muted) : theme.textTheme.bodyMedium,
                ),
                Text(
                  item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: dimmed ? muted.withValues(alpha: calendarDimmedAlpha) : muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          CalendarWhen(item: item, dimmed: dimmed),
          const SizedBox(width: 6),
          CalendarStatusIcon(item: item, now: now, size: 16),
        ],
      ),
    );
  }
}
