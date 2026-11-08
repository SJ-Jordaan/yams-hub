/// Uptime card (APP.md §12): pinned incident banner, groups of monitors with a
/// status dot, a 30-beat bar, 24 h uptime and the ping of http monitors.
library;

import 'package:flutter/material.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import 'system_format.dart';

/// Body of the uptime card for loaded data.
class UptimeContent extends StatelessWidget {
  const UptimeContent({super.key, required this.uptime});

  final UptimeResponse uptime;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = uptime.counts;
    final incident = uptime.incident;
    final monitors = uptime.groups.expand((g) => g.monitors).length;
    if (monitors == 0 && incident == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: _Note(icon: Icons.monitor_heart_outlined, text: 'No monitors on the status page'),
      );
    }
    final summary = [
      '${c.up}/${c.total} up',
      if (c.down > 0) '${c.down} down',
      if (c.pending > 0) '${c.pending} pending',
      if (c.maintenance > 0) '${c.maintenance} in maintenance',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (incident != null) ...[_IncidentBanner(incident: incident), const SizedBox(height: 12)],
        Text(
          summary,
          key: const Key('system.uptimeSummary'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: StatusColors.of(context).forTone(c.down > 0 ? StatusTone.error : StatusTone.ok),
          ),
        ),
        for (final g in uptime.groups)
          if (g.monitors.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(g.name, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
            const SizedBox(height: 4),
            for (final m in g.monitors) UptimeMonitorRow(monitor: m),
          ],
      ],
    );
  }
}

class UptimeMonitorRow extends StatelessWidget {
  const UptimeMonitorRow({super.key, required this.monitor});

  final UptimeMonitor monitor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final ping = monitor.pingMs;
    final last = monitor.lastBeatAt;
    return Tooltip(
      message: [
        uptimeStatusLabel(monitor.status),
        if (last != null) 'last beat ${formatRelative(last)} (${formatDateTime(last)})',
      ].join(' · '),
      child: Padding(
        key: Key('system.monitor.${monitor.id}'),
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            StatusDot(tone: toneForUptime(monitor.status)),
            const SizedBox(width: 10),
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(monitor.name, style: theme.textTheme.bodyMedium, overflow: TextOverflow.ellipsis),
                  if (monitor.type == 'http' && ping != null) Text('$ping ms', style: muted),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(flex: 6, child: UptimeBeatBar(beats: monitor.beats)),
            SizedBox(
              width: 56,
              child: Text(formatUptimeRatio(monitor.uptime24h), style: muted, textAlign: TextAlign.end),
            ),
          ],
        ),
      ),
    );
  }
}

/// The last [slots] beats as coloured ticks, newest on the right; missing
/// beats are empty slots on the left.
class UptimeBeatBar extends StatelessWidget {
  const UptimeBeatBar({super.key, required this.beats, this.slots = 30, this.height = 16});

  final List<UptimeBeat> beats;
  final int slots;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    final empty = Theme.of(context).colorScheme.surfaceContainerHighest;
    final shown = beats.length > slots ? beats.sublist(beats.length - slots) : beats;
    final pad = slots - shown.length;
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < slots; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 0.75),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: i < pad ? empty : colors.forTone(toneForUptime(shown[i - pad].status)),
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _IncidentBanner extends StatelessWidget {
  const _IncidentBanner({required this.incident});

  final UptimeIncident incident;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = switch (incident.style) {
      'danger' => StatusTone.error,
      'warning' => StatusTone.warning,
      'primary' || 'info' => StatusTone.info,
      _ => StatusTone.neutral,
    };
    final color = StatusColors.of(context).forTone(tone);
    final created = incident.createdAt;
    return Container(
      key: const Key('system.incident'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.campaign_outlined, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(incident.title, style: theme.textTheme.titleSmall),
                if (incident.content.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(incident.content, style: theme.textTheme.bodyMedium),
                ],
                if (created != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    formatRelative(created),
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      ],
    );
  }
}
