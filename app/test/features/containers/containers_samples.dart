/// Gateway-shaped samples for the containers feature tests (API.md §11).
library;

import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import '../../support/fake_api.dart';

ContainerSummary summary(
  String name, {
  String group = 'automation',
  ContainerState state = ContainerState.running,
  ContainerHealth health = ContainerHealth.none,
  ContainerProtection protection = ContainerProtection.none,
  bool update = false,
  double? cpu = 3.04,
  int? mem = 231051264,
  String? sharesNetworkWith,
  String? version = '4.0.20.3014-ls2',
  List<ExternalLink> links = const [],
}) => ContainerSummary(
  name: name,
  service: name,
  group: group,
  image: 'lscr.io/linuxserver/$name:latest',
  imageVersion: version,
  state: state,
  statusText: state == ContainerState.running ? 'Up 2 hours' : 'Exited (137) 3 hours ago',
  health: health,
  startedAt: state == ContainerState.running ? testNow.subtract(const Duration(hours: 2)) : null,
  uptimeSeconds: state == ContainerState.running ? 7200 : null,
  cpuPercent: state == ContainerState.running ? cpu : null,
  memBytes: state == ContainerState.running ? mem : null,
  memPercent: state == ContainerState.running && mem != null ? 2.87 : null,
  sharesNetworkWith: sharesNetworkWith,
  protection: protection,
  update: update ? ContainerUpdateFlag(available: true, checkedAt: testNow) : null,
  links: links,
);

ContainerList containerList() => ContainerList(
  items: [
    summary(
      'jellyfin',
      group: 'media',
      protection: ContainerProtection.confirm,
      links: const [ExternalLink(ExternalApp.jellyfin, '/')],
    ),
    summary('jellystat', group: 'media', health: ContainerHealth.unhealthy),
    summary('sonarr', update: true, links: const [ExternalLink(ExternalApp.sonarr, '/')]),
    summary('gluetun', group: 'downloads', health: ContainerHealth.healthy, protection: ContainerProtection.confirm),
    summary('qbittorrent', group: 'downloads', sharesNetworkWith: 'gluetun', protection: ContainerProtection.confirm),
    summary('portainer', group: 'system', state: ContainerState.exited),
    summary('yams-hub', group: 'system', protection: ContainerProtection.locked),
  ],
  engine: const ContainerEngineInfo(version: '29.4.3', running: 6, stopped: 1, total: 7, images: 114),
  statsAt: testNow,
);

ContainerDetail detail(String name, {ContainerSummary? s}) => ContainerDetail(
  summary: s ?? summary(name),
  restartCount: 2,
  restartPolicy: 'unless-stopped',
  imageId: 'sha256:ae55f56fa15cd639e4114104ddd7d292660ec259eab68d2d07d663b13a5066b5',
  createdAt: testNow.subtract(const Duration(days: 8)),
  networkMode: 'yams_network',
  finishedAt: testNow.subtract(const Duration(hours: 3)),
  exitCode: 0,
  healthLog: [
    ContainerHealthLogEntry(
      start: testNow.subtract(const Duration(seconds: 30)),
      end: testNow.subtract(const Duration(seconds: 29)),
      exitCode: 0,
      output: 'checked http://sonarr:8989/api?apikey=*** ok',
    ),
    ContainerHealthLogEntry(start: testNow, end: testNow.add(const Duration(milliseconds: 120)), exitCode: 1),
  ],
  events: [
    ContainerEvent(at: testNow.subtract(const Duration(hours: 2)), name: name, action: ContainerEventAction.start),
    ContainerEvent(
      at: testNow.subtract(const Duration(hours: 2, minutes: 1)),
      name: name,
      action: ContainerEventAction.die,
      exitCode: 137,
    ),
  ],
  dependents: name == 'gluetun' ? const ['qbittorrent'] : const [],
  mounts: const [
    ContainerMount(destination: '/config', readOnly: false),
    ContainerMount(destination: '/etc/localtime', readOnly: true),
  ],
  pids: 29,
);

UpdatesResponse updatesResponse({bool available = true, bool updater = true, DateTime? scanAt}) => UpdatesResponse(
  checkedAt: available ? testNow.subtract(const Duration(hours: 2)) : null,
  available: available,
  updaterAvailable: updater,
  lastScan: WatchtowerScan(scanned: 21, updated: 1, failed: 0, skipped: 2, restarted: 0, scansTotal: 3, at: scanAt),
  items: [
    const UpdateInfo(
      name: 'sonarr',
      image: 'lscr.io/linuxserver/sonarr:latest',
      updateAvailable: true,
      currentVersion: '4.0.20.3014-ls2',
      canUpdate: true,
    ),
    const UpdateInfo(
      name: 'homepage',
      image: 'ghcr.io/gethomepage/homepage:latest',
      updateAvailable: false,
      autoUpdate: true,
    ),
    const UpdateInfo(
      name: 'qbittorrent',
      image: 'lscr.io/linuxserver/qbittorrent:5.3.0',
      pinned: true,
      updateAvailable: false,
    ),
    const UpdateInfo(name: 'radarr', image: 'lscr.io/linuxserver/radarr:latest', error: 'registry timeout'),
  ],
);

DecluttarrStatus decluttarrStatus({bool clean = true}) => DecluttarrStatus(
  container: const MaintenanceContainerState(state: ContainerState.running, health: ContainerHealth.healthy),
  lastRunAt: testNow.subtract(const Duration(minutes: 3)),
  nextRunAt: testNow.add(const Duration(minutes: 7)),
  last24h: DecluttarrLast24h(
    runs: 144,
    removed: clean
        ? const []
        : [
            DecluttarrRemoval(
              at: testNow,
              job: 'remove_stalled',
              title: 'Some.Show.S01E01',
              kind: DecluttarrRemovalKind.queueRemoval,
            ),
          ],
    strikes: clean
        ? const []
        : [DecluttarrStrike(at: testNow, job: 'remove_stalled', title: 'Other.Show.S02E02', count: 2, max: 3)],
  ),
);

RecyclarrStatus recyclarrStatus({bool canSync = true}) => RecyclarrStatus(
  container: const MaintenanceContainerState(state: ContainerState.running, health: ContainerHealth.none),
  schedule: '0 4 * * 0',
  nextRunAt: testNow.add(const Duration(days: 7)),
  canSyncNow: canSync,
  lastRun: RecyclarrRun(
    startedAt: testNow.subtract(const Duration(hours: 1)),
    ok: true,
    instances: [
      RecyclarrInstance(
        name: 'hd-bluray-web',
        type: RecyclarrInstanceType.radarr,
        customFormatsCreated: 41,
        profilesSynced: 1,
        qualitySizesSynced: true,
        completedAt: testNow,
      ),
      RecyclarrInstance(
        name: 'web-1080p',
        type: RecyclarrInstanceType.sonarr,
        customFormatsCreated: 30,
        customFormatsUpdated: 2,
        customFormatsSkipped: 5,
        completedAt: testNow,
      ),
    ],
    warnings: const ['7 custom format(s) already existed'],
  ),
);

Job job(
  String id, {
  JobStatus status = JobStatus.succeeded,
  String kind = 'containers.restart',
  String target = 'sonarr',
  String label = 'Restart sonarr',
}) => Job(
  id: id,
  kind: kind,
  target: target,
  status: status,
  steps: [JobStep(label: label, status: status)],
  log: const ['line one', 'line two'],
  createdAt: testNow,
);

/// Serves [j] for `GET /jobs/{id}`.
void serveJob(FakeApi api, Job j) => api.getJson('/jobs/${j.id}', {'job': j.toJson()});
