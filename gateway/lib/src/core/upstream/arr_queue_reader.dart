/// Reads a whole Sonarr/Radarr queue (`GET /api/v3/queue`, paged).
library;

import 'package:yams_models/yams_models.dart';

import 'upstream_client.dart';
import 'upstream_exception.dart';

/// Records per queue page.
const arrQueuePageSize = 200;

/// At most this many pages are read (2 000 records).
const arrQueueMaxPages = 10;

/// The records of one queue read.
final class ArrQueueRead {
  const ArrQueueRead(this.records, {required this.complete, this.total});

  final List<JsonMap> records;

  /// Every record was read (false when [arrQueueMaxPages] cut it short).
  final bool complete;

  /// The *arr's `totalRecords`, when it sent one.
  final int? total;
}

/// Reads `GET /api/v3/queue` page by page until `totalRecords` (or a short
/// page) is reached: season packs add one record per episode, so a few
/// batch grabs exceed one page. [query] holds the filters and include flags;
/// `page` and `pageSize` are set here.
Future<ArrQueueRead> readArrQueue(
  UpstreamClient client,
  Map<String, Object?> query, {
  int pageSize = arrQueuePageSize,
  int maxPages = arrQueueMaxPages,
  Duration? timeout,
}) async {
  const path = '/api/v3/queue';
  final all = <JsonMap>[];
  int? total;
  for (var page = 1; page <= maxPages; page++) {
    final body = readMap(
      await client.getJson(
        path,
        query: {...query, 'page': page, 'pageSize': pageSize},
        timeout: timeout,
      ),
    );
    final records = body?['records'];
    if (records is! List) {
      throw UpstreamBadResponse(
        service: client.service,
        method: 'GET',
        path: path,
        reason: 'queue has no records',
      );
    }
    total = readInt(body?['totalRecords']) ?? total;
    all.addAll([for (final r in records) ?readMap(r)]);
    final done =
        records.length < pageSize || (total != null && all.length >= total);
    if (done) return ArrQueueRead(all, complete: true, total: total);
  }
  return ArrQueueRead(all, complete: false, total: total);
}
