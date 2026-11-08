/// Model builders for tests: gateway-shaped samples with sensible defaults.
library;

import 'package:yams_hub/core/auth/token_store.dart';
import 'package:yams_hub/core/servers/server_profile.dart';
import 'package:yams_hub/core/servers/server_proof.dart';
import 'package:yams_models/yams_models.dart';

final testNow = DateTime.utc(2026, 11, 8, 9);

const testInstanceId = '3f9c2a71d0e84b5c';
const testSessionId = 's_0123456789ab';

/// 32 bytes, base64url (what the login response carries).
const testProofKey = 'q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA';

final testLanUrl = Uri.parse('http://192.168.10.183:8090');
final testTailscaleUrl = Uri.parse('http://zenith.example.ts.net:8090');

ServerProfile buildProfile({
  String id = 'p_test',
  String name = 'Zenith',
  List<Uri>? urls,
  Uri? lastGoodUrl,
  String? instanceId = testInstanceId,
}) => ServerProfile(
  id: id,
  name: name,
  urls: urls ?? [testLanUrl, testTailscaleUrl],
  lastGoodUrl: lastGoodUrl,
  instanceId: instanceId,
);

User buildUser({Role role = Role.admin, String id = 'u_1a2b3c4d5e6f', String displayName = 'Ada'}) => User(
  id: id,
  username: displayName.toLowerCase(),
  displayName: displayName,
  role: role,
  disabled: false,
  createdAt: testNow,
  updatedAt: testNow,
);

SessionInfo buildSession({String id = testSessionId, String userId = 'u_1a2b3c4d5e6f'}) => SessionInfo(
  id: id,
  userId: userId,
  deviceName: 'Pixel 8',
  platform: ClientPlatform.android,
  createdAt: testNow,
  lastSeenAt: testNow,
  expiresAt: testNow.add(const Duration(days: 30)),
  current: true,
);

TokenPair buildTokenPair({String access = 'yha_access1', String refresh = 'yhr_s_0123456789ab.r1'}) => TokenPair(
  accessToken: access,
  accessTokenExpiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  refreshToken: refresh,
  refreshTokenExpiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
);

StoredTokens buildStoredTokens({String access = 'yha_access1', String refresh = 'yhr_s_0123456789ab.r1'}) =>
    StoredTokens.fromPair(
      buildTokenPair(access: access, refresh: refresh),
      sessionId: testSessionId,
      serverProofKey: testProofKey,
    );

LoginResponse buildLoginResponse({Role role = Role.admin}) => LoginResponse(
  user: buildUser(role: role),
  session: buildSession(),
  tokens: buildTokenPair(),
  serverProofKey: testProofKey,
);

/// A `GET /ping` answer; with [nonce] (and [proofKey]) it carries the proof.
ServerPing buildPing({String instanceId = testInstanceId, String? nonce, String? proofKey = testProofKey, int apiVersion = 1}) =>
    ServerPing(
      name: 'yams-hub',
      version: '1.0.0',
      apiVersion: apiVersion,
      minAppVersion: '1.0.0',
      instanceId: instanceId,
      time: testNow,
      proof: nonce == null || proofKey == null ? null : computeServerProof(proofKey, nonce),
    );

ServerConfig buildServerConfig({Iterable<ExternalApp>? apps}) => ServerConfig(
  version: '1.0.0',
  instanceId: testInstanceId,
  publicUrls: [testLanUrl.toString(), testTailscaleUrl.toString()],
  externalApps: {
    for (final app in apps ?? ExternalApp.values.where((a) => a != ExternalApp.unknown))
      app: ExternalAppConfig(port: _ports[app] ?? 1000),
  },
  jellyfinServerId: '79315eab3c4c401f8391d5c26210b6d7',
);

const _ports = {
  ExternalApp.jellyfin: 8096,
  ExternalApp.audiobookshelf: 13378,
  ExternalApp.kavita: 5000,
  ExternalApp.seerr: 5055,
  ExternalApp.shelfmark: 8084,
  ExternalApp.sonarr: 8989,
  ExternalApp.radarr: 7878,
  ExternalApp.prowlarr: 9696,
  ExternalApp.bazarr: 6767,
  ExternalApp.qbittorrent: 8081,
  ExternalApp.uptimeKuma: 3001,
  ExternalApp.jellystat: 3002,
  ExternalApp.portainer: 9000,
};

ServiceHealth buildServiceHealth(ServiceId id, {ServiceHealthStatus status = ServiceHealthStatus.up, String? version}) =>
    ServiceHealth(
      id: id,
      name: id.displayName,
      status: status,
      checkedAt: testNow,
      latencyMs: 4,
      version: version ?? (status == ServiceHealthStatus.up ? '1.2.3' : null),
    );

/// Every service up, except the ones in [down].
HealthReport buildHealth({Set<ServiceId> down = const {}}) => HealthReport(
  overall: down.isEmpty ? ServiceHealthStatus.up : ServiceHealthStatus.degraded,
  checkedAt: testNow,
  services: [
    for (final id in ServiceId.values.where((s) => s != ServiceId.unknown && s != ServiceId.host))
      buildServiceHealth(id, status: down.contains(id) ? ServiceHealthStatus.down : ServiceHealthStatus.up),
  ],
);

Section buildSection(JsonMap data, {bool stale = false}) => Section.ok(data, fetchedAt: testNow, stale: stale);

Alert buildAlert({
  String id = 'vpn.down',
  AlertSeverity severity = AlertSeverity.error,
  String feature = 'activity',
  String title = 'VPN down',
  String? route = '/activity',
  bool dismissible = false,
}) => Alert(
  id: id,
  severity: severity,
  source: ServiceId.gluetun,
  feature: feature,
  title: title,
  route: route,
  since: testNow,
  dismissible: dismissible,
);

/// Card data carrying the raw keys of API.md §4.
JsonMap rawCards({
  int pending = 3,
  int attention = 2,
  int next7 = 6,
  int running = 21,
  int total = 23,
  int failing = 1,
  int missing = 111,
}) => {
  DashboardCardKeys.requests: buildSection({
    'counts': {'pending': pending, 'processing': 1, 'available': 9},
  }).toJson(),
  DashboardCardKeys.activity: buildSection({
    'counts': {'downloading': 2, 'seeding': 5, 'stalled': 0, 'attention': attention},
  }).toJson(),
  DashboardCardKeys.calendar: buildSection({'countNext7Days': next7}).toJson(),
  DashboardCardKeys.containers: buildSection({'running': running, 'total': total}).toJson(),
  DashboardCardKeys.indexers: buildSection({
    'enabled': 9,
    'total': 10,
    'failing': [for (var i = 0; i < failing; i++) {'id': i, 'name': 'Indexer $i'}],
  }).toJson(),
  DashboardCardKeys.subtitles: buildSection({'missingEpisodes': missing, 'missingMovies': 4}).toJson(),
};

/// A full `GET /dashboard` body: every card (system/media not implemented
/// yet) plus [alerts].
JsonMap buildDashboardJson({List<Alert> alerts = const [], JsonMap? cards}) => {
  'generatedAt': instantToJson(testNow),
  'alerts': [for (final a in alerts) a.toJson()],
  'cards': {
    DashboardCardKeys.system: buildSection({'cpuPercent': 12.5}).toJson(),
    DashboardCardKeys.media: Section.failure(
      const ApiError(code: ApiErrorCode.notImplemented, message: 'Not implemented', status: 501),
      fetchedAt: testNow,
    ).toJson(),
    DashboardCardKeys.library: Section.disabled(
      const ApiError(code: ApiErrorCode.serviceNotConfigured, message: 'Sonarr is not configured', status: 503),
    ).toJson(),
    ...(cards ?? rawCards()),
  },
};

Job buildJob({String id = 'j_7f3a9c21b0d4', JobStatus status = JobStatus.running, ApiError? error}) => Job(
  id: id,
  kind: 'containers.restart',
  target: 'sonarr',
  status: status,
  steps: [JobStep(label: 'Restart sonarr', status: status)],
  createdAt: testNow,
  error: error,
);
