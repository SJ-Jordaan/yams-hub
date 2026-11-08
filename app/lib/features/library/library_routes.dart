/// Routes of the library feature (APP.md §1, §5). Static sub-routes are
/// declared before parameterised ones.
library;

import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/routing/admin_guard.dart';
import 'package:yams_hub/core/routing/not_found_screen.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_models/yams_models.dart';

import 'screens/library_add_screen.dart';
import 'screens/library_history_screen.dart';
import 'screens/library_screen.dart';
import 'screens/movie_detail_screen.dart';
import 'screens/series_detail_screen.dart';

int? _int(GoRouterState s, String name) => int.tryParse(s.pathParameters[name] ?? '');

/// Routes of the library feature (APP.md §1).
final List<RouteBase> libraryRoutes = [
  GoRoute(
    path: RootPaths.library,
    builder: (context, state) => LibraryScreen(initialTab: state.uri.queryParameters['tab']),
    routes: [
      GoRoute(
        path: 'add',
        redirect: adminOnly(AppPaths.library()),
        builder: (context, state) =>
            LibraryAddScreen(kind: state.uri.queryParameters['kind'], term: state.uri.queryParameters['term']),
      ),
      GoRoute(
        path: 'tv/:id',
        builder: (context, state) {
          final id = _int(state, 'id');
          return id == null ? const NotFoundScreen() : SeriesDetailScreen(id: id);
        },
        routes: [
          GoRoute(
            path: 'season/:n',
            builder: (context, state) {
              final id = _int(state, 'id');
              final n = _int(state, 'n');
              return id == null || n == null ? const NotFoundScreen() : SeasonScreen(seriesId: id, seasonNumber: n);
            },
          ),
        ],
      ),
      GoRoute(
        path: 'movies/:id',
        builder: (context, state) {
          final id = _int(state, 'id');
          return id == null ? const NotFoundScreen() : MovieDetailScreen(id: id);
        },
      ),
      GoRoute(
        path: 'history/:service/:id',
        builder: (context, state) {
          final id = _int(state, 'id');
          final service = ArrService.fromJson(state.pathParameters['service']);
          return id == null || service == ArrService.unknown
              ? const NotFoundScreen()
              : LibraryHistoryScreen(service: service, id: id);
        },
      ),
    ],
  ),
];
