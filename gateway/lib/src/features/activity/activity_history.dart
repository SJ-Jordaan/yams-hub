/// `GET /activity/history`: Sonarr and Radarr history merged newest-first
/// with the core merged-feed cursor (API.md §8.7, ARCHITECTURE §5.7).
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'arr_mapping.dart';

/// Fixed upstream page size of the merged feed.
const historyPageSize = 50;

/// Loads and merges the history feeds.
final class ActivityHistory {
  ActivityHistory(this._ctx)
    : _pages = _ctx.caches.ttl<String, List<ArrHistoryItem>>(
        'activity.history',
        const Duration(seconds: 30),
        maxEntries: 200,
      );

  final FeatureContext _ctx;
  final TtlCache<String, List<ArrHistoryItem>> _pages;

  /// One page of the merged feed.
  Future<CursorPage<ArrHistoryItem>> page({
    required List<ArrService> services,
    required List<ArrHistoryType> types,
    required int limit,
    String? cursor,
  }) {
    final typeKey = (types.map((t) => t.name).toList()..sort()).join(',');
    return mergeFeeds<ArrHistoryItem>(
      sources: {
        for (final s in services)
          s.name: (page) => _pages.value(
            '${s.name}|$typeKey|$page',
            () => _load(s, types, page),
          ),
      },
      dateOf: (i) => i.date,
      limit: limit,
      clock: _ctx.clock,
      cursor: cursor,
      pageSize: historyPageSize,
    );
  }

  Future<List<ArrHistoryItem>> _load(
    ArrService service,
    List<ArrHistoryType> types,
    int page,
  ) async {
    final query = <String, Object?>{
      'page': page,
      'pageSize': historyPageSize,
      'sortKey': 'date',
      'sortDirection': 'descending',
      if (service == ArrService.sonarr) ...{
        'includeSeries': true,
        'includeEpisode': true,
      } else
        'includeMovie': true,
      if (types.isNotEmpty)
        'eventType': [for (final t in types) ...t.eventTypesFor(service)],
    };
    final Object? body;
    try {
      body = await _ctx.upstreams
          .arr(service)
          .getJson('/api/v3/history', query: query);
    } on UpstreamException catch (e) {
      throw e.toApiException(resourceNotFound: false);
    }
    final records = readMap(body)?['records'];
    final raw = records is List ? records : const <Object?>[];
    final items = [
      for (final r in raw)
        if (readMap(r) case final m?) ?historyItemOf(service, m, _ctx.images),
    ];
    // A dropped record must not end the feed early: pad the page length so
    // the merger still loads the next page after a full upstream page.
    if (raw.length >= historyPageSize && items.length < historyPageSize) {
      final date = items.isEmpty ? _epoch : items.last.date;
      return [
        ...items,
        for (var i = items.length; i < historyPageSize; i++) _padding(date),
      ];
    }
    return items;
  }
}

final _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// Placeholder for an unreadable record (filtered out by the route), dated
/// like its predecessor so the merge order is unchanged.
ArrHistoryItem _padding(DateTime date) => ArrHistoryItem(
  id: '',
  service: ArrService.unknown,
  type: ArrHistoryType.unknown,
  date: date,
  sourceTitle: '',
  quality: const QualityInfo(name: 'Unknown'),
);

/// Whether [item] is a real record (not padding).
bool isHistoryRecord(ArrHistoryItem item) => item.id.isNotEmpty;
