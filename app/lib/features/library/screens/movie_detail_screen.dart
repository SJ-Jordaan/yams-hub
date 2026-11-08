/// `/library/movies/:id` (APP.md §5.3).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/links/external_links.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/library_api.dart';
import '../providers/library_providers.dart';
import '../widgets/library_sheets.dart';
import '../widgets/library_widgets.dart';
import '../widgets/release_picker_sheet.dart';
import 'series_detail_screen.dart';

class MovieDetailScreen extends ConsumerWidget {
  const MovieDetailScreen({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(movieDetailProvider(id));
    if (!value.hasValue && libraryIsNotFound(value.error)) {
      return const LibraryGoneView(what: 'Movie');
    }
    final body = AsyncValueView<MovieDetail>(
      value: value,
      onRetry: () => ref.invalidate(movieDetailProvider(id)),
      loading: const LibraryDetailSkeleton(),
      // The banner goes under the sliver app bar instead (see _MovieBody).
      showStaleBanner: false,
      data: (context, d) => RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(libraryHistoryPreviewProvider((ArrService.radarr, id)));
          ref.invalidate(movieDetailProvider(id));
          await libraryAwaitRefresh(ref.read(movieDetailProvider(id).future));
        },
        child: _MovieBody(detail: d, stale: value.hasError, onRetry: () => ref.invalidate(movieDetailProvider(id))),
      ),
    );
    return Scaffold(appBar: value.hasValue ? null : AppBar(), body: body);
  }
}

class _MovieBody extends ConsumerWidget {
  const _MovieBody({required this.detail, required this.stale, required this.onRetry});

  final MovieDetail detail;
  final bool stale;
  final VoidCallback onRetry;

  Future<void> _chooseRelease(BuildContext context, WidgetRef ref) async {
    final m = detail.movie;
    final grabbed = await ReleasePickerSheet.show(
      context,
      title: [m.title, if (m.year case final y?) '($y)'].join(' '),
      service: ArrService.radarr,
      search: (api) => api.movieReleases(m.id),
    );
    if (grabbed) ref.invalidate(movieDetailProvider(m.id));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = detail;
    final m = d.movie;
    final admin = ref.watch(isAdminProvider);
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final api = ref.read(libraryApiProvider);
    final meta = [
      ?m.year?.toString(),
      if (m.runtimeMinutes case final r?) '${r ~/ 60}h ${r % 60}m',
      ?m.certification,
      ?m.studio,
    ].join(' · ');
    final (availLabel, availTone) = m.hasFile
        ? ('Downloaded', StatusTone.ok)
        : !m.isAvailable
        ? ('Not released yet', StatusTone.neutral)
        : (m.monitored ? ('Missing', StatusTone.error) : ('Not monitored', StatusTone.neutral));
    final queue = d.queue;
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          title: Text(m.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            if (admin)
              PopupMenuButton<String>(
                tooltip: 'Movie actions',
                onSelected: (v) async {
                  switch (v) {
                    case 'open':
                      await openExternal(
                        ref,
                        ExternalLink(ExternalApp.radarr, m.tmdbId == null ? '/' : '/movie/${m.tmdbId}'),
                      );
                    case 'delete':
                      final deleted = await libraryDeleteFlow(
                        context,
                        ref,
                        kind: LibraryKind.movies,
                        id: m.id,
                        title: m.title,
                        fileCount: d.files.length,
                        sizeBytes: m.sizeOnDiskBytes,
                      );
                      if (deleted && context.mounted) context.go(AppPaths.library(tab: 'movies'));
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'open',
                    child: ListTile(leading: Icon(Icons.open_in_new), title: Text('Open in Radarr')),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete…')),
                  ),
                ],
              ),
          ],
        ),
        if (stale) LibraryStaleSliver(onRetry: onRetry),
        SliverToBoxAdapter(
          child: LibraryDetailHeader(
            fanartPath: m.fanartPath,
            posterPath: m.posterPath,
            title: m.title,
            meta: meta,
            placeholderIcon: Icons.movie_outlined,
            trailing: LibraryMonitorToggle(
              monitored: m.monitored,
              size: 28,
              onChanged: admin
                  ? (v) async {
                      try {
                        await ref.read(movieDetailProvider(m.id).notifier).setMonitored(v);
                      } catch (e) {
                        if (context.mounted) context.showError(e);
                      }
                    }
                  : null,
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          sliver: SliverList.list(
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  StatusChip(label: availLabel, tone: availTone),
                  if (m.qualityProfileName != null)
                    StatusChip(label: m.qualityProfileName!, icon: Icons.high_quality_outlined),
                  StatusChip(
                    label: 'Min. ${libraryAvailabilityLabel(m.minimumAvailability).toLowerCase()}',
                    icon: Icons.event_available_outlined,
                  ),
                  if (m.collection != null) StatusChip(label: m.collection!, icon: Icons.collections_bookmark_outlined),
                ],
              ),
              if (m.tags.isNotEmpty) ...[const SizedBox(height: 6), LibraryTagChips(m.tags)],
              const SizedBox(height: 8),
              LibraryCommandChips(kind: LibraryKind.movies, itemId: m.id),
              if (admin)
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () => libraryRunCommand(
                        context,
                        ref,
                        () => api.searchMovie(m.id),
                        label: 'Search',
                        kind: LibraryKind.movies,
                        itemId: m.id,
                      ),
                      icon: const Icon(Icons.search),
                      label: const Text('Search'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _chooseRelease(context, ref),
                      icon: const Icon(Icons.manage_search),
                      label: const Text('Choose release'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => libraryRunCommand(
                        context,
                        ref,
                        () => api.refreshMovie(m.id),
                        label: 'Refresh',
                        kind: LibraryKind.movies,
                        itemId: m.id,
                      ),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => MovieEditSheet.show(context, m),
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Edit'),
                    ),
                  ],
                ),
              if (queue != null) ...[
                const SizedBox(height: 12),
                ProgressBar(
                  value: queue.progress,
                  label: 'Downloading · ${queue.trackedState}',
                  trailing: queue.etaSeconds == null ? null : formatEta(queue.etaSeconds),
                  tone: StatusTone.info,
                ),
              ],
              const SizedBox(height: 12),
              KeyValueList(
                dense: true,
                entries: [
                  if (m.inCinemasDate != null) KeyValue('In cinemas', formatCalendarDate(m.inCinemasDate)),
                  if (m.digitalReleaseDate != null) KeyValue('Digital', formatCalendarDate(m.digitalReleaseDate)),
                  if (m.physicalReleaseDate != null) KeyValue('Physical', formatCalendarDate(m.physicalReleaseDate)),
                  if (m.ratingImdb != null) KeyValue('IMDb', m.ratingImdb!.toStringAsFixed(1)),
                  if (m.ratingTmdb != null) KeyValue('TMDB', m.ratingTmdb!.toStringAsFixed(1)),
                ],
              ),
              if (d.overview != null) LibraryOverview(d.overview!),
              Wrap(
                spacing: 8,
                children: [
                  if (d.youTubeTrailerId case final t?)
                    TextButton.icon(
                      icon: const Icon(Icons.play_circle_outline, size: 18),
                      label: const Text('Trailer'),
                      onPressed: () => launchExternalUri(Uri.https('www.youtube.com', '/watch', {'v': t})),
                    ),
                  if (d.links['tmdb'] case final url?)
                    TextButton.icon(
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('TMDB'),
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
              const SizedBox(height: 8),
              for (final f in d.files)
                SectionCard(
                  title: 'File',
                  icon: Icons.insert_drive_file_outlined,
                  trailing: f.cutoffNotMet
                      ? Tooltip(
                          message: 'Below the profile cutoff: an upgrade may be grabbed',
                          child: Icon(Icons.upgrade, color: colors.warning),
                        )
                      : null,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(f.relativePath, style: theme.textTheme.bodySmall),
                      if (f.cutoffNotMet)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            children: [
                              Icon(Icons.warning_amber_rounded, size: 16, color: colors.warning),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Below the quality cutoff of ${m.qualityProfileName ?? 'its profile'}',
                                  style: theme.textTheme.bodySmall?.copyWith(color: colors.warning),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 8),
                      LibraryFileInfoList(file: f),
                    ],
                  ),
                ),
              if (d.files.isEmpty && m.hasFile == false)
                const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No file on disk yet.')),
              const SizedBox(height: 12),
              LibraryHistoryPreview(service: ArrService.radarr, id: m.id),
            ],
          ),
        ),
      ],
    );
  }
}
