/// Routes of the calendar feature (APP.md §1, §7).
library;

import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/routing/paths.dart';

import 'screens/calendar_screen.dart';

/// Routes of the calendar feature (APP.md §1).
final List<RouteBase> calendarRoutes = [
  GoRoute(path: RootPaths.calendar, builder: (context, state) => const CalendarScreen()),
];
