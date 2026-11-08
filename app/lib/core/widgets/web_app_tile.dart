import 'package:flutter/material.dart';
import 'package:yams_models/yams_models.dart';

import '../theme/theme.dart';
import 'status_chip.dart';

/// A launcher tile: Material icon in a tinted circle, name, status dot and
/// version (ARCHITECTURE §7.9). Used by the web-apps launcher and Media > Apps.
class WebAppTile extends StatelessWidget {
  const WebAppTile({
    super.key,
    required this.icon,
    required this.name,
    this.status,
    this.version,
    this.subtitle,
    this.onTap,
    this.onLongPress,
    this.compact = false,
  });

  final IconData icon;
  final String name;

  /// Health status; null shows no dot (e.g. Portainer has no probe).
  final ServiceHealthStatus? status;
  final String? version;

  /// Extra line under the name (Media > Apps headline).
  final String? subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Icon + name only (dashboard section).
  final bool compact;

  static String statusLabel(ServiceHealthStatus s) => switch (s) {
    ServiceHealthStatus.up => 'Up',
    ServiceHealthStatus.degraded => 'Degraded',
    ServiceHealthStatus.down => 'Down',
    ServiceHealthStatus.disabled => 'Not configured',
    ServiceHealthStatus.unknown => 'Unknown',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = status;
    final circle = Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: compact ? 20 : 24,
          backgroundColor: scheme.primaryContainer,
          child: Icon(icon, color: scheme.onPrimaryContainer, size: compact ? 20 : 24),
        ),
        if (s != null)
          Positioned(
            right: -1,
            bottom: -1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: theme.cardTheme.color ?? scheme.surface, width: 2),
              ),
              child: StatusDot(tone: toneForHealth(s), size: 12, tooltip: statusLabel(s)),
            ),
          ),
      ],
    );
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: EdgeInsets.all(compact ? 8 : 12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              circle,
              SizedBox(height: compact ? 6 : 8),
              // Flexible: long names and versions ellipsize instead of
              // overflowing small tiles or large text scales.
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: compact ? theme.textTheme.labelMedium : theme.textTheme.titleSmall,
                ),
              ),
              if (!compact && (subtitle ?? version) != null)
                Flexible(
                  child: Text(
                    subtitle ?? version!,
                    maxLines: subtitle == null ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
