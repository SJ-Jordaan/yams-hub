// The `indexers` dashboard card (APP.md §3.3): enabled/total, failing
// indexers with "retry at", and the last 24 h of grabs and queries. Core's
// DashboardCardFrame supplies the title, route and error/disabled/stale states.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import 'widgets/indexer_widgets.dart';

/// Failing indexers listed before "+N more".
const _maxFailingRows = 4;

/// The `indexers` card on the dashboard (API.md §10.6).
class IndexersDashboardCard extends ConsumerWidget {
  const IndexersDashboardCard({super.key, required this.section});

  final Section section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final IndexersCard? card;
    try {
      card = section.decode(IndexersCard.fromJson);
    } on FormatException {
      return Text('No data', style: muted);
    }
    if (card == null) return Text('No data', style: muted);
    if (card.total == 0) {
      return Text('No indexers configured in Prowlarr', style: muted);
    }

    final grabs = card.grabs24h;
    final queries = card.queries24h;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text('${card.enabled}', style: theme.textTheme.headlineSmall),
            Text(' / ${card.total} enabled', style: theme.textTheme.bodyMedium),
            const Spacer(),
            if (grabs != null || queries != null)
              Flexible(
                child: Text(
                  [
                    if (grabs != null) '${formatCount(grabs)} grabs',
                    if (queries != null) '${formatCount(queries)} queries',
                  ].join(' · '),
                  style: muted,
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        if (grabs != null || queries != null)
          Align(
            alignment: Alignment.centerRight,
            child: Text('last 24 h', style: muted),
          ),
        const SizedBox(height: 8),
        if (card.failing.isEmpty)
          Row(
            children: [
              Icon(Icons.check_circle, size: 18, color: colors.ok),
              const SizedBox(width: 8),
              Text('All indexers working', style: theme.textTheme.bodyMedium),
            ],
          )
        else ...[
          for (final f in card.failing.take(_maxFailingRows))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 18, color: colors.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      f.name,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  if (f.disabledTill case final t?)
                    Text('retry at ${formatRetryTime(t)}', style: muted),
                ],
              ),
            ),
          if (card.failing.length > _maxFailingRows)
            Text(
              '+${card.failing.length - _maxFailingRows} more failing',
              style: muted,
            ),
        ],
      ],
    );
  }
}
