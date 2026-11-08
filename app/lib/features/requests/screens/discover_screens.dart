/// Discover `/requests`, a full carousel `/requests/discover/:slider` and
/// search `/requests/search?q=` (APP.md §4.1, §4.2).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/requests_api.dart';
import '../providers/requests_providers.dart';
import '../widgets/title_widgets.dart';

/// The search prefixes Seerr understands.
const searchTip = 'Tip: tmdb:603, imdb:tt0133093, tvdb:81189';

/// Discover filter chips.
enum DiscoverFilter {
  all('All', null),
  movies('Movies', MediaType.movie),
  series('Series', MediaType.tv);

  const DiscoverFilter(this.label, this.mediaType);

  final String label;
  final MediaType? mediaType;
}

/// The carousels shown for [filter], in APP.md order.
List<DiscoverSlider> slidersFor(DiscoverFilter filter) => [
  DiscoverSlider.trending,
  for (final s in const [
    DiscoverSlider.popularMovies,
    DiscoverSlider.popularTv,
    DiscoverSlider.upcomingMovies,
    DiscoverSlider.upcomingTv,
  ])
    if (filter.mediaType == null || s.mediaType == filter.mediaType) s,
  DiscoverSlider.watchlist,
];

String _sliderTitle(DiscoverSlider s, MediaType? filter) => switch ((s, filter)) {
  (DiscoverSlider.trending, MediaType.movie) => 'Trending movies',
  (DiscoverSlider.trending, MediaType.tv) => 'Trending series',
  _ => s.label,
};

/// `/requests`: search field, filter chips and the discover carousels.
class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  DiscoverFilter _filter = DiscoverFilter.all;

  Future<void> _refresh() async {
    ref.invalidate(discoverProvider);
    try {
      await ref.read(discoverProvider((slider: DiscoverSlider.trending, mediaType: _filter.mediaType)).future);
    } catch (_) {
      // Each carousel shows its own error.
    }
  }

  void _openGrid(DiscoverSlider s) {
    final base = AppPaths.requestsDiscover(s.slug);
    final type = _filter.mediaType;
    context.push(type == null ? base : '$base?mediaType=${type.name}');
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isAdminProvider);
    final pending = isAdmin ? ref.watch(requestCountsProvider).value?.pending ?? 0 : 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Discover'),
        actions: [
          IconButton(
            tooltip: 'Issues',
            icon: const Icon(Icons.report_problem_outlined),
            onPressed: () => context.push(AppPaths.issues()),
          ),
          if (isAdmin)
            IconButton(
              tooltip: 'Requests',
              icon: Badge(
                isLabelVisible: pending > 0,
                label: Text('$pending'),
                child: const Icon(Icons.inbox_outlined),
              ),
              onPressed: () => context.push(AppPaths.requestsList(tab: RequestsTab.pending.name)),
            )
          else
            TextButton(
              onPressed: () => context.push(AppPaths.requestsList(tab: RequestsTab.mine.name)),
              child: const Text('My requests'),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: _SearchBox(onSubmitted: (q) => context.push(AppPaths.requestsSearch(q))),
            ),
            FilterChipsBar<DiscoverFilter>(
              options: DiscoverFilter.values,
              selected: {_filter},
              labelOf: (f) => f.label,
              onSelected: (f) => setState(() => _filter = f ?? DiscoverFilter.all),
            ),
            for (final s in slidersFor(_filter))
              TitleCarousel(
                key: ValueKey('${s.slug}:${_filter.name}'),
                title: _sliderTitle(s, _filter.mediaType),
                provider: discoverProvider((slider: s, mediaType: _filter.mediaType)),
                onSeeAll: () => _openGrid(s),
                hideWhenEmpty: s == DiscoverSlider.watchlist,
              ),
          ],
        ),
      ),
    );
  }
}

/// Submit-only search box (no search-as-you-type).
class _SearchBox extends StatefulWidget {
  const _SearchBox({super.key, required this.onSubmitted, this.initial});

  final ValueChanged<String> onSubmitted;
  final String? initial;

  @override
  State<_SearchBox> createState() => _SearchBoxState();
}

class _SearchBoxState extends State<_SearchBox> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(String v) {
    final q = v.trim();
    if (q.isNotEmpty) widget.onSubmitted(q);
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    textInputAction: TextInputAction.search,
    decoration: InputDecoration(
      hintText: 'Search movies and series',
      prefixIcon: const Icon(Icons.search),
      border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(28))),
      isDense: true,
      suffixIcon: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => _controller.text.isEmpty
            ? const SizedBox.shrink()
            : IconButton(tooltip: 'Clear', icon: const Icon(Icons.clear), onPressed: _controller.clear),
      ),
    ),
    onSubmitted: _submit,
  );
}

/// `/requests/discover/:slider`: every page of one carousel.
class DiscoverGridScreen extends ConsumerWidget {
  const DiscoverGridScreen({super.key, required this.slider, this.mediaType});

  final DiscoverSlider slider;

  /// The Discover filter the user came from.
  final MediaType? mediaType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(requestsApiProvider);
    return Scaffold(
      appBar: AppBar(title: Text(_sliderTitle(slider, mediaType))),
      body: TitleGrid(
        load: (page) async {
          final p = await api.discover(slider, page: page, mediaType: mediaType);
          if (slider != DiscoverSlider.watchlist || mediaType == null) return p;
          return TitlePage(
            page: p.page,
            totalPages: p.totalPages,
            totalResults: p.totalResults,
            items: [
              for (final c in p.items)
                if (c.mediaType == mediaType) c,
            ],
          );
        },
        empty: EmptyView(
          icon: slider == DiscoverSlider.watchlist ? Icons.bookmark_border : Icons.movie_filter_outlined,
          title: slider == DiscoverSlider.watchlist ? 'Your watchlist is empty' : 'Nothing to show',
          message: slider == DiscoverSlider.watchlist ? 'Add titles to your watchlist in Seerr or Jellyfin.' : null,
        ),
      ),
    );
  }
}

/// `/requests/search?q=`: infinite results grid.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, required this.query});

  final String query;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late String _q = widget.query.trim();

  @override
  void didUpdateWidget(covariant SearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) _q = widget.query.trim();
  }

  void _search(String q) {
    setState(() => _q = q);
    // Keep the URL in sync so back/forward and web reloads show the same.
    context.replace(AppPaths.requestsSearch(q));
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(requestsApiProvider);
    final theme = Theme.of(context);
    final tip = Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Text(searchTip, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 16),
          child: _SearchBox(key: ValueKey(_q), initial: _q, onSubmitted: _search),
        ),
      ),
      body: _q.isEmpty
          ? const EmptyView(icon: Icons.search, title: 'Search movies and series', message: searchTip)
          : TitleGrid(
              resetKey: _q,
              header: tip,
              load: (page) => api.search(_q, page: page),
              empty: EmptyView(icon: Icons.search_off, title: "No titles match '$_q'", message: searchTip),
            ),
    );
  }
}
