/// Media > Stats (APP.md §8.2), refreshed every 5 min.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/media_providers.dart';
import '../widgets/media_common.dart';
import '../widgets/stats_charts.dart';

String _periodLabel(int days) => days == 365 ? '1 year' : '$days days';

class StatsTab extends ConsumerWidget {
  const StatsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = ref.watch(statsDaysProvider);
    final value = ref.watch(watchStatsProvider(days));
    Future<void> refresh() => ref.refresh(watchStatsProvider(days).future);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: [
                      for (final d in WatchStats.periods)
                        ButtonSegment(value: d, label: Text(d == 365 ? '1y' : '${d}d'), tooltip: _periodLabel(d)),
                    ],
                    selected: {days},
                    onSelectionChanged: (s) => ref.read(statsDaysProvider.notifier).select(s.first),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () => context.go(AppPaths.mediaStatsUsers()),
                icon: const Icon(Icons.people_outline),
                label: const Text('Users'),
              ),
            ],
          ),
        ),
        Expanded(
          child: AsyncValueView<WatchStats>(
            value: value,
            onRetry: () => ref.invalidate(watchStatsProvider(days)),
            loading: const _StatsSkeleton(),
            data: (context, stats) => _StatsBody(stats: stats, onRefresh: refresh),
          ),
        ),
      ],
    );
  }
}

class _StatsSkeleton extends StatelessWidget {
  const _StatsSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: const [
        Row(
          children: [
            Expanded(child: SkeletonBox(height: 64)),
            SizedBox(width: 8),
            Expanded(child: SkeletonBox(height: 64)),
          ],
        ),
        SizedBox(height: 16),
        SkeletonBox(height: 200),
        SizedBox(height: 16),
        SkeletonBox(height: 140),
      ],
    );
  }
}

class _StatsBody extends StatelessWidget {
  const _StatsBody({required this.stats, required this.onRefresh});

  final WatchStats stats;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = stats;
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return MediaRefreshList(
      onRefresh: onRefresh,
      children: [
        if (s.partial) ...[
          const SizedBox(height: 8),
          const MediaNoticeCard(
            icon: Icons.info_outline,
            tone: StatusTone.info,
            title: 'Some statistics could not be loaded',
            message: 'Jellystat did not answer every query; those parts are empty.',
          ),
        ],
        if (s.isEmpty) ...[
          const SizedBox(height: 8),
          const MediaNoticeCard(
            icon: Icons.hourglass_empty,
            tone: StatusTone.neutral,
            title: 'Not enough watch history yet',
            message: 'Stats fill in as people watch.',
          ),
        ],
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: MediaStatGrid(
            children: [
              MediaStatTile(
                label: 'Plays · ${_periodLabel(s.days)}',
                value: formatCount(s.totals.plays),
                icon: Icons.play_arrow,
              ),
              MediaStatTile(
                label: 'Watch time',
                value: formatWatchTime(s.totals.durationSeconds),
                icon: Icons.schedule,
              ),
            ],
          ),
        ),
        MediaSection(
          title: 'Views over time',
          child: ViewsOverTimeChart(stats: s),
        ),
        MediaSection(
          title: 'By weekday',
          child: SimpleBarChart(
            values: [
              for (final d in WatchWeekday.values.where((d) => d != WatchWeekday.unknown))
                s.byWeekday.where((x) => x.day == d).firstOrNull?.plays ?? 0,
            ],
            labelFor: (i) => weekdays[i],
          ),
        ),
        MediaSection(
          title: 'By hour',
          child: SimpleBarChart(
            values: [for (var h = 0; h < 24; h++) s.byHour.where((x) => x.hour == h).firstOrNull?.plays ?? 0],
            labelFor: (i) => i.toString().padLeft(2, '0'),
            tooltipFor: (i) {
              final n = s.byHour.where((x) => x.hour == i).firstOrNull?.plays ?? 0;
              return '${i.toString().padLeft(2, '0')}:00: $n ${n == 1 ? 'play' : 'plays'}';
            },
            labelEvery: 6,
          ),
        ),
        MediaSection(
          title: 'Play methods',
          child: PlayMethodDonut(methods: s.playMethods),
        ),
        _TopPosters(
          title: 'Top movies',
          items: [for (final i in s.topMovies) (i.id, i.name, i.imagePath, _plays(i.plays))],
        ),
        _TopPosters(
          title: 'Top series',
          items: [for (final i in s.topSeries) (i.id, i.name, i.imagePath, _plays(i.plays))],
        ),
        _TopPosters(
          title: 'Popular series',
          items: [
            for (final i in s.popularSeries)
              (i.id, i.name, i.imagePath, '${i.uniqueViewers} ${i.uniqueViewers == 1 ? 'viewer' : 'viewers'}'),
          ],
        ),
        _Ranked(title: 'Top users', rows: [for (final u in s.topUsers) (u.name, u.plays)], icon: Icons.person_outline),
        _Ranked(title: 'Top clients', rows: [for (final c in s.topClients) (c.client, c.plays)], icon: Icons.devices),
        _Ranked(
          title: 'Top libraries',
          rows: [for (final l in s.topLibraries) (l.name, l.plays)],
          icon: Icons.video_library_outlined,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
          child: Text(
            'From Jellystat. Durations count time actually watched.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  static String _plays(int n) => '$n ${n == 1 ? 'play' : 'plays'}';
}

class _TopPosters extends StatelessWidget {
  const _TopPosters({required this.title, required this.items});

  final String title;
  final List<(String, String, String?, String)> items;

  @override
  Widget build(BuildContext context) {
    return MediaSection(
      title: title,
      padding: items.isEmpty ? null : EdgeInsets.zero,
      child: items.isEmpty
          ? Text(
              'Nothing yet',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            )
          : MediaPosterRow(
              children: [
                for (final (id, name, image, sub) in items)
                  PosterTile(key: ValueKey(id), imagePath: image, title: name, subtitle: sub),
              ],
            ),
    );
  }
}

class _Ranked extends StatelessWidget {
  const _Ranked({required this.title, required this.rows, required this.icon});

  final String title;
  final List<(String, int)> rows;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final max = rows.fold<int>(0, (m, r) => r.$2 > m ? r.$2 : m);
    return MediaSection(
      title: title,
      child: rows.isEmpty
          ? Text('Nothing yet', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))
          : Column(
              children: [
                for (final (i, (name, plays)) in rows.indexed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 24,
                          child: Text(
                            '${i + 1}',
                            style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ProgressBar(
                            value: max == 0 ? 0 : plays / max,
                            label: name.isEmpty ? 'Unknown' : name,
                            trailing: '$plays',
                            height: 4,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}
