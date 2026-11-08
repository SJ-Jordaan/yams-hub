/// Torrents tab (APP.md §6.1): filter chips, category dropdown, sort menu,
/// local search and admin multi-select; interval 2 s.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/activity_api.dart';
import '../providers/activity_providers.dart';
import 'activity_actions.dart';
import 'activity_format.dart';

const _filters = {
  'all': 'All',
  'downloading': 'Downloading',
  'seeding': 'Seeding',
  'stopped': 'Stopped',
  'stalled': 'Stalled',
  'errored': 'Errored',
};

const _sorts = {
  'added': 'Added',
  'name': 'Name',
  'progress': 'Progress',
  'dlSpeed': 'Download speed',
  'upSpeed': 'Upload speed',
  'eta': 'ETA',
  'ratio': 'Ratio',
  'size': 'Size',
};

class TorrentsTab extends ConsumerStatefulWidget {
  const TorrentsTab({super.key});

  @override
  ConsumerState<TorrentsTab> createState() => _TorrentsTabState();
}

class _TorrentsTabState extends ConsumerState<TorrentsTab> with AutomaticKeepAliveClientMixin {
  String _filter = 'all';
  String? _category;
  String _sort = 'added';
  String _order = 'desc';
  String _search = '';
  final Set<String> _selected = {};

  @override
  bool get wantKeepAlive => true;

  TorrentQuery get _query => (filter: _filter, category: _category, sort: _sort, order: _order);

  void _toggle(String hash) => setState(() => _selected.contains(hash) ? _selected.remove(hash) : _selected.add(hash));

  Future<void> _bulk(List<TorrentSummary> visible) async {
    final hashes = _selected.toList();
    final chosen = [
      for (final t in visible)
        if (_selected.contains(t.hash)) t,
    ];
    final action = await ActionSheet.show<String>(
      context,
      title: '${hashes.length} selected',
      items: const [
        ActionSheetItem(value: 'forceStart', label: 'Force start', icon: Icons.fast_forward),
        ActionSheetItem(value: 'recheck', label: 'Recheck', icon: Icons.fact_check_outlined),
        ActionSheetItem(value: 'reannounce', label: 'Reannounce', icon: Icons.campaign_outlined),
        ActionSheetItem(value: 'category', label: 'Set category', icon: Icons.label_outline),
        ActionSheetItem(value: 'addTag', label: 'Add tag', icon: Icons.sell_outlined),
        ActionSheetItem(value: 'removeTag', label: 'Remove tag', icon: Icons.sell),
        ActionSheetItem(value: 'delete', label: 'Delete…', icon: Icons.delete_outline, destructive: true),
      ],
    );
    if (action == null || !mounted) return;
    var done = false;
    switch (action) {
      case 'forceStart':
        done = await torrentAction(context, ref, hashes, TorrentAction.forceStart, done: 'Force started');
      case 'recheck':
        done = await torrentAction(context, ref, hashes, TorrentAction.recheck, done: 'Recheck started');
      case 'reannounce':
        done = await torrentAction(context, ref, hashes, TorrentAction.reannounce, done: 'Reannounced');
      case 'category':
        await chooseCategory(context, ref, hashes);
        done = true;
      case 'addTag' || 'removeTag':
        await chooseTag(context, ref, hashes, add: action == 'addTag');
        done = true;
      case 'delete':
        done = await deleteTorrents(context, ref, chosen);
    }
    if (done && mounted) setState(_selected.clear);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final admin = ref.watch(isAdminProvider);
    final value = ref.watch(torrentsProvider(_query));
    final categories = value.value?.categories ?? const <String>[];
    final selecting = _selected.isNotEmpty;

    final toolbar = selecting
        ? Material(
            color: theme.colorScheme.secondaryContainer,
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Clear selection',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(_selected.clear),
                ),
                Expanded(child: Text('${_selected.length} selected', style: theme.textTheme.titleSmall)),
                IconButton(
                  tooltip: 'Start',
                  icon: const Icon(Icons.play_arrow),
                  onPressed: () async {
                    if (await torrentAction(context, ref, _selected.toList(), TorrentAction.start, done: 'Started') &&
                        mounted) {
                      setState(_selected.clear);
                    }
                  },
                ),
                IconButton(
                  tooltip: 'Stop',
                  icon: const Icon(Icons.pause),
                  onPressed: () async {
                    if (await torrentAction(context, ref, _selected.toList(), TorrentAction.stop, done: 'Stopped') &&
                        mounted) {
                      setState(_selected.clear);
                    }
                  },
                ),
                IconButton(
                  tooltip: 'More',
                  icon: const Icon(Icons.more_vert),
                  onPressed: () => _bulk(value.value?.items ?? const []),
                ),
              ],
            ),
          )
        : Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: SearchField(hint: 'Search torrents', onChanged: (q) => setState(() => _search = q)),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Sort',
                      icon: const Icon(Icons.sort),
                      onSelected: (s) => setState(() {
                        if (s == _sort) {
                          _order = _order == 'desc' ? 'asc' : 'desc';
                        } else {
                          _sort = s;
                          _order = s == 'name' || s == 'eta' ? 'asc' : 'desc';
                        }
                      }),
                      itemBuilder: (_) => [
                        for (final e in _sorts.entries)
                          CheckedPopupMenuItem(value: e.key, checked: e.key == _sort, child: Text(e.value)),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: FilterChipsBar<String>(
                        options: _filters.keys.toList(),
                        selected: {_filter},
                        labelOf: (f) => _filters[f]!,
                        onSelected: (f) => setState(() => _filter = f ?? 'all'),
                      ),
                    ),
                    if (categories.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: DropdownButton<String?>(
                          value: categories.contains(_category) ? _category : null,
                          hint: const Text('Category'),
                          underline: const SizedBox.shrink(),
                          onChanged: (c) => setState(() => _category = c),
                          items: [
                            const DropdownMenuItem(child: Text('All categories')),
                            for (final c in categories) DropdownMenuItem(value: c, child: Text(c)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );

    return Column(
      children: [
        toolbar,
        Expanded(
          child: AsyncValueView<TorrentList>(
            value: value,
            onRetry: () => ref.invalidate(torrentsProvider(_query)),
            data: (context, list) {
              final q = _search.trim().toLowerCase();
              final items = q.isEmpty ? list.items : list.items.where((t) => t.name.toLowerCase().contains(q)).toList();
              return RefreshIndicator(
                onRefresh: () => ref.refresh(torrentsProvider(_query).future),
                child: items.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          if (list.stale) const StaleBanner(),
                          EmptyView(
                            icon: Icons.inbox_outlined,
                            title: list.items.isEmpty && _filter == 'all' && _category == null
                                ? 'qBittorrent has no torrents'
                                : 'No matching torrents',
                          ),
                        ],
                      )
                    : ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 88),
                        itemCount: items.length + (list.stale ? 1 : 0),
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          if (list.stale && i == 0) return const StaleBanner();
                          final t = items[i - (list.stale ? 1 : 0)];
                          return TorrentTile(
                            key: ValueKey(t.hash),
                            torrent: t,
                            selecting: selecting,
                            selected: _selected.contains(t.hash),
                            onTap: () => selecting ? _toggle(t.hash) : context.push(AppPaths.torrent(t.hash)),
                            onLongPress: admin ? () => _toggle(t.hash) : null,
                          );
                        },
                      ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// One torrent row: state icon, name, progress, size/ratio/speeds/ETA,
/// category chip and the "Keep" shield.
class TorrentTile extends StatelessWidget {
  const TorrentTile({
    super.key,
    required this.torrent,
    this.onTap,
    this.onLongPress,
    this.selecting = false,
    this.selected = false,
  });

  final TorrentSummary torrent;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = torrent;
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final tone = torrentStateTone(t.state);
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return ListTile(
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
      leading: selecting
          ? Checkbox(value: selected, onChanged: (_) => onTap?.call())
          : Tooltip(
              message: torrentStateLabel(t.state),
              child: Icon(torrentStateIcon(t.state), color: colors.forTone(tone)),
            ),
      title: Text(t.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 6),
          ProgressBar(value: t.progress, tone: tone, height: 4),
          const SizedBox(height: 6),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                t.progress < 1
                    ? '${formatPercent(t.progress * 100)} of ${formatBytes(t.sizeBytes)}'
                    : formatBytes(t.sizeBytes),
                style: small,
              ),
              Text('Ratio ${ratioText(t.ratio)}', style: small),
              if (t.dlBps > 0) SpeedText(bps: t.dlBps, direction: SpeedDirection.down, style: small),
              if (t.upBps > 0) SpeedText(bps: t.upBps, direction: SpeedDirection.up, style: small),
              if (t.direction == TorrentDirection.download && t.etaSeconds != null)
                Text('ETA ${formatEta(t.etaSeconds)}', style: small),
              if (t.category != null) StatusChip(label: t.category!, dense: true),
              if (t.protected) Icon(Icons.shield, size: 14, color: colors.info, semanticLabel: 'Protected'),
              if (t.hasTrackerError) Icon(Icons.wifi_tethering_error, size: 14, color: colors.error),
            ],
          ),
        ],
      ),
    );
  }
}
