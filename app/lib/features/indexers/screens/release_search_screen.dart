/// `/indexers/search` (admin, APP.md §10.4): Prowlarr manual search with a
/// grab sheet. Explicit searches only (never as-you-type); up to 150 s.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/indexers_api.dart';
import '../providers/indexers_providers.dart';
import '../widgets/grab_sheet.dart';

/// How results are ordered.
enum ReleaseSort { seeders, size, age }

/// [releases] ordered by [sort] (most seeders, largest, newest first).
List<Release> sortReleases(List<Release> releases, ReleaseSort sort) {
  final out = [...releases];
  int cmp(Release a, Release b) => switch (sort) {
    ReleaseSort.seeders => (b.seeders ?? -1).compareTo(a.seeders ?? -1),
    ReleaseSort.size => b.sizeBytes.compareTo(a.sizeBytes),
    ReleaseSort.age => (a.ageHours ?? 1 << 30).compareTo(b.ageHours ?? 1 << 30),
  };
  out.sort(cmp);
  return out;
}

String _typeLabel(ReleaseSearchType t) => switch (t) {
  ReleaseSearchType.search => 'General',
  ReleaseSearchType.tvsearch => 'TV',
  ReleaseSearchType.movie => 'Movie',
  ReleaseSearchType.music => 'Music',
  ReleaseSearchType.book => 'Book',
  ReleaseSearchType.unknown => 'Other',
};

class ReleaseSearchScreen extends ConsumerStatefulWidget {
  const ReleaseSearchScreen({super.key});

  @override
  ConsumerState<ReleaseSearchScreen> createState() =>
      _ReleaseSearchScreenState();
}

class _ReleaseSearchScreenState extends ConsumerState<ReleaseSearchScreen> {
  final _query = TextEditingController();
  ReleaseSearchType _type = ReleaseSearchType.search;
  Set<int> _indexers = {};
  Set<int> _categories = {};
  ReleaseSort _sort = ReleaseSort.seeders;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool get _canSearch =>
      _query.text.trim().length >= 2 &&
      !ref.read(releaseSearchProvider).running;

  void _submit() {
    if (!_canSearch) return;
    FocusScope.of(context).unfocus();
    ref
        .read(releaseSearchProvider.notifier)
        .search(
          ReleaseSearchQuery(
            query: _query.text.trim(),
            type: _type,
            indexerIds: _indexers,
            categories: _categories,
          ),
        );
  }

  Future<void> _pickIndexers(List<Indexer> all) async {
    final options = [
      for (final i in all)
        if (i.enabled && i.supportsSearch) (i.id, i.name),
    ];
    final picked = await showMultiSelectDialog(
      context,
      title: 'Indexers',
      options: options,
      selected: _indexers,
    );
    if (picked != null) setState(() => _indexers = picked);
  }

  Future<void> _pickCategories(List<IndexerCategory> all) async {
    final options = [
      for (final c in all) ...[
        (c.id, c.name),
        for (final s in c.subCategories) (s.id, '    ${s.name}'),
      ],
    ];
    final picked = await showMultiSelectDialog(
      context,
      title: 'Categories',
      options: options,
      selected: _categories,
    );
    if (picked != null) setState(() => _categories = picked);
  }

  @override
  Widget build(BuildContext context) {
    final search = ref.watch(releaseSearchProvider);
    final indexers =
        ref.watch(indexerListProvider).value?.items ?? const <Indexer>[];
    final categories =
        ref.watch(indexerCategoriesProvider).value ?? const <IndexerCategory>[];
    final theme = Theme.of(context);
    final names = {for (final i in indexers) i.id: i.name};
    final catNames = {
      for (final c in categories) ...{
        c.id: c.name,
        for (final s in c.subCategories) s.id: s.name,
      },
    };

    final results = search.result;
    final sorted = results == null
        ? const <Release>[]
        : sortReleases(results.items, _sort);
    return Scaffold(
      appBar: AppBar(title: const Text('Manual search')),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            sliver: SliverList.list(
              children: [
                TextField(
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _submit(),
                  enabled: !search.running,
                  decoration: InputDecoration(
                    labelText: 'Search',
                    hintText: 'Title, author, {ImdbId:tt…}',
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                    suffixIcon: _query.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear',
                            icon: const Icon(Icons.clear),
                            onPressed: search.running ? null : _query.clear,
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final t in ReleaseSearchType.selectable)
                      ChoiceChip(
                        label: Text(_typeLabel(t)),
                        selected: _type == t,
                        onSelected: search.running
                            ? null
                            : (_) => setState(() => _type = t),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: search.running || indexers.isEmpty
                          ? null
                          : () => _pickIndexers(indexers),
                      icon: const Icon(Icons.travel_explore, size: 18),
                      label: Text(
                        _indexers.isEmpty
                            ? 'All indexers'
                            : (_indexers.length == 1
                                  ? names[_indexers.single] ?? '1 indexer'
                                  : '${_indexers.length} indexers'),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: search.running || categories.isEmpty
                          ? null
                          : () => _pickCategories(categories),
                      icon: const Icon(Icons.category_outlined, size: 18),
                      label: Text(
                        _categories.isEmpty
                            ? 'Any category'
                            : (_categories.length == 1
                                  ? catNames[_categories.single] ?? '1 category'
                                  : '${_categories.length} categories'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _canSearch ? _submit : null,
                  icon: const Icon(Icons.manage_search),
                  label: const Text('Search'),
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'For TV and movies prefer the Library search, so Sonarr/Radarr track the download.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
          if (search.running)
            SliverToBoxAdapter(
              child: _Searching(startedAt: search.startedAt ?? DateTime.now()),
            )
          else if (search.error case final e?)
            SliverToBoxAdapter(
              child: ErrorView(
                error: e,
                compact: true,
                onRetry: search.query == null
                    ? null
                    : () => ref
                          .read(releaseSearchProvider.notifier)
                          .search(search.query!),
              ),
            )
          else if (results != null && results.items.isEmpty)
            const SliverToBoxAdapter(
              child: EmptyView(
                icon: Icons.search_off,
                title: 'No releases found',
                message: 'Try other words, another type or fewer filters.',
              ),
            )
          else if (results != null) ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              sliver: SliverToBoxAdapter(
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  runSpacing: 8,
                  spacing: 8,
                  children: [
                    Text(
                      '${results.items.length} releases · ${(results.tookMs / 1000).toStringAsFixed(1)} s',
                      style: theme.textTheme.bodySmall,
                    ),
                    SegmentedButton<ReleaseSort>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: ReleaseSort.seeders,
                          label: Text('Seeders'),
                        ),
                        ButtonSegment(
                          value: ReleaseSort.size,
                          label: Text('Size'),
                        ),
                        ButtonSegment(
                          value: ReleaseSort.age,
                          label: Text('Age'),
                        ),
                      ],
                      selected: {_sort},
                      onSelectionChanged: (s) =>
                          setState(() => _sort = s.single),
                    ),
                  ],
                ),
              ),
            ),
            SliverList.separated(
              itemCount: sorted.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
              itemBuilder: (context, index) {
                final r = sorted[index];
                return ReleaseRow(
                  release: r,
                  onTap: () => showGrabSheet(context, r),
                );
              },
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ],
      ),
    );
  }
}

/// One search result.
class ReleaseRow extends StatelessWidget {
  const ReleaseRow({super.key, required this.release, required this.onTap});

  final Release release;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = release;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return ListTile(
      onTap: onTap,
      title: Text(r.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(
            '${r.indexer} · ${formatBytes(r.sizeBytes)} · ${formatReleaseAge(r)}'
            '${r.seeders == null ? '' : ' · ${r.seeders}/${r.leechers ?? 0} S/L'}',
            style: muted,
          ),
          if (r.categories.isNotEmpty)
            Text(
              r.categories.join(', '),
              style: muted,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
      trailing: r.hasMagnet
          ? const Tooltip(
              message: 'Magnet link',
              child: Icon(Icons.link, size: 18),
            )
          : null,
    );
  }
}

/// "Searching indexers… 12 s · up to 2 min".
class _Searching extends StatefulWidget {
  const _Searching({required this.startedAt});

  final DateTime startedAt;

  @override
  State<_Searching> createState() => _SearchingState();
}

class _SearchingState extends State<_Searching> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = DateTime.now().difference(widget.startedAt).inSeconds;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            'Searching indexers… $elapsed s',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Indexers behind FlareSolverr can take up to 2 minutes.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// A checkbox list dialog; resolves to the new selection, or null when
/// cancelled.
Future<Set<int>?> showMultiSelectDialog(
  BuildContext context, {
  required String title,
  required List<(int, String)> options,
  required Set<int> selected,
}) => showDialog<Set<int>>(
  context: context,
  builder: (_) =>
      _MultiSelectDialog(title: title, options: options, initial: selected),
);

class _MultiSelectDialog extends StatefulWidget {
  const _MultiSelectDialog({
    required this.title,
    required this.options,
    required this.initial,
  });

  final String title;
  final List<(int, String)> options;
  final Set<int> initial;

  @override
  State<_MultiSelectDialog> createState() => _MultiSelectDialogState();
}

class _MultiSelectDialogState extends State<_MultiSelectDialog> {
  late final Set<int> _selected = Set.of(widget.initial);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SizedBox(
        width: 400,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final (id, label) in widget.options)
              CheckboxListTile(
                dense: true,
                value: _selected.contains(id),
                title: Text(label),
                onChanged: (on) => setState(
                  () => on == true ? _selected.add(id) : _selected.remove(id),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(_selected.clear),
          child: const Text('Clear'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(Set.of(_selected)),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
