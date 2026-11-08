/// Library feature: Sonarr and Radarr library management (API.md §7).
///
/// Routes are registered with static segments before parameterised ones
/// (`lookup`, `episodes`, `releases/grab` before `<id>`); every write is
/// admin-only and audited.
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'library_data.dart';
import 'library_movies.dart';
import 'library_releases.dart';
import 'library_summary.dart';
import 'library_support.dart';
import 'library_tv.dart';
import 'library_wanted.dart';

class LibraryModule extends FeatureModule {
  LibraryModule(this.ctx) {
    final data = LibraryData(ctx.forFeature(id));
    final commands = LibraryCommands(data.ctx, data.mapper);
    _tv = LibraryTvRoutes(data, commands);
    _movies = LibraryMovieRoutes(data, commands);
    _wanted = LibraryWantedRoutes(data, commands);
    _releases = LibraryReleaseRoutes(data);
    _summary = LibrarySummaryRoutes(data);
  }

  final FeatureContext ctx;
  late final LibraryTvRoutes _tv;
  late final LibraryMovieRoutes _movies;
  late final LibraryWantedRoutes _wanted;
  late final LibraryReleaseRoutes _releases;
  late final LibrarySummaryRoutes _summary;

  @override
  String get id => 'library';

  @override
  void registerRoutes(ApiRouter router) {
    const admin = Role.admin;
    router
      ..get('/library/summary', _summary.summary)
      ..get('/library/profiles', _summary.profiles)
      ..get(
        '/library/commands/<service|sonarr|radarr>/<id|[0-9]+>',
        _wanted.command,
      )
      ..get('/library/wanted/<kind|missing|cutoff>', _wanted.list)
      ..post('/library/wanted/search', _wanted.search, role: admin, audit: true)
      ..post(
        '/library/wanted/search-all',
        _wanted.searchAll,
        role: admin,
        audit: true,
      )
      ..post(
        '/library/releases/grab',
        _releases.grab,
        role: admin,
        audit: true,
        action: 'library.release.grab',
      )
      ..get('/library/tv', _tv.list)
      ..post(
        '/library/tv',
        _tv.add,
        role: admin,
        audit: true,
        action: 'library.tv.add',
      )
      ..get('/library/tv/lookup', _tv.lookup)
      ..patch(
        '/library/tv/episodes',
        _tv.editEpisodes,
        role: admin,
        audit: true,
        action: 'library.tv.episodes.edit',
      )
      ..get(
        '/library/tv/episodes/<episodeId|[0-9]+>/releases',
        _releases.episode,
        role: admin,
      )
      ..get('/library/tv/<id|[0-9]+>', _tv.detail)
      ..patch(
        '/library/tv/<id|[0-9]+>',
        _tv.edit,
        role: admin,
        audit: true,
        action: 'library.tv.edit',
      )
      ..delete(
        '/library/tv/<id|[0-9]+>',
        _tv.delete,
        role: admin,
        audit: true,
        action: 'library.tv.delete',
      )
      ..get('/library/tv/<id|[0-9]+>/history', _tv.history)
      ..patch(
        '/library/tv/<id|[0-9]+>/seasons/<seasonNumber|[0-9]+>',
        _tv.editSeason,
        role: admin,
        audit: true,
        action: 'library.tv.season.edit',
      )
      ..get(
        '/library/tv/<id|[0-9]+>/seasons/<n|[0-9]+>/releases',
        _releases.season,
        role: admin,
      )
      ..post(
        '/library/tv/<id|[0-9]+>/search',
        _tv.search,
        role: admin,
        audit: true,
        action: 'library.tv.search',
      )
      ..post(
        '/library/tv/<id|[0-9]+>/refresh',
        _tv.refresh,
        role: admin,
        audit: true,
        action: 'library.tv.refresh',
      )
      ..get('/library/movies', _movies.list)
      ..post(
        '/library/movies',
        _movies.add,
        role: admin,
        audit: true,
        action: 'library.movies.add',
      )
      ..get('/library/movies/lookup', _movies.lookup)
      ..get('/library/movies/<id|[0-9]+>', _movies.detail)
      ..patch(
        '/library/movies/<id|[0-9]+>',
        _movies.edit,
        role: admin,
        audit: true,
        action: 'library.movies.edit',
      )
      ..delete(
        '/library/movies/<id|[0-9]+>',
        _movies.delete,
        role: admin,
        audit: true,
        action: 'library.movies.delete',
      )
      ..get('/library/movies/<id|[0-9]+>/history', _movies.history)
      ..get(
        '/library/movies/<id|[0-9]+>/releases',
        _releases.movie,
        role: admin,
      )
      ..post(
        '/library/movies/<id|[0-9]+>/search',
        _movies.search,
        role: admin,
        audit: true,
        action: 'library.movies.search',
      )
      ..post(
        '/library/movies/<id|[0-9]+>/refresh',
        _movies.refresh,
        role: admin,
        audit: true,
        action: 'library.movies.refresh',
      );
  }

  @override
  Future<DashboardContribution?> dashboard(ApiRequest req) =>
      _summary.card(req);
}
