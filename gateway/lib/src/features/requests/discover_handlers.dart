/// Discover, search and title routes (API.md §6.2, §6.3).
library;

import 'package:shelf/shelf.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'requests_service.dart';
import 'seerr_client.dart';
import 'seerr_mapper.dart';

/// The discover sliders and their Seerr endpoints.
const discoverSliders = {
  'trending': '/api/v1/discover/trending',
  'popular-movies': '/api/v1/discover/movies',
  'popular-tv': '/api/v1/discover/tv',
  'upcoming-movies': '/api/v1/discover/movies/upcoming',
  'upcoming-tv': '/api/v1/discover/tv/upcoming',
};

/// TMDB serves at most 500 pages.
const _maxPage = 500;

final class DiscoverHandlers {
  DiscoverHandlers(this.svc);

  final RequestsService svc;

  SeerrClient get _seerr => svc.seerr;
  SeerrMapper get _map => svc.mapper;

  static Response _page(TitlePage p) => ApiResponse.json(p.toJson());

  /// `GET /discover/{slider}` (shared, 10 min).
  Future<Response> slider(ApiRequest req) async {
    final slider = req.pathParam('slider');
    final path = discoverSliders[slider];
    if (path == null) {
      throw ApiException.badRequest(
        'Unknown slider "$slider"; use one of ${discoverSliders.keys.join(', ')}.',
      );
    }
    final page = req.queryInt('page', defaultValue: 1, min: 1, max: _maxPage);
    final trending = slider == 'trending';
    final popular = slider.startsWith('popular-');
    final mediaType = trending
        ? req.queryString('mediaType') == null
              ? null
              : req.queryChoice('mediaType', const ['all', 'movie', 'tv'])
        : null;
    final timeWindow = trending
        ? req.queryString('timeWindow') == null
              ? null
              : req.queryChoice('timeWindow', const ['day', 'week'])
        : null;
    final genre = popular ? req.queryIntOrNull('genre', min: 1) : null;
    final query = seerrQuery({
      'page': page,
      'mediaType': mediaType,
      'timeWindow': timeWindow,
      'genre': genre,
    });
    final fallback = switch (slider) {
      'popular-movies' || 'upcoming-movies' => MediaType.movie,
      'popular-tv' || 'upcoming-tv' => MediaType.tv,
      _ => null,
    };
    final result = await svc.discover.value('$path?$query', () async {
      if (!_seerr.configured) {
        throw ApiException.serviceNotConfigured(ServiceId.seerr);
      }
      final j = await _seerr.getMap(
        path,
        query: query,
        resourceNotFound: false,
      );
      return _map.titlePage(j, fallbackType: fallback);
    });
    return _page(result);
  }

  /// `GET /discover/watchlist`: the caller's own Seerr watchlist, as admin
  /// via `/user/{seerrUserId}/watchlist`; unlinked members get an empty page.
  Future<Response> watchlist(ApiRequest req) async {
    final page = req.queryInt('page', defaultValue: 1, min: 1, max: _maxPage);
    final actor = await svc.actor(req);
    final seerrUserId = actor.seerrUserId;
    if (seerrUserId == null) return _page(const TitlePage.empty());
    final result = await svc.watchlist.value('$seerrUserId:$page', () async {
      final j = await _seerr.getMap(
        '/api/v1/user/$seerrUserId/watchlist',
        query: seerrQuery({'page': page}),
        resourceNotFound: false,
      );
      final rows = readList(j['results'], (m) => m);
      final infos = await svc.titleInfos([
        for (final r in rows)
          if (readInt(r['tmdbId']) case final id?)
            (SeerrMapper.mediaType(r['mediaType']), id),
      ]);
      return TitlePage(
        page: readInt(j['page']) ?? page,
        totalPages: (readInt(j['totalPages']) ?? 0).clamp(0, _maxPage),
        totalResults: readInt(j['totalResults']) ?? rows.length,
        items: [
          for (final r in rows)
            ?_map.watchlistCard(
              r,
              infos[RequestsService.titleKey(
                SeerrMapper.mediaType(r['mediaType']),
                readInt(r['tmdbId']) ?? 0,
              )],
            ),
        ],
      );
    });
    return _page(result);
  }

  /// `GET /search?q=&page=` (5 min). Persons are dropped.
  Future<Response> search(ApiRequest req) async {
    final q = req.queryString('q');
    if (q == null) throw ApiException.badRequest('q is required');
    if (q.length > 100) {
      throw ApiException.badRequest('q must be at most 100 characters');
    }
    final page = req.queryInt('page', defaultValue: 1, min: 1, max: _maxPage);
    final query = seerrQuery({'query': q, 'page': page});
    final result = await svc.search.value(query, () async {
      if (!_seerr.configured) {
        throw ApiException.serviceNotConfigured(ServiceId.seerr);
      }
      final j = await _seerr.getMap(
        '/api/v1/search',
        query: query,
        resourceNotFound: false,
      );
      return _map.titlePage(j);
    });
    return _page(result);
  }

  /// `GET /discover/genres?mediaType=movie|tv` (24 h).
  Future<Response> genres(ApiRequest req) async {
    final type = req.queryChoice('mediaType', const [
      'movie',
      'tv',
    ], defaultValue: 'movie');
    final mediaType = type == 'tv' ? MediaType.tv : MediaType.movie;
    final list = await svc.genres.value(mediaType, () async {
      if (!_seerr.configured) {
        throw ApiException.serviceNotConfigured(ServiceId.seerr);
      }
      final j = await _seerr.get(
        '/api/v1/genres/$type',
        resourceNotFound: false,
      );
      return [
        for (final g in readList(j, (m) => m))
          if (readInt(g['id']) case final id?)
            Genre(id: id, name: readString(g['name']) ?? ''),
      ];
    });
    return ApiResponse.items(list, (g) => g.toJson());
  }

  // -------------------------------------------------------------------------
  // Titles
  // -------------------------------------------------------------------------

  static MediaType _mediaType(ApiRequest req) =>
      req.pathParam('mediaType') == 'tv' ? MediaType.tv : MediaType.movie;

  /// `GET /titles/movie/{tmdbId}`.
  Future<Response> movie(ApiRequest req) async {
    final id = req.pathInt('tmdbId');
    final actor = await svc.actor(req);
    final d = await svc.titleDetails(MediaType.movie, id);
    final info = _map.titleInfo(d);
    final media = _map.mediaState(
      d,
      info: info,
      viewer: actor.viewer,
      jellyfinServerId: await svc.jellyfinServerId(),
    );
    final title = _map.movieTitle(
      d,
      media: media,
      eligibility: SeerrMapper.movieEligibility(d, linked: actor.linked),
    );
    return ApiResponse.json(title.toJson());
  }

  /// `GET /titles/tv/{tmdbId}`.
  Future<Response> tv(ApiRequest req) async {
    final id = req.pathInt('tmdbId');
    final actor = await svc.actor(req);
    final d = await svc.titleDetails(MediaType.tv, id);
    final flags = await svc.flags();
    final info = _map.titleInfo(d);
    final seasons = SeerrMapper.tvSeasons(
      d,
      specials: flags.specialEpisodesEnabled,
      poster: _map.poster,
    );
    final media = _map.mediaState(
      d,
      info: info,
      viewer: actor.viewer,
      jellyfinServerId: await svc.jellyfinServerId(),
    );
    final title = _map.tvTitle(
      d,
      media: media,
      eligibility: SeerrMapper.tvEligibility(d, seasons, linked: actor.linked),
      seasons: seasons,
    );
    return ApiResponse.json(title.toJson());
  }

  /// `GET /titles/{mediaType}/{tmdbId}/ratings` (24 h). Seerr answers 404/500
  /// when RT/IMDb know nothing; that is an empty [Ratings], not an error.
  Future<Response> ratings(ApiRequest req) async {
    final type = _mediaType(req);
    final id = req.pathInt('tmdbId');
    final result = await svc.ratings.value(
      RequestsService.titleKey(type, id),
      () async {
        if (!_seerr.configured) {
          throw ApiException.serviceNotConfigured(ServiceId.seerr);
        }
        try {
          final j = await _seerr.getMap(
            type == MediaType.tv
                ? '/api/v1/tv/$id/ratings'
                : '/api/v1/movie/$id/ratingscombined',
            timeout: seerrDetailsTimeout,
            tmdbLookup: true,
          );
          return SeerrMapper.ratings(type, j);
        } on ApiException catch (e) {
          if (e.code == ApiErrorCode.notFound) return const Ratings();
          rethrow;
        }
      },
    );
    return ApiResponse.json(result.toJson());
  }

  /// `GET /titles/{mediaType}/{tmdbId}/recommendations|similar` (6 h).
  Future<Response> related(ApiRequest req, String kind) async {
    final type = _mediaType(req);
    final id = req.pathInt('tmdbId');
    final page = req.queryInt('page', defaultValue: 1, min: 1, max: _maxPage);
    final result = await svc.related.value(
      '${type.name}:$id:$kind:$page',
      () async {
        if (!_seerr.configured) {
          throw ApiException.serviceNotConfigured(ServiceId.seerr);
        }
        final j = await _seerr.getMap(
          '/api/v1/${type.name}/$id/$kind',
          query: seerrQuery({'page': page}),
          tmdbLookup: true,
        );
        return _map.titlePage(j, fallbackType: type);
      },
    );
    return _page(result);
  }

  /// `GET /titles/tv/{tmdbId}/seasons/{n}` (6 h).
  Future<Response> season(ApiRequest req) async {
    final id = req.pathInt('tmdbId');
    final n = req.pathInt('n');
    final result = await svc.seasons.value('$id:$n', () async {
      if (!_seerr.configured) {
        throw ApiException.serviceNotConfigured(ServiceId.seerr);
      }
      final j = await _seerr.getMap(
        '/api/v1/tv/$id/season/$n',
        timeout: seerrDetailsTimeout,
        tmdbLookup: true,
      );
      return _map.seasonEpisodes(j);
    });
    return ApiResponse.json(result.toJson());
  }
}
