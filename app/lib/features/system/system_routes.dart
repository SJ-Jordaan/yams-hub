// system routes: stub created by core-app (ARCHITECTURE §12); the system slice replaces the screens.
// Keep `systemRoutes` (one top-level GoRoute at the feature root) and declare static
// sub-routes before parameterised ones.

import 'package:go_router/go_router.dart';

import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/routing/placeholder_screen.dart';

/// Routes of the system feature (APP.md §1).
final List<RouteBase> systemRoutes = [
  GoRoute(
    path: RootPaths.system,
    builder: (context, state) => const PlaceholderScreen(title: 'System'),
  ),
];
