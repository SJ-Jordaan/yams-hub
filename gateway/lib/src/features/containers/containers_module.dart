/// Containers feature: containers, updates and maintenance (API.md §11).
library;

import 'package:shelf/shelf.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'containers_service.dart';

export 'containers_service.dart' show ContainersService, ContainersTimings;

/// `{name}` of the container routes: `.` and `..` never match (→ JSON 404).
const _name = '<name|[a-zA-Z0-9][a-zA-Z0-9_.-]*>';

class ContainersModule extends FeatureModule {
  ContainersModule(
    this.ctx, {
    ContainersTimings timings = const ContainersTimings(),
  }) : service = ContainersService(ctx, timings: timings);

  final FeatureContext ctx;

  /// The feature's logic (exposed for tests).
  final ContainersService service;

  @override
  String get id => 'containers';

  @override
  void registerRoutes(ApiRouter router) {
    const admin = Role.admin;
    // Static segments (`events`) before `{name}`.
    router
      ..get('/containers', _list)
      ..get('/containers/events', _events)
      ..get('/containers/$_name', _detail)
      ..get('/containers/$_name/logs', _logs, role: admin)
      ..post('/containers/$_name/actions', _action, role: admin, audit: true)
      ..get('/updates', _updates)
      ..post('/updates/check', _check, role: admin, audit: true)
      ..post(
        '/updates/<service|[a-z0-9][a-z0-9_.-]*>',
        _update,
        role: admin,
        audit: true,
      )
      ..get('/maintenance/decluttarr', _decluttarr)
      ..get('/maintenance/recyclarr', _recyclarr)
      ..post(
        '/maintenance/recyclarr/sync',
        _recyclarrSync,
        role: admin,
        audit: true,
      );
  }

  @override
  Future<DashboardContribution?> dashboard(ApiRequest req) =>
      service.dashboard();

  @override
  Future<void> start() async => service.start();

  @override
  Future<void> stop() => service.stop();

  static Response _job(JobRecord job) =>
      ApiResponse.json({'job': job.toDto().toJson()}, status: 202);

  Future<Response> _list(ApiRequest req) async {
    final list = await service.list(
      group: req.queryString('group'),
      q: req.queryString('q'),
    );
    return ApiResponse.json(list.toJson());
  }

  Future<Response> _events(ApiRequest req) async {
    final limit = req.queryInt('limit', defaultValue: 50, min: 1, max: 200);
    final name = req.queryString('name');
    final items = service.events.latest(limit: limit, name: name);
    return ApiResponse.items(items, (e) => e.toJson());
  }

  Future<Response> _detail(ApiRequest req) async {
    final d = await service.detail(req.pathParam('name'), admin: req.isAdmin);
    return ApiResponse.json(d.toJson());
  }

  Future<Response> _logs(ApiRequest req) async {
    final tail = req.queryInt('tail', defaultValue: 200, min: 1, max: 2000);
    final sinceRaw = req.queryString('since');
    final since = sinceRaw == null ? null : readInstant(sinceRaw);
    if (sinceRaw != null && since == null) {
      throw ApiException.badRequest('since must be an ISO-8601 instant');
    }
    final stream = req.queryChoice('stream', const [
      'all',
      'stdout',
      'stderr',
    ], defaultValue: 'all');
    final r = await service.logs(
      req.pathParam('name'),
      tail: tail,
      since: since,
      stream: stream,
    );
    return ApiResponse.json(r.toJson());
  }

  Future<Response> _action(ApiRequest req) async =>
      _job(await service.startAction(req, req.pathParam('name')));

  Future<Response> _updates(ApiRequest req) async =>
      ApiResponse.json((await service.updatesOverview()).toJson());

  Future<Response> _check(ApiRequest req) async =>
      _job(await service.startCheck(req));

  Future<Response> _update(ApiRequest req) async =>
      _job(await service.startUpdate(req, req.pathParam('service')));

  Future<Response> _decluttarr(ApiRequest req) async =>
      ApiResponse.json((await service.decluttarr()).value.toJson());

  Future<Response> _recyclarr(ApiRequest req) async =>
      ApiResponse.json((await service.recyclarr()).value.toJson());

  Future<Response> _recyclarrSync(ApiRequest req) async =>
      _job(await service.startRecyclarrSync(req));
}
