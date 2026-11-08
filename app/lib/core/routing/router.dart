/// The app's GoRouter (ARCHITECTURE §7.3).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/activity/activity_routes.dart';
import '../../features/calendar/calendar_routes.dart';
import '../../features/containers/containers_routes.dart';
import '../../features/indexers/indexers_routes.dart';
import '../../features/library/library_routes.dart';
import '../../features/media/media_routes.dart';
import '../../features/requests/requests_routes.dart';
import '../../features/settings/settings_routes.dart';
import '../../features/subtitles/subtitles_routes.dart';
import '../../features/system/system_routes.dart';
import '../auth/auth_controller.dart';
import '../auth/login_screen.dart';
import '../dashboard/dashboard_screen.dart';
import '../launcher/web_apps_screen.dart';
import '../servers/hosting.dart';
import '../servers/onboarding_screen.dart';
import '../servers/server_store.dart';
import 'more_screen.dart';
import 'not_found_screen.dart';
import 'paths.dart';
import 'shell_scaffold.dart';

/// Shell branches in order (index = branch, ARCHITECTURE §7.3).
List<StatefulShellBranch> buildShellBranches() => [
  StatefulShellBranch(
    routes: [
      GoRoute(
        path: RootPaths.home,
        builder: (context, state) => const DashboardScreen(),
        routes: [GoRoute(path: 'apps', builder: (context, state) => const WebAppsScreen())],
      ),
    ],
  ),
  StatefulShellBranch(routes: requestsRoutes),
  StatefulShellBranch(routes: libraryRoutes),
  StatefulShellBranch(routes: activityRoutes),
  StatefulShellBranch(routes: calendarRoutes),
  StatefulShellBranch(routes: mediaRoutes),
  StatefulShellBranch(routes: containersRoutes),
  StatefulShellBranch(routes: indexersRoutes),
  StatefulShellBranch(routes: subtitlesRoutes),
  StatefulShellBranch(routes: systemRoutes),
  StatefulShellBranch(routes: settingsRoutes),
  StatefulShellBranch(
    routes: [GoRoute(path: RootPaths.more, builder: (context, state) => const MoreScreen())],
  ),
];

/// Every route of the app: onboarding, login and the shell.
List<RouteBase> buildAppRoutes() => [
  GoRoute(path: '/', redirect: (context, state) => RootPaths.home),
  GoRoute(path: RootPaths.onboarding, builder: (context, state) => const OnboardingScreen()),
  GoRoute(
    path: RootPaths.login,
    builder: (context, state) => LoginScreen(from: state.uri.queryParameters['from']),
  ),
  StatefulShellRoute.indexedStack(
    builder: (context, state, navigationShell) => ShellScaffold(navigationShell: navigationShell),
    branches: buildShellBranches(),
  ),
];

/// Inputs of the global redirect.
@immutable
class RedirectState {
  const RedirectState({required this.hasProfile, required this.signedIn, required this.profilesEditable});

  final bool hasProfile;
  final bool signedIn;

  /// False on the gateway-served web build (no onboarding there).
  final bool profilesEditable;
}

/// The global redirect (ARCHITECTURE §7.3): no server → `/onboarding`,
/// signed out → `/login?from=<path>`, signed in on login/onboarding → `from`
/// or `/home`. Pure, for tests.
String? globalRedirect(RedirectState s, Uri uri) {
  final path = uri.path;
  final atOnboarding = path == RootPaths.onboarding;
  final atLogin = path == RootPaths.login;

  if (!s.hasProfile && s.profilesEditable) {
    return atOnboarding ? null : RootPaths.onboarding;
  }
  if (!s.signedIn) {
    if (atLogin || (atOnboarding && s.profilesEditable)) return null;
    final from = path == '/' || path.isEmpty ? null : uri.toString();
    return AppPaths.login(from: from);
  }
  if (atLogin || atOnboarding) {
    final from = uri.queryParameters['from'];
    return from != null && from.startsWith('/') && !from.startsWith('//') ? from : RootPaths.home;
  }
  return null;
}

/// Bridges Riverpod state changes to GoRouter's `refreshListenable`.
class RouterRefresh extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// The router. Rebuilt never; redirects re-run when auth or the server store
/// changes.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = RouterRefresh();
  ref.listen(authControllerProvider, (_, _) => refresh.notify());
  ref.listen(serverStoreProvider.select((s) => s.active?.id), (_, _) => refresh.notify());

  RedirectState current() => RedirectState(
    hasProfile: ref.read(serverStoreProvider).active != null,
    signedIn: ref.read(authControllerProvider).signedIn,
    profilesEditable: ref.read(hostingModeProvider).hasServerProfiles,
  );

  final router = GoRouter(
    initialLocation: ref.read(initialLocationProvider),
    refreshListenable: refresh,
    routes: buildAppRoutes(),
    redirect: (context, state) => globalRedirect(current(), state.uri),
    errorBuilder: (context, state) => NotFoundScreen(location: state.uri.path),
  );
  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
  });
  return router;
});

/// Where the router starts (the platform's URL on web takes precedence).
/// Overridden by tests.
final initialLocationProvider = Provider<String>((ref) => RootPaths.home);
