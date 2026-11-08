/// `/library/movies/**` (API.md §7.3).
library;

import 'package:shelf/shelf.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'library_data.dart';
import 'library_mappers.dart';
import 'library_support.dart';

const _movieFilters = [
  'all',
  'monitored',
  'unmonitored',
  'missing',
  'available',
  'unreleased',
  'cutoffUnmet',
];
const _movieSorts = ['title', 'added', 'releaseDate', 'sizeOnDisk', 'year'];
const _availabilities = ['announced', 'inCinemas', 'released'];
const _movieMonitors = ['movieOnly', 'movieAndCollection', 'none'];

/// Filters and sorts the cached movie list (API.md §7.3).
List<MovieSummary> filterMovies(
  List<MovieSummary> all, {
  String? q,
  String filter = 'all',
  String sort = 'title',
  bool ascending = true,
}) {
  final needle = q == null ? null : libraryFold(q);
  bool matches(MovieSummary m) {
    if (needle != null &&
        !libraryFold(m.title).contains(needle) &&
        !libraryFold(m.sortTitle).contains(needle)) {
      return false;
    }
    return switch (filter) {
      'monitored' => m.monitored,
      'unmonitored' => !m.monitored,
      'missing' => m.monitored && !m.hasFile && m.isAvailable,
      'available' => m.hasFile,
      'unreleased' => !m.isAvailable,
      'cutoffUnmet' => m.hasFile && m.cutoffNotMet,
      _ => true,
    };
  }

  int byTitle(MovieSummary a, MovieSummary b) =>
      a.sortTitle.toLowerCase().compareTo(b.sortTitle.toLowerCase());
  final out = all.where(matches).toList();
  out.sort((a, b) {
    final c = switch (sort) {
      'added' => compareNullable(a.added, b.added, ascending),
      'releaseDate' => compareNullable(a.releaseDate, b.releaseDate, ascending),
      'sizeOnDisk' =>
        ascending
            ? a.sizeOnDiskBytes.compareTo(b.sizeOnDiskBytes)
            : b.sizeOnDiskBytes.compareTo(a.sizeOnDiskBytes),
      'year' => compareNullable(a.year, b.year, ascending),
      _ => ascending ? byTitle(a, b) : byTitle(b, a),
    };
    return c != 0 ? c : byTitle(a, b);
  });
  return out;
}

/// Handlers of the Radarr part of the library.
final class LibraryMovieRoutes {
  LibraryMovieRoutes(this.data, this.commands);

  final LibraryData data;
  final LibraryCommands commands;

  UpstreamClient get _radarr => data.radarr;
  LibraryMapper get _map => data.mapper;

  static const _lookupTimeout = Duration(seconds: 20);

  Future<Response> list(ApiRequest req) async {
    final q = req.queryString('q');
    final filter = req.queryChoice(
      'filter',
      _movieFilters,
      defaultValue: 'all',
    );
    final sort = req.queryChoice('sort', _movieSorts, defaultValue: 'title');
    final ascending = sortAscending(req, defaultAscending: sort == 'title');
    final all = await arrCall(data.movies());
    return ApiResponse.items(
      filterMovies(all, q: q, filter: filter, sort: sort, ascending: ascending),
      (m) => m.toJson(),
    );
  }

  Future<MovieDetail> _loadDetail(int id) async {
    Future<List<JsonMap>> queue() async {
      try {
        return arrList(
          await _radarr.getJson(
            '/api/v3/queue/details',
            query: {'movieId': id},
          ),
          'queue',
        );
      } on UpstreamException catch (e) {
        data.ctx.log.fine('radarr queue/details failed: $e');
        return const [];
      }
    }

    final results = await Future.wait<Object?>([
      arrCall(
        _radarr.getJson('/api/v3/movie/$id'),
        resourceNotFound: true,
        notFoundMessage: 'Movie not found (it may have been deleted).',
      ),
      arrCall(_radarr.getJson('/api/v3/moviefile', query: {'movieId': id})),
      queue(),
      data.tags(ArrService.radarr),
      data.profileNames(ArrService.radarr),
    ]);
    return _map.movieDetail(
      arrMap(results[0], 'movie'),
      arrList(results[1], 'moviefile'),
      results[2]! as List<JsonMap>,
      tags: results[3]! as Map<int, String>,
      profiles: results[4]! as Map<int, String>,
    );
  }

  Future<Response> detail(ApiRequest req) async {
    final id = req.pathInt('id');
    final d = await data.movieDetails.value(id, () => _loadDetail(id));
    return ApiResponse.json(d.toJson());
  }

  Future<Response> history(ApiRequest req) async {
    final id = req.pathInt('id');
    final page = req.queryInt('page', defaultValue: 1, min: 1, max: 10000);
    final pageSize = req.queryInt(
      'pageSize',
      defaultValue: 25,
      min: 1,
      max: 50,
      clamp: true,
    );
    final raw = await arrCall(
      _radarr.getJson(
        '/api/v3/history',
        query: {
          'movieIds': id,
          'includeMovie': false,
          'sortKey': 'date',
          'sortDirection': 'descending',
          'page': page,
          'pageSize': pageSize,
        },
      ),
    );
    final p = ArrPage(arrMap(raw, 'history'));
    final movie = data.peekMovie(id);
    final items = [
      for (final r in p.records)
        _map.history(
          ArrService.radarr,
          r,
          mediaTitle: movie?.title,
          posterPath: movie?.posterPath,
        ),
    ];
    return ApiResponse.json(
      PagedList.of(
        items: items,
        page: page,
        pageSize: pageSize,
        total: p.total,
      ).toJson((i) => i.toJson()),
    );
  }

  Future<Response> lookup(ApiRequest req) async {
    final term = req.queryString('term');
    if (term == null) throw ApiException.badRequest('term is required');
    if (term.length > 200) throw ApiException.badRequest('term is too long');
    final result = await data.lookups.value(
      'movies:${term.toLowerCase()}',
      () async {
        final results = await Future.wait<Object?>([
          arrCall(
            _radarr.getJson(
              '/api/v3/movie/lookup',
              query: {'term': term},
              timeout: _lookupTimeout,
            ),
          ),
          data.profilesOrFallback(),
        ]);
        final defaults = (results[1]! as LibraryProfiles).radarr.defaults;
        return <MovieLookup>[
          for (final m in arrList(results[0], 'lookup'))
            if (readInt(m['tmdbId']) case final id? when id > 0)
              _map.movieLookup(m, defaults: defaults),
        ];
      },
    );
    return ApiResponse.items(result as List<MovieLookup>, (m) => m.toJson());
  }

  Future<Response> add(ApiRequest req) async {
    final b = LibraryBody(await req.jsonBody());
    final tmdbId = b.reqInt('tmdbId', min: 1);
    final profileId = b.reqInt('qualityProfileId', min: 1);
    final root = b.reqString('rootFolderPath');
    final availability =
        b.optChoice('minimumAvailability', _availabilities) ?? 'released';
    final monitor = b.optChoice('monitor', _movieMonitors) ?? 'movieOnly';
    final searchForMovie = b.optBool('searchForMovie') ?? false;

    final base = arrMap(
      await arrCall(
        _radarr.getJson(
          '/api/v3/movie/lookup/tmdb',
          query: {'tmdbId': tmdbId},
          timeout: _lookupTimeout,
        ),
        resourceNotFound: true,
        notFoundMessage: 'No movie with TMDB id $tmdbId was found.',
      ),
      'lookup',
    );
    if (readInt(base['id']) case final existing? when existing > 0) {
      throw libraryAlreadyExists(
        'This movie is already in your library.',
        existing,
      );
    }
    final body = <String, Object?>{
      ...base,
      'tmdbId': tmdbId,
      'qualityProfileId': profileId,
      'rootFolderPath': root,
      // Omitted, Radarr would default to `tba` (integrations/arr.md §6.4).
      'minimumAvailability': availability,
      'monitored': monitor != 'none',
      'tags': base['tags'] ?? const <int>[],
      'addOptions': {
        'monitor': monitor,
        'searchForMovie': searchForMovie,
        'addMethod': 'manual',
      },
    }..remove('path');
    final Object? created;
    try {
      created = await _radarr.sendJson('POST', '/api/v3/movie', body: body);
    } on UpstreamException catch (e) {
      if (libraryIsAlreadyAdded(e)) {
        throw libraryAlreadyExists(
          'This movie is already in your library.',
          await _movieIdByTmdb(tmdbId),
        );
      }
      throw e.toApiException(resourceNotFound: false);
    }
    data.invalidateRadarr();
    final results = await Future.wait<Object?>([
      data.tags(ArrService.radarr),
      data.profileNames(ArrService.radarr),
    ]);
    final summary = _map.movie(
      arrMap(created, 'movie'),
      tags: results[0]! as Map<int, String>,
      profiles: results[1]! as Map<int, String>,
    );
    return ApiResponse.json(summary.toJson(), status: 201);
  }

  Future<int?> _movieIdByTmdb(int tmdbId) async {
    try {
      final list = arrList(
        await _radarr.getJson('/api/v3/movie', query: {'tmdbId': tmdbId}),
      );
      return list.isEmpty ? null : readInt(list.first['id']);
    } on Object {
      return null;
    }
  }

  Future<Response> edit(ApiRequest req) async {
    final id = req.pathInt('id');
    final b = LibraryBody(await req.jsonBody());
    final changes = <String, Object?>{
      'monitored': b.optBool('monitored'),
      'qualityProfileId': b.optInt('qualityProfileId', min: 1),
      'minimumAvailability': b.optChoice(
        'minimumAvailability',
        _availabilities,
      ),
    }..removeWhere((_, v) => v == null);
    if (changes.isEmpty) {
      throw ApiException.validation(const [], message: 'Nothing to change.');
    }
    await arrCall(
      _radarr.sendJson(
        'PUT',
        '/api/v3/movie/editor',
        body: {
          'movieIds': [id],
          ...changes,
        },
      ),
    );
    data.invalidateRadarr(movieId: id);
    final results = await Future.wait<Object?>([
      arrCall(
        _radarr.getJson('/api/v3/movie/$id'),
        resourceNotFound: true,
        notFoundMessage: 'Movie not found.',
      ),
      data.tags(ArrService.radarr),
      data.profileNames(ArrService.radarr),
    ]);
    return ApiResponse.json(
      _map
          .movie(
            arrMap(results[0], 'movie'),
            tags: results[1]! as Map<int, String>,
            profiles: results[2]! as Map<int, String>,
          )
          .toJson(),
    );
  }

  Future<Response> search(ApiRequest req) async {
    final id = req.pathInt('id');
    return commandResponse(
      await commands.start(ArrService.radarr, {
        'name': 'MoviesSearch',
        'movieIds': [id],
      }),
    );
  }

  Future<Response> refresh(ApiRequest req) async {
    final id = req.pathInt('id');
    final ref = await commands.start(ArrService.radarr, {
      'name': 'RefreshMovie',
      'movieIds': [id],
    });
    data.movieDetails.invalidate(id);
    return commandResponse(ref);
  }

  Future<Response> delete(ApiRequest req) async {
    final id = req.pathInt('id');
    final deleteFiles = req.queryBool('deleteFiles');
    final addExclusion = req.queryBool('addExclusion');
    if (deleteFiles && !data.ctx.config.policy.allowArrDeleteFiles) {
      throw ApiException.policyDenied(
        'Deleting files through the hub is disabled by the gateway policy.',
      );
    }
    final movie = arrMap(
      await arrCall(
        _radarr.getJson('/api/v3/movie/$id'),
        resourceNotFound: true,
        notFoundMessage: 'Movie not found.',
      ),
      'movie',
    );
    final title = readString(movie['title']) ?? 'movie $id';
    final stats = readMap(movie['statistics']) ?? const {};
    final files =
        readInt(stats['movieFileCount']) ??
        ((readInt(movie['movieFileId']) ?? 0) > 0 ? 1 : 0);
    final size =
        readInt(movie['sizeOnDisk']) ?? readInt(stats['sizeOnDisk']) ?? 0;
    await req.requireConfirm(
      deleteFiles
          ? "Removes '$title' from Radarr and permanently deletes "
                '${libraryPlural(files, 'file')} (${libraryFormatSize(size)})'
          : "Removes '$title' from Radarr; files stay on disk",
    );
    await arrCall(
      _radarr
          .send(
            'DELETE',
            '/api/v3/movie/$id',
            // Radarr's name differs from Sonarr's `addImportListExclusion`.
            query: {
              'deleteFiles': deleteFiles,
              'addImportExclusion': addExclusion,
            },
          )
          .then((r) => r.ensureOk()),
      resourceNotFound: true,
      notFoundMessage: 'Movie not found.',
    );
    data.invalidateRadarr(movieId: id);
    return ApiResponse.noContent();
  }
}
