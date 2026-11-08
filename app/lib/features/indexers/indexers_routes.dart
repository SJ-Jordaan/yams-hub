// Routes of the indexers feature (APP.md §1, §10). Static sub-routes come
// before `:id`; the manual search is admin-only.

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'package:yams_hub/core/routing/admin_guard.dart';
import 'package:yams_hub/core/routing/not_found_screen.dart';
import 'package:yams_hub/core/routing/paths.dart';

import 'screens/indexer_detail_screen.dart';
import 'screens/indexer_history_screen.dart';
import 'screens/indexers_screen.dart';
import 'screens/release_search_screen.dart';

/// Routes of the indexers feature (APP.md §1).
final List<RouteBase> indexersRoutes = [
  GoRoute(
    path: RootPaths.indexers,
    builder: (context, state) => const IndexersScreen(),
    routes: [
      GoRoute(
        path: 'history',
        builder: (context, state) => const IndexerHistoryScreen(),
      ),
      GoRoute(
        path: 'search',
        redirect: adminOnly(AppPaths.indexers()),
        builder: (context, state) => const ReleaseSearchScreen(),
      ),
      GoRoute(
        path: ':id',
        builder: (context, state) {
          final id = int.tryParse(state.pathParameters['id'] ?? '');
          if (id == null || id <= 0) {
            return NotFoundScreen(location: state.uri.toString());
          }
          return IndexerDetailScreen(key: ValueKey(id), id: id);
        },
      ),
    ],
  ),
];
