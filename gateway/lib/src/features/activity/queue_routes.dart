/// `/activity/**`: the unified queue, *arr queue actions, manual import and
/// the merged history (API.md §8.2, §8.3, §8.7).
library;

import 'package:shelf/shelf.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'activity_body.dart';
import 'activity_history.dart';
import 'activity_services.dart';
import 'arr_mapping.dart';
import 'unified_queue.dart';

/// Handlers of the queue and history routes.
final class QueueRoutes {
  QueueRoutes(this._s);

  final ActivityServices _s;

  FeatureContext get _ctx => _s.ctx;

  void register(ApiRouter router) {
    const admin = Role.admin;
    router
      ..get('/activity/queue', queue)
      ..post(
        '/activity/queue/remove',
        remove,
        role: admin,
        audit: true,
        action: 'activity.queue.remove',
      )
      ..post(
        '/activity/queue/grab',
        grab,
        role: admin,
        audit: true,
        action: 'activity.queue.grab',
      )
      ..post(
        '/activity/queue/refresh',
        refresh,
        role: admin,
        audit: true,
        action: 'activity.queue.refresh',
      )
      ..post(
        '/activity/queue/import',
        import,
        role: admin,
        audit: true,
        action: 'activity.queue.import',
      )
      ..get(
        '/activity/queue/<service|sonarr|radarr>/<queueId|[0-9]+>/import',
        candidates,
        role: admin,
      )
      ..get('/activity/history', history);
  }

  /// `GET /activity/queue`.
  Future<Response> queue(ApiRequest req) async {
    final filter = req.queryChoice(
      'filter',
      queueFilters,
      defaultValue: 'active',
    );
    final sort = req.queryString('sort') == null
        ? null
        : req.queryChoice('sort', queueSorts);
    final category = req.queryString('category');
    final q = await _s.computeQueue(req);
    if (q.allFailed) throw apiExceptionFor(q.qbitError!);
    final rows =
        [
          for (final r in q.rows)
            if (queueRowMatches(filter, r) &&
                (category == null || r.item.torrent?.category == category))
              r,
        ]..sort(
          (a, b) => sort == null
              ? compareQueueRowsDefault(a, b)
              : compareQueueRows(sort, a, b),
        );
    return ApiResponse.json(
      QueueResponse(
        items: [for (final r in rows) r.item],
        summary: queueSummaryOf(q.rows, q.qbit?.serverState),
        sonarr: q.arr[ArrService.sonarr]!,
        radarr: q.arr[ArrService.radarr]!,
        qbittorrent: q.qbitStatus,
        stale: q.stale,
      ).toJson(),
    );
  }

  /// `POST /activity/queue/remove` [confirm].
  Future<Response> remove(ApiRequest req) async {
    final b = ActivityBody(await req.jsonBody());
    final rawItems = b.optObjects('items') ?? const [];
    if (rawItems.isEmpty) {
      throw ApiException.invalidField('items', 'Select at least one item.');
    }
    final targets = <ArrService, Set<int>>{};
    for (final raw in rawItems) {
      final i = ActivityBody(raw);
      final service = i.reqArrService('service');
      final ids = i.optIntList('queueIds') ?? const [];
      if (ids.isEmpty || ids.any((id) => id < 1)) {
        throw ApiException.invalidField('items', 'Each item needs queue ids.');
      }
      (targets[service] ??= {}).addAll(ids);
    }
    final removeFromClient = b.optBool('removeFromClient') ?? true;
    final blocklist = b.optBool('blocklist') ?? false;
    final searchAgain = b.optBool('searchAgain') ?? false;
    if (searchAgain && !blocklist) {
      throw ApiException.invalidField(
        'searchAgain',
        'Searching again needs the release to be blocklisted.',
      );
    }
    final total = targets.values.fold<int>(0, (n, s) => n + s.length);
    final names = targets.keys.map(_label).join(' and ');
    await req.requireConfirm(
      [
        'Removes $total queue item${total == 1 ? '' : 's'}',
        if (removeFromClient) ' and deletes the torrent',
        if (blocklist) '; the release is blocklisted',
        if (searchAgain) ' and $names searches again',
      ].join(),
    );

    var removed = 0;
    var gone = 0;
    for (final e in targets.entries) {
      final service = e.key;
      // Ids no longer in the queue are already gone (decluttarr may have
      // removed them); the bulk call ignores them anyway.
      Set<int>? present;
      try {
        _s.queues.invalidate(service);
        final records = await _s.queues.records(service);
        // A full first page may not hold every record: an id missing from
        // it is not known to be gone, so send every id.
        present = records.length >= queuePageSize
            ? null
            : {for (final r in records) ?readInt(r['id'])};
      } on UpstreamNotConfigured {
        rethrow;
      } catch (_) {
        present = null;
      }
      final ids = [
        for (final id in e.value)
          if (present == null || present.contains(id)) id,
      ];
      gone += e.value.length - ids.length;
      if (ids.isEmpty) continue;
      final r = await _ctx.upstreams
          .arr(service)
          .send(
            'DELETE',
            '/api/v3/queue/bulk',
            jsonBody: {'ids': ids},
            query: {
              'removeFromClient': removeFromClient,
              'blocklist': blocklist,
              'skipRedownload': !searchAgain,
            },
          );
      if (r.status == 404) {
        gone += ids.length;
        continue;
      }
      try {
        r.ensureOk();
      } on UpstreamException catch (e) {
        throw e.toApiException(resourceNotFound: false);
      }
      removed += ids.length;
    }
    _s.queues.invalidate();
    if (removeFromClient) await _s.maindata.refresh();
    return ApiResponse.json(
      QueueRemoveResult(removed: removed, alreadyGone: gone).toJson(),
    );
  }

  /// `POST /activity/queue/grab`.
  Future<Response> grab(ApiRequest req) async {
    final b = ActivityBody(await req.jsonBody());
    final service = b.reqArrService('service');
    final ids = b.optIntList('queueIds') ?? const [];
    if (ids.isEmpty || ids.any((id) => id < 1)) {
      throw ApiException.invalidField('queueIds', 'Select at least one item.');
    }
    try {
      await _ctx.upstreams
          .arr(service)
          .sendJson(
            'POST',
            '/api/v3/queue/grab/bulk',
            body: {'ids': ids.toSet().toList()},
          );
    } on UpstreamException catch (e) {
      throw e.toApiException(resourceNotFound: false);
    }
    _s.queues.invalidate(service);
    return ApiResponse.json({'ok': true});
  }

  /// `POST /activity/queue/refresh` → `RefreshMonitoredDownloads`.
  Future<Response> refresh(ApiRequest req) async {
    final b = ActivityBody(await req.jsonBody());
    final one = b.has('service') ? b.reqArrService('service') : null;
    final services = one == null
        ? [
            for (final s in queueServices)
              if (_ctx.upstreams.arr(s).configured) s,
          ]
        : [one];
    if (services.isEmpty) {
      throw ApiException.serviceNotConfigured(ServiceId.sonarr);
    }
    final commands = await Future.wait([
      for (final s in services)
        () async {
          try {
            final c = readMap(
              await _ctx.upstreams
                  .arr(s)
                  .sendJson(
                    'POST',
                    '/api/v3/command',
                    body: {'name': 'RefreshMonitoredDownloads'},
                  ),
            );
            return commandRefOf(s, c ?? const {});
          } on UpstreamException catch (e) {
            throw e.toApiException(resourceNotFound: false);
          }
        }(),
    ]);
    _s.queues.invalidate();
    return ApiResponse.json({
      'commands': [for (final c in commands) c.toJson()],
    }, status: 202);
  }

  /// `GET /activity/queue/{service}/{queueId}/import`.
  Future<Response> candidates(ApiRequest req) async {
    final service = ArrService.fromJson(req.pathParam('service'));
    final queueId = req.pathInt('queueId');
    final c = await _s.imports.candidates(req, service, queueId);
    return ApiResponse.json(c.toJson());
  }

  /// `POST /activity/queue/import`.
  Future<Response> import(ApiRequest req) async {
    final command = await _s.imports.import(req);
    return ApiResponse.json({'command': command.toJson()}, status: 202);
  }

  /// `GET /activity/history`.
  Future<Response> history(ApiRequest req) async {
    final which = req.queryChoice('service', const [
      'all',
      'sonarr',
      'radarr',
    ], defaultValue: 'all');
    final types = <ArrHistoryType>[];
    for (final name in req.queryList('types')) {
      final t = ArrHistoryType.values
          .where((t) => t != ArrHistoryType.unknown && t.name == name)
          .firstOrNull;
      if (t == null) {
        throw ApiException.badRequest(
          'types must be a comma list of '
          '${ArrHistoryType.values.where((t) => t != ArrHistoryType.unknown).map((t) => t.name).join(', ')}.',
        );
      }
      types.add(t);
    }
    final limit = req.queryInt('limit', defaultValue: 25, min: 1, max: 100);
    final services = switch (which) {
      'sonarr' => [ArrService.sonarr],
      'radarr' => [ArrService.radarr],
      _ => [
        for (final s in queueServices)
          if (_ctx.upstreams.arr(s).configured) s,
      ],
    };
    if (services.isEmpty) {
      throw ApiException.serviceNotConfigured(ServiceId.sonarr);
    }
    for (final s in services) {
      if (!_ctx.upstreams.arr(s).configured) {
        throw ApiException.serviceNotConfigured(s.serviceId);
      }
    }
    final page = await _s.history.page(
      services: services,
      types: types,
      limit: limit,
      cursor: req.queryString('cursor'),
    );
    return ApiResponse.json(
      CursorPage(
        items: page.items.where(isHistoryRecord).toList(),
        nextCursor: page.nextCursor,
      ).toJson((i) => i.toJson()),
    );
  }

  static String _label(ArrService s) =>
      s == ArrService.sonarr ? 'Sonarr' : 'Radarr';
}
