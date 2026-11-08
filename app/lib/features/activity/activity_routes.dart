// Routes of the activity feature (APP.md §1, §6). Static sub-routes come
// before parameterised ones; admin-only routes keep the core guard.

import 'package:go_router/go_router.dart';

import 'package:yams_hub/core/routing/admin_guard.dart';
import 'package:yams_hub/core/routing/paths.dart';

import 'screens/activity_screen.dart';
import 'screens/add_torrent_screen.dart';
import 'screens/torrent_detail_screen.dart';
import 'screens/transfer_settings_screen.dart';

/// Routes of the activity feature (APP.md §1).
final List<RouteBase> activityRoutes = [
  GoRoute(
    path: RootPaths.activity,
    builder: (context, state) =>
        ActivityScreen(tab: state.uri.queryParameters['tab'], importKey: state.uri.queryParameters['import']),
    routes: [
      GoRoute(
        path: 'transfer',
        redirect: adminOnly(AppPaths.activity()),
        builder: (context, state) => const TransferSettingsScreen(),
      ),
      GoRoute(
        path: 'add',
        redirect: adminOnly(AppPaths.activity()),
        builder: (context, state) => AddTorrentScreen(url: state.uri.queryParameters['url']),
      ),
      GoRoute(
        path: 'torrent/:hash',
        builder: (context, state) => TorrentDetailScreen(hash: state.pathParameters['hash']!),
      ),
    ],
  ),
];
