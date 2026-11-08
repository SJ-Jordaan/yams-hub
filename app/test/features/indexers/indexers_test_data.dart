/// Gateway-shaped samples for the indexers app tests (API.md §10).
library;

import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';

Indexer buildIndexer({
  int id = 4,
  String name = '1337x',
  bool enabled = true,
  IndexerStatus? status,
  int priority = 25,
  bool flare = false,
  DateTime? disabledTill,
  IndexerStats? stats = const IndexerStats(
    queries: 605,
    grabs: 8,
    rssQueries: 11108,
    avgResponseMs: 501,
  ),
  String? description,
  List<String>? categories,
}) => Indexer(
  id: id,
  name: name,
  enabled: enabled,
  priority: priority,
  protocol: 'torrent',
  privacy: 'public',
  status: status ?? (enabled ? IndexerStatus.ok : IndexerStatus.disabled),
  tags: flare ? const [IndexerTag(id: 1, label: 'flaresolverr')] : const [],
  usesFlareSolverr: flare,
  disabledTill: disabledTill,
  failingSince: disabledTill == null
      ? null
      : DateTime.utc(2026, 5, 29, 23, 36, 28),
  lastFailure: disabledTill?.subtract(const Duration(days: 1)),
  supportsRss: true,
  supportsSearch: true,
  baseUrl: 'https://$name.example.org/'.toLowerCase().replaceAll(' ', ''),
  implementation: 'Cardigann',
  language: 'en-US',
  added: DateTime.utc(2026, 2, 3, 19, 46, 40),
  stats: stats,
  description: description,
  categories: categories,
);

/// Retry time of the failing sample: later today in local time.
final uindexRetry = DateTime.now().add(const Duration(hours: 2));

List<Indexer> buildIndexers() => [
  buildIndexer(),
  buildIndexer(id: 8, name: 'Bangumi Moe', enabled: false, stats: null),
  buildIndexer(id: 5, name: 'Nyaa.si', flare: true, priority: 10),
  buildIndexer(
    id: 15,
    name: 'Uindex',
    status: IndexerStatus.failing,
    flare: true,
    disabledTill: uindexRetry,
  ),
];

IndexerList buildIndexerList({
  List<Indexer>? items,
  List<HealthMessage>? health,
}) => IndexerList(
  items: items ?? buildIndexers(),
  health:
      health ??
      const [
        HealthMessage(
          service: ServiceId.prowlarr,
          source: 'IndexerLongTermStatusCheck',
          type: HealthMessageType.warning,
          message: 'Indexers unavailable due to failures for more than 6 hours: Uindex',
        ),
      ],
  statsFrom: testNow.subtract(const Duration(days: 30)),
  statsTo: testNow,
);

Job buildTestJob({
  String id = 'j_test00000001',
  String kind = 'indexers.testall',
  JobStatus status = JobStatus.succeeded,
  JsonMap? result,
  ApiError? error,
}) => Job(
  id: id,
  kind: kind,
  target: 'all',
  status: status,
  steps: [JobStep(label: 'Test all indexers', status: status)],
  result: result,
  error: error,
  createdAt: testNow,
);

Release buildRelease({
  String id = 'rel_aaaaaaaaaaaaaaaaaaaaaaaa',
  String title = 'Example Author - Example Book (2025) EPUB',
  int seeders = 33,
  int sizeBytes = 15728640,
  int ageHours = 984,
  bool magnet = false,
  String? infoUrl = 'https://1337x.to/torrent/6000001/Example-Book/',
}) => Release(
  releaseId: id,
  indexerId: 4,
  indexer: '1337x',
  title: title,
  sizeBytes: sizeBytes,
  ageHours: ageHours,
  seeders: seeders,
  leechers: 2,
  categories: const ['Books'],
  infoUrl: infoUrl,
  protocol: 'torrent',
  hasMagnet: magnet,
);
