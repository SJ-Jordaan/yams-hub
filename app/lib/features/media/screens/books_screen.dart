/// `/media/books`: Kavita overview (APP.md §8.3), every 60 s.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/media_providers.dart';
import '../widgets/media_common.dart';

class BooksScreen extends ConsumerWidget {
  const BooksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(booksProvider);
    final library = value.value?.library ?? const ExternalLink(ExternalApp.kavita, '/');
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kavita'),
        actions: [
          IconButton(
            tooltip: 'Open Kavita',
            onPressed: () => openLink(context, ref, library, name: 'Kavita'),
            icon: const Icon(Icons.open_in_new),
          ),
        ],
      ),
      body: AsyncValueView<BooksOverview>(
        value: value,
        onRetry: () => ref.invalidate(booksProvider),
        loading: const MediaDetailSkeleton(),
        data: (context, o) => _Body(overview: o, onRefresh: () => ref.refresh(booksProvider.future)),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.overview, required this.onRefresh});

  final BooksOverview overview;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final o = overview;
    switch (o.auth) {
      case BooksAuth.missingKey:
        return MediaRefreshList(
          onRefresh: onRefresh,
          children: const [
            SizedBox(height: 16),
            MediaNoticeCard(
              key: Key('media.books.setup'),
              icon: Icons.key_outlined,
              title: 'Kavita needs an Auth Key',
              message:
                  'Create an Auth Key in Kavita (User settings → Auth Keys) and add it to the hub\'s env file as '
                  'KAVITA_API_KEY, then restart the hub.',
            ),
          ],
        );
      case BooksAuth.rejected:
        return MediaRefreshList(
          onRefresh: onRefresh,
          children: const [
            SizedBox(height: 16),
            MediaNoticeCard(
              icon: Icons.lock_outline,
              tone: StatusTone.error,
              title: 'Kavita rejected the key',
              message:
                  'The Auth Key in KAVITA_API_KEY no longer works. Create a new one in Kavita (User settings → '
                  'Auth Keys) and update the hub\'s env file.',
            ),
          ],
        );
      case BooksAuth.ok || BooksAuth.unknown:
        break;
    }
    final s = o.stats;
    final noSeries = o.hint != null && o.recentlyAdded.isEmpty && o.onDeck.isEmpty;
    return MediaRefreshList(
      onRefresh: onRefresh,
      children: [
        if (s != null) ...[
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: MediaStatGrid(
              minTileWidth: 110,
              children: [
                MediaStatTile(label: 'Series', value: formatCount(s.series), icon: Icons.collections_bookmark_outlined),
                MediaStatTile(label: 'Volumes', value: formatCount(s.volumes), icon: Icons.menu_book_outlined),
                MediaStatTile(label: 'Files', value: formatCount(s.files), icon: Icons.description_outlined),
                MediaStatTile(label: 'Size', value: formatBytes(s.sizeBytes), icon: Icons.storage),
              ],
            ),
          ),
        ],
        if (noSeries)
          SizedBox(
            height: 320,
            child: EmptyView(
              icon: Icons.menu_book_outlined,
              title: 'Kavita needs one folder per series',
              message: o.hint,
            ),
          )
        else ...[
          if (o.hint != null) ...[
            const SizedBox(height: 12),
            MediaNoticeCard(icon: Icons.info_outline, tone: StatusTone.info, title: 'No series yet', message: o.hint),
          ],
          if (o.onDeck.isNotEmpty)
            MediaSection(
              title: 'On deck',
              padding: EdgeInsets.zero,
              child: MediaPosterRow(children: [for (final b in o.onDeck) _SeriesPoster(series: b)]),
            ),
          if (o.recentlyAdded.isNotEmpty)
            MediaSection(
              title: 'Recently added',
              padding: EdgeInsets.zero,
              child: MediaPosterRow(children: [for (final b in o.recentlyAdded) _SeriesPoster(series: b)]),
            ),
        ],
        if (o.libraries.isNotEmpty)
          MediaSection(
            title: 'Libraries',
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final l in o.libraries)
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(l.name),
                    subtitle: Text(_type(l.type)),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  static String _type(BooksLibraryType t) => switch (t) {
    BooksLibraryType.manga => 'Manga',
    BooksLibraryType.comic => 'Comics',
    BooksLibraryType.book => 'Books',
    BooksLibraryType.image => 'Images',
    BooksLibraryType.lightNovel => 'Light novels',
    BooksLibraryType.comicVine => 'Comics (ComicVine)',
    BooksLibraryType.unknown => 'Library',
  };
}

class _SeriesPoster extends ConsumerWidget {
  const _SeriesPoster({required this.series});

  final BookSeries series;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = series.progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PosterTile(
          imagePath: series.coverPath.isEmpty ? null : series.coverPath,
          title: series.name,
          subtitle: series.libraryName,
          placeholderIcon: Icons.menu_book_outlined,
          onTap: () => openLink(context, ref, series.link, name: 'Kavita'),
        ),
        if (progress != null && progress > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: ProgressBar(value: progress, height: 3),
          ),
      ],
    );
  }
}
