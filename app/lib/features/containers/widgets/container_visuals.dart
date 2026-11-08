/// Small shared visuals of the containers screens: state dots, health chips,
/// group names and usage bars.
library;

import 'package:flutter/material.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

/// Display groups in screen order (policy groups, API.md §11.1).
const containerGroupOrder = ['media', 'automation', 'downloads', 'system', 'other'];

String containerGroupLabel(String group) => switch (group) {
  'media' => 'Media',
  'automation' => 'Automation',
  'downloads' => 'Downloads',
  'system' => 'System',
  'other' => 'Other',
  _ => group.isEmpty ? 'Other' : '${group[0].toUpperCase()}${group.substring(1)}',
};

/// Green running, amber restarting/paused, grey exited, red dead.
StatusTone containerStateTone(ContainerState s) => switch (s) {
  ContainerState.running => StatusTone.ok,
  ContainerState.restarting || ContainerState.paused || ContainerState.created => StatusTone.warning,
  ContainerState.dead => StatusTone.error,
  _ => StatusTone.neutral,
};

String containerStateLabel(ContainerState s) => switch (s) {
  ContainerState.created => 'Created',
  ContainerState.running => 'Running',
  ContainerState.paused => 'Paused',
  ContainerState.restarting => 'Restarting',
  ContainerState.removing => 'Removing',
  ContainerState.exited => 'Exited',
  ContainerState.dead => 'Dead',
  ContainerState.unknown => 'Unknown',
};

/// The health chip; nothing for containers without a healthcheck.
class ContainerHealthChip extends StatelessWidget {
  const ContainerHealthChip(this.health, {super.key, this.dense = true});

  final ContainerHealth health;
  final bool dense;

  @override
  Widget build(BuildContext context) => switch (health) {
    ContainerHealth.healthy => StatusChip(label: 'healthy', tone: StatusTone.ok, dense: dense),
    ContainerHealth.unhealthy => StatusChip(label: 'unhealthy', tone: StatusTone.error, dense: dense),
    ContainerHealth.starting => StatusChip(label: 'starting', tone: StatusTone.warning, dense: dense),
    _ => const SizedBox.shrink(),
  };
}

/// `Up 2h 5m`, `Exited`, ... for a list row.
String containerUptimeText(ContainerSummary c) {
  if (c.isRunning && c.uptimeSeconds != null) return 'Up ${formatSeconds(c.uptimeSeconds)}';
  return c.statusText.isEmpty ? containerStateLabel(c.state) : c.statusText;
}

/// A thin inline usage bar with its label (CPU / memory in list rows).
class UsageBar extends StatelessWidget {
  const UsageBar({super.key, required this.label, required this.fraction, this.width = 56});

  final String label;

  /// 0..1.
  final double fraction;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final f = fraction.clamp(0.0, 1.0);
    final color = f >= 0.9 ? colors.error : (f >= 0.7 ? colors.warning : theme.colorScheme.primary);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: width,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: f,
              minHeight: 4,
              color: color,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: theme.textTheme.labelSmall),
      ],
    );
  }
}

/// CPU share of the host (cpuPercent is 0..100 × cores; the N100 has 4).
double cpuFraction(double percent, {int cores = 4}) => percent / (100 * cores);

/// Short image id (`sha256:ae55f56fa15c` → `ae55f56fa15c`).
String shortImageId(String id) {
  final hex = id.startsWith('sha256:') ? id.substring(7) : id;
  return hex.length > 12 ? hex.substring(0, 12) : hex;
}

/// Human cron for the usual Recyclarr schedules (`0 4 * * 0` → `Sundays 04:00`).
String describeCron(String expression) {
  final f = expression.trim().split(RegExp(r'\s+'));
  if (f.length != 5) return expression;
  final minute = int.tryParse(f[0]);
  final hour = int.tryParse(f[1]);
  if (minute == null || hour == null || f[2] != '*' || f[3] != '*') return expression;
  final time = '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  if (f[4] == '*') return 'Daily $time';
  const days = ['Sundays', 'Mondays', 'Tuesdays', 'Wednesdays', 'Thursdays', 'Fridays', 'Saturdays'];
  final d = int.tryParse(f[4]);
  if (d == null || d < 0 || d > 7) return expression;
  return '${days[d % 7]} $time';
}
