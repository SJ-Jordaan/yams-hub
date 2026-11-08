/// Routes of the system feature (APP.md §1): `/system` only.
library;

import 'package:go_router/go_router.dart';

import 'package:yams_hub/core/routing/paths.dart';

import 'screens/system_screen.dart';

/// Routes of the system feature (APP.md §1).
final List<RouteBase> systemRoutes = [
  GoRoute(path: RootPaths.system, builder: (context, state) => const SystemScreen()),
];
