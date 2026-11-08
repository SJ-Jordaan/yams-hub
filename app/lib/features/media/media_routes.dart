// media routes: stub created by core-app (ARCHITECTURE §12); the media slice replaces the screens.
// Keep `mediaRoutes` (one top-level GoRoute at the feature root) and declare static
// sub-routes before parameterised ones.

import 'package:go_router/go_router.dart';

import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/routing/placeholder_screen.dart';

/// Routes of the media feature (APP.md §1).
final List<RouteBase> mediaRoutes = [
  GoRoute(
    path: RootPaths.media,
    builder: (context, state) => const PlaceholderScreen(title: 'Media'),
    routes: [
      GoRoute(
        path: 'jellyfin',
        builder: (context, state) => const PlaceholderScreen(title: 'Jellyfin'),
      ),
      GoRoute(
        path: 'audiobooks',
        builder: (context, state) => const PlaceholderScreen(title: 'Audiobookshelf'),
      ),
      GoRoute(
        path: 'books',
        builder: (context, state) => const PlaceholderScreen(title: 'Kavita'),
      ),
      GoRoute(
        path: 'shelfmark',
        builder: (context, state) => const PlaceholderScreen(title: 'Shelfmark'),
      ),
      GoRoute(
        path: 'stats/users',
        builder: (context, state) => const PlaceholderScreen(title: 'Watch stats'),
      ),
    ],
  ),
];
