// settings routes: stub created by core-app (ARCHITECTURE §12); the settings slice replaces the screens.
// Keep `settingsRoutes` (one top-level GoRoute at the feature root) and declare static
// sub-routes before parameterised ones.

import 'package:go_router/go_router.dart';

import 'package:yams_hub/core/routing/admin_guard.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/routing/placeholder_screen.dart';

/// Routes of the settings feature (APP.md §1).
final List<RouteBase> settingsRoutes = [
  GoRoute(
    path: RootPaths.settings,
    builder: (context, state) => const PlaceholderScreen(title: 'Settings'),
    routes: [
      GoRoute(
        path: 'servers',
        builder: (context, state) => const PlaceholderScreen(title: 'Servers'),
        routes: [
          GoRoute(
            path: ':id',
            builder: (context, state) => const PlaceholderScreen(title: 'Server'),
          ),
        ],
      ),
      GoRoute(
        path: 'account',
        builder: (context, state) => const PlaceholderScreen(title: 'Account'),
      ),
      GoRoute(
        path: 'sessions',
        builder: (context, state) => const PlaceholderScreen(title: 'Sessions'),
      ),
      GoRoute(
        path: 'users',
        redirect: adminOnly(AppPaths.settings()),
        builder: (context, state) => const PlaceholderScreen(title: 'Users'),
        routes: [
          GoRoute(
            path: ':id',
            builder: (context, state) => const PlaceholderScreen(title: 'User'),
          ),
        ],
      ),
      GoRoute(
        path: 'audit',
        redirect: adminOnly(AppPaths.settings()),
        builder: (context, state) => const PlaceholderScreen(title: 'Audit log'),
      ),
      GoRoute(
        path: 'appearance',
        builder: (context, state) => const PlaceholderScreen(title: 'Appearance'),
      ),
      GoRoute(
        path: 'refresh',
        builder: (context, state) => const PlaceholderScreen(title: 'Refresh'),
      ),
      GoRoute(
        path: 'apps',
        builder: (context, state) => const PlaceholderScreen(title: 'Media apps'),
      ),
      GoRoute(
        path: 'about',
        builder: (context, state) => const PlaceholderScreen(title: 'About'),
      ),
    ],
  ),
];
