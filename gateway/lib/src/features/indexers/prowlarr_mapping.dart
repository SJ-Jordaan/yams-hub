/// Prowlarr 2.7 (API v1) JSON → indexers DTOs (API.md §10,
/// integrations/downloads.md §3). Pure functions, no I/O.
///
/// Prowlarr's `description` (detail excepted), `fields`,
/// `capabilities.categories` and any `downloadUrl` never reach a DTO.
library;

import 'package:yams_models/yams_models.dart';

/// The tag label that routes an indexer through the FlareSolverr proxy.
const flareSolverrTagLabel = 'flaresolverr';

/// One `GET /api/v1/indexerstatus` row (only indexers in failure back-off).
final class ProwlarrIndexerStatus {
  const ProwlarrIndexerStatus({
    required this.indexerId,
    this.disabledTill,
    this.mostRecentFailure,
    this.initialFailure,
  });

  factory ProwlarrIndexerStatus.fromJson(JsonMap j) => ProwlarrIndexerStatus(
    indexerId: req(readInt(j['indexerId']), 'indexerId'),
    disabledTill: readInstant(j['disabledTill']),
    mostRecentFailure: readInstant(j['mostRecentFailure']),
    initialFailure: readInstant(j['initialFailure']),
  );

  final int indexerId;
  final DateTime? disabledTill;
  final DateTime? mostRecentFailure;
  final DateTime? initialFailure;

  /// Prowlarr counts an indexer as failing only while `disabledTill > now`.
  bool isFailingAt(DateTime now) {
    final till = disabledTill;
    return till != null && till.isAfter(now);
  }
}

/// Everything `GET /indexers` joins, as loaded from Prowlarr.
final class ProwlarrSnapshot {
  const ProwlarrSnapshot({
    required this.indexers,
    required this.statuses,
    required this.tags,
    required this.health,
  });

  /// Raw `GET /api/v1/indexer` objects.
  final List<JsonMap> indexers;

  /// `indexerstatus` rows by indexer id.
  final Map<int, ProwlarrIndexerStatus> statuses;

  /// Tag labels by id.
  final Map<int, String> tags;
  final List<HealthMessage> health;

  /// Indexer names by id (history rows, search results).
  Map<int, String> get names {
    final out = <int, String>{};
    for (final i in indexers) {
      final id = readInt(i['id']);
      if (id != null) out[id] = readString(i['name']) ?? '#$id';
    }
    return out;
  }
}

/// Stats for one window.
final class ProwlarrStatsWindow {
  const ProwlarrStatsWindow({
    required this.from,
    required this.to,
    required this.byIndexer,
  });

  final DateTime from;
  final DateTime to;
  final Map<int, IndexerStats> byIndexer;

  int get totalGrabs => byIndexer.values.fold(0, (sum, s) => sum + s.grabs);

  int get totalQueries => byIndexer.values.fold(0, (sum, s) => sum + s.queries);
}

List<JsonMap> _objects(Object? v) => [
  if (v is List)
    for (final e in v) ?readMap(e),
];

/// `GET /api/v1/indexer`.
List<JsonMap> parseIndexers(Object? body) {
  if (body is! List) throw const FormatException('indexer list');
  return _objects(body);
}

/// `GET /api/v1/indexerstatus`.
Map<int, ProwlarrIndexerStatus> parseStatuses(Object? body) => {
  for (final row in _objects(body))
    if (readInt(row['indexerId']) != null)
      readInt(row['indexerId'])!: ProwlarrIndexerStatus.fromJson(row),
};

/// `GET /api/v1/tag`.
Map<int, String> parseTags(Object? body) {
  final out = <int, String>{};
  for (final t in _objects(body)) {
    final id = readInt(t['id']);
    if (id != null) out[id] = readString(t['label']) ?? '';
  }
  return out;
}

/// `GET /api/v1/health`.
List<HealthMessage> parseHealth(Object? body) => [
  for (final h in _objects(body))
    HealthMessage(
      service: ServiceId.prowlarr,
      source: readString(h['source']) ?? '',
      type: HealthMessageType.fromJson(h['type']),
      message: readString(h['message']) ?? '',
      wikiUrl: readString(h['wikiUrl']),
    ),
];

/// `GET /api/v1/indexerstats` → stats by indexer id.
Map<int, IndexerStats> parseStats(Object? body) {
  final out = <int, IndexerStats>{};
  for (final s in _objects(readMap(body)?['indexers'])) {
    final id = readInt(s['indexerId']);
    if (id == null) continue;
    out[id] = IndexerStats(
      queries: readInt(s['numberOfQueries']) ?? 0,
      grabs: readInt(s['numberOfGrabs']) ?? 0,
      rssQueries: readInt(s['numberOfRssQueries']) ?? 0,
      authQueries: readInt(s['numberOfAuthQueries']) ?? 0,
      failedQueries: readInt(s['numberOfFailedQueries']) ?? 0,
      failedGrabs: readInt(s['numberOfFailedGrabs']) ?? 0,
      failedRssQueries: readInt(s['numberOfFailedRssQueries']) ?? 0,
      avgResponseMs: readDouble(s['averageResponseTime'])?.round() ?? 0,
    );
  }
  return out;
}

String? _baseUrl(JsonMap raw) {
  for (final f in _objects(raw['fields'])) {
    if (f['name'] == 'baseUrl') {
      final v = readString(f['value']);
      if (v != null && v.isNotEmpty) return v;
    }
  }
  final urls = readStringList(raw['indexerUrls']);
  return urls.isEmpty ? null : urls.first;
}

/// Maps one raw Prowlarr indexer. With [detail], `description` and the
/// top-level category names are included.
Indexer mapIndexer(
  JsonMap raw, {
  required Map<int, ProwlarrIndexerStatus> statuses,
  required Map<int, String> tags,
  required Map<int, IndexerStats> stats,
  required DateTime now,
  bool detail = false,
}) {
  final id = req(readInt(raw['id']), 'id');
  final enabled = readBool(raw['enable']) ?? false;
  final status = statuses[id];
  final tagList = [
    for (final tagId in readIntList(raw['tags']))
      IndexerTag(id: tagId, label: tags[tagId] ?? '#$tagId'),
  ];
  final IndexerStatus state;
  if (!enabled) {
    state = IndexerStatus.disabled;
  } else if (status != null && status.isFailingAt(now)) {
    state = IndexerStatus.failing;
  } else {
    state = IndexerStatus.ok;
  }
  final description = readString(raw['description']);
  return Indexer(
    id: id,
    name: readString(raw['name']) ?? '#$id',
    enabled: enabled,
    priority: readInt(raw['priority']) ?? 25,
    protocol: readString(raw['protocol']) ?? 'unknown',
    privacy: readString(raw['privacy']) ?? 'unknown',
    tags: tagList,
    usesFlareSolverr: tagList.any(
      (t) => t.label.toLowerCase() == flareSolverrTagLabel,
    ),
    status: state,
    disabledTill: status?.disabledTill,
    failingSince: status?.initialFailure,
    lastFailure: status?.mostRecentFailure,
    supportsRss: readBool(raw['supportsRss']) ?? false,
    supportsSearch: readBool(raw['supportsSearch']) ?? false,
    baseUrl: _baseUrl(raw),
    implementation: readString(raw['implementation']),
    language: readString(raw['language']),
    added: readInstant(raw['added']),
    stats: stats[id],
    description: detail && description != null && description.isNotEmpty
        ? description
        : null,
    categories: detail
        ? [
            for (final c in _objects(
              readMap(raw['capabilities'])?['categories'],
            ))
              if (readString(c['name']) case final n? when n.isNotEmpty) n,
          ]
        : null,
  );
}

/// The indexers of [snapshot], sorted by name.
List<Indexer> mapIndexers(
  ProwlarrSnapshot snapshot, {
  required Map<int, IndexerStats> stats,
  required DateTime now,
}) {
  final items = [
    for (final raw in snapshot.indexers)
      if (readInt(raw['id']) != null)
        mapIndexer(
          raw,
          statuses: snapshot.statuses,
          tags: snapshot.tags,
          stats: stats,
          now: now,
        ),
  ];
  items.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return items;
}

String? _nonEmpty(Object? v) {
  final s = readString(v)?.trim();
  return s == null || s.isEmpty ? null : s;
}

/// One `GET /api/v1/history` record (`data` values are all strings; `url` is
/// dropped).
IndexerHistoryItem mapHistoryRecord(JsonMap r, Map<int, String> names) {
  final indexerId = readInt(r['indexerId']) ?? 0;
  final data = readMap(r['data']) ?? const <String, Object?>{};
  return IndexerHistoryItem(
    id: req(readInt(r['id']), 'id'),
    indexerId: indexerId,
    indexerName: names[indexerId] ?? '#$indexerId',
    date: req(readInstant(r['date']), 'date'),
    successful: readBool(r['successful']) ?? false,
    type: IndexerHistoryType.fromUpstream(r['eventType']),
    source: _nonEmpty(data['source']),
    host: _nonEmpty(data['host']),
    query: _nonEmpty(data['query']),
    queryType: _nonEmpty(data['queryType']),
    categories: _nonEmpty(data['categories']),
    results: readInt(data['queryResults']),
    elapsedMs: readInt(data['elapsedTime']),
    grabTitle: _nonEmpty(data['grabTitle']),
  );
}

/// `GET /api/v1/indexer/categories` (sub-sub-categories are dropped).
List<IndexerCategory> parseCategories(Object? body) {
  if (body is! List) throw const FormatException('categories');
  return [
    for (final c in _objects(body))
      if (readInt(c['id']) case final id?)
        IndexerCategory(
          id: id,
          name: readString(c['name']) ?? '$id',
          subCategories: [
            for (final s in _objects(c['subCategories']))
              if (readInt(s['id']) case final sid?)
                IndexerSubcategory(
                  id: sid,
                  name: readString(s['name']) ?? '$sid',
                ),
          ],
        ),
  ];
}

/// The parts of a Prowlarr search result the gateway keeps for a grab.
final class ProwlarrReleaseLinks {
  const ProwlarrReleaseLinks({
    required this.indexerId,
    required this.title,
    required this.protocol,
    this.downloadUrl,
    this.magnetUrl,
    this.magnetLinkUrl,
  });

  final int indexerId;
  final String title;
  final String protocol;

  /// Never returned to clients nor logged.
  final String? downloadUrl;

  /// A real `magnet:` link.
  final String? magnetUrl;

  /// A `magnetUrl` that is not a `magnet:` link: Prowlarr rewrites magnet
  /// links to its own proxied download route, which answers with a redirect
  /// to the magnet. Fetched like [downloadUrl] (same SSRF rules) when there is
  /// no [downloadUrl].
  final String? magnetLinkUrl;

  bool get hasMagnet =>
      magnetUrl != null ||
      magnetLinkUrl != null ||
      (downloadUrl?.toLowerCase().startsWith('magnet:') ?? false);
}

String? _url(Object? v) {
  final s = readString(v)?.trim();
  return s == null || s.isEmpty ? null : s;
}

/// Extracts the grab links of one search result.
ProwlarrReleaseLinks releaseLinks(JsonMap r) {
  final magnet = _url(r['magnetUrl']);
  final isMagnet = magnet != null && magnet.toLowerCase().startsWith('magnet:');
  return ProwlarrReleaseLinks(
    indexerId: readInt(r['indexerId']) ?? 0,
    title: readString(r['title']) ?? '',
    protocol: readString(r['protocol']) ?? 'unknown',
    downloadUrl: _url(r['downloadUrl']),
    magnetUrl: isMagnet ? magnet : null,
    magnetLinkUrl: isMagnet ? null : magnet,
  );
}

final _secretInUrl = RegExp(
  r'(api[_-]?key|apikey|passkey|token|auth|sid)=',
  caseSensitive: false,
);

String? _imdb(Object? v) {
  final s = readString(v)?.trim();
  if (s == null || s.isEmpty || s == '0') return null;
  if (RegExp(r'^tt\d+$').hasMatch(s)) return s;
  final n = int.tryParse(s);
  if (n == null || n <= 0) return null;
  return 'tt${n.toString().padLeft(7, '0')}';
}

int? _positive(Object? v) {
  final n = readInt(v);
  return n == null || n <= 0 ? null : n;
}

/// Maps one Prowlarr search result to the client DTO under [releaseId].
Release mapRelease(JsonMap r, String releaseId, Map<int, String> names) {
  final links = releaseLinks(r);
  final infoUrl = _url(r['infoUrl']);
  final ageHours =
      readDouble(r['ageHours']) ??
      switch (readDouble(r['age'])) {
        final days? => days * 24,
        null => null,
      };
  return Release(
    releaseId: releaseId,
    indexerId: links.indexerId,
    indexer:
        readString(r['indexer']) ??
        names[links.indexerId] ??
        '#${links.indexerId}',
    title: links.title,
    sizeBytes: readInt(r['size']) ?? 0,
    publishDate: readInstant(r['publishDate']),
    ageHours: ageHours?.floor(),
    seeders: readInt(r['seeders']),
    leechers: readInt(r['leechers']),
    grabs: readInt(r['grabs']),
    categories: [
      for (final c in _objects(r['categories']))
        if (readString(c['name']) case final n? when n.isNotEmpty) n,
    ],
    // Info pages are public tracker URLs; drop any that look like they carry
    // credentials.
    infoUrl:
        infoUrl != null &&
            (infoUrl.startsWith('https://') || infoUrl.startsWith('http://')) &&
            !_secretInUrl.hasMatch(infoUrl)
        ? infoUrl
        : null,
    protocol: links.protocol,
    hasMagnet: links.hasMagnet,
    imdbId: _imdb(r['imdbId']),
    tmdbId: _positive(r['tmdbId']),
    tvdbId: _positive(r['tvdbId']),
  );
}
