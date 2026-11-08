/// The shell's top-level destinations (APP.md §1, ARCHITECTURE §7.3).
library;

import 'package:flutter/material.dart';

import 'paths.dart';

@immutable
class HubDestination {
  const HubDestination({
    required this.branch,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.path,
  });

  /// Index of the StatefulShellRoute branch.
  final int branch;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final String path;
}

/// Branch indexes (StatefulShellRoute order).
abstract final class Branches {
  static const home = 0;
  static const requests = 1;
  static const library = 2;
  static const activity = 3;
  static const calendar = 4;
  static const media = 5;
  static const containers = 6;
  static const indexers = 7;
  static const subtitles = 8;
  static const system = 9;
  static const settings = 10;
  static const more = 11;
}

/// Every destination, indexed by branch.
const List<HubDestination> hubDestinations = [
  HubDestination(
    branch: Branches.home,
    label: 'Home',
    icon: Icons.dashboard_outlined,
    selectedIcon: Icons.dashboard,
    path: RootPaths.home,
  ),
  HubDestination(
    branch: Branches.requests,
    label: 'Requests',
    icon: Icons.movie_filter_outlined,
    selectedIcon: Icons.movie_filter,
    path: RootPaths.requests,
  ),
  HubDestination(
    branch: Branches.library,
    label: 'Library',
    icon: Icons.video_library_outlined,
    selectedIcon: Icons.video_library,
    path: RootPaths.library,
  ),
  HubDestination(
    branch: Branches.activity,
    label: 'Activity',
    icon: Icons.swap_vert_outlined,
    selectedIcon: Icons.swap_vert,
    path: RootPaths.activity,
  ),
  HubDestination(
    branch: Branches.calendar,
    label: 'Calendar',
    icon: Icons.calendar_month_outlined,
    selectedIcon: Icons.calendar_month,
    path: RootPaths.calendar,
  ),
  HubDestination(
    branch: Branches.media,
    label: 'Media',
    icon: Icons.play_circle_outline,
    selectedIcon: Icons.play_circle,
    path: RootPaths.media,
  ),
  HubDestination(
    branch: Branches.containers,
    label: 'Containers',
    icon: Icons.inventory_2_outlined,
    selectedIcon: Icons.inventory_2,
    path: RootPaths.containers,
  ),
  HubDestination(
    branch: Branches.indexers,
    label: 'Indexers',
    icon: Icons.travel_explore_outlined,
    selectedIcon: Icons.travel_explore,
    path: RootPaths.indexers,
  ),
  HubDestination(
    branch: Branches.subtitles,
    label: 'Subtitles',
    icon: Icons.subtitles_outlined,
    selectedIcon: Icons.subtitles,
    path: RootPaths.subtitles,
  ),
  HubDestination(
    branch: Branches.system,
    label: 'System',
    icon: Icons.monitor_heart_outlined,
    selectedIcon: Icons.monitor_heart,
    path: RootPaths.system,
  ),
  HubDestination(
    branch: Branches.settings,
    label: 'Settings',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
    path: RootPaths.settings,
  ),
  HubDestination(
    branch: Branches.more,
    label: 'More',
    icon: Icons.more_horiz,
    selectedIcon: Icons.more_horiz,
    path: RootPaths.more,
  ),
];

/// Phone bottom bar: Home, Requests, Library, Activity, More.
const List<int> compactBranches = [Branches.home, Branches.requests, Branches.library, Branches.activity, Branches.more];

/// Tablet rail: every destination except More.
const List<int> railBranches = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10];

/// Expanded navigation groups (ARCHITECTURE §7.3).
const List<(String?, List<int>)> expandedGroups = [
  ('Overview', [Branches.home]),
  ('Media', [Branches.requests, Branches.library, Branches.calendar, Branches.media]),
  ('Downloads', [Branches.activity, Branches.indexers, Branches.subtitles]),
  ('Server', [Branches.containers, Branches.system]),
  (null, [Branches.settings]),
];
