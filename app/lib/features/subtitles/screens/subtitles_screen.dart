/// Subtitles `/subtitles` (APP.md §11): tabs Episodes | Movies | History,
/// a summary header, language-chip searches and admin actions.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/subtitles_api.dart';
import '../providers/subtitles_providers.dart';
import '../widgets/subtitle_tiles.dart';
import '../widgets/subtitles_header.dart';

/// The tabs, in order; [name] is the `?tab=` value.
enum SubtitlesTab {
  episodes,
  movies,
  history;

  /// The tab for a `?tab=` value (Episodes by default).
  static SubtitlesTab fromQuery(String? v) => values.firstWhere((t) => t.name == v, orElse: () => episodes);
}

enum _AdminAction { searchAllEpisodes, searchAllMovies, resetProviders, tasks }

class SubtitlesScreen extends ConsumerStatefulWidget {
  const SubtitlesScreen({super.key, this.initialTab = SubtitlesTab.episodes});

  final SubtitlesTab initialTab;

  @override
  ConsumerState<SubtitlesScreen> createState() => _SubtitlesScreenState();
}

class _SubtitlesScreenState extends ConsumerState<SubtitlesScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: SubtitlesTab.values.length,
    vsync: this,
    initialIndex: widget.initialTab.index,
  );

  /// Bumped to reload a wanted list from its first page.
  int _episodesReload = 0;
  int _moviesReload = 0;

  @override
  void didUpdateWidget(covariant SubtitlesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) _tabs.animateTo(widget.initialTab.index);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  SubtitlesApi get _api => ref.read(subtitlesApiProvider);

  void _reloadWanted({bool episodes = true, bool movies = true}) => setState(() {
    if (episodes) _episodesReload++;
    if (movies) _moviesReload++;
  });

  Future<void> _onAdminAction(_AdminAction action) async {
    switch (action) {
      case _AdminAction.searchAllEpisodes:
        await _searchAll(SubtitleListType.episodes);
      case _AdminAction.searchAllMovies:
        await _searchAll(SubtitleListType.movies);
      case _AdminAction.resetProviders:
        await _resetProviders();
      case _AdminAction.tasks:
        await SubtitleTasksSheet.show(context, onRun: _runTask);
    }
  }

  Future<void> _searchAll(SubtitleListType type) async {
    final summary = ref.read(subtitlesSummaryProvider).value;
    final episodes = type == SubtitleListType.episodes;
    final count = summary == null ? null : (episodes ? summary.missingEpisodes : summary.missingMovies);
    final noun = episodes ? (count == 1 ? 'episode' : 'episodes') : (count == 1 ? 'movie' : 'movies');
    final confirmed = await ConfirmDialog.show(
      context,
      title: count == null ? 'Search providers for all missing $noun?' : 'Search providers for $count $noun?',
      message:
          'Bazarr searches every ${episodes ? 'episode' : 'movie'} with missing subtitles. '
          'This can take a while and uses provider quotas.',
      confirmLabel: 'Search',
    );
    if (!confirmed || !mounted) return;
    try {
      await _api.searchAll(type);
      if (!mounted) return;
      context.showSnack('Search started');
      ref.invalidate(subtitlesSummaryProvider);
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  Future<void> _resetProviders() async {
    final confirmed = await ConfirmDialog.show(
      context,
      title: 'Reset throttled providers?',
      message: 'Bazarr uses every provider again right away, even those it paused after errors.',
      confirmLabel: 'Reset',
    );
    if (!confirmed || !mounted) return;
    try {
      await _api.resetProviders();
      if (!mounted) return;
      context.showSnack('Providers reset');
      ref.invalidate(subtitlesSummaryProvider);
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  Future<void> _runTask(SubtitleTask task) async {
    await _api.runTask(task.id);
    if (!mounted) return;
    context.showSnack('${task.name} started');
    ref.invalidate(subtitlesSummaryProvider);
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isAdminProvider);
    final summary = ref.watch(subtitlesSummaryProvider).value;
    final search = ref.watch(subtitleSearchProvider);

    // Searches finished: refresh what they changed.
    ref.listen(subtitleSearchProvider.select((s) => s.completed), (previous, next) {
      if (previous == null || next <= previous) return;
      context.showSnack('Subtitle search finished');
      ref.invalidate(subtitlesSummaryProvider);
      _reloadWanted();
    });
    // The periodic summary refresh shows the missing counts moved: reload
    // the affected list (cheaper and calmer than reloading lists blindly).
    ref.listen(subtitlesSummaryProvider.select((s) => s.value), (previous, next) {
      if (previous == null || next == null) return;
      final episodes = previous.missingEpisodes != next.missingEpisodes;
      final movies = previous.missingMovies != next.missingMovies;
      if (episodes || movies) _reloadWanted(episodes: episodes, movies: movies);
    });

    String label(String name, int? count) => count == null || count == 0 ? name : '$name · ${formatCount(count)}';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Subtitles'),
        actions: [
          if (isAdmin)
            PopupMenuButton<_AdminAction>(
              key: const ValueKey('subtitles-admin-menu'),
              tooltip: 'Bazarr actions',
              onSelected: _onAdminAction,
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: _AdminAction.searchAllEpisodes,
                  child: ListTile(leading: Icon(Icons.manage_search), title: Text('Search all missing episodes')),
                ),
                PopupMenuItem(
                  value: _AdminAction.searchAllMovies,
                  child: ListTile(leading: Icon(Icons.manage_search), title: Text('Search all missing movies')),
                ),
                PopupMenuItem(
                  value: _AdminAction.resetProviders,
                  child: ListTile(leading: Icon(Icons.restart_alt), title: Text('Reset providers')),
                ),
                PopupMenuItem(
                  value: _AdminAction.tasks,
                  child: ListTile(leading: Icon(Icons.schedule), title: Text('Tasks')),
                ),
              ],
            ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: label('Episodes', summary?.missingEpisodes)),
            Tab(text: label('Movies', summary?.missingMovies)),
            const Tab(text: 'History'),
          ],
        ),
      ),
      body: Column(
        children: [
          if (search.active) _SearchingBanner(jobs: search.jobs),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _WantedTab(
                  key: const PageStorageKey('wanted-episodes'),
                  type: SubtitleListType.episodes,
                  reload: _episodesReload,
                ),
                _WantedTab(
                  key: const PageStorageKey('wanted-movies'),
                  type: SubtitleListType.movies,
                  reload: _moviesReload,
                ),
                const _HistoryTab(key: PageStorageKey('subtitle-history')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Searching subtitles…" with Bazarr's active jobs.
class _SearchingBanner extends StatelessWidget {
  const _SearchingBanner({required this.jobs});

  final List<SubtitleJob> jobs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = StatusColors.of(context).info;
    final first = jobs.isEmpty ? null : jobs.first;
    final detail = first == null
        ? 'Waiting for Bazarr…'
        : [
            first.name,
            if (first.message case final m? when m.isNotEmpty) m,
            if (jobs.length > 1) '+${jobs.length - 1} more',
          ].join(' · ');
    return Material(
      color: color.withValues(alpha: 0.14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Searching subtitles…', style: theme.textTheme.labelLarge),
                      Text(detail, style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (first?.progress case final p?) LinearProgressIndicator(value: p, minHeight: 2),
        ],
      ),
    );
  }
}

/// Episodes or Movies: the wanted list with the summary header on top.
class _WantedTab extends ConsumerStatefulWidget {
  const _WantedTab({super.key, required this.type, required this.reload});

  final SubtitleListType type;

  /// Changes when the screen wants the list reloaded.
  final int reload;

  @override
  ConsumerState<_WantedTab> createState() => _WantedTabState();
}

class _WantedTabState extends ConsumerState<_WantedTab> with AutomaticKeepAliveClientMixin {
  bool _loadedOnce = false;
  bool _screenReload = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(covariant _WantedTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reload != widget.reload) _screenReload = true;
  }

  Future<PagedList<WantedSubtitle>> _fetch(int page) {
    if (page == 1) {
      // Pull-to-refresh also refreshes the header; reloads the screen asked
      // for already did.
      if (_loadedOnce && !_screenReload) ref.invalidate(subtitlesSummaryProvider);
      _loadedOnce = true;
      _screenReload = false;
    }
    return ref.read(subtitlesApiProvider).wanted(widget.type, page: page);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final movies = widget.type == SubtitleListType.movies;
    return InfiniteList.paged<WantedSubtitle>(
      resetKey: widget.reload,
      fetchPage: _fetch,
      header: const SubtitlesHeader(),
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 76),
      itemBuilder: (context, item, _) => WantedSubtitleTile(key: ValueKey(item.key), item: item),
      empty: EmptyView(
        icon: Icons.check_circle_outline,
        title: 'No missing subtitles',
        message: movies ? 'Every movie has the subtitles it wants.' : 'Every episode has the subtitles it wants.',
      ),
    );
  }
}

/// History: episodes or movies, newest first.
class _HistoryTab extends ConsumerStatefulWidget {
  const _HistoryTab({super.key});

  @override
  ConsumerState<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends ConsumerState<_HistoryTab> with AutomaticKeepAliveClientMixin {
  SubtitleListType _type = SubtitleListType.episodes;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<SubtitleListType>(
              segments: const [
                ButtonSegment(value: SubtitleListType.episodes, label: Text('Episodes'), icon: Icon(Icons.tv)),
                ButtonSegment(value: SubtitleListType.movies, label: Text('Movies'), icon: Icon(Icons.movie)),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            ),
          ),
        ),
        Expanded(
          child: InfiniteList.paged<SubtitleHistoryItem>(
            resetKey: _type,
            fetchPage: (page) => ref.read(subtitlesApiProvider).history(_type, page: page),
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
            itemBuilder: (context, item, _) => SubtitleHistoryTile(item: item),
            empty: const EmptyView(
              icon: Icons.history,
              title: 'No subtitle history',
              message: 'Downloaded and upgraded subtitles appear here.',
            ),
          ),
        ),
      ],
    );
  }
}
