// The "Downloads" dashboard card (APP.md §3.3, API.md §8.9). Core's
// DashboardCardFrame supplies the title, route and error/disabled/stale
// states; this widget renders `section.data` when the section is ok.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/dashboard/section_decode.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import 'widgets/activity_format.dart';

/// The `activity` card on the dashboard (API.md §4).
class ActivityDashboardCard extends ConsumerWidget {
  const ActivityDashboardCard({super.key, required this.section});

  final Section section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ActivityCard? card;
    try {
      card = decodeCached(section, ActivityCard.fromJson);
    } on FormatException {
      card = null;
    }
    final theme = Theme.of(context);
    if (card == null) {
      return Text('No data', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant));
    }
    final c = card;
    final colors = StatusColors.of(context);
    final big = theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 20,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SpeedText(bps: c.transfer.dlBps, direction: SpeedDirection.down, style: big),
            SpeedText(bps: c.transfer.upBps, direction: SpeedDirection.up, style: big),
            if (c.transfer.altSpeedEnabled)
              const StatusChip(label: 'Alt speed', icon: Icons.slow_motion_video, tone: StatusTone.info, dense: true),
            if (c.transfer.connectionStatus != TransferConnectionStatus.connected &&
                c.transfer.connectionStatus != TransferConnectionStatus.unknown)
              StatusChip(
                label: connectionLabel(c.transfer.connectionStatus),
                tone: connectionTone(c.transfer.connectionStatus),
                dense: true,
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _Count(label: 'Downloading', value: c.counts.downloading),
            _Count(label: 'Seeding', value: c.counts.seeding),
            _Count(
              label: 'Attention',
              value: c.counts.attention,
              color: c.counts.attention > 0 ? colors.warning : null,
            ),
          ],
        ),
        if (c.top.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (final item in c.top) _TopItem(item: item, admin: ref.watch(isAdminProvider)),
        ],
        if (c.vpn case final vpn?) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              StatusDot(tone: vpnTone(vpn.status)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  vpnSummary(vpn),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: vpn.status == VpnConnectionState.down ? colors.error : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.label, required this.value, this.color});

  final String label;
  final int value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$value', style: theme.textTheme.titleLarge?.copyWith(color: color)),
          Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _TopItem extends StatelessWidget {
  const _TopItem({required this.item, required this.admin});

  final QueueItem item;

  /// Only admins can import: members open the queue.
  final bool admin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final attention = item.attention;
    final tone = attention == null ? null : attentionTone(attention);
    final trailing = attention != null
        ? attentionLabel(attention)
        : '${formatPercent(item.progress * 100)} · ${formatEta(item.etaSeconds)}';
    return InkWell(
      onTap: () => context.go(
        admin && (attention?.isImport ?? false)
            ? AppPaths.activity(tab: 'queue', importKey: item.key)
            : AppPaths.activity(tab: 'queue'),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.title,
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    trailing,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: tone == null ? null : StatusColors.of(context).forTone(tone),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ProgressBar(value: item.progress, tone: tone),
          ],
        ),
      ),
    );
  }
}
