/// Routes of the containers feature (APP.md §1, §9). Static sub-routes
/// (`updates`, `maintenance`) come before `:name`.
library;

import 'package:go_router/go_router.dart';

import 'package:yams_hub/core/routing/admin_guard.dart';
import 'package:yams_hub/core/routing/paths.dart';

import 'screens/container_detail_screen.dart';
import 'screens/container_logs_screen.dart';
import 'screens/containers_screen.dart';
import 'screens/maintenance_screen.dart';
import 'screens/updates_screen.dart';

/// Routes of the containers feature (APP.md §1).
final List<RouteBase> containersRoutes = [
  GoRoute(
    path: RootPaths.containers,
    builder: (context, state) => const ContainersScreen(),
    routes: [
      GoRoute(path: 'updates', builder: (context, state) => const UpdatesScreen()),
      GoRoute(path: 'maintenance', builder: (context, state) => const MaintenanceScreen()),
      GoRoute(
        path: ':name',
        builder: (context, state) => ContainerDetailScreen(name: state.pathParameters['name']!),
        routes: [
          GoRoute(
            path: 'logs',
            redirect: adminOnlyTo((s) => AppPaths.container(s.pathParameters['name']!)),
            builder: (context, state) => ContainerLogsScreen(name: state.pathParameters['name']!),
          ),
        ],
      ),
    ],
  ),
];
