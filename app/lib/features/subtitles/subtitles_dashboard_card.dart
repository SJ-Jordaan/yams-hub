// subtitles dashboard card (API.md §12.6). Core's DashboardCardFrame supplies the title, route and
// error/disabled/stale states, so this widget only renders `section.data` when the section is ok.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/dashboard/section_decode.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

/// The `subtitles` card on the dashboard (API.md §4): missing episode and
/// movie counts, plus warnings for a lost SignalR link and throttled
/// providers.
class SubtitlesDashboardCard extends ConsumerWidget {
  const SubtitlesDashboardCard({super.key, required this.section});

  final Section section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final card = decodeCached(section, SubtitlesCard.fromJson);
    if (card == null) {
      return Text('No data', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant));
    }
    final allPresent = card.missingEpisodes == 0 && card.missingMovies == 0;
    final warnings = <Widget>[
      if (card.signalrDown)
        const StatusChip(label: 'Sonarr/Radarr link down', tone: StatusTone.warning, icon: Icons.link_off, dense: true),
      if (card.throttledProviders > 0)
        StatusChip(
          label: card.throttledProviders == 1
              ? '1 provider throttled'
              : '${card.throttledProviders} providers throttled',
          tone: StatusTone.warning,
          icon: Icons.hourglass_bottom,
          dense: true,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (allPresent)
          Row(
            children: [
              Icon(Icons.check_circle_outline, size: 20, color: StatusColors.of(context).ok),
              const SizedBox(width: 8),
              Expanded(child: Text('No missing subtitles', style: theme.textTheme.bodyMedium)),
            ],
          )
        else
          Row(
            children: [
              Expanded(
                child: _Stat(value: card.missingEpisodes, label: 'episodes missing'),
              ),
              Expanded(
                child: _Stat(value: card.missingMovies, label: 'movies missing'),
              ),
            ],
          ),
        if (warnings.isNotEmpty) ...[const SizedBox(height: 10), Wrap(spacing: 6, runSpacing: 6, children: warnings)],
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(formatCount(value), style: theme.textTheme.headlineSmall),
        Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}
