/// Core's wrapper around every feature dashboard card (APP.md §3.3): title,
/// icon, route, `status: error|disabled`, and the stale badge.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_models/yams_models.dart';

import '../api/api_exception.dart';
import '../theme/theme.dart';
import '../widgets/error_view.dart';
import '../widgets/formatters.dart';
import '../widgets/section_card.dart';
import 'dashboard_cards.dart';
import 'dashboard_providers.dart';

/// The dashboard card for [cardKey], watching only that card's section: a
/// refresh that leaves the section unchanged (same instance, see
/// `reuseSection`) does not rebuild it.
///
/// The built card is reused while the section is the same, so a parent
/// rebuild (the lazy list re-running its builder) stops here instead of
/// rebuilding the whole card. Inherited changes (theme, text scale) still
/// reach the card's widgets directly.
///
/// Cards also show times relative to now ("last scan 5 min ago", today's
/// aired episodes), so an unchanged card is still rebuilt once per minute of
/// the dashboard's `generatedAt` (at most once a minute, on a refresh).
class DashboardCardFrame extends ConsumerStatefulWidget {
  const DashboardCardFrame({super.key, required this.cardKey});

  /// One of [DashboardCardKeys], registered in [dashboardCards].
  final String cardKey;

  @override
  ConsumerState<DashboardCardFrame> createState() => _DashboardCardFrameState();
}

class _DashboardCardFrameState extends ConsumerState<DashboardCardFrame> {
  Section? _section;
  DashboardCardSpec? _spec;
  int? _minute;
  Widget? _view;

  void _retry() => refreshDashboard(ref);

  @override
  Widget build(BuildContext context) {
    final key = widget.cardKey;
    final spec = dashboardCards[key];
    final section = ref.watch(dashboardProvider.select((s) => s.value?.card(key)));
    final minute = ref.watch(dashboardProvider.select((s) => dashboardMinuteOf(s.value?.generatedAt)));
    if (spec == null || section == null) return const SizedBox.shrink();
    if (_view == null || !identical(section, _section) || !identical(spec, _spec) || minute != _minute) {
      _section = section;
      _spec = spec;
      _minute = minute;
      _view = DashboardCardView(spec: spec, section: section, onRetry: _retry);
    }
    return _view!;
  }
}

/// The whole minutes since the epoch of [t] (null when there is no data).
int? dashboardMinuteOf(DateTime? t) => t == null ? null : t.millisecondsSinceEpoch ~/ Duration.millisecondsPerMinute;

/// A feature card in core's frame for a given [section].
class DashboardCardView extends StatelessWidget {
  const DashboardCardView({super.key, required this.spec, required this.section, this.onRetry});

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
    final cached = since == null ? 'Showing cached data' : 'Showing data from ${formatRelative(since)}';
    // A refresh refused by Allowed Hosts says how to fix it (issue #2).
    final error = section.error;
    return Tooltip(
      message: error != null && error.code == ApiErrorCode.upstreamHostRejected ? '$cached\n${error.message}' : cached,
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
        Expanded(
          child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: color)),
        ),
      ],
    );
  }
}
