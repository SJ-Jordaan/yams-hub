// The `requests` dashboard card (API.md §6.9). Core's DashboardCardFrame
// supplies the title, route and error/disabled/stale states; this widget
// renders `section.data` when the section is ok.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/dashboard/dashboard_providers.dart';
import 'package:yams_hub/core/dashboard/section_decode.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_models/yams_models.dart';

import 'widgets/request_tile.dart';

/// The `requests` card on the dashboard (API.md §4).
class RequestsDashboardCard extends ConsumerWidget {
  const RequestsDashboardCard({super.key, required this.section});

  final Section section;

  /// Rows shown under the counters (the gateway sends at most 5).
  static const rows = 5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final isAdmin = ref.watch(isAdminProvider);
    RequestsCard card;
    try {
      card = decodeCached(section, RequestsCard.fromJson) ?? const RequestsCard();
    } on FormatException {
      card = const RequestsCard();
    }
    final c = card.counts;
    final list = isAdmin ? card.pending : card.recent;
    final listTab = AppPaths.requestsList(tab: isAdmin ? 'all' : 'mine');
    // APP.md §3.3: pending · processing · available, plus what needs a look.
    final stats = <_Stat>[
      if (isAdmin)
        _Stat('Pending', c.pending, c.pending > 0 ? colors.warning : null, AppPaths.requestsList(tab: 'pending')),
      _Stat('Processing', c.processing, null, listTab),
      _Stat('Available', c.available, null, listTab),
      if (isAdmin && c.failed > 0) _Stat('Failed', c.failed, colors.error, AppPaths.requestsList(tab: 'failed')),
      if (card.openIssues > 0) _Stat('Issues', card.openIssues, colors.warning, AppPaths.issues()),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: [for (final s in stats) _StatChip(stat: s)]),
        const SizedBox(height: 8),
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              isAdmin ? 'No requests waiting' : 'No requests yet',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          )
        else ...[
          Text(isAdmin ? 'Waiting for approval' : 'Your latest requests', style: theme.textTheme.labelLarge),
          for (final r in list.take(rows))
            RequestTile(
              key: ValueKey(r.id),
              request: r,
              compact: true,
              // Admins approve/decline inline (decline asks first).
              actions: isAdmin ? RequestTileActions.decide : RequestTileActions.none,
              onActionDone: () => _refreshCard(ref),
            ),
          if (isAdmin && c.pending > rows)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => context.go(AppPaths.requestsList(tab: 'pending')),
                child: Text('All ${c.pending} pending requests'),
              ),
            ),
        ],
      ],
    );
  }
}

/// Reloads this card on Home after an inline action.
void _refreshCard(WidgetRef ref) {
  if (ref.exists(dashboardProvider)) {
    ref.read(dashboardProvider.notifier).refreshFast([DashboardCardKeys.requests]);
  }
}

class _Stat {
  const _Stat(this.label, this.value, this.color, this.route);

  final String label;
  final int value;
  final Color? color;
  final String route;
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.stat});

  final _Stat stat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = stat.color ?? theme.colorScheme.onSurface;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.go(stat.route),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${stat.value}', style: theme.textTheme.titleLarge?.copyWith(color: color)),
              Text(stat.label, style: theme.textTheme.labelSmall),
            ],
          ),
        ),
      ),
    );
  }
}
