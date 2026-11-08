// requests routes: stub created by core-app (ARCHITECTURE §12); the requests slice replaces the screens.
// Keep `requestsRoutes` (one top-level GoRoute at the feature root) and declare static
// sub-routes before parameterised ones.

import 'package:go_router/go_router.dart';

import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/routing/placeholder_screen.dart';

/// Routes of the requests feature (APP.md §1).
final List<RouteBase> requestsRoutes = [
  GoRoute(
    path: RootPaths.requests,
    builder: (context, state) => const PlaceholderScreen(title: 'Discover'),
    routes: [
      GoRoute(
        path: 'search',
        builder: (context, state) => const PlaceholderScreen(title: 'Search'),
      ),
      GoRoute(
        path: 'list',
        builder: (context, state) => const PlaceholderScreen(title: 'Requests'),
        routes: [
          GoRoute(
            path: ':id',
            builder: (context, state) => const PlaceholderScreen(title: 'Request'),
          ),
        ],
      ),
      GoRoute(
        path: 'issues',
        builder: (context, state) => const PlaceholderScreen(title: 'Issues'),
        routes: [
          GoRoute(
            path: ':id',
            builder: (context, state) => const PlaceholderScreen(title: 'Issue'),
          ),
        ],
      ),
      GoRoute(
        path: 'discover/:slider',
        builder: (context, state) => const PlaceholderScreen(title: 'Discover'),
      ),
      GoRoute(
        path: 'title/:mediaType/:tmdbId',
        builder: (context, state) => const PlaceholderScreen(title: 'Title'),
      ),
    ],
  ),
];
