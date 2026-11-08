/// `/indexers/history` (APP.md §10.3): Prowlarr history as an infinite list
/// with type, failure and indexer filters.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/indexers_api.dart';
import '../providers/indexers_providers.dart';

/// History page size.
const indexerHistoryPageSize = 50;

class IndexerHistoryScreen extends ConsumerStatefulWidget {
  const IndexerHistoryScreen({super.key});

  @override
  ConsumerState<IndexerHistoryScreen> createState() =>
      _IndexerHistoryScreenState();
}

class _IndexerHistoryScreenState extends ConsumerState<IndexerHistoryScreen> {
  IndexerHistoryType? _type;
  bool _failedOnly = false;
  int? _indexerId;

  static const _types = [
    (IndexerHistoryType.grabbed, 'Grabs'),
    (IndexerHistoryType.query, 'Queries'),
    (IndexerHistoryType.rss, 'RSS'),
  ];

  bool get _filtered => _type != null || _failedOnly || _indexerId != null;

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(indexersApiProvider);
    final indexers =
        ref.watch(indexerListProvider).value?.items ?? const <Indexer>[];
    return Scaffold(
      appBar: AppBar(title: const Text('Indexer history')),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                for (final (type, label) in _types)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(label),
                      selected: _type == type,
                      showCheckmark: false,
                      onSelected: (on) =>
                          setState(() => _type = on ? type : null),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: const Text('Failed only'),
                    selected: _failedOnly,
                    onSelected: (on) => setState(() => _failedOnly = on),
                  ),
                ),
                DropdownButton<int?>(
                  value: indexers.any((i) => i.id == _indexerId)
                      ? _indexerId
                      : null,
                  hint: const Text('All indexers'),
                  underline: const SizedBox.shrink(),
                  items: [
                    const DropdownMenuItem<int?>(child: Text('All indexers')),
                    for (final i in indexers)
                      DropdownMenuItem<int?>(value: i.id, child: Text(i.name)),
                  ],
                  onChanged: (v) => setState(() => _indexerId = v),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: InfiniteList.paged<IndexerHistoryItem>(
              resetKey: (_type, _failedOnly, _indexerId),
              fetchPage: (page) => api.history(
                page: page,
                pageSize: indexerHistoryPageSize,
                type: _type,
                successful: _failedOnly ? false : null,
                indexerId: _indexerId,
              ),
              itemBuilder: (context, item, _) => IndexerHistoryRow(item: item),
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
              empty: EmptyView(
                icon: Icons.history,
                title: _filtered
                    ? 'Nothing matches these filters'
                    : 'No indexer history yet',
                message: _filtered ? 'Try fewer filters.' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One history record.
class IndexerHistoryRow extends StatelessWidget {
  const IndexerHistoryRow({super.key, required this.item});

  final IndexerHistoryItem item;

  static IconData iconFor(IndexerHistoryType type) => switch (type) {
    IndexerHistoryType.grabbed => Icons.download,
    IndexerHistoryType.query => Icons.search,
    IndexerHistoryType.rss => Icons.rss_feed,
    IndexerHistoryType.auth => Icons.key,
    IndexerHistoryType.infoQuery => Icons.info_outline,
    IndexerHistoryType.unknown => Icons.help_outline,
  };

  String get _title {
    if (item.grabTitle case final t?) return t;
    if (item.query case final q?) return q;
    return switch (item.type) {
      IndexerHistoryType.rss => 'RSS sync',
      IndexerHistoryType.auth => 'Login',
      IndexerHistoryType.grabbed => 'Grab',
      _ => item.queryType == null ? 'Query' : 'Query (${item.queryType})',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final details = [
      item.indexerName,
      ?item.source,
      if (item.results case final n?) '$n results',
      if (item.elapsedMs case final ms?) '$ms ms',
    ].join(' · ');
    return ListTile(
      leading: Icon(
        iconFor(item.type),
        color: item.successful
            ? theme.colorScheme.onSurfaceVariant
            : colors.error,
      ),
      title: Text(_title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Tooltip(
            message: formatDateTime(item.date),
            child: Text(
              formatRelative(item.date),
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (!item.successful)
            Icon(
              Icons.close,
              size: 18,
              color: colors.error,
              semanticLabel: 'Failed',
            ),
        ],
      ),
    );
  }
}
