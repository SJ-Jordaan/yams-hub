/// Service health card (APP.md §12, `GET /health`): every service with its
/// status, latency, version and message; a row opens the related screen.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

/// The screen a service's health row opens, or null when the service has no
/// screen of its own (Uptime Kuma and the host are on this screen).
String? systemHealthRoute(ServiceId id) => switch (id) {
  ServiceId.sonarr => AppPaths.library(tab: 'tv'),
  ServiceId.radarr => AppPaths.library(tab: 'movies'),
  ServiceId.prowlarr => AppPaths.indexers(),
  ServiceId.bazarr => AppPaths.subtitles(),
  ServiceId.seerr => AppPaths.requests(),
  ServiceId.jellyfin => AppPaths.mediaJellyfin(),
  ServiceId.jellystat => AppPaths.media(tab: 'stats'),
  ServiceId.qbittorrent || ServiceId.gluetun => AppPaths.activity(),
  ServiceId.docker => AppPaths.containers(),
  ServiceId.watchtower || ServiceId.updater => AppPaths.containersUpdates(),
  ServiceId.audiobookshelf => AppPaths.mediaAudiobooks(),
  ServiceId.kavita => AppPaths.mediaBooks(),
  ServiceId.shelfmark => AppPaths.mediaShelfmark(),
  ServiceId.uptimeKuma || ServiceId.host || ServiceId.unknown => null,
};

/// Body of the service health card for a loaded report.
class ServiceHealthContent extends StatelessWidget {
  const ServiceHealthContent({super.key, required this.report});

  final HealthReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (report.services.isEmpty) {
      return Text('No services reported', style: theme.textTheme.bodyMedium);
    }
    final up = report.services.where((s) => s.status == ServiceHealthStatus.up).length;
    final configured = report.services.where((s) => s.status != ServiceHealthStatus.disabled).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            StatusChip.health(report.overall, dense: true),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$up of $configured up · checked ${formatRelative(report.checkedAt)}',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        for (final s in report.services) ServiceHealthRow(health: s),
      ],
    );
  }
}

class ServiceHealthRow extends StatelessWidget {
  const ServiceHealthRow({super.key, required this.health});

  final ServiceHealth health;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final route = systemHealthRoute(health.id);
    final details = [
      if (health.version case final v? when v.isNotEmpty) v,
      if (health.latencyMs case final ms?) '$ms ms',
    ].join(' · ');
    final message = health.message;
    return InkWell(
      key: Key('system.health.${health.id.name}'),
      borderRadius: BorderRadius.circular(8),
      onTap: route == null ? null : () => context.go(route),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            StatusDot(tone: toneForHealth(health.status), tooltip: health.status.name),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(health.name, style: theme.textTheme.bodyMedium),
                  if (message != null && message.isNotEmpty)
                    Text(message, style: muted, maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (details.isNotEmpty) ...[const SizedBox(width: 8), Text(details, style: muted)],
            SizedBox(
              width: 28,
              child: route == null
                  ? null
                  : Icon(Icons.chevron_right, size: 20, color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
