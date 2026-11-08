// indexers routes: stub created by core-app (ARCHITECTURE §12); the indexers slice replaces the screens.
// Keep `indexersRoutes` (one top-level GoRoute at the feature root) and declare static
// sub-routes before parameterised ones.

import 'package:go_router/go_router.dart';

import 'package:yams_hub/core/routing/admin_guard.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/routing/placeholder_screen.dart';

/// Routes of the indexers feature (APP.md §1).
final List<RouteBase> indexersRoutes = [
  GoRoute(
    path: RootPaths.indexers,
    builder: (context, state) => const PlaceholderScreen(title: 'Indexers'),
    routes: [
      GoRoute(
        path: 'history',
        builder: (context, state) => const PlaceholderScreen(title: 'Indexer history'),
      ),
      GoRoute(
        path: 'search',
        redirect: adminOnly(AppPaths.indexers()),
        builder: (context, state) => const PlaceholderScreen(title: 'Manual search'),
      ),
      GoRoute(
        path: ':id',
        builder: (context, state) => const PlaceholderScreen(title: 'Indexer'),
      ),
    ],
  ),
];
