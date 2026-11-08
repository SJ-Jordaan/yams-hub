/// Gateway-shaped activity samples for the app tests.
library;

import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';

const sonarrHash = '0985d9efdf7508db837e629ae8f40ee8b56f4d71';
const seedHash = '4f1acde36a17c2f9faedc9f425758ca8525e2e57';

TorrentSummary buildTorrent({
  String hash = seedHash,
  String name = 'Cyberpunk.Edgerunners.S02E01.1080p.WEB-DL',
  TorrentState state = TorrentState.seeding,
  String stateRaw = 'uploading',
  TorrentDirection direction = TorrentDirection.upload,
  double progress = 1,
  String? category,
  List<String> tags = const [],
  int upBps = 686561,
}) => TorrentSummary(
  hash: hash,
  name: name,
  state: state,
  stateRaw: stateRaw,
  direction: direction,
  progress: progress,
  sizeBytes: 920507089,
  downloadedBytes: 920507089,
  uploadedBytes: 248603649,
  amountLeftBytes: progress >= 1 ? 0 : 400000000,
  dlBps: direction == TorrentDirection.download ? 4800000 : 0,
  upBps: upBps,
  etaSeconds: direction == TorrentDirection.download ? 2470 : null,
  ratio: 0.267,
  seeds: 3,
  peers: 12,
  category: category,
  tags: tags,
  addedAt: testNow.subtract(const Duration(days: 1)),
  protected: tags.contains('Keep'),
  managedBy: category == 'tv-sonarr' ? ArrService.sonarr : null,
);

QueueArrEntry buildArrEntry({bool admin = true, QueueTrackedState state = QueueTrackedState.importPending}) =>
    QueueArrEntry(
      service: ArrService.sonarr,
      queueIds: const [123456, 123457],
      mediaTitle: 'That Time I Got Reincarnated as a Slime',
      seriesId: 54,
      episodeIds: const [5580, 5581],
      episodesLabel: 'S04E01–E02',
      status: QueueArrStatus.completed,
      trackedStatus: QueueTrackedStatus.warning,
      trackedState: state,
      messages: const ['No files found are eligible for import'],
      downloadId: sonarrHash.toUpperCase(),
      canManualImport: admin && state.needsImport,
      links: admin ? const [ExternalLink(ExternalApp.sonarr, '/activity/queue')] : const [],
    );

QueueItem buildAttentionItem({bool admin = true}) => QueueItem(
  key: sonarrHash,
  title: 'That Time I Got Reincarnated as a Slime',
  subtitle: 'Sonarr · S04E01–E02',
  state: QueueItemState.importPending,
  needsAttention: true,
  attention: QueueAttention.importPending,
  progress: 1,
  sizeBytes: 920507089,
  sizeLeftBytes: 0,
  torrent: buildTorrent(
    hash: sonarrHash,
    name: '[SubsPlease] Tensei Shitara Slime Datta Ken S4 (01-24) (1080p) [Batch]',
    category: 'tv-sonarr',
    state: TorrentState.queued,
    stateRaw: 'queuedUP',
  ),
  arr: [buildArrEntry(admin: admin)],
);

QueueItem buildDownloadingItem() => QueueItem(
  key: 'b' * 40,
  title: 'Dune: Part Two',
  subtitle: 'Radarr',
  state: QueueItemState.downloading,
  progress: 0.42,
  sizeBytes: 61820790488,
  sizeLeftBytes: 35000000000,
  etaSeconds: 2470,
  dlBps: 4800000,
  torrent: buildTorrent(
    hash: 'b' * 40,
    name: 'Dune.Part.Two.2024.2160p.WEB-DL',
    state: TorrentState.downloading,
    stateRaw: 'downloading',
    direction: TorrentDirection.download,
    progress: 0.42,
  ),
);

QueueResponse buildQueue({List<QueueItem>? items, int seeding = 4, SectionStatus radarr = const SectionStatus.ok()}) =>
    QueueResponse(
      items: items ?? [buildAttentionItem(), buildDownloadingItem()],
      summary: QueueSummary(downloading: 1, seeding: seeding, attention: 1, dlBps: 4800000, upBps: 906283),
      sonarr: const SectionStatus.ok(),
      radarr: radarr,
      qbittorrent: const SectionStatus.ok(),
    );

TransferState buildTransfer({bool alt = true}) => TransferState(
  dlBps: 4800000,
  upBps: 906283,
  dlLimitBps: alt ? 10240000 : 0,
  upLimitBps: alt ? 10240000 : 0,
  altSpeedEnabled: alt,
  limits: const TransferLimits(dlBps: 0, upBps: 0, altDlBps: 10240000, altUpBps: 10240000),
  schedule: const TransferSchedule(enabled: true, from: '08:00', to: '17:00', days: TransferScheduleDays.everyDay),
  connectionStatus: TransferConnectionStatus.connected,
  dhtNodes: 352,
  freeSpaceBytes: 4048915001344,
  sessionPaused: false,
  globalRatio: 0.92,
  allTimeDownloadedBytes: 8030115406493,
  allTimeUploadedBytes: 7409988593182,
  sessionDownloadedBytes: 0,
  sessionUploadedBytes: 1469956128,
  updatedAt: testNow,
);

VpnStatus buildVpn({VpnConnectionState status = VpnConnectionState.connected, int? port = 36681}) => VpnStatus(
  status: status,
  publicIp: status == VpnConnectionState.down ? null : '203.0.113.10',
  country: status == VpnConnectionState.down ? null : 'France',
  city: 'Marseille',
  forwardedPort: port,
  listenPort: 36681,
  portInSync: port == 36681,
  qbitConnection: 'connected',
  gluetunHealth: VpnGluetunHealth.healthy,
  checkedAt: testNow,
);

TorrentList buildTorrentList({List<TorrentSummary>? items}) => TorrentList(
  items:
      items ??
      [
        buildTorrent(),
        buildTorrent(
          hash: sonarrHash,
          name: '[ToonsHub] The Apothecary Diaries S03E06 1080p',
          category: 'tv-sonarr',
          tags: const ['Keep'],
          state: TorrentState.queued,
          stateRaw: 'queuedUP',
          upBps: 0,
        ),
      ],
  transfer: buildTransfer(),
  categories: const ['books', 'radarr', 'tv-sonarr'],
  tags: const ['Keep', 'Obsolete'],
);

const categoryList = CategoryList(
  categories: [
    TorrentCategory(name: 'books', readOnly: true),
    TorrentCategory(name: 'lidarr', readOnly: true),
    TorrentCategory(name: 'manual'),
    TorrentCategory(name: 'radarr', readOnly: true),
    TorrentCategory(name: 'tv-sonarr', readOnly: true),
  ],
  tags: ['Keep', 'Obsolete'],
);

ManualImportCandidates buildCandidates() => const ManualImportCandidates(
  service: ArrService.sonarr,
  queueId: 123456,
  downloadId: '0985D9EFDF7508DB837E629AE8F40EE8B56F4D71',
  title: '[SubsPlease] Tensei Shitara Slime Datta Ken S4 (01-24) (1080p) [Batch]',
  items: [
    ManualImportFile(
      fileId: 'mi_1',
      relativePath: '[SubsPlease] Tensei Shitara Slime Datta Ken - 73 (1080p).mkv',
      sizeBytes: 1461367836,
      quality: QualityInfo(name: 'WEBDL-1080p', resolution: 1080),
      languages: ['Japanese'],
      releaseGroup: 'SubsPlease',
      seriesId: 54,
      seasonNumber: 4,
      episodes: [ManualImportFileEpisode(id: 5580, label: 'S04E01 (073)', title: 'Episode 1')],
      importable: true,
    ),
    ManualImportFile(
      fileId: 'mi_2',
      relativePath: 'NCOP.mkv',
      sizeBytes: 104857600,
      quality: QualityInfo(name: 'WEBDL-1080p'),
      seriesId: 54,
      rejections: [
        ManualImportFileRejection(
          reason: 'Unable to determine if file is a sample',
          type: ManualImportFileRejectionType.permanent,
        ),
      ],
    ),
  ],
);

TorrentDetail buildDetail({TorrentSummary? summary, List<QueueArrEntry> arr = const []}) => TorrentDetail(
  summary: summary ?? buildTorrent(),
  savePath: '/data/downloads/torrents',
  pieceSizeBytes: 2097152,
  piecesHave: 439,
  piecesTotal: 439,
  timeActiveSeconds: 15145,
  seedingTimeSeconds: 14973,
  wastedBytes: 0,
  avgDlBps: 9119879,
  avgUpBps: 412370,
  connections: 40,
  seedsTotal: 315,
  peersTotal: 118,
  isPrivate: false,
  shareLimits: const ShareLimits(
    mode: ShareLimitsMode.global,
    action: ShareLimitsAction.byDefault,
    effectiveRatio: 1,
    effectiveSeedingMinutes: -1,
  ),
  files: const [
    TorrentFile(
      index: 0,
      name: 'Show/E01.mkv',
      sizeBytes: 920507089,
      progress: 1,
      priority: TorrentFilePriority.normal,
    ),
  ],
  trackers: const [
    TrackerInfo(url: 'http://nyaa.tracker.wf:7777', tier: 0, status: TrackerInfoStatus.working, seeds: 305, peers: 100),
  ],
  arr: arr,
);

/// The default activity endpoints on top of the core fakes.
FakeApi activityFakeApi({Role role = Role.admin, QueueResponse? queue}) {
  final api = buildCoreFakeApi(role: role);
  final q =
      queue ??
      buildQueue(
        items: [
          buildAttentionItem(admin: role == Role.admin),
          buildDownloadingItem(),
        ],
      );
  api
    ..getJson('/transfer', buildTransfer().toJson())
    ..getJson('/vpn', buildVpn().toJson())
    ..getJson('/activity/queue', q.toJson())
    ..getJson('/torrents', buildTorrentList().toJson())
    ..getJson('/transfer/categories', categoryList.toJson());
  return api;
}
