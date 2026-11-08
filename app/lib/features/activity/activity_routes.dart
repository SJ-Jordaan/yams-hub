// activity routes: stub created by core-app (ARCHITECTURE §12); the activity slice replaces the screens.
// Keep `activityRoutes` (one top-level GoRoute at the feature root) and declare static
// sub-routes before parameterised ones.

import 'package:go_router/go_router.dart';

import 'package:yams_hub/core/routing/admin_guard.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/routing/placeholder_screen.dart';

/// Routes of the activity feature (APP.md §1).
final List<RouteBase> activityRoutes = [
  GoRoute(
    path: RootPaths.activity,
    builder: (context, state) => const PlaceholderScreen(title: 'Activity'),
    routes: [
      GoRoute(
        path: 'transfer',
        redirect: adminOnly(AppPaths.activity()),
        builder: (context, state) => const PlaceholderScreen(title: 'Transfer settings'),
      ),
      GoRoute(
        path: 'add',
        redirect: adminOnly(AppPaths.activity()),
        builder: (context, state) => const PlaceholderScreen(title: 'Add torrent'),
      ),
      GoRoute(
        path: 'torrent/:hash',
        builder: (context, state) => const PlaceholderScreen(title: 'Torrent'),
      ),
    ],
  ),
];
