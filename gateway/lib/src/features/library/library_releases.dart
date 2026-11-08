/// Interactive release search ("Choose release", API.md §7.8).
///
/// Searches run through Sonarr/Radarr (`GET /api/v3/release`) so a grab is
/// tracked and imported like any other download. Results carry gateway
/// tokens: GUIDs, download URLs, magnets and info hashes stay here.
library;

import 'package:shelf/shelf.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_hub_gateway/src/core/ids.dart';
import 'package:yams_models/yams_models.dart';

import 'library_data.dart';
import 'library_mappers.dart';
import 'library_support.dart';

/// What a release token stands for.
final class LibraryReleaseRef {
  LibraryReleaseRef({
    required this.userId,
    required this.service,
    required this.guid,
    required this.indexerId,
    required this.title,
    required this.expiresAt,
    this.seriesId,
    this.episodeIds = const [],
    this.movieId,
  });

  final String userId;
  final ArrService service;
  final String guid;
  final int indexerId;
  final String title;
  final DateTime expiresAt;
  final int? seriesId;
  final List<int> episodeIds;
  final int? movieId;
}

/// Release tokens (30 min, in memory, per user).
final class LibraryReleaseTokens {
  LibraryReleaseTokens(this._clock, {this.maxEntries = 5000});

  static const ttl = Duration(minutes: 30);

  final Clock _clock;
  final int maxEntries;
  final _refs = <String, LibraryReleaseRef>{};

  int get length => _refs.length;

  void _prune() {
    final now = _clock.now();
    _refs.removeWhere((_, r) => !r.expiresAt.isAfter(now));
    while (_refs.length > maxEntries) {
      _refs.remove(_refs.keys.first);
    }
  }

  /// Stores [ref] and returns its token.
  String put(LibraryReleaseRef ref) {
    _prune();
    final token = 'rl_${randomToken(18)}';
    _refs[token] = ref;
    return token;
  }

  /// The live ref of [token] for [userId] (tokens of other users are
  /// unknown).
  LibraryReleaseRef? find(String token, String userId) {
    _prune();
    final r = _refs[token];
    return r == null || r.userId != userId ? null : r;
  }

  void remove(String token) => _refs.remove(token);
}

/// Handlers of the release picker.
final class LibraryReleaseRoutes {
  LibraryReleaseRoutes(this.data)
    : tokens = LibraryReleaseTokens(data.ctx.clock);

  final LibraryData data;
  final LibraryReleaseTokens tokens;
  final _searching = <String>{};

  LibraryMapper get _map => data.mapper;

  static const searchTimeout = Duration(seconds: 150);
  static const grabTimeout = Duration(seconds: 30);

  Future<Response> episode(ApiRequest req) async {
    final episodeId = req.pathInt('episodeId');
    return _search(
      req,
      ArrService.sonarr,
      {'episodeId': episodeId},
      episodeIds: [episodeId],
    );
  }

  Future<Response> season(ApiRequest req) async {
    final id = req.pathInt('id');
    final n = req.pathInt('n');
    return _search(req, ArrService.sonarr, {
      'seriesId': id,
      'seasonNumber': n,
    }, seriesId: id);
  }

  Future<Response> movie(ApiRequest req) async {
    final id = req.pathInt('id');
    return _search(req, ArrService.radarr, {'movieId': id}, movieId: id);
  }

  Future<Response> _search(
    ApiRequest req,
    ArrService svc,
    Map<String, Object?> query, {
    int? seriesId,
    List<int> episodeIds = const [],
    int? movieId,
  }) async {
    final userId = req.user.id;
    // Each search hits every indexer live: one at a time per user.
    if (!_searching.add(userId)) {
      throw ApiException(
        409,
        ApiErrorCode.jobRunning,
        'A release search is already running; wait for it to finish.',
      );
    }
    try {
      final sw = Stopwatch()..start();
      // The series types (for the anime episode labels) load alongside the
      // search; the list is cached and cheap next to an indexer search.
      final animeIds = svc == ArrService.sonarr
          ? _animeSeriesIds()
          : Future.value(const <int>{});
      final raw = arrList(
        await arrCall(
          data
              .client(svc)
              .getJson('/api/v3/release', query: query, timeout: searchTimeout),
        ),
        'release',
      );
      final anime = await animeIds;
      // The matched ids are `mappedSeriesId` / `mappedEpisodeInfo` /
      // `mappedMovieId`; `seriesId` / `episodeIds` / `movieId` are overrides
      // for POST /release and empty on a search. An episode search has no
      // series id in the route: when a release lacks the mapped one, the
      // episode's series is read once.
      int? episodeSeries;
      if (svc == ArrService.sonarr &&
          seriesId == null &&
          episodeIds.length == 1 &&
          raw.any((r) => _seriesOf(r) == null)) {
        episodeSeries = await _seriesOfEpisode(episodeIds.single);
      }
      final expiresAt = data.ctx.clock.now().add(LibraryReleaseTokens.ttl);
      final choices = <ReleaseChoice>[];
      for (final r in raw) {
        final guid = readString(r['guid']);
        final indexerId = readInt(r['indexerId']);
        if (guid == null || guid.isEmpty || indexerId == null) continue;
        final rSeries = _seriesOf(r) ?? seriesId ?? episodeSeries;
        final mappedEpisodes = [
          for (final e in releaseMappedEpisodes(r)) ?positiveId(e['id']),
        ];
        final rEpisodes = mappedEpisodes.isNotEmpty
            ? mappedEpisodes
            : readIntList(r['episodeIds']).isNotEmpty
            ? readIntList(r['episodeIds'])
            : episodeIds;
        final token = tokens.put(
          LibraryReleaseRef(
            userId: userId,
            service: svc,
            guid: guid,
            indexerId: indexerId,
            title: readString(r['title']) ?? '',
            expiresAt: expiresAt,
            seriesId: rSeries,
            episodeIds: rEpisodes,
            movieId:
                positiveId(r['mappedMovieId']) ??
                positiveId(r['movieId']) ??
                movieId,
          ),
        );
        choices.add(
          _map.release(
            svc,
            r,
            releaseId: token,
            anime: rSeries != null && anime.contains(rSeries),
          ),
        );
      }
      // Approved first, then the *arr's own order (quality / custom format
      // weight); a stable sort keeps the upstream order within each group.
      final sorted = [
        ...choices.where((c) => c.approved),
        ...choices.where((c) => !c.approved && !c.rejected),
        ...choices.where((c) => !c.approved && c.rejected),
      ];
      return ApiResponse.json(
        ReleaseChoiceList(
          items: sorted,
          tookMs: sw.elapsedMilliseconds,
        ).toJson(),
      );
    } finally {
      _searching.remove(userId);
    }
  }

  static int? _seriesOf(JsonMap r) =>
      positiveId(r['mappedSeriesId']) ?? positiveId(r['seriesId']);

  /// The series of episode [id] (`GET /api/v3/episode/{id}`); null when it
  /// cannot be read (the anime label and the detail invalidation are then
  /// skipped, nothing else changes).
  Future<int?> _seriesOfEpisode(int id) async {
    try {
      final e = readMap(
        await data
            .client(ArrService.sonarr)
            .getJson('/api/v3/episode/$id', timeout: grabTimeout),
      );
      return positiveId(e?['seriesId']);
    } on Object catch (e) {
      data.ctx.log.fine('series of episode $id unavailable: ${e.runtimeType}');
      return null;
    }
  }

  /// Ids of the anime-type series; empty when the list cannot be read (the
  /// labels then lack the absolute number, nothing else changes).
  Future<Set<int>> _animeSeriesIds() async {
    try {
      return {
        for (final s in await data.series())
          if (s.seriesType == LibrarySeriesType.anime) s.id,
      };
    } on Object catch (e) {
      data.ctx.log.fine('series types unavailable: ${e.runtimeType}');
      return const {};
    }
  }

  Future<Response> grab(ApiRequest req) async {
    final b = LibraryBody(await req.jsonBody());
    final token = b.reqString('releaseId', maxLength: 200);
    final ref = tokens.find(token, req.user.id);
    if (ref == null) throw _expired();
    final svc = ref.service;
    try {
      await data
          .client(svc)
          .sendJson(
            'POST',
            '/api/v3/release',
            body: {'guid': ref.guid, 'indexerId': ref.indexerId},
            timeout: grabTimeout,
          );
    } on UpstreamException catch (e) {
      if (e.isNotFound) {
        // The *arr's own 30 min cache expired.
        tokens.remove(token);
        throw _expired(e.service);
      }
      final s = e.status;
      if (s == 400 || s == 409 || s == 422) {
        throw ApiException(
          422,
          ApiErrorCode.validationFailed,
          e.message ?? '${arrName(svc)} refused this release.',
          service: e.service,
          fields: [
            for (final v in e.validation)
              ApiFieldError(field: v.field, message: v.message),
          ],
        );
      }
      throw e.toApiException(resourceNotFound: false);
    }
    if (svc == ArrService.sonarr) {
      data.seriesDetails.invalidateWhere((id) => id == ref.seriesId);
    } else {
      data.movieDetails.invalidateWhere((id) => id == ref.movieId);
    }
    data.summaries.clear();
    return ApiResponse.json({'ok': true, 'title': ref.title}, status: 201);
  }

  static ApiException _expired([ServiceId? service]) => ApiException(
    404,
    ApiErrorCode.notFound,
    'Release expired, search again.',
    service: service,
  );
}
