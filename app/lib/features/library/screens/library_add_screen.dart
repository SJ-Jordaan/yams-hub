/// `/library/add?kind=tv|movie&term=` (admin, APP.md §5.4).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/library_api.dart';
import '../widgets/library_sheets.dart';

/// One lookup result of either kind, for the shared list.
class _Result {
  _Result.series(SeriesLookup this.series) : movie = null;
  _Result.movie(MovieLookup this.movie) : series = null;

  final SeriesLookup? series;
  final MovieLookup? movie;

  String get title => series?.title ?? movie!.title;
  int? get year => series?.year ?? movie?.year;
  String? get posterPath => series?.posterPath ?? movie?.posterPath;
  String? get overview => series?.overview ?? movie?.overview;
  String? get byline => series?.network ?? movie?.studio;
  bool get inLibrary => series?.inLibrary ?? movie!.inLibrary;
  int? get libraryId => series?.libraryId ?? movie?.libraryId;
}

class LibraryAddScreen extends ConsumerStatefulWidget {
  const LibraryAddScreen({super.key, this.kind, this.term});

  /// `tv` (default) or `movie`.
  final String? kind;
  final String? term;

  @override
  ConsumerState<LibraryAddScreen> createState() => _LibraryAddScreenState();
}

class _LibraryAddScreenState extends ConsumerState<LibraryAddScreen> {
  late LibraryKind _kind = widget.kind == 'movie' || widget.kind == 'movies' ? LibraryKind.movies : LibraryKind.tv;
  late final _controller = TextEditingController(text: widget.term ?? '');
  Future<List<_Result>>? _results;
  String _searched = '';

  @override
  void initState() {
    super.initState();
    if ((widget.term ?? '').trim().isNotEmpty) _search();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _search() {
    final term = _controller.text.trim();
    if (term.isEmpty) return;
    final api = ref.read(libraryApiProvider);
    setState(() {
      _searched = term;
      _results = _kind == LibraryKind.tv
          ? api.lookupSeries(term).then((l) => [for (final s in l) _Result.series(s)])
          : api.lookupMovies(term).then((l) => [for (final m in l) _Result.movie(m)]);
    });
  }

  void _open(int id) =>
      context.pushReplacement(_kind == LibraryKind.tv ? AppPaths.seriesDetail(id) : AppPaths.movieDetail(id));

  Future<void> _tap(_Result r) async {
    if (r.inLibrary && r.libraryId != null) {
      _open(r.libraryId!);
      return;
    }
    final id = r.series != null
        ? await AddSeriesSheet.show(context, r.series!)
        : await AddMovieSheet.show(context, r.movie!);
    if (id != null && id > 0 && mounted) {
      context.showSnack('${r.title} added');
      _open(id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(_kind == LibraryKind.tv ? 'Add series' : 'Add movie')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SegmentedButton<LibraryKind>(
              segments: const [
                ButtonSegment(value: LibraryKind.tv, label: Text('Series'), icon: Icon(Icons.tv)),
                ButtonSegment(value: LibraryKind.movies, label: Text('Movie'), icon: Icon(Icons.movie_outlined)),
              ],
              selected: {_kind},
              onSelectionChanged: (s) {
                setState(() {
                  _kind = s.first;
                  _results = null;
                });
                _search();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _controller,
              autofocus: (widget.term ?? '').isEmpty,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: _kind == LibraryKind.tv
                    ? 'Series title, tvdb:123 or imdb:tt…'
                    : 'Movie title, tmdb:123 or imdb:tt…',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(tooltip: 'Search', icon: const Icon(Icons.arrow_forward), onPressed: _search),
              ),
              onSubmitted: (_) => _search(),
            ),
          ),
          Expanded(
            child: _results == null
                ? EmptyView(
                    icon: Icons.travel_explore,
                    title: _kind == LibraryKind.tv ? 'Find a series to add' : 'Find a movie to add',
                    message: 'Results come from ${_kind == LibraryKind.tv ? 'TheTVDB via Sonarr' : 'TMDB via Radarr'}.',
                  )
                : FutureBuilder<List<_Result>>(
                    future: _results,
                    builder: (context, snap) {
                      if (snap.connectionState != ConnectionState.done) return const SkeletonList();
                      if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _search);
                      final items = snap.data!;
                      if (items.isEmpty) {
                        return EmptyView(icon: Icons.search_off, title: "Nothing found for '$_searched'");
                      }
                      return ListView.separated(
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const Divider(height: 1, indent: 88),
                        itemBuilder: (context, i) {
                          final r = items[i];
                          return ListTile(
                            onTap: () => _tap(r),
                            leading: HubImage(
                              r.posterPath,
                              width: 56,
                              height: 84,
                              borderRadius: BorderRadius.circular(6),
                              placeholderIcon: r.series != null ? Icons.tv : Icons.movie_outlined,
                            ),
                            title: Text(
                              [r.title, if (r.year case final y?) '($y)'].join(' '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (r.byline != null) Text(r.byline!, style: theme.textTheme.labelMedium),
                                if (r.overview != null) Text(r.overview!, maxLines: 2, overflow: TextOverflow.ellipsis),
                              ],
                            ),
                            isThreeLine: r.overview != null,
                            trailing: r.inLibrary
                                ? const StatusChip(
                                    label: 'In library',
                                    icon: Icons.check,
                                    tone: StatusTone.ok,
                                    dense: true,
                                  )
                                : const Icon(Icons.add_circle_outline),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
