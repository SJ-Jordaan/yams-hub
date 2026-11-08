/// Dashboard card registry: card key → title, icon, route and the feature's
/// card widget (ARCHITECTURE §12 stub contract).
library;

import 'package:flutter/material.dart';
import 'package:yams_models/yams_models.dart';

import '../../features/activity/activity_dashboard_card.dart';
import '../../features/calendar/calendar_dashboard_card.dart';
import '../../features/containers/containers_dashboard_card.dart';
import '../../features/indexers/indexers_dashboard_card.dart';
import '../../features/library/library_dashboard_card.dart';
import '../../features/media/media_dashboard_card.dart';
import '../../features/requests/requests_dashboard_card.dart';
import '../../features/subtitles/subtitles_dashboard_card.dart';
import '../../features/system/system_dashboard_card.dart';
import '../routing/paths.dart';

/// How core presents one feature's dashboard card.
@immutable
class DashboardCardSpec {
  const DashboardCardSpec({
    required this.key,
    required this.title,
    required this.icon,
    required this.route,
    required this.builder,
  });

  final String key;
  final String title;
  final IconData icon;

  /// Where tapping the card header goes.
  final String Function() route;

  /// The feature widget for an ok section.
  final Widget Function(Section section) builder;
}

/// Every card, keyed by [DashboardCardKeys].
final Map<String, DashboardCardSpec> dashboardCards = {
  DashboardCardKeys.system: DashboardCardSpec(
    key: DashboardCardKeys.system,
    title: 'System',
    icon: Icons.monitor_heart_outlined,
    route: AppPaths.system,
    builder: (s) => SystemDashboardCard(section: s),
  ),
  DashboardCardKeys.media: DashboardCardSpec(
    key: DashboardCardKeys.media,
    title: 'Now playing',
    icon: Icons.play_circle_outline,
    route: AppPaths.media,
    builder: (s) => MediaDashboardCard(section: s),
  ),
  DashboardCardKeys.activity: DashboardCardSpec(
    key: DashboardCardKeys.activity,
    title: 'Downloads',
    icon: Icons.swap_vert,
    route: AppPaths.activity,
    builder: (s) => ActivityDashboardCard(section: s),
  ),
  DashboardCardKeys.calendar: DashboardCardSpec(
    key: DashboardCardKeys.calendar,
    title: 'Upcoming',
    icon: Icons.calendar_month_outlined,
    route: AppPaths.calendar,
    builder: (s) => CalendarDashboardCard(section: s),
  ),
  DashboardCardKeys.requests: DashboardCardSpec(
    key: DashboardCardKeys.requests,
    title: 'Requests',
    icon: Icons.movie_filter_outlined,
    route: AppPaths.requestsList,
    builder: (s) => RequestsDashboardCard(section: s),
  ),
  DashboardCardKeys.library: DashboardCardSpec(
    key: DashboardCardKeys.library,
    title: 'Library',
    icon: Icons.video_library_outlined,
    route: AppPaths.library,
    builder: (s) => LibraryDashboardCard(section: s),
  ),
  DashboardCardKeys.containers: DashboardCardSpec(
    key: DashboardCardKeys.containers,
    title: 'Containers',
    icon: Icons.inventory_2_outlined,
    route: AppPaths.containers,
    builder: (s) => ContainersDashboardCard(section: s),
  ),
  DashboardCardKeys.indexers: DashboardCardSpec(
    key: DashboardCardKeys.indexers,
    title: 'Indexers',
    icon: Icons.travel_explore,
    route: AppPaths.indexers,
    builder: (s) => IndexersDashboardCard(section: s),
  ),
  DashboardCardKeys.subtitles: DashboardCardSpec(
    key: DashboardCardKeys.subtitles,
    title: 'Subtitles',
    icon: Icons.subtitles_outlined,
    route: AppPaths.subtitles,
    builder: (s) => SubtitlesDashboardCard(section: s),
  ),
};
