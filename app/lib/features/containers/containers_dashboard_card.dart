/// The `containers` dashboard card (API.md §11.8). Core's DashboardCardFrame
/// supplies the title, route and error/disabled/stale states; this widget
/// renders `section.data` when the section is ok.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import 'widgets/container_visuals.dart';

/// The `containers` card on the dashboard (API.md §4).
class ContainersDashboardCard extends ConsumerWidget {
  const ContainersDashboardCard({super.key, required this.section});

  final Section section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final ContainersCard? card;
    try {
      card = section.decode(ContainersCard.fromJson);
    } on FormatException {
      return Text('No data', style: theme.textTheme.bodyMedium);
    }
    if (card == null) return Text('No data', style: theme.textTheme.bodyMedium);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final allUp = card.running == card.total && card.unhealthy.isEmpty;
    final scan = card.lastScan;
    final declutter = card.decluttarr;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('${card.running}', style: theme.textTheme.headlineMedium),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Text('/ ${card.total} running', style: theme.textTheme.titleSmall),
            ),
            const Spacer(),
            if (allUp)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Icon(Icons.check_circle, color: colors.ok, semanticLabel: 'All running'),
              ),
          ],
        ),
        if (card.unhealthy.isNotEmpty || card.stopped.isNotEmpty || card.updatesAvailable > 0) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final n in card.unhealthy)
                ActionChip(
                  avatar: Icon(Icons.heart_broken_outlined, size: 16, color: colors.error),
                  label: Text(n),
                  tooltip: '$n is unhealthy',
                  onPressed: () => context.go(AppPaths.container(n)),
                ),
              for (final n in card.stopped)
                ActionChip(
                  avatar: Icon(Icons.stop_circle_outlined, size: 16, color: colors.warning),
                  label: Text(n),
                  tooltip: '$n is stopped',
                  onPressed: () => context.go(AppPaths.container(n)),
                ),
              if (card.updatesAvailable > 0)
                ActionChip(
                  avatar: Icon(Icons.system_update_alt, size: 16, color: colors.info),
                  label: Text(card.updatesAvailable == 1 ? '1 update' : '${card.updatesAvailable} updates'),
                  onPressed: () => context.go(AppPaths.containersUpdates()),
                ),
            ],
          ),
        ],
        if (card.topCpu.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (final c in card.topCpu)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(child: Text(c.name, overflow: TextOverflow.ellipsis)),
                  UsageBar(
                    label: formatPercent(c.cpuPercent, decimals: 1),
                    fraction: cpuFraction(c.cpuPercent),
                    width: 72,
                  ),
                ],
              ),
            ),
        ],
        if (scan != null) ...[
          const SizedBox(height: 8),
          Text(
            [
              'Watchtower',
              if (scan.at != null) 'last scan ${formatRelative(scan.at)}' else if (scan.scansTotal == 0) 'no scan yet',
              '${scan.scanned} scanned',
              if (scan.updated > 0) '${scan.updated} updated',
              if (scan.failed > 0) '${scan.failed} failed',
            ].join(' · '),
            style: muted,
          ),
        ],
        if (declutter != null) ...[
          const SizedBox(height: 2),
          Text(
            [
              'Decluttarr',
              if (declutter.lastRunAt != null) 'last run ${formatTime(declutter.lastRunAt)}',
              declutter.removed24h == 0 ? 'nothing removed (24 h)' : '${declutter.removed24h} removed (24 h)',
            ].join(' · '),
            style: muted,
          ),
        ],
      ],
    );
  }
}
