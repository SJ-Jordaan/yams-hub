/// `/ping`, `/server`, `/health` and `/jobs/**` (API.md §2.1, §2.4–2.6).
library;

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:yams_models/yams_models.dart';

import '../config/config.dart';
import '../version.dart';
import 'auth/auth_service.dart';
import 'auth/server_proof.dart';
import 'clock.dart';
import 'health/health_service.dart';
import 'http/api_exception.dart';
import 'http/api_request.dart';
import 'http/api_response.dart';
import 'http/api_router.dart';
import 'ids.dart';
import 'jobs/job_registry.dart';
import 'services/jellyfin_info.dart';
import 'services/seerr_identity.dart';
import 'store/json_file_store.dart';

final _log = Logger('core.routes');

/// The random installation id stored in `$DATA/instance.json`.
Future<String> loadInstanceId(StoreFactory stores) async {
  final store = stores.open('instance.json');
  final doc = store.read();
  final existing = doc is Map ? doc['instanceId'] : null;
  if (existing is String && RegExp(r'^[0-9a-f]{16}$').hasMatch(existing)) {
    return existing;
  }
  final id = randomHex(16);
  await store.writeNow({'instanceId': id});
  return id;
}

/// Core routes other than auth, admin, images and the dashboard.
final class CoreRoutes {
  CoreRoutes({
    required this.config,
    required this.instanceId,
    required this.auth,
    required this.health,
    required this.jobs,
    required this.jellyfin,
    required this.seerrSettings,
    required this.clock,
  });

  final HubConfig config;
  final String instanceId;
  final AuthService auth;
  final HealthService health;
  final JobRegistry jobs;
  final JellyfinServerInfo jellyfin;
  final SeerrPublicSettings seerrSettings;
  final Clock clock;

  void register(ApiRouter r) {
    r
      ..public('GET', '/ping', _ping)
      ..get('/server', _server)
      ..get('/health', _health)
      ..get('/jobs', _jobs)
      ..get('/jobs/<id|j_[0-9a-f]{12}>', _job);
  }

  Future<Response> _ping(ApiRequest req) async {
    final nonce = req.query['nonce'];
    final sid = req.query['sid'];
    String? proof;
    if (nonce != null) {
      if (!noncePattern.hasMatch(nonce)) {
        throw ApiException.badRequest(
          'nonce must be 16..64 base64url characters',
        );
      }
      if (sid != null) proof = auth.serverProof(sid, nonce);
    }
    return ApiResponse.json(
      ServerPing(
        name: 'yams-hub',
        version: hubVersion,
        apiVersion: apiVersion,
        minAppVersion: minAppVersion,
        instanceId: instanceId,
        time: clock.now(),
        proof: proof,
      ),
    );
  }

  Future<Response> _server(ApiRequest req) async {
    final results = await Future.wait<Object?>([
      jellyfin.serverId(),
      seerrSettings.flags().then<Object?>(
        (f) => f,
        onError: (Object e) {
          _log.fine('Seerr public settings unavailable: $e');
          return const SeerrFlags();
        },
      ),
    ]);
    final policy = config.policy;
    final dto = ServerConfig(
      version: hubVersion,
      instanceId: instanceId,
      publicUrls: [for (final u in config.publicUrls) u.toString()],
      services: [
        for (final id in ServiceId.values)
          if (id != ServiceId.unknown)
            ServerServiceInfo(id: id, configured: config.isConfigured(id)),
      ],
      externalApps: config.externalApps,
      jellyfinServerId: results[0] as String?,
      policy: ServerPolicy(
        allowGlobalSearch: policy.allowGlobalSearch,
        allowArrDeleteFiles: policy.allowArrDeleteFiles,
        lockedContainers: policy.containers.locked,
        confirmContainers: policy.containers.confirm,
      ),
      features: health.features.toDto(health.dockerProxy),
      seerr: (results[1] as SeerrFlags).toDto(),
    );
    return ApiResponse.json(dto);
  }

  Future<Response> _health(ApiRequest req) async =>
      ApiResponse.json(await health.report());

  Future<Response> _jobs(ApiRequest req) async {
    final active = req.queryBool('active');
    final kind = req.queryString('kind');
    final list = jobs.list(
      activeOnly: active,
      kindPrefix: kind,
      userId: req.isAdmin ? null : req.user.id,
    );
    return ApiResponse.items(list.map((j) => j.toDto()), (j) => j.toJson());
  }

  Future<Response> _job(ApiRequest req) async {
    final job = jobs.get(req.pathParam('id'));
    if (job == null) throw ApiException.notFound('Job not found or expired.');
    if (!req.isAdmin && job.userId != req.user.id) {
      throw ApiException.forbidden();
    }
    return ApiResponse.json({'job': job.toDto().toJson()});
  }
}
