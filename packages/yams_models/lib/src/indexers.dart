/// Indexers (Prowlarr) DTOs (API.md §10).
library;

import 'package:meta/meta.dart';

import 'arr_common.dart';
import 'json.dart';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// The app-facing state of an [Indexer] (API.md §10.1).
///
/// [disabled] when the user switched it off, [failing] while Prowlarr keeps it
/// in failure back-off (`disabledTill > now`), else [ok].
enum IndexerStatus {
  ok,
  failing,
  disabled,
  unknown;

  static IndexerStatus fromJson(Object? v) =>
      readEnum(v, IndexerStatus.values, IndexerStatus.unknown);

  String toJson() => name;
}

/// Prowlarr history event types (API.md §10.2). Upstream filters by the
/// integer in [upstreamEventType]; records carry the camelCase name.
enum IndexerHistoryType {
  grabbed(1, 'releaseGrabbed'),
  query(2, 'indexerQuery'),
  rss(3, 'indexerRss'),
  auth(4, 'indexerAuth'),
  infoQuery(5, 'indexerInfoQuery'),
  unknown(null, null);

  const IndexerHistoryType(this.upstreamEventType, this.upstreamName);

  /// The `eventType=` filter value of Prowlarr's `GET /api/v1/history`.
  final int? upstreamEventType;

  /// The `eventType` string in Prowlarr history records.
  final String? upstreamName;

  /// The values accepted by the gateway's `type=` filter.
  static const filterable = [grabbed, query, rss, auth];

  static IndexerHistoryType fromJson(Object? v) =>
      readEnum(v, IndexerHistoryType.values, IndexerHistoryType.unknown);

  /// Maps a Prowlarr record's `eventType` (camelCase string, or the int).
  static IndexerHistoryType fromUpstream(Object? v) {
    final n = readInt(v);
    for (final t in values) {
      if (t == unknown) continue;
      if (v is String && t.upstreamName == v) return t;
      if (n != null && t.upstreamEventType == n) return t;
    }
    return unknown;
  }

  String toJson() => name;
}

/// The `type=` of a manual release search (API.md §10.4).
enum ReleaseSearchType {
  search,
  tvsearch,
  movie,
  music,
  book,
  unknown;

  /// The values a client may send.
  static const selectable = [search, tvsearch, movie, music, book];

  static ReleaseSearchType fromJson(Object? v) =>
      readEnum(v, ReleaseSearchType.values, ReleaseSearchType.unknown);

  String toJson() => name;
}

// ---------------------------------------------------------------------------
// Indexers
// ---------------------------------------------------------------------------

/// A Prowlarr tag (`{"id": 1, "label": "flaresolverr"}`).
@immutable
final class IndexerTag {
  const IndexerTag({required this.id, required this.label});

  factory IndexerTag.fromJson(JsonMap j) => IndexerTag(
    id: req(readInt(j['id']), 'id'),
    label: readString(j['label']) ?? '',
  );

  final int id;
  final String label;

  JsonMap toJson() => {'id': id, 'label': label};
}

/// Per-indexer counters from Prowlarr `indexerstats` (last 30 days).
@immutable
final class IndexerStats {
  const IndexerStats({
    this.queries = 0,
    this.grabs = 0,
    this.rssQueries = 0,
    this.authQueries = 0,
    this.failedQueries = 0,
    this.failedGrabs = 0,
    this.failedRssQueries = 0,
    this.avgResponseMs = 0,
  });

  factory IndexerStats.fromJson(JsonMap j) => IndexerStats(
    queries: readInt(j['queries']) ?? 0,
    grabs: readInt(j['grabs']) ?? 0,
    rssQueries: readInt(j['rssQueries']) ?? 0,
    authQueries: readInt(j['authQueries']) ?? 0,
    failedQueries: readInt(j['failedQueries']) ?? 0,
    failedGrabs: readInt(j['failedGrabs']) ?? 0,
    failedRssQueries: readInt(j['failedRssQueries']) ?? 0,
    avgResponseMs: readInt(j['avgResponseMs']) ?? 0,
  );

  final int queries;
  final int grabs;
  final int rssQueries;
  final int authQueries;
  final int failedQueries;
  final int failedGrabs;
  final int failedRssQueries;
  final int avgResponseMs;

  /// Search + RSS queries.
  int get totalQueries => queries + rssQueries;

  /// Failed search + RSS queries as a 0..1 share of [totalQueries] (0 when
  /// there were none).
  double get failureRate {
    final total = totalQueries;
    if (total <= 0) return 0;
    return (failedQueries + failedRssQueries) / total;
  }

  JsonMap toJson() => {
    'queries': queries,
    'grabs': grabs,
    'rssQueries': rssQueries,
    'authQueries': authQueries,
    'failedQueries': failedQueries,
    'failedGrabs': failedGrabs,
    'failedRssQueries': failedRssQueries,
    'avgResponseMs': avgResponseMs,
  };
}

/// One Prowlarr indexer (API.md §10.1). [description] and [categories] are
/// only sent by `GET /indexers/{id}`.
@immutable
final class Indexer {
  const Indexer({
    required this.id,
    required this.name,
    required this.enabled,
    required this.priority,
    required this.protocol,
    required this.privacy,
    required this.status,
    this.tags = const [],
    this.usesFlareSolverr = false,
    this.disabledTill,
    this.failingSince,
    this.lastFailure,
    this.supportsRss = false,
    this.supportsSearch = false,
    this.baseUrl,
    this.implementation,
    this.language,
    this.added,
    this.stats,
    this.description,
    this.categories,
  });

  factory Indexer.fromJson(JsonMap j) => Indexer(
    id: req(readInt(j['id']), 'id'),
    name: req(readString(j['name']), 'name'),
    enabled: readBool(j['enabled']) ?? false,
    priority: readInt(j['priority']) ?? 25,
    protocol: readString(j['protocol']) ?? 'unknown',
    privacy: readString(j['privacy']) ?? 'unknown',
    tags: readList(j['tags'], IndexerTag.fromJson),
    usesFlareSolverr: readBool(j['usesFlareSolverr']) ?? false,
    status: IndexerStatus.fromJson(j['status']),
    disabledTill: readInstant(j['disabledTill']),
    failingSince: readInstant(j['failingSince']),
    lastFailure: readInstant(j['lastFailure']),
    supportsRss: readBool(j['supportsRss']) ?? false,
    supportsSearch: readBool(j['supportsSearch']) ?? false,
    baseUrl: readString(j['baseUrl']),
    implementation: readString(j['implementation']),
    language: readString(j['language']),
    added: readInstant(j['added']),
    stats: switch (readMap(j['stats'])) {
      final m? => IndexerStats.fromJson(m),
      null => null,
    },
    description: readString(j['description']),
    categories: j['categories'] is List
        ? readStringList(j['categories'])
        : null,
  );

  final int id;
  final String name;
  final bool enabled;

  /// 1–50, lower = preferred (Prowlarr default 25).
  final int priority;

  /// `torrent` | `usenet`.
  final String protocol;

  /// `public` | `semiPrivate` | `private`.
  final String privacy;
  final List<IndexerTag> tags;

  /// Has the tag labelled `flaresolverr`.
  final bool usesFlareSolverr;
  final IndexerStatus status;

  /// Back-off end (the indexer is failing while this is in the future).
  final DateTime? disabledTill;

  /// First failure of the current failure streak.
  final DateTime? failingSince;

  /// Most recent failure.
  final DateTime? lastFailure;
  final bool supportsRss;
  final bool supportsSearch;
  final String? baseUrl;
  final String? implementation;
  final String? language;
  final DateTime? added;

  /// 30-day counters; null when the indexer has no history in the window or
  /// the stats could not be loaded.
  final IndexerStats? stats;

  /// Detail only.
  final String? description;

  /// Detail only: top-level category names.
  final List<String>? categories;

  bool get isFailing => status == IndexerStatus.failing;

  /// A copy with [enabled] (and the derived [status]) changed, for optimistic
  /// updates of the enable switch.
  Indexer withEnabled(bool value, {DateTime? now}) {
    final IndexerStatus next;
    if (!value) {
      next = IndexerStatus.disabled;
    } else {
      final till = disabledTill;
      final failing = till != null && till.isAfter(now ?? DateTime.now());
      next = failing ? IndexerStatus.failing : IndexerStatus.ok;
    }
    return _copy(enabled: value, status: next);
  }

  /// A copy with [priority] changed.
  Indexer withPriority(int value) => _copy(priority: value);

  Indexer _copy({bool? enabled, IndexerStatus? status, int? priority}) =>
      Indexer(
        id: id,
        name: name,
        enabled: enabled ?? this.enabled,
        priority: priority ?? this.priority,
        protocol: protocol,
        privacy: privacy,
        tags: tags,
        usesFlareSolverr: usesFlareSolverr,
        status: status ?? this.status,
        disabledTill: disabledTill,
        failingSince: failingSince,
        lastFailure: lastFailure,
        supportsRss: supportsRss,
        supportsSearch: supportsSearch,
        baseUrl: baseUrl,
        implementation: implementation,
        language: language,
        added: added,
        stats: stats,
        description: description,
        categories: categories,
      );

  JsonMap toJson() => compactJson({
    'id': id,
    'name': name,
    'enabled': enabled,
    'priority': priority,
    'protocol': protocol,
    'privacy': privacy,
    'tags': [for (final t in tags) t.toJson()],
    'usesFlareSolverr': usesFlareSolverr,
    'status': status.toJson(),
    'disabledTill': optionalInstantToJson(disabledTill),
    'failingSince': optionalInstantToJson(failingSince),
    'lastFailure': optionalInstantToJson(lastFailure),
    'supportsRss': supportsRss,
    'supportsSearch': supportsSearch,
    'baseUrl': baseUrl,
    'implementation': implementation,
    'language': language,
    'added': optionalInstantToJson(added),
    'stats': stats?.toJson(),
    'description': description,
    'categories': categories,
  });
}

/// 200 body of `GET /indexers` and `PATCH /indexers`.
@immutable
final class IndexerList {
  const IndexerList({
    required this.items,
    required this.statsFrom,
    required this.statsTo,
    this.health = const [],
  });

  factory IndexerList.fromJson(JsonMap j) => IndexerList(
    items: readList(j['items'], Indexer.fromJson),
    health: readList(j['health'], HealthMessage.fromJson),
    statsFrom: req(readInstant(j['statsFrom']), 'statsFrom'),
    statsTo: req(readInstant(j['statsTo']), 'statsTo'),
  );

  final List<Indexer> items;

  /// Prowlarr health checks (`GET /api/v1/health`).
  final List<HealthMessage> health;

  /// The window of every [Indexer.stats].
  final DateTime statsFrom;
  final DateTime statsTo;

  /// A copy with [items] replaced (optimistic updates).
  IndexerList withItems(List<Indexer> items) => IndexerList(
    items: items,
    health: health,
    statsFrom: statsFrom,
    statsTo: statsTo,
  );

  JsonMap toJson() => {
    'items': [for (final i in items) i.toJson()],
    'health': [for (final h in health) h.toJson()],
    'statsFrom': instantToJson(statsFrom),
    'statsTo': instantToJson(statsTo),
  };
}

/// Body of `PATCH /indexers` (at least one of [enabled] and [priority]).
@immutable
final class IndexerBulkUpdate {
  const IndexerBulkUpdate({required this.ids, this.enabled, this.priority});

  factory IndexerBulkUpdate.fromJson(JsonMap j) => IndexerBulkUpdate(
    ids: readIntList(j['ids']),
    enabled: readBool(j['enabled']),
    priority: readInt(j['priority']),
  );

  final List<int> ids;
  final bool? enabled;
  final int? priority;

  JsonMap toJson() =>
      compactJson({'ids': ids, 'enabled': enabled, 'priority': priority});
}

/// One indexer test outcome (job `result` of `POST /indexers/{id}/test`;
/// `items` of `POST /indexers/test-all`).
@immutable
final class IndexerTestResult {
  const IndexerTestResult({
    required this.id,
    required this.valid,
    this.failures = const [],
  });

  factory IndexerTestResult.fromJson(JsonMap j) => IndexerTestResult(
    id: req(readInt(j['id']), 'id'),
    valid: readBool(j['valid']) ?? false,
    failures: readStringList(j['failures']),
  );

  final int id;
  final bool valid;

  /// Prowlarr's validation messages (redacted).
  final List<String> failures;

  /// Decodes the `items` of a test-all job result.
  static List<IndexerTestResult> listFromJobResult(JsonMap? result) =>
      readList(result?['items'], IndexerTestResult.fromJson);

  JsonMap toJson() => {'id': id, 'valid': valid, 'failures': failures};
}

// ---------------------------------------------------------------------------
// History and categories
// ---------------------------------------------------------------------------

/// One Prowlarr history record (API.md §10.2); the upstream `url` is dropped.
@immutable
final class IndexerHistoryItem {
  const IndexerHistoryItem({
    required this.id,
    required this.indexerId,
    required this.indexerName,
    required this.date,
    required this.successful,
    required this.type,
    this.source,
    this.host,
    this.query,
    this.queryType,
    this.categories,
    this.results,
    this.elapsedMs,
    this.grabTitle,
  });

  factory IndexerHistoryItem.fromJson(JsonMap j) => IndexerHistoryItem(
    id: req(readInt(j['id']), 'id'),
    indexerId: readInt(j['indexerId']) ?? 0,
    indexerName: readString(j['indexerName']) ?? '',
    date: req(readInstant(j['date']), 'date'),
    successful: readBool(j['successful']) ?? false,
    type: IndexerHistoryType.fromJson(j['type']),
    source: readString(j['source']),
    host: readString(j['host']),
    query: readString(j['query']),
    queryType: readString(j['queryType']),
    categories: readString(j['categories']),
    results: readInt(j['results']),
    elapsedMs: readInt(j['elapsedMs']),
    grabTitle: readString(j['grabTitle']),
  );

  final int id;
  final int indexerId;
  final String indexerName;
  final DateTime date;
  final bool successful;
  final IndexerHistoryType type;

  /// The app that asked (`Sonarr`, `Radarr`, `Prowlarr`).
  final String? source;
  final String? host;
  final String? query;
  final String? queryType;

  /// Comma-separated Newznab category ids (`"5000,5040"`).
  final String? categories;
  final int? results;
  final int? elapsedMs;
  final String? grabTitle;

  JsonMap toJson() => compactJson({
    'id': id,
    'indexerId': indexerId,
    'indexerName': indexerName,
    'date': instantToJson(date),
    'successful': successful,
    'type': type.toJson(),
    'source': source,
    'host': host,
    'query': query,
    'queryType': queryType,
    'categories': categories,
    'results': results,
    'elapsedMs': elapsedMs,
    'grabTitle': grabTitle,
  });
}

/// A Newznab sub-category of an [IndexerCategory].
@immutable
final class IndexerSubcategory {
  const IndexerSubcategory({required this.id, required this.name});

  factory IndexerSubcategory.fromJson(JsonMap j) => IndexerSubcategory(
    id: req(readInt(j['id']), 'id'),
    name: readString(j['name']) ?? '',
  );

  final int id;
  final String name;

  JsonMap toJson() => {'id': id, 'name': name};
}

/// A top-level Newznab category (`GET /indexers/categories`).
@immutable
final class IndexerCategory {
  const IndexerCategory({
    required this.id,
    required this.name,
    this.subCategories = const [],
  });

  factory IndexerCategory.fromJson(JsonMap j) => IndexerCategory(
    id: req(readInt(j['id']), 'id'),
    name: readString(j['name']) ?? '',
    subCategories: readList(j['subCategories'], IndexerSubcategory.fromJson),
  );

  final int id;
  final String name;
  final List<IndexerSubcategory> subCategories;

  JsonMap toJson() => {
    'id': id,
    'name': name,
    'subCategories': [for (final s in subCategories) s.toJson()],
  };
}

// ---------------------------------------------------------------------------
// Manual search and grab
// ---------------------------------------------------------------------------

/// One manual-search result (API.md §10.4). The download URL stays in the
/// gateway; [releaseId] is the token to grab it with (valid 30 min).
@immutable
final class Release {
  const Release({
    required this.releaseId,
    required this.indexerId,
    required this.indexer,
    required this.title,
    required this.sizeBytes,
    required this.protocol,
    this.publishDate,
    this.ageHours,
    this.seeders,
    this.leechers,
    this.grabs,
    this.categories = const [],
    this.infoUrl,
    this.hasMagnet = false,
    this.imdbId,
    this.tmdbId,
    this.tvdbId,
  });

  factory Release.fromJson(JsonMap j) => Release(
    releaseId: req(readString(j['releaseId']), 'releaseId'),
    indexerId: readInt(j['indexerId']) ?? 0,
    indexer: readString(j['indexer']) ?? '',
    title: req(readString(j['title']), 'title'),
    sizeBytes: readInt(j['sizeBytes']) ?? 0,
    publishDate: readInstant(j['publishDate']),
    ageHours: readInt(j['ageHours']),
    seeders: readInt(j['seeders']),
    leechers: readInt(j['leechers']),
    grabs: readInt(j['grabs']),
    categories: readStringList(j['categories']),
    infoUrl: readString(j['infoUrl']),
    protocol: readString(j['protocol']) ?? 'unknown',
    hasMagnet: readBool(j['hasMagnet']) ?? false,
    imdbId: readString(j['imdbId']),
    tmdbId: readInt(j['tmdbId']),
    tvdbId: readInt(j['tvdbId']),
  );

  final String releaseId;
  final int indexerId;
  final String indexer;
  final String title;
  final int sizeBytes;
  final DateTime? publishDate;
  final int? ageHours;
  final int? seeders;
  final int? leechers;
  final int? grabs;

  /// Category names.
  final List<String> categories;
  final String? infoUrl;

  /// `torrent` | `usenet`.
  final String protocol;
  final bool hasMagnet;

  /// `tt…` form.
  final String? imdbId;
  final int? tmdbId;
  final int? tvdbId;

  JsonMap toJson() => compactJson({
    'releaseId': releaseId,
    'indexerId': indexerId,
    'indexer': indexer,
    'title': title,
    'sizeBytes': sizeBytes,
    'publishDate': optionalInstantToJson(publishDate),
    'ageHours': ageHours,
    'seeders': seeders,
    'leechers': leechers,
    'grabs': grabs,
    'categories': categories,
    'infoUrl': infoUrl,
    'protocol': protocol,
    'hasMagnet': hasMagnet,
    'imdbId': imdbId,
    'tmdbId': tmdbId,
    'tvdbId': tvdbId,
  });
}

/// 200 body of `GET /indexers/search`.
@immutable
final class ReleaseList {
  const ReleaseList({required this.items, required this.tookMs});

  factory ReleaseList.fromJson(JsonMap j) => ReleaseList(
    items: readList(j['items'], Release.fromJson),
    tookMs: readInt(j['tookMs']) ?? 0,
  );

  final List<Release> items;

  /// How long the upstream search took.
  final int tookMs;

  JsonMap toJson() => {
    'items': [for (final r in items) r.toJson()],
    'tookMs': tookMs,
  };
}

/// Body of `POST /indexers/grab`.
@immutable
final class ReleaseGrabRequest {
  const ReleaseGrabRequest({
    required this.releaseId,
    this.category = defaultCategory,
    this.tags,
  });

  factory ReleaseGrabRequest.fromJson(JsonMap j) => ReleaseGrabRequest(
    releaseId: req(readString(j['releaseId']), 'releaseId'),
    category: readString(j['category']) ?? defaultCategory,
    tags: j['tags'] is List ? readStringList(j['tags']) : null,
  );

  /// The qBittorrent category for manual grabs (created when missing).
  static const defaultCategory = 'manual';

  final String releaseId;
  final String category;
  final List<String>? tags;

  JsonMap toJson() =>
      compactJson({'releaseId': releaseId, 'category': category, 'tags': tags});
}

// ---------------------------------------------------------------------------
// Dashboard card
// ---------------------------------------------------------------------------

/// One failing indexer on the [IndexersCard].
@immutable
final class IndexersCardFailing {
  const IndexersCardFailing({
    required this.id,
    required this.name,
    this.disabledTill,
  });

  factory IndexersCardFailing.fromJson(JsonMap j) => IndexersCardFailing(
    id: req(readInt(j['id']), 'id'),
    name: readString(j['name']) ?? '',
    disabledTill: readInstant(j['disabledTill']),
  );

  final int id;
  final String name;

  /// When Prowlarr retries the indexer.
  final DateTime? disabledTill;

  JsonMap toJson() => compactJson({
    'id': id,
    'name': name,
    'disabledTill': optionalInstantToJson(disabledTill),
  });
}

/// Dashboard card `indexers` (API.md §10.6). Core reads the raw `failing`
/// array length for the More screen.
@immutable
final class IndexersCard {
  const IndexersCard({
    required this.total,
    required this.enabled,
    this.failing = const [],
    this.grabs24h,
    this.queries24h,
  });

  factory IndexersCard.fromJson(JsonMap j) => IndexersCard(
    total: readInt(j['total']) ?? 0,
    enabled: readInt(j['enabled']) ?? 0,
    failing: readList(j['failing'], IndexersCardFailing.fromJson),
    grabs24h: readInt(j['grabs24h']),
    queries24h: readInt(j['queries24h']),
  );

  final int total;
  final int enabled;
  final List<IndexersCardFailing> failing;

  /// Last 24 h; null when the stats could not be loaded.
  final int? grabs24h;
  final int? queries24h;

  JsonMap toJson() => compactJson({
    'total': total,
    'enabled': enabled,
    'failing': [for (final f in failing) f.toJson()],
    'grabs24h': grabs24h,
    'queries24h': queries24h,
  });
}
