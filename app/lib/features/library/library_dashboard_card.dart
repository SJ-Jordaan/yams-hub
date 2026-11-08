/// The `library` dashboard card (API.md §7.11). Core's DashboardCardFrame
/// supplies the title, route and error/disabled/stale states; this widget
/// renders `section.data` when the section is ok.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/dashboard/section_decode.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import 'widgets/library_widgets.dart';

/// The `library` card on the dashboard (API.md §4).
class LibraryDashboardCard extends ConsumerWidget {
  const LibraryDashboardCard({super.key, required this.section});

  final Section section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    LibraryCard? card;
    try {
      card = decodeCached(section, LibraryCard.fromJson);
    } on FormatException {
      card = null;
    }
    if (card == null) {
      return Text('No data', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant));
    }
    final rows = [
      if (card.sonarr.configured) (ArrService.sonarr, card.sonarr),
      if (card.radarr.configured) (ArrService.radarr, card.radarr),
    ];
    if (rows.isEmpty) {
      return Text(
        'Sonarr and Radarr are not configured',
        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (service, s) in rows) ...[
          LibrarySummaryLine(service: service, summary: s, dense: true),
          if (s.cutoffUnmet > 0 || s.queue.errors)
            Padding(
              padding: const EdgeInsets.only(left: 22, bottom: 4),
              child: Wrap(
                spacing: 6,
                children: [
                  if (s.cutoffUnmet > 0) StatusChip(label: '${formatCount(s.cutoffUnmet)} below cutoff', dense: true),
                  if (s.queue.errors) const StatusChip(label: 'Download errors', tone: StatusTone.error, dense: true),
                ],
              ),
            ),
        ],
      ],
    );
  }
}
