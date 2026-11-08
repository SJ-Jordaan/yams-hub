// calendar routes: stub created by core-app (ARCHITECTURE §12); the calendar slice replaces the screens.
// Keep `calendarRoutes` (one top-level GoRoute at the feature root) and declare static
// sub-routes before parameterised ones.

import 'package:go_router/go_router.dart';

import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/routing/placeholder_screen.dart';

/// Routes of the calendar feature (APP.md §1).
final List<RouteBase> calendarRoutes = [
  GoRoute(
    path: RootPaths.calendar,
    builder: (context, state) => const PlaceholderScreen(title: 'Calendar'),
  ),
];
