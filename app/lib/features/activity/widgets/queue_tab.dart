/// Queue tab (APP.md §6.1): the unified queue with filter chips, source
/// banners and attention tiles; interval 3 s.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/activity_providers.dart';
import 'queue_item_tile.dart';

/// Filter chips of the queue tab (`GET /activity/queue?filter=`).
const queueTabFilters = {
  'active': 'Active',
  'downloading': 'Downloading',
  'seeding': 'Seeding',
  'attention': 'Needs attention',
  'all': 'All',
};

class QueueTab extends ConsumerStatefulWidget {
  const QueueTab({super.key, this.onShowTorrents});

  /// "Seeding: 12" in the empty state switches to the Torrents tab.
  final VoidCallback? onShowTorrents;

  @override
  ConsumerState<QueueTab> createState() => _QueueTabState();
}

class _QueueTabState extends ConsumerState<QueueTab> with AutomaticKeepAliveClientMixin {
  String _filter = 'active';

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final value = ref.watch(queueProvider(_filter));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: FilterChipsBar<String>(
            options: queueTabFilters.keys.toList(),
            selected: {_filter},
            labelOf: (f) => queueTabFilters[f]!,
            onSelected: (f) => setState(() => _filter = f ?? 'active'),
          ),
        ),
        Expanded(
          child: AsyncValueView<QueueResponse>(
            value: value,
            onRetry: () => ref.invalidate(queueProvider(_filter)),
            loading: const SkeletonList(count: 5, leadingSize: 48),
            data: (context, q) => RefreshIndicator(
              onRefresh: () => ref.refresh(queueProvider(_filter).future),
              child: _QueueList(response: q, filter: _filter, onShowTorrents: widget.onShowTorrents),
            ),
          ),
        ),
      ],
    );
  }
}

class _QueueList extends StatelessWidget {
  const _QueueList({required this.response, required this.filter, this.onShowTorrents});

  final QueueResponse response;
  final String filter;
  final VoidCallback? onShowTorrents;

  @override
  Widget build(BuildContext context) {
    final banners = <Widget>[
      if (response.stale) const StaleBanner(),
      for (final (name, status) in [
        ('qBittorrent', response.qbittorrent),
        ('Sonarr', response.sonarr),
        ('Radarr', response.radarr),
      ])
        if (status.status == SectionState.error) _SourceBanner(name: name, status: status),
    ];
    if (response.items.isEmpty) {
      final seeding = response.summary.seeding;
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          ...banners,
          EmptyView(
            icon: Icons.download_done,
            title: filter == 'attention' ? 'Nothing needs attention' : 'No active downloads',
            message: filter == 'active' ? 'Sonarr, Radarr and qBittorrent are idle.' : null,
            action: seeding > 0 && onShowTorrents != null
                ? TextButton(onPressed: onShowTorrents, child: Text('Seeding: $seeding'))
                : null,
          ),
        ],
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: banners.length + response.items.length,
      itemBuilder: (context, i) {
        if (i < banners.length) return banners[i];
        final item = response.items[i - banners.length];
        return QueueItemTile(key: ValueKey(item.key), item: item);
      },
    );
  }
}

class _SourceBanner extends StatelessWidget {
  const _SourceBanner({required this.name, required this.status});

  final String name;
  final SectionStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    final theme = Theme.of(context);
    final error = status.error;
    final reason = error == null ? null : ApiException.fromApiError(error);
    final text = reason?.code == ApiErrorCode.upstreamUnavailable || reason == null
        ? "$name unreachable, its queue isn't shown"
        : "$name: ${reason.message} Its queue isn't shown.";
    return Material(
      color: colors.error.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.cloud_off, size: 18, color: colors.error),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
          ],
        ),
      ),
    );
  }
}
