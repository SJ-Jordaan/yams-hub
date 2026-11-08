/// History tab (APP.md §6.1): the merged Sonarr/Radarr history, cursor
/// paged, manual refresh.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/activity_api.dart';

const _types = [ArrHistoryType.grabbed, ArrHistoryType.imported, ArrHistoryType.failed, ArrHistoryType.deleted];

class HistoryTab extends ConsumerStatefulWidget {
  const HistoryTab({super.key});

  @override
  ConsumerState<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends ConsumerState<HistoryTab> with AutomaticKeepAliveClientMixin {
  final Set<ArrHistoryType> _selected = {};
  String _service = 'all';

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final api = ref.watch(activityApiProvider);
    final types = _types.where(_selected.contains).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'all', label: Text('All')),
              ButtonSegment(value: 'sonarr', label: Text('Sonarr')),
              ButtonSegment(value: 'radarr', label: Text('Radarr')),
            ],
            selected: {_service},
            onSelectionChanged: (s) => setState(() => _service = s.first),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: FilterChipsBar<ArrHistoryType>(
            options: _types,
            selected: _selected,
            multi: true,
            labelOf: historyTypeLabel,
            onSelected: (t) => setState(() => _selected.contains(t) ? _selected.remove(t) : _selected.add(t!)),
          ),
        ),
        Expanded(
          child: InfiniteList.cursor<ArrHistoryItem>(
            resetKey: '$_service|${types.map((t) => t.name).join(',')}',
            fetchPage: (cursor) => api.history(service: _service, types: types, cursor: cursor),
            separatorBuilder: (_, _) => const Divider(height: 1),
            empty: const EmptyView(
              icon: Icons.history,
              title: 'No history',
              message: 'Grabs, imports and deletes from Sonarr and Radarr show up here.',
            ),
            itemBuilder: (context, item, _) => HistoryRow(item: item),
          ),
        ),
      ],
    );
  }
}

String historyTypeLabel(ArrHistoryType t) => switch (t) {
  ArrHistoryType.grabbed => 'Grabbed',
  ArrHistoryType.imported => 'Imported',
  ArrHistoryType.failed => 'Failed',
  ArrHistoryType.deleted => 'Deleted',
  ArrHistoryType.renamed => 'Renamed',
  ArrHistoryType.ignored => 'Ignored',
  ArrHistoryType.unknown => 'Other',
};

/// One history event (as in Library > History, plus media title and poster).
class HistoryRow extends StatelessWidget {
  const HistoryRow({super.key, required this.item});

  final ArrHistoryItem item;

  (IconData, StatusTone) get _icon => switch (item.type) {
    ArrHistoryType.grabbed => (Icons.download, StatusTone.info),
    ArrHistoryType.imported => (Icons.check_circle_outline, StatusTone.ok),
    ArrHistoryType.failed => (Icons.error_outline, StatusTone.error),
    ArrHistoryType.deleted => (Icons.delete_outline, StatusTone.warning),
    _ => (Icons.history, StatusTone.neutral),
  };

  String? get _route {
    if (item.seriesId case final id?) return AppPaths.seriesDetail(id);
    if (item.movieId case final id?) return AppPaths.movieDetail(id);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final (icon, tone) = _icon;
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final title = [?item.mediaTitle, ?item.episode?.label].join(' · ');
    final details = [
      ?item.indexer,
      ?item.releaseGroup,
      if (item.sizeBytes != null) formatBytes(item.sizeBytes),
      if (item.type == ArrHistoryType.deleted) ?item.reason,
    ].join(' · ');
    final route = _route;
    return ListTile(
      onTap: route == null ? null : () => context.go(route),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          HubImage(
            item.posterPath,
            width: 40,
            height: 60,
            borderRadius: BorderRadius.circular(6),
            placeholderIcon: icon,
          ),
          Positioned(
            right: -6,
            bottom: -6,
            child: CircleAvatar(
              radius: 11,
              backgroundColor: theme.colorScheme.surface,
              child: Icon(icon, size: 16, color: colors.forTone(tone), semanticLabel: historyTypeLabel(item.type)),
            ),
          ),
        ],
      ),
      title: Text(title.isEmpty ? item.sourceTitle : title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.sourceTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusChip(label: historyTypeLabel(item.type), tone: tone, dense: true),
              StatusChip(label: item.quality.name, dense: true),
              Tooltip(
                message: formatDateTime(item.date),
                child: Text(formatRelative(item.date), style: small),
              ),
            ],
          ),
          if (details.isNotEmpty) Text(details, style: small, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
      isThreeLine: true,
    );
  }
}
