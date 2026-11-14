/// The dashboard's alerts panel (APP.md §3.3): problems sorted by severity
/// with a colour bar, info notices folded behind an "N notices" row, tap
/// opens the alert's route, dismissals remembered per device by
/// [Alert.dismissalKey].
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
/// within a severity). A dismissal is remembered by [Alert.dismissalKey], so
/// a notice whose content changed (a new key) shows again.
List<Alert> visibleAlerts(List<Alert> alerts, Set<String> dismissed) {
  final list = [
    for (final a in alerts)
      if (!(a.dismissible && dismissed.contains(a.dismissalKey))) a,
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

/// Info (and unknown) alerts: notices, not problems.
bool isNotice(Alert a) => a.severity.rank <= AlertSeverity.info.rank;

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
  bool _noticesOpen = false;

  @override
  Widget build(BuildContext context) {
    final dismissed = ref.watch(appSettingsProvider.select((s) => s.dismissedAlerts));
    final all = ref.watch(dashboardProvider.select((s) => s.value?.alerts ?? const <Alert>[]));
    final alerts = visibleAlerts(all, dismissed);
    if (alerts.isEmpty) return const SizedBox.shrink();
    final problems = [
      for (final a in alerts)
        if (!isNotice(a)) a,
    ];
    final notices = [
      for (final a in alerts)
        if (isNotice(a)) a,
    ];
    final shown = _expanded ? problems : problems.take(AlertsPanel.collapsedCount).toList();
    final hidden = problems.length - shown.length;
    Widget row(Alert a) => _AlertRow(
      alert: a,
      onDismiss: a.dismissible ? () => ref.read(appSettingsProvider.notifier).dismissAlert(a.dismissalKey) : null,
    );
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, a) in shown.indexed) ...[if (i > 0) const Divider(height: 1), row(a)],
          if (hidden > 0 || _expanded && problems.length > AlertsPanel.collapsedCount)
            TextButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded ? 'Show less' : '$hidden more'),
            ),
          if (notices.isNotEmpty) ...[
            if (shown.isNotEmpty) const Divider(height: 1),
            _NoticesRow(
              count: notices.length,
              open: _noticesOpen,
              onTap: () => setState(() => _noticesOpen = !_noticesOpen),
            ),
            if (_noticesOpen)
              for (final a in notices) ...[const Divider(height: 1), row(a)],
          ],
        ],
      ),
    );
  }
}

/// The compact row that folds the info notices away.
class _NoticesRow extends StatelessWidget {
  const _NoticesRow({required this.count, required this.open, required this.onTap});

  final int count;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 18, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                open ? 'Hide notices' : (count == 1 ? '1 notice' : '$count notices'),
                style: theme.textTheme.bodyMedium?.copyWith(color: color),
              ),
            ),
            Icon(open ? Icons.expand_less : Icons.expand_more, color: color),
          ],
        ),
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
