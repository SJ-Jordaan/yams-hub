// subtitles routes (APP.md §1, §11). One top-level GoRoute at the feature root; no sub-routes.

import 'package:go_router/go_router.dart';

import 'package:yams_hub/core/routing/paths.dart';

import 'screens/subtitles_screen.dart';

/// Routes of the subtitles feature (APP.md §1): `/subtitles?tab=episodes|movies|history`.
final List<RouteBase> subtitlesRoutes = [
  GoRoute(
    path: RootPaths.subtitles,
    builder: (context, state) => SubtitlesScreen(initialTab: SubtitlesTab.fromQuery(state.uri.queryParameters['tab'])),
  ),
];
