/// `/library/tv/:id` and `/library/tv/:id/season/:n` (APP.md §5.2).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/links/external_links.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/library_api.dart';
import '../providers/library_providers.dart';
import '../widgets/episode_widgets.dart';
import '../widgets/library_sheets.dart';
import '../widgets/library_widgets.dart';

/// Expanded layouts show a season's episodes inline instead of navigating.
const _inlineSeasonsWidth = 840.0;

/// Shared header of the series and movie detail screens: fanart, poster,
/// title and meta line.
class LibraryDetailHeader extends StatelessWidget {
  const LibraryDetailHeader({
    super.key,
    required this.fanartPath,
    required this.posterPath,
    required this.title,
    required this.meta,
    this.placeholderIcon = Icons.tv,
    this.trailing,
  });

  final String? fanartPath;
  final String? posterPath;
  final String title;
  final String meta;
  final IconData placeholderIcon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 230,
      child: Stack(
        fit: StackFit.expand,
        children: [
          LayoutBuilder(
            builder: (context, c) => HubImage(fanartPath, width: c.maxWidth, height: 180, fit: BoxFit.cover),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, theme.colorScheme.surface],
                stops: const [0.2, 0.95],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 0,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                HubImage(
                  posterPath,
                  width: 96,
                  height: 144,
                  borderRadius: BorderRadius.circular(10),
                  placeholderIcon: placeholderIcon,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, style: theme.textTheme.titleLarge, maxLines: 3, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Text(meta, style: theme.textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A stat in the stats row (an [Expanded]: use it directly in a [Row]).
class LibraryStat extends StatelessWidget {
  const LibraryStat({super.key, required this.value, required this.label, this.color});

  final String value;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value, maxLines: 1, style: theme.textTheme.titleMedium?.copyWith(color: color)),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Overview text that expands on tap.
class LibraryOverview extends StatefulWidget {
  const LibraryOverview(this.text, {super.key});

  final String text;

  @override
  State<LibraryOverview> createState() => _LibraryOverviewState();
}

class _LibraryOverviewState extends State<LibraryOverview> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => setState(() => _open = !_open),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 150),
        alignment: Alignment.topCenter,
        child: Text(widget.text, maxLines: _open ? null : 3, overflow: _open ? null : TextOverflow.ellipsis),
      ),
    ),
  );
}

/// First-load placeholder shaped like a detail page: fanart, poster, title
/// lines, a chip row and a few list rows.
class LibraryDetailSkeleton extends StatelessWidget {
  const LibraryDetailSkeleton({super.key});

  @override
  Widget build(BuildContext context) => ListView(
    physics: const NeverScrollableScrollPhysics(),
    children: [
      const SizedBox(
        height: 230,
        child: Stack(
          children: [
            SkeletonBox(height: 180, radius: 0),
            Positioned(
              left: 16,
              right: 16,
              bottom: 0,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  SkeletonBox(width: 96, height: 144, radius: 10),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [SkeletonBox(height: 22), SizedBox(height: 8), SkeletonBox(width: 160, height: 14)],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Row(
          children: [
            SkeletonBox(width: 110, height: 28, radius: 14),
            SizedBox(width: 8),
            SkeletonBox(width: 80, height: 28, radius: 14),
          ],
        ),
      ),
      const Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 8), child: SkeletonBox(height: 64, radius: 12)),
      for (var i = 0; i < 4; i++)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              SkeletonBox(width: 40, height: 40),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [SkeletonBox(height: 14), SizedBox(height: 6), SkeletonBox(width: 120, height: 12)],
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

/// The stale banner as a sliver under a [SliverAppBar] (the detail pages
/// have no fixed app bar, so the banner scrolls with the page).
class LibraryStaleSliver extends StatelessWidget {
  const LibraryStaleSliver({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(child: StaleBanner(onRetry: onRetry));
}

/// The "Recent history" section with "See all".
class LibraryHistoryPreview extends ConsumerWidget {
  const LibraryHistoryPreview({super.key, required this.service, required this.id});

  final ArrService service;
  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(libraryHistoryPreviewProvider((service, id)));
    return SectionCard(
      title: 'Recent history',
      icon: Icons.history,
      trailing: TextButton(
        onPressed: () => context.push(AppPaths.libraryHistory(service.name, id)),
        child: const Text('See all'),
      ),
      padding: EdgeInsets.zero,
      child: AsyncValueView<List<ArrHistoryItem>>(
        value: history,
        showStaleBanner: false,
        compactError: true,
        loading: const Padding(
          padding: EdgeInsets.all(16),
          child: Column(children: [SkeletonBox(height: 16), SizedBox(height: 12), SkeletonBox(height: 16)]),
        ),
        onRetry: () => ref.invalidate(libraryHistoryPreviewProvider((service, id))),
        data: (context, items) => items.isEmpty
            ? const Padding(padding: EdgeInsets.all(16), child: Text('Nothing yet'))
            : Column(children: [for (final i in items) LibraryHistoryTile(item: i)]),
      ),
    );
  }
}

/// Body for a detail that no longer exists.
class LibraryGoneView extends StatelessWidget {
  const LibraryGoneView({super.key, required this.what});

  final String what;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: EmptyView(
      icon: Icons.search_off,
      title: '$what not found',
      message: 'It may have been deleted.',
      action: OutlinedButton(
        onPressed: () => context.canPop() ? context.pop() : context.go(AppPaths.library()),
        child: const Text('Back'),
      ),
    ),
  );
}

/// The series detail screen.
class SeriesDetailScreen extends ConsumerWidget {
  const SeriesDetailScreen({super.key, required this.id});

  final int id;

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(libraryHistoryPreviewProvider((ArrService.sonarr, id)));
    ref.invalidate(seriesDetailProvider(id));
    await libraryAwaitRefresh(ref.read(seriesDetailProvider(id).future));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(seriesDetailProvider(id));
    if (!value.hasValue && libraryIsNotFound(value.error)) {
      return const LibraryGoneView(what: 'Series');
    }
    final body = AsyncValueView<SeriesDetail>(
      value: value,
      onRetry: () => ref.invalidate(seriesDetailProvider(id)),
      loading: const LibraryDetailSkeleton(),
      // The banner goes under the sliver app bar instead (see _SeriesBody).
      showStaleBanner: false,
      data: (context, d) => RefreshIndicator(
        onRefresh: () => _refresh(ref),
        child: _SeriesBody(detail: d, stale: value.hasError, onRetry: () => ref.invalidate(seriesDetailProvider(id))),
      ),
    );
    // Before the first load the page has no app bar of its own.
    return Scaffold(appBar: value.hasValue ? null : AppBar(), body: body);
  }
}

class _SeriesBody extends ConsumerWidget {
  const _SeriesBody({required this.detail, required this.stale, required this.onRetry});

  final SeriesDetail detail;
  final bool stale;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = detail;
    final s = d.series;
    final admin = ref.watch(isAdminProvider);
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= _inlineSeasonsWidth;
    final meta = [
      ?s.year?.toString(),
      ?s.network,
      librarySeriesStatusLabel(s.status),
      if (d.runtimeMinutes case final r?) '$r min',
      ?d.certification,
    ].join(' · ');
    final next = s.nextAiring;
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [if (admin) _SeriesMenu(detail: d)],
        ),
        if (stale) LibraryStaleSliver(onRetry: onRetry),
        SliverToBoxAdapter(
          child: LibraryDetailHeader(
            fanartPath: s.fanartPath,
            posterPath: s.posterPath,
            title: s.title,
            meta: meta,
            trailing: admin
                ? LibraryMonitorToggle(
                    monitored: s.monitored,
                    size: 28,
                    onChanged: (v) async {
                      try {
                        await ref.read(seriesDetailProvider(s.id).notifier).setMonitored(v);
                      } catch (e) {
                        if (context.mounted) context.showError(e);
                      }
                    },
                  )
                : LibraryMonitorToggle(monitored: s.monitored, onChanged: null),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          sliver: SliverList.list(
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (s.qualityProfileName != null)
                    StatusChip(label: s.qualityProfileName!, icon: Icons.high_quality_outlined),
                  StatusChip(label: librarySeriesTypeLabel(s.seriesType), icon: Icons.category_outlined),
                  if (!s.monitored) const StatusChip(label: 'Not monitored', icon: Icons.bookmark_border),
                ],
              ),
              if (s.tags.isNotEmpty) ...[const SizedBox(height: 6), LibraryTagChips(s.tags)],
              const SizedBox(height: 8),
              LibraryCommandChips(kind: LibraryKind.tv, itemId: s.id),
              if (admin) _SeriesActions(detail: d),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      LibraryStat(value: '${s.episodeFileCount}/${s.episodeCount}', label: 'Episodes'),
                      LibraryStat(
                        value: '${s.missingCount}',
                        label: 'Missing',
                        color: s.missingCount > 0 ? theme.colorScheme.error : null,
                      ),
                      LibraryStat(value: formatBytes(s.sizeOnDiskBytes), label: 'On disk'),
                      LibraryStat(value: next == null ? '–' : formatDate(next), label: 'Next airing'),
                    ],
                  ),
                ),
              ),
              if (d.overview != null) LibraryOverview(d.overview!),
              Wrap(
                spacing: 8,
                children: [
                  if (d.links['tvdb'] case final url?)
                    TextButton.icon(
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('TVDB'),
                      onPressed: () => launchExternalUri(Uri.parse(url)),
                    ),
                  if (d.links['imdb'] case final url?)
                    TextButton.icon(
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('IMDb'),
                      onPressed: () => launchExternalUri(Uri.parse(url)),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text('Seasons', style: theme.textTheme.titleMedium),
            ],
          ),
        ),
        SliverList.list(
          children: [
            for (final season in d.seasons)
              if (wide)
                ExpansionTile(
                  key: PageStorageKey('season-${season.seasonNumber}'),
                  title: Text(seasonTitle(season.seasonNumber)),
                  subtitle: Text('${season.episodeFileCount}/${season.episodeCount} episodes'),
                  leading: LibraryMonitorToggle(
                    monitored: season.monitored,
                    onChanged: admin
                        ? (v) => LibraryEpisodeActions.setSeasonMonitored(context, ref, s.id, season.seasonNumber, v)
                        : null,
                  ),
                  trailing: admin ? SeasonMenu(seriesId: s.id, seasonNumber: season.seasonNumber) : null,
                  children: [
                    SeasonEpisodeList(
                      seriesId: s.id,
                      admin: admin,
                      shrinkWrap: true,
                      episodes: [
                        for (final e in d.episodes)
                          if (e.seasonNumber == season.seasonNumber) e,
                      ],
                    ),
                  ],
                )
              else
                SeasonTile(
                  seriesId: s.id,
                  season: season,
                  admin: admin,
                  onTap: () => context.push(AppPaths.seasonDetail(s.id, season.seasonNumber)),
                ),
          ],
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          sliver: SliverToBoxAdapter(
            child: LibraryHistoryPreview(service: ArrService.sonarr, id: s.id),
          ),
        ),
      ],
    );
  }
}

class _SeriesActions extends ConsumerWidget {
  const _SeriesActions({required this.detail});

  final SeriesDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = detail.series;
    final api = ref.read(libraryApiProvider);
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        MenuAnchor(
          builder: (context, controller, _) => FilledButton.tonalIcon(
            onPressed: () => controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.search),
            label: const Text('Search'),
          ),
          menuChildren: [
            MenuItemButton(
              leadingIcon: const Icon(Icons.bookmark_outline),
              onPressed: () => libraryRunCommand(
                context,
                ref,
                () => api.searchSeries(s.id, scope: 'series'),
                label: 'Search monitored',
                kind: LibraryKind.tv,
                itemId: s.id,
              ),
              child: const Text('Search monitored'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.error_outline),
              onPressed: () => libraryRunCommand(
                context,
                ref,
                () => api.searchSeries(s.id, scope: 'missing'),
                label: 'Search missing',
                kind: LibraryKind.tv,
                itemId: s.id,
              ),
              child: const Text('Search missing'),
            ),
          ],
        ),
        OutlinedButton.icon(
          onPressed: () => libraryRunCommand(
            context,
            ref,
            () => api.refreshSeries(s.id),
            label: 'Refresh',
            kind: LibraryKind.tv,
            itemId: s.id,
          ),
          icon: const Icon(Icons.refresh),
          label: const Text('Refresh'),
        ),
        OutlinedButton.icon(
          onPressed: () => SeriesEditSheet.show(context, s),
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Edit'),
        ),
      ],
    );
  }
}

class _SeriesMenu extends ConsumerWidget {
  const _SeriesMenu({required this.detail});

  final SeriesDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = detail.series;
    return PopupMenuButton<String>(
      tooltip: 'Series actions',
      onSelected: (v) async {
        switch (v) {
          case 'open':
            final slug = detail.titleSlug;
            await openExternal(ref, ExternalLink(ExternalApp.sonarr, slug == null ? '/' : '/series/$slug'));
          case 'delete':
            final deleted = await libraryDeleteFlow(
              context,
              ref,
              kind: LibraryKind.tv,
              id: s.id,
              title: s.title,
              fileCount: s.episodeFileCount,
              sizeBytes: s.sizeOnDiskBytes,
            );
            if (deleted && context.mounted) context.go(AppPaths.library(tab: 'tv'));
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'open',
          child: ListTile(leading: Icon(Icons.open_in_new), title: Text('Open in Sonarr')),
        ),
        PopupMenuItem(
          value: 'delete',
          child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete…')),
        ),
      ],
    );
  }
}

/// The season screen (phones).
class SeasonScreen extends ConsumerWidget {
  const SeasonScreen({super.key, required this.seriesId, required this.seasonNumber});

  final int seriesId;
  final int seasonNumber;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(seriesDetailProvider(seriesId));
    final admin = ref.watch(isAdminProvider);
    if (!value.hasValue && libraryIsNotFound(value.error)) {
      return const LibraryGoneView(what: 'Series');
    }
    final d = value.value;
    final season = d?.seasons.where((s) => s.seasonNumber == seasonNumber).firstOrNull;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(seasonTitle(seasonNumber)),
            if (d != null)
              Text(
                d.series.title,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          if (season != null)
            LibraryMonitorToggle(
              monitored: season.monitored,
              onChanged: admin
                  ? (v) => LibraryEpisodeActions.setSeasonMonitored(context, ref, seriesId, seasonNumber, v)
                  : null,
            ),
          if (admin && season != null) SeasonMenu(seriesId: seriesId, seasonNumber: seasonNumber),
        ],
      ),
      body: AsyncValueView<SeriesDetail>(
        value: value,
        onRetry: () => ref.invalidate(seriesDetailProvider(seriesId)),
        data: (context, d) {
          final episodes = [
            for (final e in d.episodes)
              if (e.seasonNumber == seasonNumber) e,
          ];
          if (season == null) {
            return EmptyView(icon: Icons.search_off, title: '${seasonTitle(seasonNumber)} not found');
          }
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(seriesDetailProvider(seriesId));
              await libraryAwaitRefresh(ref.read(seriesDetailProvider(seriesId).future));
            },
            child: episodes.isEmpty
                ? ListView(
                    children: const [EmptyView(icon: Icons.video_library_outlined, title: 'No episodes listed yet')],
                  )
                : SeasonEpisodeList(seriesId: seriesId, episodes: episodes, admin: admin),
          );
        },
      ),
    );
  }
}
