/// `/media/audiobooks`: Audiobookshelf overview (APP.md §8.3), every 60 s.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/media_providers.dart';
import '../widgets/media_common.dart';
import '../widgets/stats_charts.dart';

class AudiobooksScreen extends ConsumerWidget {
  const AudiobooksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(audiobooksProvider);
    final library = value.value?.library ?? const ExternalLink(ExternalApp.audiobookshelf, '/');
    return Scaffold(
      appBar: AppBar(
        title: const Text('Audiobookshelf'),
        actions: [
          IconButton(
            tooltip: 'Open Audiobookshelf',
            onPressed: () => openLink(context, ref, library, name: 'Audiobookshelf'),
            icon: const Icon(Icons.open_in_new),
          ),
        ],
      ),
      body: AsyncValueView<AudiobooksOverview>(
        value: value,
        onRetry: () => ref.invalidate(audiobooksProvider),
        loading: const MediaDetailSkeleton(),
        data: (context, o) => _Body(overview: o, onRefresh: () => ref.refresh(audiobooksProvider.future)),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.overview, required this.onRefresh});

  final AudiobooksOverview overview;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final o = overview;
    if (o.libraries.isEmpty) {
      return MediaRefreshList(
        onRefresh: onRefresh,
        children: const [
          SizedBox(
            height: 360,
            child: EmptyView(
              icon: Icons.headphones,
              title: 'No libraries yet',
              message: 'Create a library in Audiobookshelf and it shows up here.',
            ),
          ),
        ],
      );
    }
    final hintDismissed = ref.watch(absNamingHintDismissedProvider);
    final items = o.libraries.fold(0, (a, l) => a + l.items);
    final authors = o.libraries.fold(0, (a, l) => a + l.authors);
    final duration = o.libraries.fold(0, (a, l) => a + l.durationSeconds);
    final size = o.libraries.fold(0, (a, l) => a + l.sizeBytes);
    return MediaRefreshList(
      onRefresh: onRefresh,
      children: [
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: MediaStatGrid(
            minTileWidth: 140,
            children: [
              MediaStatTile(label: 'Items', value: formatCount(items), icon: Icons.headphones),
              MediaStatTile(label: 'Authors', value: formatCount(authors), icon: Icons.person_outline),
              MediaStatTile(label: 'Total length', value: formatWatchTime(duration), icon: Icons.schedule),
              MediaStatTile(label: 'Size', value: formatBytes(size), icon: Icons.storage),
            ],
          ),
        ),
        if (!hintDismissed) ...[
          const SizedBox(height: 12),
          MediaNoticeCard(
            icon: Icons.info_outline,
            tone: StatusTone.info,
            title: 'Some authors and narrators look swapped',
            message: 'Check the folder naming in Audiobookshelf: (Author)/Title {Narrator}.',
            onDismiss: () => ref.read(absNamingHintDismissedProvider.notifier).dismiss(),
          ),
        ],
        MediaSection(
          title: 'Continue listening',
          padding: o.continueListening.isEmpty ? null : EdgeInsets.zero,
          child: o.continueListening.isEmpty
              ? Text(
                  'Nothing in progress',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                )
              : _CoverRow(children: [for (final i in o.continueListening) _ProgressCover(item: i)]),
        ),
        if (o.recentlyAdded.isNotEmpty)
          MediaSection(
            title: 'Recently added',
            padding: EdgeInsets.zero,
            child: _CoverRow(children: [for (final i in o.recentlyAdded) _RecentCover(item: i)]),
          ),
        MediaSection(
          title: 'Listening',
          trailing: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text('Today ${formatWatchTime(o.listening.todaySeconds)}', style: theme.textTheme.labelLarge),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListeningWeekChart(days: o.listening.last7Days),
              const SizedBox(height: 4),
              Text(
                'Minutes per day, last 7 days · ${formatWatchTime(o.listening.totalSeconds)} in total',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CoverRow extends StatelessWidget {
  const _CoverRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => MediaPosterRow(tileWidth: 128, height: 212, children: children);
}

class _Cover extends StatelessWidget {
  const _Cover({required this.path, this.overlay});

  final String path;
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: Stack(
        fit: StackFit.expand,
        children: [
          LayoutBuilder(
            builder: (context, c) => HubImage(
              path.isEmpty ? null : path,
              width: c.maxWidth,
              height: c.maxHeight,
              borderRadius: BorderRadius.circular(10),
              placeholderIcon: Icons.headphones,
            ),
          ),
          if (overlay != null) Positioned(right: 6, bottom: 6, child: overlay!),
        ],
      ),
    );
  }
}

class _CoverText extends StatelessWidget {
  const _CoverText({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
        if (subtitle != null)
          Text(
            subtitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
      ],
    );
  }
}

class _ProgressCover extends ConsumerWidget {
  const _ProgressCover({required this.item});

  final AudiobookProgressItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => openLink(context, ref, item.link, name: 'Audiobookshelf'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Cover(
            path: item.coverPath,
            overlay: Tooltip(
              message: '${(item.progress * 100).round()} % listened',
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(color: scheme.surface.withValues(alpha: 0.85), shape: BoxShape.circle),
                child: SizedBox.square(
                  dimension: 26,
                  child: CircularProgressIndicator(
                    value: item.progress.clamp(0.02, 1),
                    strokeWidth: 3,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
              ),
            ),
          ),
          _CoverText(title: item.title, subtitle: '${formatWatchTime(item.remainingSeconds)} left'),
        ],
      ),
    );
  }
}

class _RecentCover extends ConsumerWidget {
  const _RecentCover({required this.item});

  final AudiobookRecentItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => openLink(context, ref, item.link, name: 'Audiobookshelf'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Cover(path: item.coverPath),
          _CoverText(title: item.title, subtitle: item.author ?? formatRelative(item.addedAt)),
        ],
      ),
    );
  }
}
