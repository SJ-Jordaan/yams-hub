/// Request routes: create, list, counts, detail, manage, options
/// (API.md §6.4, §6.5).
library;

import 'package:shelf/shelf.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'requests_service.dart';
import 'seerr_client.dart';
import 'seerr_mapper.dart';

/// `filter` values of `GET /requests` (API.md §6.5).
const requestFilters = [
  'all',
  'pending',
  'approved',
  'processing',
  'available',
  'failed',
  'declined',
  'completed',
];

/// Seerr has no `declined` filter: the gateway reads this many requests and
/// pages them itself (integrations/seerr.md §1.9: take=500 is fine).
const _declinedTake = 500;

final class RequestHandlers {
  RequestHandlers(this.svc);

  final RequestsService svc;

  SeerrClient get _seerr => svc.seerr;

  // -------------------------------------------------------------------------
  // Create
  // -------------------------------------------------------------------------

  /// `POST /requests`.
  Future<Response> create(ApiRequest req) async {
    final body = await req.jsonBody();
    final type = SeerrMapper.mediaType(body['mediaType']);
    if (type == MediaType.unknown) {
      throw ApiException.invalidField('mediaType', 'Must be movie or tv.');
    }
    final tmdbId = readInt(body['tmdbId']);
    if (tmdbId == null || tmdbId < 1) {
      throw ApiException.invalidField('tmdbId', 'Must be a TMDB id.');
    }
    final Object? seasons = type == MediaType.tv ? _seasons(body) : null;
    final advanced = _advanced(body, req);
    final actor = await svc.actor(req);
    actor.requireLinked();

    final upstreamBody = <String, Object?>{
      'mediaType': type.name,
      'mediaId': tmdbId,
      'seasons': ?seasons,
      ...?advanced?.toJson(),
    };
    final SeerrReply reply;
    try {
      reply = await _seerr.send(
        'POST',
        '/api/v1/request',
        body: upstreamBody,
        asUser: actor.asUser,
        timeout: seerrCreateTimeout,
        resourceNotFound: false,
        onError: _createError,
      );
    } on ApiException catch (e) {
      if (e.code == ApiErrorCode.quotaExceeded) {
        throw await _withQuota(e, actor);
      }
      rethrow;
    } finally {
      // Any attempt may have used (or freed) quota.
      if (actor.seerrUserId case final id?) {
        ctx.seerrIdentity.invalidateQuota(id);
      }
    }
    svc
      ..invalidateRequests()
      ..invalidateTitle(type, tmdbId);
    if (reply.status == 202) {
      return ApiResponse.json(
        const CreateRequestResult(
          outcome: CreateRequestOutcome.nothingToRequest,
        ).toJson(),
      );
    }
    final summary = await svc.summary(reply.map, actor);
    return ApiResponse.json(
      CreateRequestResult(
        outcome: summary.status == RequestStatus.approved
            ? CreateRequestOutcome.autoApproved
            : CreateRequestOutcome.created,
        request: summary,
      ).toJson(),
      status: 201,
    );
  }

  FeatureContext get ctx => svc.ctx;

  /// `seasons`: an int array or `"all"` (tv only, required).
  static Object _seasons(JsonMap body) {
    final s = body['seasons'];
    if (s == 'all') return 'all';
    if (s is List && s.isNotEmpty) {
      final list = <int>[];
      for (final v in s) {
        final n = readInt(v);
        if (n == null || n < 0) {
          throw ApiException.invalidField(
            'seasons',
            'Season numbers must be whole numbers ≥ 0.',
          );
        }
        if (!list.contains(n)) list.add(n);
      }
      return list..sort();
    }
    throw ApiException.invalidField(
      'seasons',
      'Pick at least one season (or "all").',
    );
  }

  /// `advanced` is admin only; omitted fields keep Seerr's defaults.
  static CreateRequestAdvanced? _advanced(JsonMap body, ApiRequest req) {
    final raw = body['advanced'];
    if (raw == null) return null;
    final m = readMap(raw);
    if (m == null) {
      throw ApiException.invalidField('advanced', 'Must be an object.');
    }
    for (final key in const ['serverId', 'profileId']) {
      final v = m[key];
      if (v != null && (readInt(v) == null || readInt(v)! < 0)) {
        throw ApiException.invalidField(
          'advanced.$key',
          'Must be a whole number ≥ 0.',
        );
      }
    }
    final folder = m['rootFolder'];
    if (folder != null &&
        (folder is! String || !folder.startsWith('/') || folder.length > 500)) {
      throw ApiException.invalidField(
        'advanced.rootFolder',
        'Must be an absolute path.',
      );
    }
    final a = CreateRequestAdvanced.fromJson(m);
    if (a.isEmpty) return null;
    if (!req.isAdmin) {
      throw ApiException.forbidden('Only admins can choose advanced options.');
    }
    return a;
  }

  static ApiException? _createError(SeerrError e) {
    if (e.keyRejected) return null;
    final msg = e.message ?? '';
    if (e.status == 409) {
      return ApiException(
        409,
        ApiErrorCode.alreadyRequested,
        e.message ?? 'This title has already been requested.',
        service: ServiceId.seerr,
      );
    }
    if (e.status == 403) {
      final lower = msg.toLowerCase();
      if (lower.contains('quota')) {
        return ApiException(
          403,
          ApiErrorCode.quotaExceeded,
          e.message ?? 'Request quota exceeded.',
          service: ServiceId.seerr,
        );
      }
      if (lower.contains('blocklist')) {
        return ApiException(
          403,
          ApiErrorCode.blocklisted,
          e.message ?? 'This title is blocklisted.',
          service: ServiceId.seerr,
        );
      }
    }
    return null;
  }

  /// Adds `details.quota` (a fresh read) to a `quota_exceeded` error.
  Future<ApiException> _withQuota(ApiException e, SeerrActor actor) async {
    final id = actor.seerrUserId;
    if (id == null) return e;
    try {
      ctx.seerrIdentity.invalidateQuota(id);
      final quota = requestsQuota(await ctx.seerrIdentity.quota(id));
      return ApiException(
        e.status,
        e.code,
        e.message,
        service: e.service,
        details: {'quota': quota.toJson()},
      );
    } on Object catch (err) {
      ctx.log.fine('Seerr quota unavailable: $err');
      return e;
    }
  }

  // -------------------------------------------------------------------------
  // List, counts, detail
  // -------------------------------------------------------------------------

  /// `GET /requests` (cache 15 s).
  Future<Response> list(ApiRequest req) async {
    final filter = req.queryChoice(
      'filter',
      requestFilters,
      defaultValue: 'all',
    );
    final mediaType = req.queryChoice('mediaType', const [
      'all',
      'movie',
      'tv',
    ], defaultValue: 'all');
    final sort = req.queryChoice('sort', const [
      'added',
      'modified',
    ], defaultValue: 'added');
    final order = req.queryChoice('order', const [
      'desc',
      'asc',
    ], defaultValue: 'desc');
    final page = req.queryInt('page', defaultValue: 1, min: 1);
    final pageSize = req.queryInt(
      'pageSize',
      defaultValue: 25,
      min: 1,
      max: 50,
    );
    final mineParam = req.queryBool('mine');
    final actor = await svc.actor(req);
    final mine = !actor.isAdmin || mineParam;
    if (mine) actor.requireLinked();
    final requestedBy = mine ? actor.seerrUserId : null;

    final List<JsonMap> raw;
    final int total;
    if (filter == 'declined') {
      final all = await svc.declined.value(
        '${actor.asUser ?? 'admin'}|$sort|$order|$mediaType|${requestedBy ?? ''}',
        () async {
          final p = await _seerr.getMap(
            '/api/v1/request',
            query: seerrQuery({
              'take': _declinedTake,
              'skip': 0,
              'filter': 'all',
              'sort': sort,
              'sortDirection': order,
              'mediaType': mediaType,
              'requestedBy': requestedBy,
            }),
            asUser: actor.asUser,
            resourceNotFound: false,
          );
          return [
            for (final r in readList(p['results'], (m) => m))
              if (readInt(r['status']) == 3) r,
          ];
        },
      );
      total = all.length;
      raw = all.skip((page - 1) * pageSize).take(pageSize).toList();
    } else {
      final p = await svc.requestPage(
        seerrQuery({
          'take': pageSize,
          'skip': (page - 1) * pageSize,
          'filter': filter,
          'sort': sort,
          'sortDirection': order,
          'mediaType': mediaType,
          'requestedBy': requestedBy,
        }),
        asUser: actor.asUser,
      );
      raw = p.results;
      total = p.total;
    }
    final items = await svc.summaries(raw, actor);
    return ApiResponse.json(
      PagedList.of(
        items: items,
        page: page,
        pageSize: pageSize,
        total: total,
      ).toJson((r) => r.toJson()),
    );
  }

  /// `GET /requests/counts` (cache 15 s).
  Future<Response> counts(ApiRequest req) async {
    if (!_seerr.configured) {
      throw ApiException.serviceNotConfigured(ServiceId.seerr);
    }
    return ApiResponse.json((await svc.requestCounts()).toJson());
  }

  /// `GET /requests/{id}` as the caller (Seerr's 404/403 pass through).
  Future<Response> detail(ApiRequest req) async {
    final id = req.pathInt('id');
    final actor = await svc.actor(req);
    actor.requireLinked();
    final raw = await _seerr.getMap(
      '/api/v1/request/$id',
      asUser: actor.asUser,
    );
    return ApiResponse.json((await svc.summary(raw, actor)).toJson());
  }

  // -------------------------------------------------------------------------
  // Manage
  // -------------------------------------------------------------------------

  static ApiException? _stateError(SeerrError e) => e.status == 409
      ? ApiException(
          409,
          ApiErrorCode.invalidState,
          e.message ?? 'The request is not in a state that allows this.',
          service: ServiceId.seerr,
        )
      : null;

  /// `POST /requests/{id}/approve|decline|retry` (admin, as Seerr admin).
  Future<Response> transition(ApiRequest req, String verb) async {
    final id = req.pathInt('id');
    final actor = await svc.actor(req);
    final reply = await _seerr.send(
      'POST',
      '/api/v1/request/$id/$verb',
      timeout: seerrCreateTimeout,
      onError: _stateError,
    );
    svc.invalidateRequests();
    final raw = reply.map;
    final media = readMap(raw['media']);
    final tmdbId = readInt(media?['tmdbId']);
    if (tmdbId != null) {
      svc.invalidateTitle(
        SeerrMapper.mediaType(raw['type'] ?? media?['mediaType']),
        tmdbId,
      );
    }
    if (raw['requestedBy'] == null) {
      // Older Seerr versions answer retry without the request.
      final fresh = await _seerr.getMap('/api/v1/request/$id');
      return ApiResponse.json((await svc.summary(fresh, actor)).toJson());
    }
    return ApiResponse.json((await svc.summary(raw, actor)).toJson());
  }

  /// `PUT /requests/{id}`: edit a pending request (owner or admin).
  Future<Response> update(ApiRequest req) async {
    final id = req.pathInt('id');
    final body = await req.jsonBody();
    final advanced = _advanced(body, req);
    final actor = await svc.actor(req);
    actor.requireLinked();
    final current = await _seerr.getMap(
      '/api/v1/request/$id',
      asUser: actor.asUser,
    );
    final type = SeerrMapper.mediaType(
      current['type'] ?? readMap(current['media'])?['mediaType'],
    );
    List<int>? seasons;
    if (type == MediaType.tv) {
      if (body['seasons'] != null) {
        final s = _seasons(body);
        if (s is! List<int>) {
          throw ApiException.invalidField(
            'seasons',
            'List the season numbers to keep.',
          );
        }
        seasons = s;
      } else {
        seasons = [
          for (final s in readList(current['seasons'], (m) => m))
            ?readInt(s['seasonNumber']),
        ];
      }
    }
    final reply = await _seerr.send(
      'PUT',
      '/api/v1/request/$id',
      body: {
        'mediaType': type.name,
        'seasons': ?seasons,
        ...?advanced?.toJson(),
      },
      asUser: actor.asUser,
      timeout: seerrCreateTimeout,
      onError: _stateError,
    );
    svc.invalidateRequests();
    final tmdbId = readInt(readMap(current['media'])?['tmdbId']);
    if (tmdbId != null) svc.invalidateTitle(type, tmdbId);
    if (reply.status == 202) {
      return ApiResponse.json(
        const CreateRequestResult(
          outcome: CreateRequestOutcome.nothingToRequest,
        ).toJson(),
      );
    }
    return ApiResponse.json((await svc.summary(reply.map, actor)).toJson());
  }

  /// `DELETE /requests/{id}` [confirm]: removes the Seerr request record
  /// only. Seerr's 401 for someone else's request is `403 forbidden`.
  Future<Response> delete(ApiRequest req) async {
    final id = req.pathInt('id');
    await req.requireConfirm(
      'Deletes request $id from Seerr. Nothing is removed from the library.',
    );
    final actor = await svc.actor(req);
    actor.requireLinked();
    await _seerr.send(
      'DELETE',
      '/api/v1/request/$id',
      asUser: actor.asUser,
      onError: (e) => e.status == 401 && !e.keyRejected
          ? ApiException(
              403,
              ApiErrorCode.forbidden,
              e.message ?? 'You do not have permission to delete this request.',
              service: ServiceId.seerr,
            )
          : null,
    );
    svc
      ..invalidateRequests()
      ..discover.clear()
      ..search.clear()
      ..details.clear();
    return ApiResponse.noContent();
  }

  // -------------------------------------------------------------------------
  // Options
  // -------------------------------------------------------------------------

  /// `GET /requests/options` [admin] (cache 10 min). 4K servers are left
  /// out (the hub never sends `is4k`).
  Future<Response> options(ApiRequest req) async {
    if (!_seerr.configured) {
      throw ApiException.serviceNotConfigured(ServiceId.seerr);
    }
    final result = await svc.options.value(0, () async {
      Future<List<ServiceOptions>> load(String type) async {
        final servers = readList(
          await _seerr.get('/api/v1/service/$type', resourceNotFound: false),
          (m) => m,
        ).where((s) => readBool(s['is4k']) != true).toList();
        return Future.wait([
          for (final s in servers)
            _seerr
                .getMap(
                  '/api/v1/service/$type/${readInt(s['id'])}',
                  resourceNotFound: false,
                )
                .then((d) => SeerrMapper.serviceOptions(s, d)),
        ]);
      }

      final both = await Future.wait([load('radarr'), load('sonarr')]);
      return RequestsOptions(radarr: both[0], sonarr: both[1]);
    });
    return ApiResponse.json(result.toJson());
  }
}

/// Seerr `GET /user/{id}/quota` → [SeerrQuota] (a missing or 0 `limit` is
/// unlimited).
SeerrQuota requestsQuota(JsonMap j) {
  QuotaInfo info(JsonMap? q) {
    final limit = readInt(q?['limit']);
    final unlimited = limit == null || limit == 0;
    return QuotaInfo(
      limit: unlimited ? null : limit,
      days: readInt(q?['days']),
      used: readInt(q?['used']) ?? 0,
      remaining: unlimited ? null : readInt(q?['remaining']),
      restricted: readBool(q?['restricted']) ?? false,
    );
  }

  return SeerrQuota(
    movie: info(readMap(j['movie'])),
    tv: info(readMap(j['tv'])),
  );
}
