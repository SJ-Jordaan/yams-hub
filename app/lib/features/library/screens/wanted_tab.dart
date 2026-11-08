/// Wanted tab: missing and cutoff-unmet items with multi-select search
/// (APP.md §5.1).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/servers/server_config_provider.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/library_api.dart';
import '../widgets/library_widgets.dart';

class WantedTab extends ConsumerStatefulWidget {
  const WantedTab({super.key});

  @override
  ConsumerState<WantedTab> createState() => _WantedTabState();
}

class _WantedTabState extends ConsumerState<WantedTab> with AutomaticKeepAliveClientMixin {
  ArrService _service = ArrService.sonarr;
  LibraryWantedKind _kind = LibraryWantedKind.missing;
  final Set<int> _selected = {};
  bool _selecting = false;
  bool _searching = false;

  @override
  bool get wantKeepAlive => true;

  void _exitSelection() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  /// `POST /library/wanted/search` takes up to 50 ids.
  static const _maxSelected = 50;

  void _toggle(int id) {
    if (!_selected.contains(id) && _selected.length >= _maxSelected) {
      context.showSnack('Up to $_maxSelected items per search');
      return;
    }
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  Future<void> _searchSelected() async {
    final ids = _selected.toList();
    setState(() => _searching = true);
    await libraryRunCommand(
      context,
      ref,
      () => ref.read(libraryApiProvider).searchWanted(_service, ids),
      label:
          'Search ${ids.length} ${_service == ArrService.sonarr ? (ids.length == 1 ? 'episode' : 'episodes') : (ids.length == 1 ? 'movie' : 'movies')}',
    );
    if (mounted) {
      setState(() => _searching = false);
      _exitSelection();
    }
  }

  Future<void> _searchAll(int total) async {
    final what = _service == ArrService.sonarr ? 'episodes' : 'movies';
    final ok = await TypedConfirmDialog.show(
      context,
      expected: 'SEARCH',
      title: 'Search all ${_kind.label.toLowerCase()}?',
      message: 'This asks every indexer for $total $what at once. Upgrades normally happen gradually via RSS.',
      confirmLabel: 'Search all',
    );
    if (!ok || !mounted) return;
    await libraryRunCommand(
      context,
      ref,
      () => ref.read(libraryApiProvider).searchAllWanted(_service, _kind),
      label: 'Search all ${_kind.label.toLowerCase()} $what',
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final admin = ref.watch(isAdminProvider);
    final allowGlobal = ref.watch(serverConfigProvider).value?.policy.allowGlobalSearch ?? false;
    final api = ref.watch(libraryApiProvider);
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            children: [
              SegmentedButton<ArrService>(
                segments: const [
                  ButtonSegment(value: ArrService.sonarr, label: Text('Sonarr'), icon: Icon(Icons.tv)),
                  ButtonSegment(value: ArrService.radarr, label: Text('Radarr'), icon: Icon(Icons.movie_outlined)),
                ],
                selected: {_service},
                onSelectionChanged: (s) => setState(() {
                  _service = s.first;
                  _selected.clear();
                  _selecting = false;
                }),
              ),
              SegmentedButton<LibraryWantedKind>(
                segments: const [
                  ButtonSegment(value: LibraryWantedKind.missing, label: Text('Missing')),
                  ButtonSegment(value: LibraryWantedKind.cutoff, label: Text('Cutoff unmet')),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() {
                  _kind = s.first;
                  _selected.clear();
                  _selecting = false;
                }),
              ),
            ],
          ),
        ),
        Expanded(
          child: InfiniteList.paged<WantedItem>(
            key: ValueKey('wanted-${_service.name}-${_kind.name}'),
            resetKey: (_service, _kind),
            fetchPage: (page) => api.wanted(_kind, service: _service, page: page),
            header: admin && allowGlobal && !_selecting
                ? Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Builder(
                        builder: (context) => TextButton.icon(
                          icon: const Icon(Icons.travel_explore, size: 18),
                          label: const Text('Search all'),
                          onPressed: () async {
                            try {
                              final first = await api.wanted(_kind, service: _service, pageSize: 1);
                              if (mounted) await _searchAll(first.total);
                            } catch (e) {
                              if (context.mounted) context.showError(e);
                            }
                          },
                        ),
                      ),
                    ),
                  )
                : null,
            empty: EmptyView(
              icon: Icons.check_circle_outline,
              title: _kind == LibraryWantedKind.missing ? 'Nothing missing' : 'Everything meets its cutoff',
              message: 'Monitored ${_service == ArrService.sonarr ? 'episodes' : 'movies'} only.',
            ),
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
            itemBuilder: (context, item, _) => WantedRow(
              item: item,
              selecting: _selecting,
              selected: _selected.contains(item.id),
              onTap: () {
                if (_selecting) {
                  _toggle(item.id);
                } else if (item.service == ArrService.sonarr && item.seriesId != null) {
                  context.push(AppPaths.seriesDetail(item.seriesId!));
                } else if (item.service == ArrService.radarr) {
                  context.push(AppPaths.movieDetail(item.id));
                }
              },
              onLongPress: admin
                  ? () {
                      if (_selecting) {
                        _toggle(item.id);
                      } else {
                        setState(() {
                          _selecting = true;
                          _selected.add(item.id);
                        });
                      }
                    }
                  : null,
            ),
          ),
        ),
        if (_selecting)
          Material(
            elevation: 3,
            color: theme.colorScheme.surfaceContainer,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    IconButton(tooltip: 'Cancel', icon: const Icon(Icons.close), onPressed: _exitSelection),
                    Expanded(child: Text('${_selected.length} selected', style: theme.textTheme.titleSmall)),
                    FilledButton.icon(
                      onPressed: _searching || _selected.isEmpty ? null : _searchSelected,
                      icon: _searching
                          ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.search),
                      label: const Text('Search selected'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One wanted row.
class WantedRow extends StatelessWidget {
  const WantedRow({
    super.key,
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.selecting = false,
    this.selected = false,
  });

  final WantedItem item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final w = item;
    final line1 = w.service == ArrService.sonarr
        ? [?w.episodeLabel, ?w.episodeTitle].join(' · ')
        : [?w.year?.toString()].join();
    final when = w.service == ArrService.radarr && !w.isAvailable
        ? 'Not released yet'
        : (w.service == ArrService.sonarr
              ? libraryAirDate(w.airDateUtc, null)
              : (w.releaseDate == null ? null : formatCalendarDate(w.releaseDate)));
    final quality = w.currentQuality != null || w.cutoffQuality != null
        ? '${w.currentQuality ?? '?'} → ${w.cutoffQuality ?? '?'}'
        : null;
    final searched = w.lastSearchTime == null ? 'Never searched' : 'Searched ${formatRelative(w.lastSearchTime)}';
    return ListTile(
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
      leading: selecting
          ? Checkbox(value: selected, onChanged: (_) => onTap())
          : SizedBox(
              width: 40,
              child: HubImage(
                w.posterPath,
                width: 40,
                height: 60,
                borderRadius: BorderRadius.circular(6),
                placeholderIcon: w.service == ArrService.sonarr ? Icons.tv : Icons.movie_outlined,
              ),
            ),
      title: Text(w.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (line1.isNotEmpty) line1,
          [?when, ?quality].join(' · '),
          searched,
        ].where((s) => s.isNotEmpty).join('\n'),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: true,
      trailing: !w.isAvailable
          ? Icon(Icons.schedule, color: theme.colorScheme.onSurfaceVariant, size: 20)
          : (w.monitored ? null : Icon(Icons.bookmark_border, color: colors.neutral, size: 20)),
    );
  }
}
