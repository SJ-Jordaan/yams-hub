// subtitles routes: stub created by core-app (ARCHITECTURE §12); the subtitles slice replaces the screens.
// Keep `subtitlesRoutes` (one top-level GoRoute at the feature root) and declare static
// sub-routes before parameterised ones.

import 'package:go_router/go_router.dart';

import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/routing/placeholder_screen.dart';

/// Routes of the subtitles feature (APP.md §1).
final List<RouteBase> subtitlesRoutes = [
  GoRoute(
    path: RootPaths.subtitles,
    builder: (context, state) => const PlaceholderScreen(title: 'Subtitles'),
  ),
];
