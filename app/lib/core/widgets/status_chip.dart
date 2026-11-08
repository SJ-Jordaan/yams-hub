import 'package:flutter/material.dart';
import 'package:yams_models/yams_models.dart';

import '../theme/theme.dart';

/// A small coloured status label; the colour comes from [StatusColors].
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, this.tone = StatusTone.neutral, this.icon, this.dense = false});

  /// Service health ("Up", "Degraded", ...).
  factory StatusChip.health(ServiceHealthStatus status, {Key? key, bool dense = false}) => StatusChip(
    key: key,
    label: switch (status) {
      ServiceHealthStatus.up => 'Up',
      ServiceHealthStatus.degraded => 'Degraded',
      ServiceHealthStatus.down => 'Down',
      ServiceHealthStatus.disabled => 'Disabled',
      ServiceHealthStatus.unknown => 'Unknown',
    },
    tone: toneForHealth(status),
    dense: dense,
  );

  /// Job status ("Running", "Succeeded", ...).
  factory StatusChip.job(JobStatus status, {Key? key, bool dense = false}) => StatusChip(
    key: key,
    label: switch (status) {
      JobStatus.queued => 'Queued',
      JobStatus.running => 'Running',
      JobStatus.succeeded => 'Succeeded',
      JobStatus.failed => 'Failed',
      JobStatus.unknown => 'Unknown',
    },
    tone: toneForJob(status),
    dense: dense,
  );

  final String label;
  final StatusTone tone;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = StatusColors.of(context).forTone(tone);
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 8, vertical: dense ? 1 : 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: dense ? 12 : 14, color: color), const SizedBox(width: 4)],
          Text(
            label,
            style: (dense ? theme.textTheme.labelSmall : theme.textTheme.labelMedium)?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// A coloured status dot (launcher tiles, health rows).
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.tone, this.size = 10, this.tooltip});

  final StatusTone tone;
  final double size;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: StatusColors.of(context).forTone(tone), shape: BoxShape.circle),
    );
    return tooltip == null ? dot : Tooltip(message: tooltip, child: dot);
  }
}
