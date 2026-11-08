// containers dashboard card: stub created by core-app (ARCHITECTURE §12); the containers slice replaces the body.
// Keep the class name and constructor; core's DashboardCardFrame supplies the title, route and
// error/disabled/stale states, so this widget only renders `section.data` when the section is ok.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_models/yams_models.dart';

/// The `containers` card on the dashboard (API.md §4).
class ContainersDashboardCard extends ConsumerWidget {
  const ContainersDashboardCard({super.key, required this.section});

  final Section section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Text(
      'Not available yet',
      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
  }
}
