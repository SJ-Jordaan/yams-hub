// containers routes: stub created by core-app (ARCHITECTURE §12); the containers slice replaces the screens.
// Keep `containersRoutes` (one top-level GoRoute at the feature root) and declare static
// sub-routes before parameterised ones.

import 'package:go_router/go_router.dart';

import 'package:yams_hub/core/routing/admin_guard.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/routing/placeholder_screen.dart';

/// Routes of the containers feature (APP.md §1).
final List<RouteBase> containersRoutes = [
  GoRoute(
    path: RootPaths.containers,
    builder: (context, state) => const PlaceholderScreen(title: 'Containers'),
    routes: [
      GoRoute(
        path: 'updates',
        builder: (context, state) => const PlaceholderScreen(title: 'Updates'),
      ),
      GoRoute(
        path: 'maintenance',
        builder: (context, state) => const PlaceholderScreen(title: 'Maintenance'),
      ),
      GoRoute(
        path: ':name',
        builder: (context, state) => const PlaceholderScreen(title: 'Container'),
        routes: [
          GoRoute(
            path: 'logs',
            redirect: adminOnlyTo((s) => AppPaths.container(s.pathParameters['name']!)),
            builder: (context, state) => const PlaceholderScreen(title: 'Logs'),
          ),
        ],
      ),
    ],
  ),
];
