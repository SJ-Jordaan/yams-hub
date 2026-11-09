/// Navigation chrome around the shell branches (ARCHITECTURE §7.3): bottom
/// bar on phones, rail on tablets, grouped side navigation on wide screens.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_controller.dart';
import '../servers/hosting.dart';
import '../servers/network_kind.dart';
import '../servers/server_connection.dart';
import 'destinations.dart';
import 'nav_badges.dart';
import 'paths.dart';

/// Width classes of the navigation chrome.
enum ShellLayout {
  /// < 600 dp: NavigationBar with Home, Requests, Library, Activity, More.
  compact,

  /// 600–1199 dp: NavigationRail with every destination but More.
  medium,

  /// ≥ 1200 dp: grouped side navigation with labels.
  expanded;

  static ShellLayout forWidth(double width) => width < 600 ? compact : (width < 1200 ? medium : expanded);
}

class ShellScaffold extends ConsumerWidget {
  const ShellScaffold({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watching keeps the badge poller alive on every tab.
    final badges = ref.watch(navBadgesProvider);
    // Refreshes the cached user (role, display name) once per session.
    ref.listen(meProvider, (_, _) {});
    final isAdmin = ref.watch(isAdminProvider);
    final current = navigationShell.currentIndex;
    final layout = ShellLayout.forWidth(MediaQuery.sizeOf(context).width);

    void go(int branch) => navigationShell.goBranch(branch, initialLocation: branch == current);

    int? badgeFor(int branch) => switch (branch) {
      Branches.requests => isAdmin ? badges.requestsPending : null,
      Branches.activity => badges.activityAttention,
      _ => null,
    };

    Widget icon(int branch, {required bool selected}) {
      final d = hubDestinations[branch];
      final child = Icon(selected ? d.selectedIcon : d.icon);
      final count = badgeFor(branch);
      if (count == null || count <= 0) return child;
      return Badge(label: Text(count > 99 ? '99+' : '$count'), child: child);
    }

    final body = Column(
      children: [
        const OfflineBanner(),
        Expanded(child: navigationShell),
      ],
    );

    switch (layout) {
      case ShellLayout.compact:
        final selected = compactBranches.indexOf(current);
        return Scaffold(
          body: body,
          bottomNavigationBar: NavigationBar(
            selectedIndex: selected < 0 ? compactBranches.indexOf(Branches.more) : selected,
            onDestinationSelected: (i) => go(compactBranches[i]),
            destinations: [
              for (final b in compactBranches)
                NavigationDestination(
                  icon: icon(b, selected: false),
                  selectedIcon: icon(b, selected: true),
                  label: hubDestinations[b].label,
                ),
            ],
          ),
        );
      case ShellLayout.medium:
        final selected = railBranches.indexOf(current);
        return Scaffold(
          body: SafeArea(
            bottom: false,
            right: false,
            child: Row(
              children: [
                NavigationRail(
                  selectedIndex: selected < 0 ? null : selected,
                  labelType: NavigationRailLabelType.selected,
                  onDestinationSelected: (i) => go(railBranches[i]),
                  destinations: [
                    for (final b in railBranches)
                      NavigationRailDestination(
                        icon: icon(b, selected: false),
                        selectedIcon: icon(b, selected: true),
                        label: Text(hubDestinations[b].label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            ),
          ),
        );
      case ShellLayout.expanded:
        final flat = [for (final (_, branches) in expandedGroups) ...branches];
        final selected = flat.indexOf(current);
        final theme = Theme.of(context);
        return Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 256,
                child: NavigationDrawer(
                  selectedIndex: selected < 0 ? null : selected,
                  onDestinationSelected: (i) => go(flat[i]),
                  tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(28, 20, 16, 8),
                      child: Text('YAMS Hub', style: theme.textTheme.titleLarge),
                    ),
                    for (final (label, branches) in expandedGroups) ...[
                      if (label != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(28, 16, 16, 8),
                          child: Text(label, style: theme.textTheme.titleSmall),
                        )
                      else
                        const Padding(padding: EdgeInsets.symmetric(horizontal: 28, vertical: 8), child: Divider()),
                      for (final b in branches)
                        NavigationDrawerDestination(
                          icon: icon(b, selected: false),
                          selectedIcon: icon(b, selected: true),
                          label: Text(hubDestinations[b].label),
                        ),
                    ],
                  ],
                ),
              ),
              Expanded(child: body),
            ],
          ),
        );
    }
  }
}

/// "Can't reach YAMS (tried LAN and Tailscale)" with Retry and Server
/// settings, shown while no URL of the active profile answers (APP.md §2.1).
class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(activeServerProvider);
    if (connection.status != ConnectionStatus.unreachable) return const SizedBox.shrink();
    final profile = connection.profile;
    final kinds = {for (final u in profile?.urls ?? const <Uri>[]) networkKindOf(u).label}.toList();
    final tried = kinds.isEmpty ? '' : ' (tried ${kinds.join(' and ')})';
    // Only proof failures: the hub answers but does not know this session.
    // Signing in again is the user's explicit choice (an impostor could be
    // answering, so the app never does it on its own).
    final proofOnly = connection.proofFailedOnly;
    final message = proofOnly
        ? "Can't verify ${profile?.name ?? 'the hub'}: your session may have ended"
        : "Can't reach ${profile?.name ?? 'the hub'}$tried";
    final showSettings = ref.watch(hostingModeProvider).hasServerProfiles;
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    proofOnly ? Icons.gpp_maybe_outlined : Icons.wifi_off,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      message,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
              // Wraps onto further lines on narrow phones instead of overflowing.
              OverflowBar(
                alignment: MainAxisAlignment.end,
                overflowAlignment: OverflowBarAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => ref.read(activeServerProvider.notifier).resolve(),
                    child: const Text('Retry'),
                  ),
                  if (proofOnly)
                    TextButton(
                      onPressed: () async {
                        // Captured first: the banner unmounts once the router
                        // leaves the shell for /login.
                        final auth = ref.read(authControllerProvider.notifier);
                        final server = ref.read(activeServerProvider.notifier);
                        await auth.logout();
                        await server.resolve();
                      },
                      child: const Text('Sign in again'),
                    ),
                  if (showSettings)
                    TextButton(
                      onPressed: () => context.go(AppPaths.settingsServers()),
                      child: const Text('Server settings'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
