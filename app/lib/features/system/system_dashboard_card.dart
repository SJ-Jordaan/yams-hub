/// The `system` dashboard card (APP.md §3.3, API.md §13.4): CPU % with a
/// 5-min sparkline, temperature, memory bar, volume bar, RAID chip, network
/// down/up with a Tailscale dot, Uptime Kuma "19/21 up". Core's
/// DashboardCardFrame supplies the title, the tap to `/system` and the
/// error/disabled/stale states.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/dashboard/section_decode.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import 'widgets/rate_text.dart';
import 'widgets/system_format.dart';

/// The `system` card on the dashboard (API.md §4).
class SystemDashboardCard extends ConsumerWidget {
  const SystemDashboardCard({super.key, required this.section});

  final Section section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = decodeCached(section, SystemCard.fromJson);
    if (card == null) return const SizedBox.shrink();
    return SystemCardView(card: card);
  }
}

/// The card body for a decoded [SystemCard].
class SystemCardView extends StatelessWidget {
  const SystemCardView({super.key, required this.card});

  final SystemCard card;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final memRatio = card.memTotalBytes <= 0 ? 0.0 : card.memUsedBytes / card.memTotalBytes;
    final volume = card.volume;
    final raid = card.raid;
    final net = card.net;
    final monitors = card.monitors;
    final cpuTone = toneForCpu(card.cpuPercent);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  card.cpuPercent == null ? '–' : formatPercent(card.cpuPercent),
                  key: const Key('systemCard.cpu'),
                  style: theme.textTheme.headlineSmall?.copyWith(color: colors.forTone(cpuTone)),
                ),
                Text('CPU', style: muted),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Sparkline(
                key: const Key('systemCard.sparkline'),
                values: card.cpuSparkline,
                minY: 0,
                maxY: 100,
                height: 40,
                color: colors.forTone(cpuTone),
              ),
            ),
            const SizedBox(width: 12),
            if (card.packageTempC case final t?)
              StatusChip(
                key: const Key('systemCard.temp'),
                icon: Icons.thermostat,
                label: formatCelsius(t),
                tone: toneForTemperature(t),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (card.memTotalBytes > 0)
          ProgressBar(
            key: const Key('systemCard.memory'),
            value: memRatio,
            label: 'Memory',
            trailing: '${formatBytes(card.memUsedBytes)} / ${formatBytes(card.memTotalBytes)}',
            tone: toneForUsage(memRatio),
          ),
        if (volume != null) ...[
          const SizedBox(height: 10),
          ProgressBar(
            key: const Key('systemCard.volume'),
            value: volume.usedPercent / 100,
            label: '/volume1',
            trailing:
                '${formatBytes(volume.usedBytes)} / ${formatBytes(volume.totalBytes)} · ${formatPercent(volume.usedPercent)}',
            tone: toneForUsage(volume.usedPercent / 100),
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (raid != null)
              Row(
                key: const Key('systemCard.raid'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  StatusChip(
                    label: raidChipLabel(raid.level, raid.state),
                    tone: raid.healthy ? StatusTone.ok : StatusTone.error,
                    dense: true,
                  ),
                  if (!raid.redundant) ...[
                    const SizedBox(width: 4),
                    Tooltip(
                      message: noRedundancyText,
                      child: Icon(Icons.info_outline, size: 18, color: colors.warning, semanticLabel: 'No redundancy'),
                    ),
                  ],
                ],
              ),
            if (net != null)
              Row(
                key: const Key('systemCard.net'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  RateText(rxBps: net.rxBps, txBps: net.txBps, style: theme.textTheme.bodySmall),
                  const SizedBox(width: 6),
                  StatusDot(
                    key: const Key('systemCard.tailscale'),
                    size: 8,
                    tone: net.tailscaleActive ? StatusTone.info : StatusTone.neutral,
                    tooltip: net.tailscaleActive ? 'Tailscale: remote use' : 'Tailscale: idle',
                  ),
                ],
              ),
            if (monitors != null)
              StatusChip(
                key: const Key('systemCard.monitors'),
                icon: Icons.monitor_heart_outlined,
                label: '${monitors.up}/${monitors.total} up',
                tone: monitors.down > 0
                    ? StatusTone.error
                    : monitors.pending > 0
                    ? StatusTone.warning
                    : StatusTone.ok,
                dense: true,
              ),
            if (card.uptimeSeconds > 0) Text('up ${formatSeconds(card.uptimeSeconds)}', style: muted),
          ],
        ),
      ],
    );
  }
}
