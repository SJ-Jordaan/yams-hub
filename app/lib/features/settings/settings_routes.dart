// Settings routes (APP.md §1, §13). Static sub-routes are declared before
// parameterised ones; admin-only routes keep their `adminOnly` guards.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/routing/admin_guard.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/servers/hosting.dart';

import 'screens/about_screen.dart';
import 'screens/account_screen.dart';
import 'screens/appearance_screen.dart';
import 'screens/audit_screen.dart';
import 'screens/media_apps_screen.dart';
import 'screens/refresh_screen.dart';
import 'screens/server_editor_screen.dart';
import 'screens/servers_screen.dart';
import 'screens/sessions_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/user_editor_screen.dart';
import 'screens/users_screen.dart';

/// The gateway-served web build has a single implicit server: the server
/// pages are hidden and their URLs lead back to Settings.
GoRouterRedirect _serverProfilesOnly() => (context, state) {
  final container = ProviderScope.containerOf(context, listen: false);
  return container.read(hostingModeProvider).hasServerProfiles ? null : AppPaths.settings();
};

/// Routes of the settings feature (APP.md §1).
final List<RouteBase> settingsRoutes = [
  GoRoute(
    path: RootPaths.settings,
    builder: (context, state) => const SettingsScreen(),
    routes: [
      GoRoute(
        path: 'servers',
        redirect: _serverProfilesOnly(),
        builder: (context, state) => const ServersScreen(),
        routes: [
          GoRoute(
            path: ':id',
            builder: (context, state) => ServerEditorScreen(profileId: state.pathParameters['id']!),
          ),
        ],
      ),
      GoRoute(
        path: 'account',
        builder: (context, state) => const AccountScreen(),
      ),
      GoRoute(
        path: 'sessions',
        builder: (context, state) => const SessionsScreen(),
      ),
      GoRoute(
        path: 'users',
        redirect: adminOnly(AppPaths.settings()),
        builder: (context, state) => const UsersScreen(),
        routes: [
          GoRoute(
            path: ':id',
            builder: (context, state) => UserEditorScreen(userId: state.pathParameters['id']!),
          ),
        ],
      ),
      GoRoute(
        path: 'audit',
        redirect: adminOnly(AppPaths.settings()),
        builder: (context, state) => const AuditScreen(),
      ),
      GoRoute(
        path: 'appearance',
        builder: (context, state) => const AppearanceScreen(),
      ),
      GoRoute(
        path: 'refresh',
        builder: (context, state) => const RefreshScreen(),
      ),
      GoRoute(
        path: 'apps',
        builder: (context, state) => const MediaAppsScreen(),
      ),
      GoRoute(
        path: 'about',
        builder: (context, state) => const AboutScreen(),
      ),
    ],
  ),
];
