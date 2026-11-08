/// `/library/tv/**` (API.md §7.2).
library;

import 'package:shelf/shelf.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'library_data.dart';
import 'library_mappers.dart';
import 'library_support.dart';

const _tvFilters = [
  'all',
  'monitored',
  'unmonitored',
  'missing',
  'continuing',
  'ended',
  'anime',
  'upcoming',
];
const _tvSorts = [
  'title',
  'added',
  'nextAiring',
  'sizeOnDisk',
  'missing',
  'year',
];
const _seriesTypes = ['standard', 'daily', 'anime'];
const _monitorNewItems = ['all', 'none'];
const _seriesMonitors = [
  'all',
  'future',
  'missing',
  'existing',
  'firstSeason',
  'latestSeason',
  'pilot',
  'none',
];

/// Filters and sorts the cached series list (API.md §7.2).
List<SeriesSummary> filterSeries(
  List<SeriesSummary> all, {
  String? q,
  String filter = 'all',
  String sort = 'title',
  bool ascending = true,
}) {
  final needle = q == null ? null : libraryFold(q);
  bool matches(SeriesSummary s) {
    if (needle != null &&
        !libraryFold(s.title).contains(needle) &&
        !libraryFold(s.sortTitle).contains(needle)) {
      return false;
    }
    return switch (filter) {
      'monitored' => s.monitored,
      'unmonitored' => !s.monitored,
      'missing' => s.missingCount > 0,
      'continuing' => s.status == LibrarySeriesStatus.continuing,
      'ended' => s.status == LibrarySeriesStatus.ended,
      'anime' => s.isAnime,
      'upcoming' =>
        s.status == LibrarySeriesStatus.upcoming || s.nextAiring != null,
      _ => true,
    };
  }

  int byTitle(SeriesSummary a, SeriesSummary b) =>
      a.sortTitle.toLowerCase().compareTo(b.sortTitle.toLowerCase());
  final out = all.where(matches).toList();
  out.sort((a, b) {
    final c = switch (sort) {
      'added' => compareNullable(a.added, b.added, ascending),
      'nextAiring' => compareNullable(a.nextAiring, b.nextAiring, ascending),
      'sizeOnDisk' =>
        ascending
            ? a.sizeOnDiskBytes.compareTo(b.sizeOnDiskBytes)
            : b.sizeOnDiskBytes.compareTo(a.sizeOnDiskBytes),
      'missing' =>
        ascending
            ? a.missingCount.compareTo(b.missingCount)
            : b.missingCount.compareTo(a.missingCount),
      'year' => compareNullable(a.year, b.year, ascending),
      _ => ascending ? byTitle(a, b) : byTitle(b, a),
    };
    return c != 0 ? c : byTitle(a, b);
  });
  return out;
}

/// Handlers of the Sonarr part of the library.
final class LibraryTvRoutes {
  LibraryTvRoutes(this.data, this.commands);

  final LibraryData data;
  final LibraryCommands commands;

  UpstreamClient get _sonarr => data.sonarr;
  LibraryMapper get _map => data.mapper;

  static const _lookupTimeout = Duration(seconds: 20);

  Future<Response> list(ApiRequest req) async {
    final q = req.queryString('q');
    final filter = req.queryChoice('filter', _tvFilters, defaultValue: 'all');
    final sort = req.queryChoice('sort', _tvSorts, defaultValue: 'title');
    final ascending = sortAscending(
      req,
      defaultAscending: sort == 'title' || sort == 'nextAiring',
    );
    final all = await arrCall(data.series());
    return ApiResponse.items(
      filterSeries(all, q: q, filter: filter, sort: sort, ascending: ascending),
      (s) => s.toJson(),
    );
  }

  Future<SeriesDetail> _loadDetail(int id) async {
    final results = await Future.wait<Object?>([
      arrCall(
        _sonarr.getJson(
          '/api/v3/series/$id',
          query: {'includeSeasonImages': true},
        ),
        resourceNotFound: true,
        notFoundMessage: 'Series not found (it may have been deleted).',
      ),
      arrCall(
        _sonarr.getJson(
          '/api/v3/episode',
          query: {'seriesId': id, 'includeEpisodeFile': true},
        ),
      ),
      _queueDetails({'seriesId': id}),
      data.tags(ArrService.sonarr),
      data.profileNames(ArrService.sonarr),
    ]);
    return _map.seriesDetail(
      arrMap(results[0], 'series'),
      arrList(results[1], 'episode'),
      results[2]! as List<JsonMap>,
      tags: results[3]! as Map<int, String>,
      profiles: results[4]! as Map<int, String>,
    );
  }

  /// The queue entries of a detail screen; a failing queue read shows the
  /// page without download states.
  Future<List<JsonMap>> _queueDetails(Map<String, Object?> query) async {
    try {
      return arrList(
        await _sonarr.getJson('/api/v3/queue/details', query: query),
        'queue',
      );
    } on UpstreamException catch (e) {
      data.ctx.log.fine('sonarr queue/details failed: $e');
      return const [];
    }
  }

  Future<Response> detail(ApiRequest req) async {
    final id = req.pathInt('id');
    final d = await data.seriesDetails.value(id, () => _loadDetail(id));
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
      _sonarr.getJson(
        '/api/v3/history',
        query: {
          'seriesIds': id,
          'includeEpisode': true,
          'sortKey': 'date',
          'sortDirection': 'descending',
          'page': page,
          'pageSize': pageSize,
        },
      ),
    );
    final p = ArrPage(arrMap(raw, 'history'));
    final series = data.peekSeries(id);
    final items = [
      for (final r in p.records)
        _map.history(
          ArrService.sonarr,
          r,
          mediaTitle: series?.title,
          anime: series?.seriesType == LibrarySeriesType.anime,
          posterPath: series?.posterPath,
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
    // Sonarr answers an empty term with a 503 from SkyHook: never send it.
    if (term == null) throw ApiException.badRequest('term is required');
    if (term.length > 200) throw ApiException.badRequest('term is too long');
    final result = await data.lookups.value(
      'tv:${term.toLowerCase()}',
      () async {
        final results = await Future.wait<Object?>([
          arrCall(
            _sonarr.getJson(
              '/api/v3/series/lookup',
              query: {'term': term},
              timeout: _lookupTimeout,
            ),
          ),
          data.profilesOrFallback(),
        ]);
        final defaults = (results[1]! as LibraryProfiles).sonarr.defaults;
        return <SeriesLookup>[
          for (final s in arrList(results[0], 'lookup'))
            if (readInt(s['tvdbId']) != null)
              _map.seriesLookup(s, defaults: defaults),
        ];
      },
    );
    return ApiResponse.items(result as List<SeriesLookup>, (s) => s.toJson());
  }

  Future<Response> add(ApiRequest req) async {
    final b = LibraryBody(await req.jsonBody());
    final tvdbId = b.reqInt('tvdbId', min: 1);
    final profileId = b.reqInt('qualityProfileId', min: 1);
    final root = b.reqString('rootFolderPath');
    final seriesType = b.reqChoice('seriesType', _seriesTypes);
    final seasonFolder = b.optBool('seasonFolder') ?? true;
    final monitor = b.optChoice('monitor', _seriesMonitors) ?? 'all';
    final newItems = b.optChoice('monitorNewItems', _monitorNewItems) ?? 'all';
    final searchMissing = b.optBool('searchForMissing') ?? false;
    final searchCutoff = b.optBool('searchForCutoffUnmet') ?? false;

    final found = arrList(
      await arrCall(
        _sonarr.getJson(
          '/api/v3/series/lookup',
          query: {'term': 'tvdb:$tvdbId'},
          timeout: _lookupTimeout,
        ),
      ),
      'lookup',
    );
    if (found.isEmpty) {
      throw ApiException.notFound('No series with TVDB id $tvdbId was found.');
    }
    final base = found.first;
    if (readInt(base['id']) case final existing? when existing > 0) {
      throw libraryAlreadyExists(
        'This series is already in your library.',
        existing,
      );
    }
    final body = <String, Object?>{
      ...base,
      'tvdbId': tvdbId,
      'qualityProfileId': profileId,
      'rootFolderPath': root,
      'seriesType': seriesType,
      'seasonFolder': seasonFolder,
      'monitored': monitor != 'none',
      'monitorNewItems': newItems,
      'tags': base['tags'] ?? const <int>[],
      'addOptions': {
        'monitor': monitor,
        'searchForMissingEpisodes': searchMissing,
        'searchForCutoffUnmetEpisodes': searchCutoff,
        'ignoreEpisodesWithFiles': false,
        'ignoreEpisodesWithoutFiles': false,
      },
    }..remove('path');
    final Object? created;
    try {
      created = await _sonarr.sendJson('POST', '/api/v3/series', body: body);
    } on UpstreamException catch (e) {
      if (libraryIsAlreadyAdded(e)) {
        throw libraryAlreadyExists(
          'This series is already in your library.',
          await _seriesIdByTvdb(tvdbId),
        );
      }
      throw e.toApiException(resourceNotFound: false);
    }
    data.invalidateSonarr();
    final results = await Future.wait<Object?>([
      data.tags(ArrService.sonarr),
      data.profileNames(ArrService.sonarr),
    ]);
    final summary = _map.series(
      arrMap(created, 'series'),
      tags: results[0]! as Map<int, String>,
      profiles: results[1]! as Map<int, String>,
    );
    return ApiResponse.json(summary.toJson(), status: 201);
  }

  Future<int?> _seriesIdByTvdb(int tvdbId) async {
    try {
      final list = arrList(
        await _sonarr.getJson('/api/v3/series', query: {'tvdbId': tvdbId}),
      );
      return list.isEmpty ? null : readInt(list.first['id']);
    } on Object {
      return null;
    }
  }

  Future<SeriesSummary> _reread(int id) async {
    final results = await Future.wait<Object?>([
      arrCall(
        _sonarr.getJson('/api/v3/series/$id'),
        resourceNotFound: true,
        notFoundMessage: 'Series not found.',
      ),
      data.tags(ArrService.sonarr),
      data.profileNames(ArrService.sonarr),
    ]);
    return _map.series(
      arrMap(results[0], 'series'),
      tags: results[1]! as Map<int, String>,
      profiles: results[2]! as Map<int, String>,
    );
  }

  Future<Response> edit(ApiRequest req) async {
    final id = req.pathInt('id');
    final b = LibraryBody(await req.jsonBody());
    final changes = <String, Object?>{
      'monitored': b.optBool('monitored'),
      'qualityProfileId': b.optInt('qualityProfileId', min: 1),
      'seriesType': b.optChoice('seriesType', _seriesTypes),
      'monitorNewItems': b.optChoice('monitorNewItems', _monitorNewItems),
    }..removeWhere((_, v) => v == null);
    if (changes.isEmpty) {
      throw ApiException.validation(const [], message: 'Nothing to change.');
    }
    await arrCall(
      _sonarr.sendJson(
        'PUT',
        '/api/v3/series/editor',
        body: {
          'seriesIds': [id],
          ...changes,
        },
      ),
    );
    data.invalidateSonarr(seriesId: id);
    return ApiResponse.json((await _reread(id)).toJson());
  }

  Future<Response> editSeason(ApiRequest req) async {
    final id = req.pathInt('id');
    final n = req.pathInt('seasonNumber');
    final monitored = LibraryBody(await req.jsonBody()).reqBool('monitored');
    final series = arrMap(
      await arrCall(
        _sonarr.getJson('/api/v3/series/$id'),
        resourceNotFound: true,
        notFoundMessage: 'Series not found.',
      ),
      'series',
    );
    final seasons = arrList(series['seasons'] ?? const [], 'seasons');
    final index = seasons.indexWhere((s) => readInt(s['seasonNumber']) == n);
    if (index < 0) throw ApiException.notFound('Season $n does not exist.');
    final updatedSeasons = [
      for (var i = 0; i < seasons.length; i++)
        i == index ? {...seasons[i], 'monitored': monitored} : seasons[i],
    ];
    // The full resource is required: a missing `seasons` list would wipe
    // them and an empty `path` is rejected (integrations/arr.md §7.1).
    final saved = await arrCall(
      _sonarr.sendJson(
        'PUT',
        '/api/v3/series/$id',
        body: {...series, 'seasons': updatedSeasons},
      ),
    );
    data.invalidateSonarr(seriesId: id);
    final savedSeasons = readMap(saved)?['seasons'];
    final source = savedSeasons is List
        ? arrList(savedSeasons).firstWhere(
            (s) => readInt(s['seasonNumber']) == n,
            orElse: () => updatedSeasons[index],
          )
        : updatedSeasons[index];
    return ApiResponse.json(_map.season(source).toJson());
  }

  Future<Response> editEpisodes(ApiRequest req) async {
    final b = LibraryBody(await req.jsonBody());
    final ids = b.intList('episodeIds', maxLength: 500);
    final monitored = b.reqBool('monitored');
    final result = await arrCall(
      _sonarr.sendJson(
        'PUT',
        '/api/v3/episode/monitor',
        body: {'episodeIds': ids, 'monitored': monitored},
      ),
    );
    data.invalidateSonarr();
    final returned = result is List ? arrList(result) : const <JsonMap>[];
    final items = returned.isEmpty
        ? [
            for (final id in ids) {'id': id, 'monitored': monitored},
          ]
        : [
            for (final e in returned)
              if (readInt(e['id']) case final id?)
                {'id': id, 'monitored': readBool(e['monitored']) ?? monitored},
          ];
    return ApiResponse.json({'items': items});
  }

  Future<Response> search(ApiRequest req) async {
    final id = req.pathInt('id');
    final b = LibraryBody(await req.jsonBody());
    final scope = b.reqChoice('scope', const [
      'series',
      'season',
      'episodes',
      'missing',
    ]);
    final JsonMap command = switch (scope) {
      'season' => {
        'name': 'SeasonSearch',
        'seriesId': id,
        'seasonNumber': b.reqInt('seasonNumber', min: 0),
      },
      'episodes' => {
        'name': 'EpisodeSearch',
        'episodeIds': b.intList('episodeIds', maxLength: 500),
      },
      'missing' => {
        'name': 'MissingEpisodeSearch',
        'seriesId': id,
        'monitored': true,
      },
      _ => {'name': 'SeriesSearch', 'seriesId': id},
    };
    return commandResponse(await commands.start(ArrService.sonarr, command));
  }

  Future<Response> refresh(ApiRequest req) async {
    final id = req.pathInt('id');
    final ref = await commands.start(ArrService.sonarr, {
      'name': 'RefreshSeries',
      'seriesIds': [id],
    });
    data.seriesDetails.invalidate(id);
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
    final series = arrMap(
      await arrCall(
        _sonarr.getJson('/api/v3/series/$id'),
        resourceNotFound: true,
        notFoundMessage: 'Series not found.',
      ),
      'series',
    );
    final title = readString(series['title']) ?? 'series $id';
    final stats = readMap(series['statistics']) ?? const {};
    final files = readInt(stats['episodeFileCount']) ?? 0;
    final size = readInt(stats['sizeOnDisk']) ?? 0;
    await req.requireConfirm(
      deleteFiles
          ? "Removes '$title' from Sonarr and permanently deletes "
                '${libraryPlural(files, 'file')} (${libraryFormatSize(size)})'
          : "Removes '$title' from Sonarr; files stay on disk",
    );
    await arrCall(
      _sonarr
          .send(
            'DELETE',
            '/api/v3/series/$id',
            query: {
              'deleteFiles': deleteFiles,
              'addImportListExclusion': addExclusion,
            },
          )
          .then((r) => r.ensureOk()),
      resourceNotFound: true,
      notFoundMessage: 'Series not found.',
    );
    data.invalidateSonarr(seriesId: id);
    return ApiResponse.noContent();
  }
}
