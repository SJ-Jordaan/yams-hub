/// Season tiles and episode rows (APP.md §5.2).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/library_api.dart';
import '../providers/library_providers.dart';
import 'library_widgets.dart';
import 'release_picker_sheet.dart';

String seasonTitle(int n) => n == 0 ? 'Specials' : 'Season $n';

/// Admin actions on episodes and seasons, shared by the series and season
/// screens.
abstract final class LibraryEpisodeActions {
  static Future<void> searchEpisodes(BuildContext context, WidgetRef ref, int seriesId, List<Episode> episodes) =>
      libraryRunCommand(
        context,
        ref,
        () => ref
            .read(libraryApiProvider)
            .searchSeries(seriesId, scope: 'episodes', episodeIds: [for (final e in episodes) e.id]),
        label: episodes.length == 1 ? 'Search ${episodes.single.label}' : 'Search ${episodes.length} episodes',
        kind: LibraryKind.tv,
        itemId: seriesId,
      );

  static Future<void> searchSeason(BuildContext context, WidgetRef ref, int seriesId, int seasonNumber) =>
      libraryRunCommand(
        context,
        ref,
        () => ref.read(libraryApiProvider).searchSeries(seriesId, scope: 'season', seasonNumber: seasonNumber),
        label: 'Search ${seasonTitle(seasonNumber).toLowerCase()}',
        kind: LibraryKind.tv,
        itemId: seriesId,
      );

  static Future<void> chooseEpisodeRelease(BuildContext context, WidgetRef ref, int seriesId, Episode e) async {
    final grabbed = await ReleasePickerSheet.show(
      context,
      title: [e.label, ?e.title].join(' · '),
      service: ArrService.sonarr,
      search: (api) => api.episodeReleases(e.id),
    );
    if (grabbed) ref.invalidate(seriesDetailProvider(seriesId));
  }

  static Future<void> chooseSeasonRelease(BuildContext context, WidgetRef ref, int seriesId, int seasonNumber) async {
    final grabbed = await ReleasePickerSheet.show(
      context,
      title: seasonTitle(seasonNumber),
      service: ArrService.sonarr,
      search: (api) => api.seasonReleases(seriesId, seasonNumber),
    );
    if (grabbed) ref.invalidate(seriesDetailProvider(seriesId));
  }

  static Future<void> setEpisodesMonitored(
    BuildContext context,
    WidgetRef ref,
    int seriesId,
    Set<int> ids,
    bool monitored,
  ) async {
    try {
      await ref.read(seriesDetailProvider(seriesId).notifier).setEpisodesMonitored(ids, monitored);
    } catch (e) {
      if (context.mounted) context.showError(e);
    }
  }

  static Future<void> setSeasonMonitored(
    BuildContext context,
    WidgetRef ref,
    int seriesId,
    int seasonNumber,
    bool monitored,
  ) async {
    try {
      await ref.read(seriesDetailProvider(seriesId).notifier).setSeasonMonitored(seasonNumber, monitored);
    } catch (e) {
      if (context.mounted) context.showError(e);
    }
  }
}

/// The overflow menu of a season (admin).
class SeasonMenu extends ConsumerWidget {
  const SeasonMenu({super.key, required this.seriesId, required this.seasonNumber});

  final int seriesId;
  final int seasonNumber;

  @override
  Widget build(BuildContext context, WidgetRef ref) => PopupMenuButton<String>(
    tooltip: 'Season actions',
    onSelected: (v) => switch (v) {
      'search' => LibraryEpisodeActions.searchSeason(context, ref, seriesId, seasonNumber),
      _ => LibraryEpisodeActions.chooseSeasonRelease(context, ref, seriesId, seasonNumber),
    },
    itemBuilder: (_) => const [
      PopupMenuItem(
        value: 'search',
        child: ListTile(leading: Icon(Icons.search), title: Text('Search season')),
      ),
      PopupMenuItem(
        value: 'release',
        child: ListTile(leading: Icon(Icons.manage_search), title: Text('Choose release…')),
      ),
    ],
  );
}

/// A season tile: monitored toggle, progress, size, next airing.
class SeasonTile extends ConsumerWidget {
  const SeasonTile({super.key, required this.seriesId, required this.season, required this.admin, this.onTap});

  final int seriesId;
  final SeasonInfo season;
  final bool admin;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = season;
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final complete = s.episodeCount > 0 && s.episodeFileCount >= s.episodeCount;
    final meta = [
      '${s.episodeFileCount}/${s.episodeCount} episodes',
      if (s.sizeOnDiskBytes > 0) formatBytes(s.sizeOnDiskBytes),
      if (s.nextAiring case final n?) 'Next ${formatDate(n)}',
    ].join(' · ');
    return ListTile(
      onTap: onTap,
      leading: LibraryMonitorToggle(
        monitored: s.monitored,
        onChanged: admin
            ? (v) => LibraryEpisodeActions.setSeasonMonitored(context, ref, seriesId, s.seasonNumber, v)
            : null,
      ),
      title: Text(seasonTitle(s.seasonNumber)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(meta),
          if (s.episodeCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                value: s.episodeFileCount / s.episodeCount,
                minHeight: 4,
                color: complete ? colors.ok : theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (admin) SeasonMenu(seriesId: seriesId, seasonNumber: s.seasonNumber),
          if (onTap != null) const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}

/// The file / download state of an episode.
class EpisodeStatusIcon extends StatelessWidget {
  const EpisodeStatusIcon({super.key, required this.episode, this.now});

  final Episode episode;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final e = episode;
    final colors = StatusColors.of(context);
    final theme = Theme.of(context);
    final q = e.queue;
    if (q != null) {
      return Tooltip(
        message: 'Downloading (${q.trackedState})',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(value: q.progress, strokeWidth: 2.5, color: colors.info),
            ),
            const SizedBox(width: 4),
            Text('${(q.progress * 100).round()}%', style: theme.textTheme.labelSmall),
          ],
        ),
      );
    }
    if (e.hasFile) {
      final file = e.file;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 18, color: file?.cutoffNotMet ?? false ? colors.warning : colors.ok),
          if (file != null) ...[
            const SizedBox(width: 4),
            StatusChip(label: libraryShortQuality(file.quality.name), dense: true),
          ],
        ],
      );
    }
    final air = e.airDateUtc;
    final unaired = air == null || air.isAfter(now ?? DateTime.now());
    if (unaired) {
      return Tooltip(
        message: 'Not aired yet',
        child: Icon(Icons.schedule, size: 18, color: colors.neutral),
      );
    }
    return Tooltip(
      message: e.monitored ? 'Missing' : 'Missing (not monitored)',
      child: Icon(Icons.error_outline, size: 18, color: e.monitored ? colors.error : colors.neutral),
    );
  }
}

/// One episode row with its monitored toggle and overflow menu.
class EpisodeRow extends ConsumerWidget {
  const EpisodeRow({
    super.key,
    required this.seriesId,
    required this.episode,
    required this.admin,
    this.selecting = false,
    this.selected = false,
    this.onSelect,
    this.onLongPress,
  });

  final int seriesId;
  final Episode episode;
  final bool admin;
  final bool selecting;
  final bool selected;
  final VoidCallback? onSelect;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = episode;
    final theme = Theme.of(context);
    void showFile() {
      final f = e.file;
      if (f != null) LibraryFileInfoSheet.show(context, f, title: [e.label, ?e.title].join(' · '));
    }

    return ListTile(
      selected: selected,
      onTap: selecting ? onSelect : (e.file != null ? showFile : null),
      onLongPress: onLongPress,
      leading: selecting
          ? Checkbox(value: selected, onChanged: (_) => onSelect?.call())
          : LibraryMonitorToggle(
              monitored: e.monitored,
              size: 20,
              onChanged: admin
                  ? (v) => LibraryEpisodeActions.setEpisodesMonitored(context, ref, seriesId, {e.id}, v)
                  : null,
            ),
      title: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: e.label,
              style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
            ),
            if (e.title != null) TextSpan(text: '  ${e.title}'),
          ],
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          libraryAirDate(e.airDateUtc, e.airDate),
          if (e.finaleType != null) '${e.finaleType![0].toUpperCase()}${e.finaleType!.substring(1)} finale',
        ].join(' · '),
        style: theme.textTheme.bodySmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          EpisodeStatusIcon(episode: e),
          PopupMenuButton<String>(
            tooltip: 'Episode actions',
            onSelected: (v) => switch (v) {
              'search' => LibraryEpisodeActions.searchEpisodes(context, ref, seriesId, [e]),
              'release' => LibraryEpisodeActions.chooseEpisodeRelease(context, ref, seriesId, e),
              _ => showFile(),
            },
            itemBuilder: (_) => [
              if (admin) ...const [
                PopupMenuItem(
                  value: 'search',
                  child: ListTile(leading: Icon(Icons.search), title: Text('Search episode')),
                ),
                PopupMenuItem(
                  value: 'release',
                  child: ListTile(leading: Icon(Icons.manage_search), title: Text('Choose release…')),
                ),
              ],
              PopupMenuItem(
                value: 'file',
                enabled: e.file != null,
                child: const ListTile(leading: Icon(Icons.info_outline), title: Text('File info')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Episodes of one season with long-press multi-select (admin): Monitor,
/// Unmonitor, Search selected.
class SeasonEpisodeList extends ConsumerStatefulWidget {
  const SeasonEpisodeList({
    super.key,
    required this.seriesId,
    required this.episodes,
    required this.admin,
    this.shrinkWrap = false,
  });

  final int seriesId;
  final List<Episode> episodes;
  final bool admin;

  /// Inside another scroll view (inline expansion on tablets).
  final bool shrinkWrap;

  @override
  ConsumerState<SeasonEpisodeList> createState() => _SeasonEpisodeListState();
}

class _SeasonEpisodeListState extends ConsumerState<SeasonEpisodeList> {
  final Set<int> _selected = {};

  bool get _selecting => _selected.isNotEmpty;

  void _toggle(int id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  Future<void> _monitor(bool monitored) async {
    final ids = Set.of(_selected);
    setState(_selected.clear);
    await LibraryEpisodeActions.setEpisodesMonitored(context, ref, widget.seriesId, ids, monitored);
  }

  Future<void> _search() async {
    final chosen = [
      for (final e in widget.episodes)
        if (_selected.contains(e.id)) e,
    ];
    setState(_selected.clear);
    await LibraryEpisodeActions.searchEpisodes(context, ref, widget.seriesId, chosen);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final episodes = widget.episodes;
    final rows = [
      for (final e in episodes)
        EpisodeRow(
          key: ValueKey(e.id),
          seriesId: widget.seriesId,
          episode: e,
          admin: widget.admin,
          selecting: _selecting,
          selected: _selected.contains(e.id),
          onSelect: () => _toggle(e.id),
          onLongPress: widget.admin ? () => _toggle(e.id) : null,
        ),
    ];
    final bar = _selecting
        ? Material(
            color: theme.colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Cancel',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(_selected.clear),
                  ),
                  Expanded(child: Text('${_selected.length} selected')),
                  IconButton(
                    tooltip: 'Monitor',
                    icon: const Icon(Icons.bookmark_add_outlined),
                    onPressed: () => _monitor(true),
                  ),
                  IconButton(
                    tooltip: 'Unmonitor',
                    icon: const Icon(Icons.bookmark_remove_outlined),
                    onPressed: () => _monitor(false),
                  ),
                  IconButton(tooltip: 'Search selected', icon: const Icon(Icons.search), onPressed: _search),
                ],
              ),
            ),
          )
        : null;
    if (widget.shrinkWrap) {
      return Column(children: [?bar, ...rows]);
    }
    return Column(
      children: [
        ?bar,
        Expanded(
          child: ListView(padding: const EdgeInsets.only(bottom: 24), children: rows),
        ),
      ],
    );
  }
}
