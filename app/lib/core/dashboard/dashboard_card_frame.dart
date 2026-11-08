/// Core's wrapper around every feature dashboard card (APP.md §3.3): title,
/// icon, route, `status: error|disabled`, and the stale badge.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_models/yams_models.dart';

import '../api/api_exception.dart';
import '../theme/theme.dart';
import '../widgets/error_view.dart';
import '../widgets/formatters.dart';
import '../widgets/section_card.dart';
import 'dashboard_cards.dart';

class DashboardCardFrame extends StatelessWidget {
  const DashboardCardFrame({super.key, required this.spec, required this.section, this.onRetry});

  final DashboardCardSpec spec;
  final Section section;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: spec.title,
      icon: spec.icon,
      onTap: () => context.go(spec.route()),
      trailing: section.stale ? _StaleBadge(section: section) : const Icon(Icons.chevron_right),
      child: switch (section.status) {
        SectionState.ok when section.data != null => spec.builder(section),
        SectionState.disabled => const _CardNote(icon: Icons.settings, text: 'Not configured on the hub'),
        _ => _errorBody(),
      },
    );
  }

  Widget _errorBody() {
    final error = section.error;
    if (error == null) {
      return const _CardNote(icon: Icons.help_outline, text: 'No data');
    }
    final e = ApiException.fromApiError(error);
    if (e.isNotImplemented) {
      return const _CardNote(icon: Icons.construction_outlined, text: 'Not available yet');
    }
    return ErrorView(error: e, compact: true, onRetry: onRetry);
  }
}

class _StaleBadge extends StatelessWidget {
  const _StaleBadge({required this.section});

  final Section section;

  @override
  Widget build(BuildContext context) {
    final color = StatusColors.of(context).warning;
    final since = section.fetchedAt;
    return Tooltip(
      message: since == null ? 'Showing cached data' : 'Showing data from ${formatRelative(since)}',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history, size: 16, color: color),
            const SizedBox(width: 4),
            Text('Stale', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}

class _CardNote extends StatelessWidget {
  const _CardNote({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: color))),
      ],
    );
  }
}
