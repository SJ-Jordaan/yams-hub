/// `/library`: tabs TV | Movies | Wanted with the summary header
/// (APP.md §5.1).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/library_providers.dart';
import '../widgets/library_tiles.dart';
import '../widgets/library_widgets.dart';
import 'wanted_tab.dart';

/// TV filter chips (APP.md §5.1).
enum SeriesFilter {
  all('All'),
  monitored('Monitored'),
  missing('Missing'),
  continuing('Continuing'),
  ended('Ended'),
  anime('Anime'),
  upcoming('Upcoming');

  const SeriesFilter(this.label);
  final String label;

  bool matches(SeriesSummary s) => switch (this) {
    all => true,
    monitored => s.monitored,
    missing => s.missingCount > 0,
    continuing => s.status == LibrarySeriesStatus.continuing,
    ended => s.status == LibrarySeriesStatus.ended,
    anime => s.isAnime,
    upcoming => s.status == LibrarySeriesStatus.upcoming || s.nextAiring != null,
  };
}

enum SeriesSort {
  title('Title'),
  added('Added'),
  nextAiring('Next airing'),
  size('Size'),
  missing('Missing'),
  year('Year');

  const SeriesSort(this.label);
  final String label;
}

/// Movie filter chips (APP.md §5.1).
enum MovieFilter {
  all('All'),
  monitored('Monitored'),
  missing('Missing'),
  available('Available'),
  unreleased('Unreleased'),
  cutoffUnmet('Cutoff unmet');

  const MovieFilter(this.label);
  final String label;

  bool matches(MovieSummary m) => switch (this) {
    all => true,
    monitored => m.monitored,
    missing => m.monitored && !m.hasFile && m.isAvailable,
    available => m.hasFile,
    unreleased => !m.isAvailable,
    cutoffUnmet => m.hasFile && m.cutoffNotMet,
  };
}

enum MovieSort {
  title('Title'),
  added('Added'),
  releaseDate('Release date'),
  size('Size'),
  year('Year');

  const MovieSort(this.label);
  final String label;
}

const _folds = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', //
  'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ñ': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ý': 'y', 'ÿ': 'y', 'ß': 'ss',
};

/// Lower-case without diacritics, for the local search.
String libraryFoldText(String s) => s.toLowerCase().split('').map((c) => _folds[c] ?? c).join();

int _nullsLast<T extends Comparable<Object>>(T? a, T? b, {bool descending = false}) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return descending ? b.compareTo(a) : a.compareTo(b);
}

/// Filters and sorts the series list locally (the list is complete).
List<SeriesSummary> applySeriesView(
  List<SeriesSummary> all, {
  String q = '',
  SeriesFilter filter = SeriesFilter.all,
  SeriesSort sort = SeriesSort.title,
}) {
  final needle = libraryFoldText(q.trim());
  final out = [
    for (final s in all)
      if (filter.matches(s) &&
          (needle.isEmpty ||
              libraryFoldText(s.title).contains(needle) ||
              libraryFoldText(s.sortTitle).contains(needle)))
        s,
  ];
  int byTitle(SeriesSummary a, SeriesSummary b) => a.sortTitle.toLowerCase().compareTo(b.sortTitle.toLowerCase());
  out.sort((a, b) {
    final c = switch (sort) {
      SeriesSort.title => 0,
      SeriesSort.added => _nullsLast(a.added, b.added, descending: true),
      SeriesSort.nextAiring => _nullsLast(a.nextAiring, b.nextAiring),
      SeriesSort.size => b.sizeOnDiskBytes.compareTo(a.sizeOnDiskBytes),
      SeriesSort.missing => b.missingCount.compareTo(a.missingCount),
      SeriesSort.year => _nullsLast(a.year, b.year, descending: true),
    };
    return c != 0 ? c : byTitle(a, b);
  });
  return out;
}

/// Filters and sorts the movie list locally.
List<MovieSummary> applyMovieView(
  List<MovieSummary> all, {
  String q = '',
  MovieFilter filter = MovieFilter.all,
  MovieSort sort = MovieSort.title,
}) {
  final needle = libraryFoldText(q.trim());
  final out = [
    for (final m in all)
      if (filter.matches(m) &&
          (needle.isEmpty ||
              libraryFoldText(m.title).contains(needle) ||
              libraryFoldText(m.sortTitle).contains(needle)))
        m,
  ];
  int byTitle(MovieSummary a, MovieSummary b) => a.sortTitle.toLowerCase().compareTo(b.sortTitle.toLowerCase());
  out.sort((a, b) {
    final c = switch (sort) {
      MovieSort.title => 0,
      MovieSort.added => _nullsLast(a.added, b.added, descending: true),
      MovieSort.releaseDate => _nullsLast(a.releaseDate, b.releaseDate, descending: true),
      MovieSort.size => b.sizeOnDiskBytes.compareTo(a.sizeOnDiskBytes),
      MovieSort.year => _nullsLast(a.year, b.year, descending: true),
    };
    return c != 0 ? c : byTitle(a, b);
  });
  return out;
}

/// The Library screen.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key, this.initialTab});

  /// `tv`, `movies` or `wanted` (from `?tab=`).
  final String? initialTab;

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> with SingleTickerProviderStateMixin {
  static const _tabs = ['tv', 'movies', 'wanted'];

  late final TabController _controller = TabController(
    length: 3,
    vsync: this,
    initialIndex: _tabs.indexOf(widget.initialTab ?? 'tv').clamp(0, 2),
  )..addListener(() => setState(() {}));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final admin = ref.watch(isAdminProvider);
    final mode = ref.watch(libraryViewModeProvider);
    final index = _controller.index;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          if (index < 2)
            IconButton(
              tooltip: mode == LibraryViewMode.grid ? 'Show as list' : 'Show as grid',
              icon: Icon(mode == LibraryViewMode.grid ? Icons.view_list_outlined : Icons.grid_view_outlined),
              onPressed: () => ref.read(libraryViewModeProvider.notifier).toggle(),
            ),
        ],
        bottom: TabBar(
          controller: _controller,
          tabs: const [
            Tab(text: 'TV'),
            Tab(text: 'Movies'),
            Tab(text: 'Wanted'),
          ],
        ),
      ),
      floatingActionButton: !admin || index == 2
          ? null
          : FloatingActionButton.extended(
              heroTag: 'library-add',
              onPressed: () => context.push(AppPaths.libraryAdd(kind: index == 0 ? 'tv' : 'movie')),
              icon: const Icon(Icons.add),
              label: Text(index == 0 ? 'Add series' : 'Add movie'),
            ),
      body: Column(
        children: [
          const LibrarySummaryHeader(),
          Expanded(
            child: TabBarView(controller: _controller, children: const [SeriesTab(), MoviesTab(), WantedTab()]),
          ),
        ],
      ),
    );
  }
}

/// A sort menu button.
class _SortButton<T extends Enum> extends StatelessWidget {
  const _SortButton({required this.values, required this.value, required this.labelOf, required this.onSelected});

  final List<T> values;
  final T value;
  final String Function(T) labelOf;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) => PopupMenuButton<T>(
    tooltip: 'Sort',
    initialValue: value,
    onSelected: onSelected,
    itemBuilder: (_) => [
      for (final v in values) CheckedPopupMenuItem(value: v, checked: v == value, child: Text(labelOf(v))),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [const Icon(Icons.sort, size: 20), const SizedBox(width: 4), Text(labelOf(value))],
      ),
    ),
  );
}

const _gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 140,
  mainAxisSpacing: 12,
  crossAxisSpacing: 12,
  childAspectRatio: 0.5,
);

Widget _listBody<T>({
  required BuildContext context,
  required LibraryViewMode mode,
  required List<T> items,
  required Widget Function(T) grid,
  required Widget Function(T) row,
}) {
  if (mode == LibraryViewMode.grid) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
      sliver: SliverGrid.builder(
        gridDelegate: _gridDelegate,
        itemCount: items.length,
        itemBuilder: (_, i) => grid(items[i]),
      ),
    );
  }
  return SliverPadding(
    padding: const EdgeInsets.only(bottom: 88),
    sliver: SliverList.builder(itemCount: items.length, itemBuilder: (_, i) => row(items[i])),
  );
}

/// TV tab.
class SeriesTab extends ConsumerStatefulWidget {
  const SeriesTab({super.key});

  @override
  ConsumerState<SeriesTab> createState() => _SeriesTabState();
}

class _SeriesTabState extends ConsumerState<SeriesTab> with AutomaticKeepAliveClientMixin {
  String _q = '';
  int _searchGeneration = 0;
  SeriesFilter _filter = SeriesFilter.all;
  SeriesSort _sort = SeriesSort.title;

  @override
  bool get wantKeepAlive => true;

  Future<void> _refresh() async {
    ref.invalidate(librarySummaryProvider);
    ref.invalidate(seriesListProvider);
    await libraryAwaitRefresh(ref.read(seriesListProvider.future));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final value = ref.watch(seriesListProvider);
    final mode = ref.watch(libraryViewModeProvider);
    final admin = ref.watch(isAdminProvider);
    return AsyncValueView<List<SeriesSummary>>(
      value: value,
      onRetry: () => ref.invalidate(seriesListProvider),
      loading: const SkeletonPosterGrid(),
      data: (context, all) {
        if (all.isEmpty) {
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              children: [
                EmptyView(
                  icon: Icons.tv_off_outlined,
                  title: 'No series yet',
                  message: 'Series you add to Sonarr show up here.',
                  action: admin
                      ? FilledButton.icon(
                          onPressed: () => context.push(AppPaths.libraryAdd(kind: 'tv')),
                          icon: const Icon(Icons.add),
                          label: const Text('Add series'),
                        )
                      : null,
                ),
              ],
            ),
          );
        }
        final items = applySeriesView(all, q: _q, filter: _filter, sort: _sort);
        return RefreshIndicator(
          onRefresh: _refresh,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: SearchField(
                    key: ValueKey(_searchGeneration),
                    hint: 'Filter ${all.length} series',
                    debounce: const Duration(milliseconds: 150),
                    onChanged: (v) => setState(() => _q = v),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Row(
                  children: [
                    Expanded(
                      child: FilterChipsBar<SeriesFilter>(
                        options: SeriesFilter.values,
                        selected: {_filter},
                        labelOf: (f) => f.label,
                        onSelected: (f) => setState(() => _filter = f ?? SeriesFilter.all),
                      ),
                    ),
                    _SortButton<SeriesSort>(
                      values: SeriesSort.values,
                      value: _sort,
                      labelOf: (s) => s.label,
                      onSelected: (s) => setState(() => _sort = s),
                    ),
                  ],
                ),
              ),
              if (items.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyView(
                    icon: Icons.filter_alt_off_outlined,
                    title: 'No series match these filters',
                    action: OutlinedButton(
                      onPressed: () => setState(() {
                        _filter = SeriesFilter.all;
                        _q = '';
                        _searchGeneration++;
                      }),
                      child: const Text('Clear filters'),
                    ),
                  ),
                )
              else
                _listBody<SeriesSummary>(
                  context: context,
                  mode: mode,
                  items: items,
                  grid: (s) => SeriesGridTile(series: s, onTap: () => context.push(AppPaths.seriesDetail(s.id))),
                  row: (s) => SeriesListRow(series: s, onTap: () => context.push(AppPaths.seriesDetail(s.id))),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Movies tab.
class MoviesTab extends ConsumerStatefulWidget {
  const MoviesTab({super.key});

  @override
  ConsumerState<MoviesTab> createState() => _MoviesTabState();
}

class _MoviesTabState extends ConsumerState<MoviesTab> with AutomaticKeepAliveClientMixin {
  String _q = '';
  int _searchGeneration = 0;
  MovieFilter _filter = MovieFilter.all;
  MovieSort _sort = MovieSort.title;

  @override
  bool get wantKeepAlive => true;

  Future<void> _refresh() async {
    ref.invalidate(librarySummaryProvider);
    ref.invalidate(moviesListProvider);
    await libraryAwaitRefresh(ref.read(moviesListProvider.future));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final value = ref.watch(moviesListProvider);
    final mode = ref.watch(libraryViewModeProvider);
    final admin = ref.watch(isAdminProvider);
    return AsyncValueView<List<MovieSummary>>(
      value: value,
      onRetry: () => ref.invalidate(moviesListProvider),
      loading: const SkeletonPosterGrid(),
      data: (context, all) {
        if (all.isEmpty) {
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              children: [
                EmptyView(
                  icon: Icons.movie_outlined,
                  title: 'No movies yet',
                  message: 'Movies you add to Radarr show up here.',
                  action: admin
                      ? FilledButton.icon(
                          onPressed: () => context.push(AppPaths.libraryAdd(kind: 'movie')),
                          icon: const Icon(Icons.add),
                          label: const Text('Add movie'),
                        )
                      : null,
                ),
              ],
            ),
          );
        }
        final items = applyMovieView(all, q: _q, filter: _filter, sort: _sort);
        return RefreshIndicator(
          onRefresh: _refresh,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: SearchField(
                    key: ValueKey(_searchGeneration),
                    hint: 'Filter ${all.length} movies',
                    debounce: const Duration(milliseconds: 150),
                    onChanged: (v) => setState(() => _q = v),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Row(
                  children: [
                    Expanded(
                      child: FilterChipsBar<MovieFilter>(
                        options: MovieFilter.values,
                        selected: {_filter},
                        labelOf: (f) => f.label,
                        onSelected: (f) => setState(() => _filter = f ?? MovieFilter.all),
                      ),
                    ),
                    _SortButton<MovieSort>(
                      values: MovieSort.values,
                      value: _sort,
                      labelOf: (s) => s.label,
                      onSelected: (s) => setState(() => _sort = s),
                    ),
                  ],
                ),
              ),
              if (items.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyView(
                    icon: Icons.filter_alt_off_outlined,
                    title: 'No movies match these filters',
                    action: OutlinedButton(
                      onPressed: () => setState(() {
                        _filter = MovieFilter.all;
                        _q = '';
                        _searchGeneration++;
                      }),
                      child: const Text('Clear filters'),
                    ),
                  ),
                )
              else
                _listBody<MovieSummary>(
                  context: context,
                  mode: mode,
                  items: items,
                  grid: (m) => MovieGridTile(movie: m, onTap: () => context.push(AppPaths.movieDetail(m.id))),
                  row: (m) => MovieListRow(movie: m, onTap: () => context.push(AppPaths.movieDetail(m.id))),
                ),
            ],
          ),
        );
      },
    );
  }
}
