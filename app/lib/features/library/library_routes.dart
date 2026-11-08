// library routes: stub created by core-app (ARCHITECTURE §12); the library slice replaces the screens.
// Keep `libraryRoutes` (one top-level GoRoute at the feature root) and declare static
// sub-routes before parameterised ones.

import 'package:go_router/go_router.dart';

import 'package:yams_hub/core/routing/admin_guard.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/routing/placeholder_screen.dart';

/// Routes of the library feature (APP.md §1).
final List<RouteBase> libraryRoutes = [
  GoRoute(
    path: RootPaths.library,
    builder: (context, state) => const PlaceholderScreen(title: 'Library'),
    routes: [
      GoRoute(
        path: 'add',
        redirect: adminOnly(AppPaths.library()),
        builder: (context, state) => const PlaceholderScreen(title: 'Add new'),
      ),
      GoRoute(
        path: 'tv/:id',
        builder: (context, state) => const PlaceholderScreen(title: 'Series'),
        routes: [
          GoRoute(
            path: 'season/:n',
            builder: (context, state) => const PlaceholderScreen(title: 'Season'),
          ),
        ],
      ),
      GoRoute(
        path: 'movies/:id',
        builder: (context, state) => const PlaceholderScreen(title: 'Movie'),
      ),
      GoRoute(
        path: 'history/:service/:id',
        builder: (context, state) => const PlaceholderScreen(title: 'History'),
      ),
    ],
  ),
];
