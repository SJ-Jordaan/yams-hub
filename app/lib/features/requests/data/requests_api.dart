/// Typed wrapper over the requests endpoints (API.md §6).
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_models/yams_models.dart';

/// The discover carousels (`GET /discover/{slider}`).
enum DiscoverSlider {
  trending('trending', 'Trending'),
  popularMovies('popular-movies', 'Popular movies'),
  popularTv('popular-tv', 'Popular series'),
  upcomingMovies('upcoming-movies', 'Upcoming movies'),
  upcomingTv('upcoming-tv', 'Upcoming series'),
  watchlist('watchlist', 'Your watchlist');

  const DiscoverSlider(this.slug, this.label);

  /// Path segment (`/discover/<slug>`, `/requests/discover/<slug>`).
  final String slug;
  final String label;

  /// The media type this slider is limited to (null: mixed).
  MediaType? get mediaType => switch (this) {
    popularMovies || upcomingMovies => MediaType.movie,
    popularTv || upcomingTv => MediaType.tv,
    trending || watchlist => null,
  };

  static DiscoverSlider? fromSlug(String slug) {
    for (final s in values) {
      if (s.slug == slug) return s;
    }
    return null;
  }
}

/// `filter` of `GET /requests`.
enum RequestsFilter { all, pending, approved, processing, available, failed, declined, completed }

/// `filter` of `GET /issues`.
enum IssuesFilter { open, resolved, all }

class RequestsApi {
  RequestsApi(this.dio);

  final Dio dio;

  static const _bad = ApiException(
    status: 0,
    code: ClientErrorCode.badResponse,
    message: 'The hub sent a response this app does not understand.',
  );

  static T _decode<T>(JsonMap json, T Function(JsonMap) decode) {
    try {
      return decode(json);
    } on FormatException {
      throw _bad;
    }
  }

  static String _type(MediaType t) => t == MediaType.tv ? 'tv' : 'movie';

  // Discover and search ----------------------------------------------------

  /// One discover carousel page. [mediaType] applies to trending only.
  Future<TitlePage> discover(DiscoverSlider slider, {int page = 1, MediaType? mediaType, int? genre}) => dio.getModel(
    '/discover/${slider.slug}',
    TitlePage.fromJson,
    query: {
      'page': page,
      if (slider == DiscoverSlider.trending && mediaType != null && mediaType != MediaType.unknown)
        'mediaType': _type(mediaType),
      'genre': ?genre,
    },
  );

  Future<TitlePage> search(String q, {int page = 1}) =>
      dio.getModel('/search', TitlePage.fromJson, query: {'q': q, 'page': page});

  Future<List<Genre>> genres(MediaType type) => dio.getModel(
    '/discover/genres',
    (j) => ItemList.fromJson(j, Genre.fromJson).items,
    query: {'mediaType': _type(type)},
  );

  // Titles -------------------------------------------------------------------

  Future<MovieTitle> movie(int tmdbId) => dio.getModel('/titles/movie/$tmdbId', MovieTitle.fromJson);

  Future<TvTitle> tv(int tmdbId) => dio.getModel('/titles/tv/$tmdbId', TvTitle.fromJson);

  Future<Ratings> ratings(MediaType type, int tmdbId) =>
      dio.getModel('/titles/${_type(type)}/$tmdbId/ratings', Ratings.fromJson);

  Future<TitlePage> recommendations(MediaType type, int tmdbId, {int page = 1}) =>
      dio.getModel('/titles/${_type(type)}/$tmdbId/recommendations', TitlePage.fromJson, query: {'page': page});

  Future<TitlePage> similar(MediaType type, int tmdbId, {int page = 1}) =>
      dio.getModel('/titles/${_type(type)}/$tmdbId/similar', TitlePage.fromJson, query: {'page': page});

  Future<SeasonEpisodes> season(int tmdbId, int seasonNumber) =>
      dio.getModel('/titles/tv/$tmdbId/seasons/$seasonNumber', SeasonEpisodes.fromJson);

  // Requests -----------------------------------------------------------------

  Future<CreateRequestResult> create(CreateRequest request) async =>
      _decode(await dio.postMap('/requests', body: request.toJson()), CreateRequestResult.fromJson);

  Future<PagedList<RequestSummary>> list({
    RequestsFilter filter = RequestsFilter.all,
    bool mine = false,
    int page = 1,
    int pageSize = 25,
  }) => dio.getModel(
    '/requests',
    (j) => PagedList.fromJson(j, RequestSummary.fromJson),
    query: {'filter': filter.name, if (mine) 'mine': 'true', 'page': page, 'pageSize': pageSize},
  );

  Future<RequestCounts> counts() => dio.getModel('/requests/counts', RequestCounts.fromJson);

  Future<RequestSummary> request(int id) => dio.getModel('/requests/$id', RequestSummary.fromJson);

  Future<RequestSummary> approve(int id) async =>
      _decode(await dio.postMap('/requests/$id/approve'), RequestSummary.fromJson);

  Future<RequestSummary> decline(int id) async =>
      _decode(await dio.postMap('/requests/$id/decline'), RequestSummary.fromJson);

  Future<RequestSummary> retry(int id) async =>
      _decode(await dio.postMap('/requests/$id/retry'), RequestSummary.fromJson);

  /// Edits a pending request; null when nothing was left to request.
  Future<RequestSummary?> update(int id, RequestUpdate update) async {
    final j = await dio.putMap('/requests/$id', body: update.toJson());
    if (j['outcome'] == CreateRequestOutcome.nothingToRequest.name) return null;
    return _decode(j, RequestSummary.fromJson);
  }

  /// Deletes the Seerr request record (the user confirmed).
  Future<void> delete(int id) async => dio.deleteMap('/requests/$id', query: {'confirm': 'true'});

  Future<RequestsOptions> options() => dio.getModel('/requests/options', RequestsOptions.fromJson);

  // Issues -------------------------------------------------------------------

  Future<PagedList<Issue>> issues({IssuesFilter filter = IssuesFilter.open, int page = 1, int pageSize = 25}) =>
      dio.getModel(
        '/issues',
        (j) => PagedList.fromJson(j, Issue.fromJson),
        query: {'filter': filter.name, 'page': page, 'pageSize': pageSize},
      );

  Future<IssueCounts> issueCounts() => dio.getModel('/issues/counts', IssueCounts.fromJson);

  Future<Issue> issue(int id) => dio.getModel('/issues/$id', Issue.fromJson);

  Future<Issue> createIssue(CreateIssue issue) async =>
      _decode(await dio.postMap('/issues', body: issue.toJson()), Issue.fromJson);

  Future<Issue> comment(int id, String message) async =>
      _decode(await dio.postMap('/issues/$id/comments', body: {'message': message}), Issue.fromJson);

  Future<Issue> resolve(int id) async => _decode(await dio.postMap('/issues/$id/resolve'), Issue.fromJson);

  Future<Issue> reopen(int id) async => _decode(await dio.postMap('/issues/$id/reopen'), Issue.fromJson);
}

final requestsApiProvider = Provider<RequestsApi>((ref) => RequestsApi(ref.watch(dioProvider)));
