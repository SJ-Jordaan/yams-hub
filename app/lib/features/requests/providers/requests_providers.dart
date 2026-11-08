/// Riverpod providers of the requests feature (ARCHITECTURE §7.2).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/refresh/auto_refresh.dart';
import 'package:yams_models/yams_models.dart';

import '../data/requests_api.dart';

/// Bumped after every request/issue write so every requests screen reloads
/// (lists, counts, title pages, discover badges).
class RequestsGeneration extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final requestsGenerationProvider = NotifierProvider<RequestsGeneration, int>(RequestsGeneration.new);

/// The caller's Seerr link from `/auth/me` (null while loading).
final seerrInfoProvider = Provider<MeSeerrInfo?>((ref) => ref.watch(meProvider).value?.seerr);

// ---------------------------------------------------------------------------
// Discover and search
// ---------------------------------------------------------------------------

/// A discover carousel: [mediaType] narrows trending (and filters the
/// watchlist on the device).
typedef DiscoverKey = ({DiscoverSlider slider, MediaType? mediaType});

/// The first page of a carousel (manual refresh, APP.md §4.1).
final discoverProvider = FutureProvider.autoDispose.family<TitlePage, DiscoverKey>((ref, key) async {
  ref.watch(requestsGenerationProvider);
  final page = await ref.watch(requestsApiProvider).discover(key.slider, mediaType: key.mediaType);
  if (key.slider == DiscoverSlider.watchlist && key.mediaType != null) {
    return TitlePage(
      page: page.page,
      totalPages: page.totalPages,
      totalResults: page.totalResults,
      items: [
        for (final c in page.items)
          if (c.mediaType == key.mediaType) c,
      ],
    );
  }
  return page;
});

// ---------------------------------------------------------------------------
// Titles
// ---------------------------------------------------------------------------

typedef TitleKey = ({MediaType type, int tmdbId});

/// A movie or series detail page behind one interface.
class TitleDetail {
  TitleDetail.movie(MovieTitle this.movie) : tv = null;
  TitleDetail.tv(TvTitle this.tv) : movie = null;

  final MovieTitle? movie;
  final TvTitle? tv;

  bool get isTv => tv != null;
  MediaType get type => isTv ? MediaType.tv : MediaType.movie;
  int get tmdbId => movie?.tmdbId ?? tv!.tmdbId;
  String get title => movie?.title ?? tv!.title;
  int? get year => movie?.year ?? tv?.year;
  String? get tagline => movie?.tagline ?? tv?.tagline;
  String? get overview => movie?.overview ?? tv?.overview;
  String? get certification => movie?.certification ?? tv?.certification;
  List<String> get genres => movie?.genres ?? tv!.genres;
  double? get voteAverage => movie?.voteAverage ?? tv?.voteAverage;
  String? get posterPath => movie?.posterPath ?? tv?.posterPath;
  String? get backdropPath => movie?.backdropPath ?? tv?.backdropPath;
  RequestsTrailer? get trailer => movie?.trailer ?? tv?.trailer;
  List<RequestsCastMember> get cast => movie?.cast ?? tv!.cast;
  List<RequestsWatchProvider> get watchProviders => movie?.watchProviders ?? tv!.watchProviders;
  MediaState? get media => movie?.media ?? tv?.media;
  RequestEligibility get request => movie?.request ?? tv!.request;

  /// Movie runtime or typical episode runtime.
  int? get runtimeMinutes => movie?.runtimeMinutes ?? tv?.episodeRuntimeMinutes;

  /// Directors (movies) or creators (series).
  List<String> get people => movie?.directors ?? tv!.creators;
  List<TvSeason> get seasons => tv?.seasons ?? const [];

  Availability get availability => media?.availability ?? Availability.none;
}

final titleDetailProvider = FutureProvider.autoDispose.family<TitleDetail, TitleKey>((ref, key) async {
  ref.watch(requestsGenerationProvider);
  final api = ref.watch(requestsApiProvider);
  return key.type == MediaType.tv
      ? TitleDetail.tv(await api.tv(key.tmdbId))
      : TitleDetail.movie(await api.movie(key.tmdbId));
});

/// Lazily loaded RT/IMDb scores.
final titleRatingsProvider = FutureProvider.autoDispose.family<Ratings, TitleKey>(
  (ref, key) => ref.watch(requestsApiProvider).ratings(key.type, key.tmdbId),
);

/// Recommendations ([similar] false) or similar titles.
final relatedTitlesProvider = FutureProvider.autoDispose.family<TitlePage, ({TitleKey key, bool similar})>((ref, k) {
  final api = ref.watch(requestsApiProvider);
  return k.similar ? api.similar(k.key.type, k.key.tmdbId) : api.recommendations(k.key.type, k.key.tmdbId);
});

/// The advanced request options (admins only).
final requestOptionsProvider = FutureProvider.autoDispose<RequestsOptions>(
  (ref) => ref.watch(requestsApiProvider).options(),
);

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

/// The tabs of the requests list (APP.md §4.4).
enum RequestsTab {
  pending('Pending', RequestsFilter.pending, adminOnly: true),
  mine('Mine', RequestsFilter.all, mineOnly: true),
  all('All', RequestsFilter.all, adminOnly: true),
  failed('Failed', RequestsFilter.failed, adminOnly: true);

  const RequestsTab(this.label, this.filter, {this.mineOnly = false, this.adminOnly = false});

  final String label;
  final RequestsFilter filter;

  /// Only the caller's own requests.
  final bool mineOnly;
  final bool adminOnly;

  static List<RequestsTab> visible({required bool isAdmin}) => [
    for (final t in values)
      if (isAdmin || !t.adminOnly) t,
  ];

  static RequestsTab? fromName(String? name) {
    for (final t in values) {
      if (t.name == name) return t;
    }
    return null;
  }
}

/// `GET /requests/counts` for the tab badges (30 s).
final requestCountsProvider = FutureProvider.autoDispose<RequestCounts>((ref) {
  ref.watch(requestsGenerationProvider);
  autoRefresh(ref, RefreshIntervals.thirtySeconds);
  return ref.watch(requestsApiProvider).counts();
});

/// A loaded, growing list of pages.
class PagedItems<T> {
  const PagedItems({required this.items, required this.total, required this.pages});

  final List<T> items;
  final int total;

  /// Pages loaded so far.
  final int pages;

  bool get hasMore => items.length < total;

  PagedItems<T> copyWith({List<T>? items, int? total, int? pages}) =>
      PagedItems(items: items ?? this.items, total: total ?? this.total, pages: pages ?? this.pages);
}

/// Shared paging for the requests and issues lists: auto-refresh reloads
/// every page loaded so far, so a refresh never jumps back to the top.
abstract class PagedController<T> extends AsyncNotifier<PagedItems<T>> {
  static const pageSize = 25;
  int _pages = 1;
  bool _loadingMore = false;

  Duration get refreshInterval;

  Future<PagedList<T>> fetch(int page);

  @override
  Future<PagedItems<T>> build() async {
    ref.watch(requestsGenerationProvider);
    autoRefresh(ref, refreshInterval);
    final items = <T>[];
    var total = 0;
    var loaded = 0;
    for (var p = 1; p <= _pages; p++) {
      final page = await fetch(p);
      items.addAll(page.items);
      total = page.total;
      loaded = p;
      if (!page.hasMore) break;
    }
    _pages = loaded;
    return PagedItems(items: items, total: total, pages: loaded);
  }

  /// Loads the next page (no-op while loading or at the end). Errors
  /// propagate so the list can show a retry row.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || _loadingMore) return;
    _loadingMore = true;
    try {
      final next = await fetch(current.pages + 1);
      if (!ref.mounted) return;
      _pages = current.pages + 1;
      state = AsyncData(current.copyWith(items: [...current.items, ...next.items], total: next.total, pages: _pages));
    } finally {
      _loadingMore = false;
    }
  }

  /// Pull-to-refresh.
  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }

  /// Drops an item before the reload confirms it (swipe actions).
  void removeLocally(bool Function(T item) test) {
    final current = state.value;
    if (current == null) return;
    final items = current.items.where((i) => !test(i)).toList();
    state = AsyncData(current.copyWith(items: items, total: current.total - (current.items.length - items.length)));
  }
}

class RequestsListController extends PagedController<RequestSummary> {
  RequestsListController(this.tab);

  final RequestsTab tab;

  @override
  Duration get refreshInterval => RefreshIntervals.thirtySeconds;

  @override
  Future<PagedList<RequestSummary>> fetch(int page) => ref
      .read(requestsApiProvider)
      .list(filter: tab.filter, mine: tab.mineOnly, page: page, pageSize: PagedController.pageSize);
}

final requestsListProvider = AsyncNotifierProvider.autoDispose
    .family<RequestsListController, PagedItems<RequestSummary>, RequestsTab>(RequestsListController.new);

final requestDetailProvider = FutureProvider.autoDispose.family<RequestSummary, int>((ref, id) {
  ref.watch(requestsGenerationProvider);
  autoRefresh(ref, RefreshIntervals.thirtySeconds);
  return ref.watch(requestsApiProvider).request(id);
});

// ---------------------------------------------------------------------------
// Issues
// ---------------------------------------------------------------------------

class IssuesListController extends PagedController<Issue> {
  IssuesListController(this.filter);

  final IssuesFilter filter;

  @override
  Duration get refreshInterval => RefreshIntervals.sixtySeconds;

  @override
  Future<PagedList<Issue>> fetch(int page) =>
      ref.read(requestsApiProvider).issues(filter: filter, page: page, pageSize: PagedController.pageSize);
}

final issuesListProvider = AsyncNotifierProvider.autoDispose
    .family<IssuesListController, PagedItems<Issue>, IssuesFilter>(IssuesListController.new);

/// One issue with its thread; the methods post as the caller.
class IssueController extends AsyncNotifier<Issue> {
  IssueController(this.id);

  final int id;

  @override
  Future<Issue> build() {
    autoRefresh(ref, RefreshIntervals.sixtySeconds);
    return ref.watch(requestsApiProvider).issue(id);
  }

  Future<void> _apply(Future<Issue> Function(RequestsApi api) call) async {
    final updated = await call(ref.read(requestsApiProvider));
    if (!ref.mounted) return;
    state = AsyncData(updated);
    ref.read(requestsGenerationProvider.notifier).bump();
  }

  Future<void> comment(String message) => _apply((api) => api.comment(id, message));

  Future<void> resolve() => _apply((api) => api.resolve(id));

  Future<void> reopen() => _apply((api) => api.reopen(id));
}

final issueProvider = AsyncNotifierProvider.autoDispose.family<IssueController, Issue, int>(IssueController.new);
