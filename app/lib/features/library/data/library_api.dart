/// Typed wrapper over the gateway's `/library/**` endpoints (API.md §7).
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_models/yams_models.dart';

/// `tv` or `movies`, the two halves of the library.
enum LibraryKind {
  tv,
  movies;

  ArrService get service => this == tv ? ArrService.sonarr : ArrService.radarr;
}

/// `missing` or `cutoff` (Wanted tab).
enum LibraryWantedKind {
  missing,
  cutoff;

  String get label => this == missing ? 'Missing' : 'Cutoff unmet';
}

/// One method per library endpoint; every method throws [ApiException].
class LibraryApi {
  LibraryApi(this._dio);

  final Dio _dio;

  // Reads -------------------------------------------------------------------

  Future<LibrarySummary> summary() => _dio.getModel('/library/summary', LibrarySummary.fromJson);

  Future<LibraryProfiles> profiles() => _dio.getModel('/library/profiles', LibraryProfiles.fromJson);

  Future<List<SeriesSummary>> series() async =>
      (await _dio.getModel('/library/tv', (j) => ItemList.fromJson(j, SeriesSummary.fromJson))).items;

  Future<List<MovieSummary>> movies() async =>
      (await _dio.getModel('/library/movies', (j) => ItemList.fromJson(j, MovieSummary.fromJson))).items;

  Future<SeriesDetail> seriesDetail(int id) => _dio.getModel('/library/tv/$id', SeriesDetail.fromJson);

  Future<MovieDetail> movieDetail(int id) => _dio.getModel('/library/movies/$id', MovieDetail.fromJson);

  Future<PagedList<ArrHistoryItem>> history(ArrService service, int id, {int page = 1, int pageSize = 25}) =>
      _dio.getModel(
        service == ArrService.sonarr ? '/library/tv/$id/history' : '/library/movies/$id/history',
        (j) => PagedList.fromJson(j, ArrHistoryItem.fromJson),
        query: {'page': page, 'pageSize': pageSize},
      );

  Future<List<SeriesLookup>> lookupSeries(String term) async => (await _dio.getModel(
    '/library/tv/lookup',
    (j) => ItemList.fromJson(j, SeriesLookup.fromJson),
    query: {'term': term},
    options: Options(receiveTimeout: const Duration(seconds: 30)),
  )).items;

  Future<List<MovieLookup>> lookupMovies(String term) async => (await _dio.getModel(
    '/library/movies/lookup',
    (j) => ItemList.fromJson(j, MovieLookup.fromJson),
    query: {'term': term},
    options: Options(receiveTimeout: const Duration(seconds: 30)),
  )).items;

  Future<PagedList<WantedItem>> wanted(
    LibraryWantedKind kind, {
    required ArrService service,
    int page = 1,
    int pageSize = 25,
  }) => _dio.getModel(
    '/library/wanted/${kind.name}',
    (j) => PagedList.fromJson(j, WantedItem.fromJson),
    query: {'service': service.name, 'page': page, 'pageSize': pageSize},
  );

  Future<CommandRef> command(ServiceId service, int id) async =>
      (await _dio.getModel('/library/commands/${service.name}/$id', LibraryCommandResponse.fromJson)).command;

  // Releases [long] ---------------------------------------------------------

  Future<ReleaseChoiceList> episodeReleases(int episodeId) =>
      _dio.getModel('/library/tv/episodes/$episodeId/releases', ReleaseChoiceList.fromJson, options: longOptions());

  Future<ReleaseChoiceList> seasonReleases(int seriesId, int seasonNumber) => _dio.getModel(
    '/library/tv/$seriesId/seasons/$seasonNumber/releases',
    ReleaseChoiceList.fromJson,
    options: longOptions(),
  );

  Future<ReleaseChoiceList> movieReleases(int movieId) =>
      _dio.getModel('/library/movies/$movieId/releases', ReleaseChoiceList.fromJson, options: longOptions());

  Future<ReleaseChoiceGrabResult> grab(String releaseId) async =>
      ReleaseChoiceGrabResult.fromJson(await _dio.postMap('/library/releases/grab', body: {'releaseId': releaseId}));

  // Writes ------------------------------------------------------------------

  Future<SeriesSummary> addSeries(AddSeriesRequest request) async =>
      SeriesSummary.fromJson(await _dio.postMap('/library/tv', body: request.toJson()));

  Future<MovieSummary> addMovie(AddMovieRequest request) async =>
      MovieSummary.fromJson(await _dio.postMap('/library/movies', body: request.toJson()));

  /// `PATCH /library/tv/{id}` with the changed fields only.
  Future<SeriesSummary> editSeries(
    int id, {
    bool? monitored,
    int? qualityProfileId,
    LibrarySeriesType? seriesType,
    LibraryMonitorNewItems? monitorNewItems,
  }) async => SeriesSummary.fromJson(
    await _dio.patchMap(
      '/library/tv/$id',
      body: {
        'monitored': ?monitored,
        'qualityProfileId': ?qualityProfileId,
        'seriesType': ?seriesType?.name,
        'monitorNewItems': ?monitorNewItems?.name,
      },
    ),
  );

  Future<SeasonInfo> setSeasonMonitored(int id, int seasonNumber, bool monitored) async =>
      SeasonInfo.fromJson(await _dio.patchMap('/library/tv/$id/seasons/$seasonNumber', body: {'monitored': monitored}));

  Future<void> setEpisodesMonitored(List<int> episodeIds, bool monitored) =>
      _dio.patchMap('/library/tv/episodes', body: {'episodeIds': episodeIds, 'monitored': monitored});

  /// `POST /library/tv/{id}/search` (`scope`: series, season, episodes,
  /// missing).
  Future<CommandRef> searchSeries(int id, {required String scope, int? seasonNumber, List<int>? episodeIds}) async =>
      LibraryCommandResponse.fromJson(
        await _dio.postMap(
          '/library/tv/$id/search',
          body: {'scope': scope, 'seasonNumber': ?seasonNumber, 'episodeIds': ?episodeIds},
        ),
      ).command;

  Future<CommandRef> refreshSeries(int id) async =>
      LibraryCommandResponse.fromJson(await _dio.postMap('/library/tv/$id/refresh')).command;

  Future<MovieSummary> editMovie(
    int id, {
    bool? monitored,
    int? qualityProfileId,
    LibraryMinimumAvailability? minimumAvailability,
  }) async => MovieSummary.fromJson(
    await _dio.patchMap(
      '/library/movies/$id',
      body: {
        'monitored': ?monitored,
        'qualityProfileId': ?qualityProfileId,
        'minimumAvailability': ?minimumAvailability?.name,
      },
    ),
  );

  Future<CommandRef> searchMovie(int id) async =>
      LibraryCommandResponse.fromJson(await _dio.postMap('/library/movies/$id/search')).command;

  Future<CommandRef> refreshMovie(int id) async =>
      LibraryCommandResponse.fromJson(await _dio.postMap('/library/movies/$id/refresh')).command;

  /// `DELETE /library/{tv|movies}/{id}` (sent only after the user confirmed).
  Future<void> delete(LibraryKind kind, int id, {required bool deleteFiles, required bool addExclusion}) =>
      _dio.deleteMap(
        '/library/${kind.name}/$id',
        query: {'deleteFiles': deleteFiles, 'addExclusion': addExclusion, 'confirm': true},
      );

  Future<CommandRef> searchWanted(ArrService service, List<int> ids) async => LibraryCommandResponse.fromJson(
    await _dio.postMap('/library/wanted/search', body: {'service': service.name, 'ids': ids}),
  ).command;

  /// Global search (policy-gated; sent only after the typed confirmation).
  Future<CommandRef> searchAllWanted(ArrService service, LibraryWantedKind kind) async =>
      LibraryCommandResponse.fromJson(
        await _dio.postMap(
          '/library/wanted/search-all',
          body: {'service': service.name, 'kind': kind.name, 'confirm': true},
        ),
      ).command;
}

final libraryApiProvider = Provider<LibraryApi>((ref) => LibraryApi(ref.watch(dioProvider)));
