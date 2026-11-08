/// `/library/wanted/**` and `/library/commands/**` (API.md §7.4, §7.5).
library;

import 'package:shelf/shelf.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'library_data.dart';
import 'library_mappers.dart';
import 'library_support.dart';

/// Gateway sort name → upstream `sortKey` and default ascending order.
const _sonarrSorts = {
  'airDate': ('episodes.airDateUtc', false),
  'title': ('series.sortTitle', true),
  'lastSearched': ('episodes.lastSearchTime', false),
};
const _radarrSorts = {
  'title': ('movieMetadata.sortTitle', true),
  'year': ('movieMetadata.year', true),
};

/// Handlers of the Wanted tab and the command status route.
final class LibraryWantedRoutes {
  LibraryWantedRoutes(this.data, this.commands);

  final LibraryData data;
  final LibraryCommands commands;

  LibraryMapper get _map => data.mapper;

  Future<Response> list(ApiRequest req) async {
    final kind = req.pathParam('kind');
    final svc = ArrService.fromJson(
      req.queryChoice('service', const ['sonarr', 'radarr']),
    );
    final page = req.queryInt('page', defaultValue: 1, min: 1, max: 100000);
    final pageSize = req.queryInt(
      'pageSize',
      defaultValue: 25,
      min: 1,
      max: 50,
      clamp: true,
    );
    final sorts = svc == ArrService.sonarr ? _sonarrSorts : _radarrSorts;
    final sort = req.queryChoice(
      'sort',
      sorts.keys.toList(),
      defaultValue: svc == ArrService.sonarr ? 'airDate' : 'title',
    );
    final (sortKey, defaultAsc) = sorts[sort]!;
    final ascending = sortAscending(req, defaultAscending: defaultAsc);
    final key = '${svc.name}:$kind:$page:$pageSize:$sortKey:$ascending';
    final result = await data.wanted.value(
      key,
      () => _load(svc, kind, page, pageSize, sortKey, ascending),
    );
    return ApiResponse.json(result.toJson((w) => w.toJson()));
  }

  Future<PagedList<WantedItem>> _load(
    ArrService svc,
    String kind,
    int page,
    int pageSize,
    String sortKey,
    bool ascending,
  ) async {
    final cutoff = kind == 'cutoff';
    final client = data.client(svc);
    final results = await Future.wait<Object?>([
      arrCall(
        client.getJson(
          '/api/v3/wanted/$kind',
          query: {
            'page': page,
            'pageSize': pageSize,
            'monitored': true,
            if (svc == ArrService.sonarr) 'includeSeries': true,
            if (svc == ArrService.sonarr && cutoff) 'includeEpisodeFile': true,
            'sortKey': sortKey,
            'sortDirection': ascending ? 'ascending' : 'descending',
          },
        ),
      ),
      if (cutoff)
        data.cutoffNames(svc)
      else
        Future.value(const <int, String>{}),
    ]);
    final p = ArrPage(arrMap(results[0], 'wanted'));
    final cutoffs = results[1]! as Map<int, String>;
    final List<WantedItem> items;
    if (svc == ArrService.sonarr) {
      items = [
        for (final r in p.records)
          _map.wantedEpisode(
            r,
            cutoffQuality: cutoff
                ? cutoffs[readInt(readMap(r['series'])?['qualityProfileId'])]
                : null,
          ),
      ];
    } else {
      // Radarr cutoff records carry only `movieFileId`: read the current
      // quality from the file (parallel, cached 10 min).
      final qualities = cutoff
          ? await Future.wait([
              for (final r in p.records) _movieFileQuality(r['movieFileId']),
            ])
          : List<String?>.filled(p.records.length, null);
      items = [
        for (var i = 0; i < p.records.length; i++)
          _map.wantedMovie(
            p.records[i],
            currentQuality: qualities[i],
            cutoffQuality: cutoff
                ? cutoffs[readInt(p.records[i]['qualityProfileId'])]
                : null,
          ),
      ];
    }
    return PagedList.of(
      items: items,
      page: page,
      pageSize: pageSize,
      total: p.total,
    );
  }

  Future<String?> _movieFileQuality(Object? fileId) async {
    final id = readInt(fileId);
    if (id == null || id <= 0) return null;
    try {
      return await data.movieFileQuality.value(id, () async {
        final f = arrMap(
          await data.radarr.getJson('/api/v3/moviefile/$id'),
          'moviefile',
        );
        return _map.quality(f['quality']).name;
      });
    } on Object catch (e) {
      data.ctx.log.fine('moviefile $id unavailable: ${e.runtimeType}');
      return null;
    }
  }

  Future<Response> search(ApiRequest req) async {
    final b = LibraryBody(await req.jsonBody());
    final svc = b.service();
    final ids = b.intList('ids', maxLength: 50);
    final ref = await commands.start(
      svc,
      svc == ArrService.sonarr
          ? {'name': 'EpisodeSearch', 'episodeIds': ids}
          : {'name': 'MoviesSearch', 'movieIds': ids},
    );
    return commandResponse(ref);
  }

  Future<Response> searchAll(ApiRequest req) async {
    final b = LibraryBody(await req.jsonBody());
    final svc = b.service();
    final kind = b.reqChoice('kind', const ['missing', 'cutoff']);
    if (!data.ctx.config.policy.allowGlobalSearch) {
      throw ApiException.policyDenied(
        'Global searches are disabled by the gateway policy '
        '(upgrades happen gradually via RSS).',
      );
    }
    final count = ArrPage(
      arrMap(
        await arrCall(
          data
              .client(svc)
              .getJson(
                '/api/v3/wanted/$kind',
                query: {'pageSize': 0, 'monitored': true},
              ),
        ),
        'wanted',
      ),
    ).total;
    final what = svc == ArrService.sonarr
        ? libraryPlural(count, 'episode')
        : libraryPlural(count, 'movie');
    await req.requireConfirm('Searches indexers for $what');
    final JsonMap command = switch ((svc, kind)) {
      (ArrService.sonarr, 'missing') => {
        'name': 'MissingEpisodeSearch',
        'monitored': true,
      },
      (ArrService.sonarr, _) => {
        'name': 'CutoffUnmetEpisodeSearch',
        'monitored': true,
      },
      (_, 'missing') => {'name': 'MissingMoviesSearch'},
      _ => {'name': 'CutoffUnmetMoviesSearch'},
    };
    return commandResponse(await commands.start(svc, command));
  }

  Future<Response> command(ApiRequest req) async {
    final svc = arrServiceParam(req);
    final ref = await commands.status(svc, req.pathInt('id'));
    // A finished search changes what is wanted and downloading.
    if (!ref.status.isActive) data.summaries.clear();
    return ApiResponse.json({'command': ref.toJson()});
  }
}
