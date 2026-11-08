/// The dashboard's alerts panel (APP.md §3.3): sorted by severity, colour
/// bar, tap opens the alert's route, dismissible alerts remembered per device.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_models/yams_models.dart';

import '../settings/app_settings.dart';
import '../theme/theme.dart';
import '../widgets/formatters.dart';
import 'dashboard_providers.dart';

/// [alerts] without the dismissed ones, most severe first (newest first
/// within a severity).
List<Alert> visibleAlerts(List<Alert> alerts, Set<String> dismissed) {
  final list = [
    for (final a in alerts)
      if (!(a.dismissible && dismissed.contains(a.id))) a,
  ];
  list.sort((a, b) {
    final bySeverity = b.severity.rank.compareTo(a.severity.rank);
    if (bySeverity != 0) return bySeverity;
    final sa = a.since, sb = b.since;
    if (sa == null || sb == null) return sa == null ? (sb == null ? 0 : 1) : -1;
    return sb.compareTo(sa);
  });
  return list;
}

/// The dashboard's alerts; watches only `alerts` of [dashboardProvider].
class AlertsPanel extends ConsumerStatefulWidget {
  const AlertsPanel({super.key});

  /// Rows shown before "N more".
  static const collapsedCount = 3;

  @override
  ConsumerState<AlertsPanel> createState() => _AlertsPanelState();
}

class _AlertsPanelState extends ConsumerState<AlertsPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final dismissed = ref.watch(appSettingsProvider.select((s) => s.dismissedAlerts));
    final all = ref.watch(dashboardProvider.select((s) => s.value?.alerts ?? const <Alert>[]));
    final alerts = visibleAlerts(all, dismissed);
    if (alerts.isEmpty) return const SizedBox.shrink();
    final shown = _expanded ? alerts : alerts.take(AlertsPanel.collapsedCount).toList();
    final hidden = alerts.length - shown.length;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, a) in shown.indexed) ...[
            if (i > 0) const Divider(height: 1),
            _AlertRow(
              alert: a,
              onDismiss: a.dismissible ? () => ref.read(appSettingsProvider.notifier).dismissAlert(a.id) : null,
            ),
          ],
          if (hidden > 0 || _expanded && alerts.length > AlertsPanel.collapsedCount)
            TextButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded ? 'Show less' : '$hidden more'),
            ),
        ],
      ),
    );
  }
}

class _AlertRow extends StatelessWidget {
  const _AlertRow({required this.alert, this.onDismiss});

  final Alert alert;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = StatusColors.of(context).forTone(toneForSeverity(alert.severity));
    final route = alert.route;
    final canOpen = route != null && route.startsWith('/') && !route.startsWith('//');
    final since = alert.since;
    final subtitle = [
      if (alert.message != null && alert.message!.isNotEmpty) alert.message!,
      if (since != null) formatRelative(since),
    ].join(' · ');
    return InkWell(
      onTap: canOpen ? () => context.go(route) : null,
      // The colour bar is a border, not a stretched child: no intrinsic
      // layout pass.
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(width: 4, color: color)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(alert.title, style: theme.textTheme.bodyLarge),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
            ),
            if (onDismiss != null)
              IconButton(tooltip: 'Dismiss', icon: const Icon(Icons.close, size: 18), onPressed: onDismiss)
            else if (canOpen)
              const Padding(padding: EdgeInsets.only(right: 8), child: Icon(Icons.chevron_right)),
          ],
        ),
      ),
    );
  }
}
