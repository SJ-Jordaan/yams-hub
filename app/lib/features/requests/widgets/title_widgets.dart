/// Poster tiles, carousels and the infinite poster grid of the requests
/// feature.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import 'request_ui.dart';

/// Width of a carousel poster.
const titleTileWidth = 120.0;

/// A [TitleCard] poster with its availability badge; opens the title page.
class TitleCardTile extends StatelessWidget {
  const TitleCardTile({super.key, required this.card});

  final TitleCard card;

  @override
  Widget build(BuildContext context) {
    final year = card.year;
    return Semantics(
      button: true,
      label: [card.title, ?year?.toString(), availabilityLabel(card.availability)].join(', '),
      excludeSemantics: true,
      child: PosterTile(
        imagePath: card.posterPath,
        title: card.title,
        subtitle: [?year?.toString(), mediaTypeLabel(card.mediaType)].join(' · '),
        badge: AvailabilityBadge.maybe(card.availability),
        placeholderIcon: mediaTypeIcon(card.mediaType),
        onTap: () => context.push(AppPaths.title(card.mediaType.name, card.tmdbId)),
      ),
    );
  }
}

/// A titled horizontal carousel over one [TitlePage] provider: skeleton while
/// loading, an inline retry on error (one failing slider never blanks the
/// page), and optionally nothing at all when empty.
class TitleCarousel extends ConsumerWidget {
  const TitleCarousel({
    super.key,
    required this.title,
    required this.provider,
    this.onSeeAll,
    this.hideWhenEmpty = false,
    this.emptyText = 'Nothing here yet',
  });

  final String title;
  final FutureProvider<TitlePage> provider;
  final VoidCallback? onSeeAll;
  final bool hideWhenEmpty;
  final String emptyText;

  /// The carousel height: poster (2:3) plus two text lines.
  static const height = titleTileWidth * 1.5 + 72;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(provider);
    final items = value.value?.items;
    if (hideWhenEmpty && items != null && items.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final Widget body;
    if (items != null) {
      body = items.isEmpty
          ? Center(
              child: Text(
                emptyText,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            )
          : ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, i) => SizedBox(
                width: titleTileWidth,
                child: TitleCardTile(card: items[i]),
              ),
            );
    } else if (value.hasError) {
      body = Center(
        child: ErrorView(error: value.error!, compact: true, onRetry: () => _retry(ref)),
      );
    } else {
      body = ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: 6,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (_, _) => const SizedBox(
          width: titleTileWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(aspectRatio: 2 / 3, child: SkeletonBox(radius: 12)),
              SizedBox(height: 8),
              SkeletonBox(width: 90, height: 12),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 4, 4),
          child: Row(
            children: [
              Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
              if (onSeeAll != null && (items?.isNotEmpty ?? false))
                TextButton(onPressed: onSeeAll, child: const Text('See all')),
            ],
          ),
        ),
        SizedBox(height: height, child: body),
      ],
    );
  }

  void _retry(WidgetRef ref) => ref.invalidate(provider);
}

/// An infinite poster grid over a paged [TitlePage] loader (search results,
/// "See all"): skeleton, error with retry, [empty], pull-to-refresh, and a
/// load-more row that stops at `totalPages`.
class TitleGrid extends StatefulWidget {
  const TitleGrid({super.key, required this.load, required this.empty, this.header, this.resetKey});

  final Future<TitlePage> Function(int page) load;
  final Widget empty;

  /// Scrolls above the grid (e.g. the search tip).
  final Widget? header;

  /// Changing it reloads from page 1.
  final Object? resetKey;

  @override
  State<TitleGrid> createState() => _TitleGridState();
}

class _TitleGridState extends State<TitleGrid> {
  final _items = <TitleCard>[];
  final _seen = <String>{};
  int _page = 0;
  int _totalPages = 1;
  bool _loading = false;
  Object? _error;
  int _generation = 0;
  final _scroll = ScrollController();

  bool get _done => _page >= _totalPages;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_loadMore());
  }

  @override
  void didUpdateWidget(covariant TitleGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetKey != widget.resetKey) unawaited(_reload());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 600) unawaited(_loadMore());
  }

  Future<void> _reload() async {
    _generation++;
    setState(() {
      _items.clear();
      _seen.clear();
      _page = 0;
      _totalPages = 1;
      _loading = false;
      _error = null;
    });
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || _done) return;
    final generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.load(_page + 1);
      if (!mounted || generation != _generation) return;
      setState(() {
        _page = _page + 1;
        _totalPages = page.totalPages.clamp(0, 500);
        // TMDB pages overlap when popularity shifts between calls.
        for (final c in page.items) {
          if (_seen.add('${c.mediaType.name}:${c.tmdbId}')) _items.add(c);
        }
        _loading = false;
      });
      // A page that does not fill the viewport never scrolls: keep loading.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients && _scroll.position.extentAfter < 600) unawaited(_loadMore());
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final firstLoad = _page == 0;
    final slivers = <Widget>[if (widget.header != null) SliverToBoxAdapter(child: widget.header)];
    if (firstLoad && _error != null) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: ErrorView(error: _error!, onRetry: _loadMore),
        ),
      );
    } else if (firstLoad) {
      slivers.add(const SliverFillRemaining(child: SkeletonPosterGrid(maxTileWidth: 150)));
    } else if (_items.isEmpty) {
      slivers.add(SliverFillRemaining(hasScrollBody: false, child: widget.empty));
    } else {
      slivers
        ..add(
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                const spacing = 12.0;
                final width = constraints.crossAxisExtent;
                final columns = ((width + spacing) / (150 + spacing)).ceil().clamp(2, 12);
                final tile = (width - spacing * (columns - 1)) / columns;
                // Poster (2:3) plus two title lines and the subtitle.
                final text = MediaQuery.textScalerOf(context).scale(58) + 10;
                return SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisExtent: tile * 1.5 + text,
                    mainAxisSpacing: spacing,
                    crossAxisSpacing: spacing,
                  ),
                  itemCount: _items.length,
                  itemBuilder: (context, i) => TitleCardTile(card: _items[i]),
                );
              },
            ),
          ),
        )
        ..add(
          SliverToBoxAdapter(
            child: _error != null
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: Center(
                      child: TextButton.icon(
                        onPressed: _loadMore,
                        icon: const Icon(Icons.refresh),
                        label: const Text("Couldn't load more · Retry"),
                      ),
                    ),
                  )
                : _done
                ? const SizedBox(height: 24)
                : const Padding(
                    padding: EdgeInsets.only(bottom: 24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
          ),
        );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: CustomScrollView(controller: _scroll, physics: const AlwaysScrollableScrollPhysics(), slivers: slivers),
    );
  }
}
