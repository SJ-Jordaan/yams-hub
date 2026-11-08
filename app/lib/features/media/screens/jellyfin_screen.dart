/// `/media/jellyfin`: counts, libraries and the Jellyfin rows (APP.md §8.3).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/media_api.dart';
import '../providers/media_providers.dart';
import '../widgets/media_common.dart';

class JellyfinScreen extends ConsumerStatefulWidget {
  const JellyfinScreen({super.key});

  @override
  ConsumerState<JellyfinScreen> createState() => _JellyfinScreenState();
}

class _JellyfinScreenState extends ConsumerState<JellyfinScreen> {
  bool _scanning = false;

  Future<void> _scan() async {
    setState(() => _scanning = true);
    try {
      await ref.read(mediaApiProvider).refreshLibraries();
      if (mounted) context.showSnack('Library scan started');
      ref.invalidate(jellyfinOverviewProvider);
    } catch (e) {
      if (mounted) context.showError(ApiException.from(e));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isAdminProvider);
    final value = ref.watch(jellyfinOverviewProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Jellyfin'),
        actions: [
          if (isAdmin)
            IconButton(
              tooltip: 'Scan libraries',
              onPressed: _scanning ? null : _scan,
              icon: _scanning
                  ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.manage_search),
            ),
          IconButton(
            tooltip: 'Open Jellyfin',
            onPressed: () => openLink(context, ref, const ExternalLink(ExternalApp.jellyfin, '/'), name: 'Jellyfin'),
            icon: const Icon(Icons.open_in_new),
          ),
        ],
      ),
      body: AsyncValueView<JellyfinOverview>(
        value: value,
        onRetry: () => ref.invalidate(jellyfinOverviewProvider),
        loading: const MediaDetailSkeleton(),
        data: (context, o) => _Body(overview: o, onRefresh: () => ref.refresh(jellyfinOverviewProvider.future)),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.overview, required this.onRefresh});

  final JellyfinOverview overview;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final o = overview;
    final c = o.counts;
    final hw = o.server.hwAccel;
    return MediaRefreshList(
      onRefresh: onRefresh,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            [
              o.server.name,
              if (o.server.version.isNotEmpty) 'v${o.server.version}',
              'Transcoding: ${hw == null ? 'software' : hw.toUpperCase()}',
            ].join(' · '),
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: MediaStatGrid(
            minTileWidth: 110,
            children: [
              MediaStatTile(label: 'Movies', value: formatCount(c.movies), icon: Icons.movie_outlined),
              MediaStatTile(label: 'Shows', value: formatCount(c.series), icon: Icons.tv_outlined),
              MediaStatTile(label: 'Episodes', value: formatCount(c.episodes), icon: Icons.video_library_outlined),
              if (c.songs > 0) MediaStatTile(label: 'Songs', value: formatCount(c.songs), icon: Icons.music_note),
              if (c.books > 0) MediaStatTile(label: 'Books', value: formatCount(c.books), icon: Icons.menu_book),
            ],
          ),
        ),
        if (o.libraries.isNotEmpty)
          MediaSection(
            title: 'Libraries',
            padding: EdgeInsets.zero,
            child: Column(children: [for (final l in o.libraries) _LibraryTile(library: l)]),
          ),
        MediaSection(
          title: 'Recently added',
          child: o.recentlyAdded.isEmpty
              ? Text(
                  'Nothing new yet',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                )
              : MediaPosterGrid(
                  children: [for (final i in o.recentlyAdded) MediaItemPoster(key: ValueKey(i.id), item: i)],
                ),
        ),
        if (o.continueWatching.isNotEmpty) _Row(title: 'Continue watching', items: o.continueWatching),
        if (o.nextUp.isNotEmpty) _Row(title: 'Next up', items: o.nextUp),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.title, required this.items});

  final String title;
  final List<MediaItem> items;

  @override
  Widget build(BuildContext context) {
    return MediaSection(
      title: title,
      padding: EdgeInsets.zero,
      child: MediaPosterRow(
        children: [for (final i in items) MediaItemPoster(key: ValueKey(i.id), item: i)],
      ),
    );
  }
}

class _LibraryTile extends StatelessWidget {
  const _LibraryTile({required this.library});

  final JellyfinLibrary library;

  static IconData _icon(JellyfinLibraryType t) => switch (t) {
    JellyfinLibraryType.movies => Icons.movie_outlined,
    JellyfinLibraryType.tvshows => Icons.tv_outlined,
    JellyfinLibraryType.music => Icons.library_music_outlined,
    JellyfinLibraryType.books => Icons.menu_book_outlined,
    _ => Icons.folder_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final l = library;
    final details = [
      if (l.itemCount != null) '${formatCount(l.itemCount)} items',
      if (l.files != null) '${formatCount(l.files)} files',
      if (l.sizeBytes != null) formatBytes(l.sizeBytes),
    ];
    return ListTile(
      leading: Icon(_icon(l.type)),
      title: Text(l.name),
      subtitle: details.isEmpty ? null : Text(details.join(' · ')),
      trailing: l.refreshing
          ? const Tooltip(
              message: 'Scanning',
              child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          : null,
    );
  }
}
