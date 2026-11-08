/// Issue routes (API.md §6.6). Writes run as the caller's Seerr user, so
/// Seerr's own "creator or MANAGE_ISSUES" rule applies.
library;

import 'package:shelf/shelf.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'requests_service.dart';
import 'seerr_client.dart';
import 'seerr_mapper.dart';

const _maxMessage = 2000;

final class IssueHandlers {
  IssueHandlers(this.svc);

  final RequestsService svc;

  SeerrClient get _seerr => svc.seerr;

  Future<Issue> _issue(JsonMap raw, {bool withComments = true}) async {
    final media = readMap(raw['media']);
    final type = SeerrMapper.mediaType(media?['mediaType']);
    final tmdbId = readInt(media?['tmdbId']) ?? 0;
    final info = await svc.titleInfo(type, tmdbId);
    return svc.mapper.issue(raw, info: info, withComments: withComments);
  }

  /// `GET /issues?filter=open|resolved|all&page&pageSize` as the caller.
  /// Members see what their Seerr user may see (their own issues without
  /// VIEW_ISSUES); unlinked members have no Seerr user, so their read-only
  /// list (APP.md §4.5) is empty rather than the admin's view of everyone's
  /// issues.
  Future<Response> list(ApiRequest req) async {
    final filter = req.queryChoice('filter', const [
      'open',
      'resolved',
      'all',
    ], defaultValue: 'open');
    final page = req.queryInt('page', defaultValue: 1, min: 1);
    final pageSize = req.queryInt(
      'pageSize',
      defaultValue: 25,
      min: 1,
      max: 50,
    );
    final actor = await svc.actor(req);
    if (!actor.isAdmin && !actor.linked) {
      return ApiResponse.json(
        PagedList<Issue>.of(
          items: const [],
          page: page,
          pageSize: pageSize,
          total: 0,
        ).toJson((i) => i.toJson()),
      );
    }
    final j = await _seerr.getMap(
      '/api/v1/issue',
      query: seerrQuery({
        'take': pageSize,
        'skip': (page - 1) * pageSize,
        'filter': filter,
        'sort': 'added',
      }),
      asUser: actor.asUser,
      resourceNotFound: false,
    );
    final rows = readList(j['results'], (m) => m);
    final infos = await svc.titleInfos([
      for (final r in rows)
        (
          SeerrMapper.mediaType(readMap(r['media'])?['mediaType']),
          readInt(readMap(r['media'])?['tmdbId']) ?? 0,
        ),
    ]);
    final items = [
      for (final r in rows)
        svc.mapper.issue(
          r,
          info:
              infos[RequestsService.titleKey(
                SeerrMapper.mediaType(readMap(r['media'])?['mediaType']),
                readInt(readMap(r['media'])?['tmdbId']) ?? 0,
              )] ??
              const TitleInfo(title: ''),
          withComments: false,
        ),
    ];
    final total = readInt(readMap(j['pageInfo'])?['results']) ?? items.length;
    return ApiResponse.json(
      PagedList.of(
        items: items,
        page: page,
        pageSize: pageSize,
        total: total,
      ).toJson((i) => i.toJson()),
    );
  }

  /// `GET /issues/counts`.
  Future<Response> counts(ApiRequest req) async {
    if (!_seerr.configured) {
      throw ApiException.serviceNotConfigured(ServiceId.seerr);
    }
    return ApiResponse.json((await svc.issueCountsValue()).toJson());
  }

  /// `GET /issues/{id}` with comments, as the caller.
  Future<Response> detail(ApiRequest req) async {
    final id = req.pathInt('id');
    final actor = await svc.actor(req);
    actor.requireLinked();
    final raw = await _seerr.getMap('/api/v1/issue/$id', asUser: actor.asUser);
    return ApiResponse.json((await _issue(raw)).toJson());
  }

  static String _message(JsonMap body) {
    final m = readString(body['message'])?.trim() ?? '';
    if (m.isEmpty) {
      throw ApiException.invalidField('message', 'Write a message.');
    }
    if (m.length > _maxMessage) {
      throw ApiException.invalidField(
        'message',
        'At most $_maxMessage characters.',
      );
    }
    return m;
  }

  /// `POST /issues`: resolves Seerr's media id from the title details.
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
    final issueType = SeerrMapper.issueTypeCode(
      IssueType.fromJson(body['type']),
    );
    if (issueType == null) {
      throw ApiException.invalidField(
        'type',
        'Must be video, audio, subtitles or other.',
      );
    }
    final message = _message(body);
    int season = 0;
    int episode = 0;
    if (type == MediaType.tv) {
      season = readInt(body['season']) ?? 0;
      episode = readInt(body['episode']) ?? 0;
      if (season < 0 || episode < 0) {
        throw ApiException.invalidField(
          season < 0 ? 'season' : 'episode',
          'Must be 0 or more.',
        );
      }
      if (season == 0) episode = 0;
    }
    final actor = await svc.actor(req);
    actor.requireLinked();
    final details = await svc.titleDetails(type, tmdbId);
    final mediaId = readInt(readMap(details['mediaInfo'])?['id']);
    if (mediaId == null) {
      throw ApiException.notFound('Seerr does not track this title yet.');
    }
    final reply = await _seerr.send(
      'POST',
      '/api/v1/issue',
      body: {
        'issueType': issueType,
        'message': message,
        'mediaId': mediaId,
        'problemSeason': season,
        'problemEpisode': episode,
      },
      asUser: actor.asUser,
      resourceNotFound: false,
    );
    svc
      ..invalidateIssues()
      ..details.invalidate(RequestsService.titleKey(type, tmdbId));
    return ApiResponse.json((await _issue(reply.map)).toJson(), status: 201);
  }

  /// `POST /issues/{id}/comments` as the caller.
  Future<Response> comment(ApiRequest req) async {
    final id = req.pathInt('id');
    final message = _message(await req.jsonBody());
    final actor = await svc.actor(req);
    actor.requireLinked();
    final reply = await _seerr.send(
      'POST',
      '/api/v1/issue/$id/comment',
      body: {'message': message},
      asUser: actor.asUser,
    );
    return _issueReply(reply, id, actor);
  }

  /// `POST /issues/{id}/resolve|reopen` as the caller; Seerr's refusal (not
  /// the creator, no MANAGE_ISSUES: a 403, or the handler's 401) is
  /// `403 forbidden`.
  Future<Response> setStatus(ApiRequest req, {required bool resolve}) async {
    final id = req.pathInt('id');
    final actor = await svc.actor(req);
    actor.requireLinked();
    final reply = await _seerr.send(
      'POST',
      '/api/v1/issue/$id/${resolve ? 'resolved' : 'open'}',
      asUser: actor.asUser,
      onError: (e) => (e.status == 403 || e.status == 401) && !e.keyRejected
          ? const ApiException(
              403,
              ApiErrorCode.forbidden,
              'Only the reporter or an admin can do that.',
              service: ServiceId.seerr,
            )
          : null,
    );
    svc.invalidateIssues();
    return _issueReply(reply, id, actor);
  }

  /// Seerr answers with the issue; re-read it when the body is not one.
  Future<Response> _issueReply(
    SeerrReply reply,
    int id,
    SeerrActor actor,
  ) async {
    var raw = reply.map;
    if (raw['id'] == null || raw['media'] == null) {
      raw = await _seerr.getMap('/api/v1/issue/$id', asUser: actor.asUser);
    }
    return ApiResponse.json((await _issue(raw)).toJson());
  }
}
