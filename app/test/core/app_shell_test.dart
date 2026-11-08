import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/routing/nav_badges.dart';
import 'package:yams_hub/core/routing/router.dart';
import 'package:yams_hub/core/servers/server_connection.dart';
import 'package:yams_hub/core/servers/server_resolver.dart';
import 'package:yams_hub/core/settings/app_settings.dart';
import 'package:yams_models/yams_models.dart';

import '../support/builders.dart';
import '../support/fake_api.dart';
import '../support/pump_hub_app.dart';

String location(HubTestApp app) =>
    app.container.read(routerProvider).routerDelegate.currentConfiguration.uri.toString();

void main() {
  testWidgets('dashboard: alerts, cards in their states, web apps', (tester) async {
    final api = buildCoreFakeApi(
      alerts: [
        buildAlert(id: 'seerr.pending', severity: AlertSeverity.info, title: '3 requests waiting', route: '/requests/list?tab=pending', feature: 'requests'),
        buildAlert(id: 'vpn.down', title: 'VPN down'),
      ],
    );
    await pumpHubApp(tester, api: api);

    expect(find.text('VPN down'), findsOneWidget);
    expect(find.text('3 requests waiting'), findsOneWidget);
    // Feature card frames.
    expect(find.text('System'), findsWidgets);
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.text('Not configured on the hub'), findsOneWidget); // library: disabled
    await tester.scrollUntilVisible(find.text('Web apps'), 300);
    expect(find.text('Web apps'), findsOneWidget);
    expect(find.text('Jellyfin'), findsOneWidget);
    // One full dashboard request (no ?cards=).
    expect(api.requestsTo('/dashboard').first.uri.queryParameters.containsKey('cards'), isFalse);
  });

  testWidgets('tapping an alert opens its route', (tester) async {
    final api = buildCoreFakeApi(alerts: [buildAlert(id: 'vpn.down', title: 'VPN down', route: '/activity?tab=queue')]);
    final app = await pumpHubApp(tester, api: api);
    await tester.tap(find.text('VPN down'));
    await settle(tester);
    expect(location(app), '/activity?tab=queue');
    expect(find.text('Activity'), findsWidgets);
  });

  testWidgets('dismissing an alert hides it and remembers it per device', (tester) async {
    final api = buildCoreFakeApi(
      alerts: [buildAlert(id: 'raid.noRedundancy', severity: AlertSeverity.info, title: 'Storage is RAID0', dismissible: true)],
    );
    final app = await pumpHubApp(tester, api: api);
    expect(find.text('Storage is RAID0'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss'));
    await settle(tester);
    expect(find.text('Storage is RAID0'), findsNothing);
    expect(app.container.read(appSettingsProvider).dismissedAlerts, contains('raid.noRedundancy'));
  });

  testWidgets('phone layout: bottom bar with badges for admins', (tester) async {
    await pumpHubApp(tester);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    for (final label in ['Home', 'Requests', 'Library', 'Activity', 'More']) {
      expect(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)), findsOneWidget);
    }
    // Seeded from the dashboard: pending requests (admin) and activity attention.
    expect(find.descendant(of: find.byType(NavigationBar), matching: find.text('3')), findsOneWidget);
    expect(find.descendant(of: find.byType(NavigationBar), matching: find.text('2')), findsOneWidget);
  });

  testWidgets('members get no pending-requests badge', (tester) async {
    await pumpHubApp(tester, role: Role.member);
    expect(find.descendant(of: find.byType(NavigationBar), matching: find.text('3')), findsNothing);
    expect(find.descendant(of: find.byType(NavigationBar), matching: find.text('2')), findsOneWidget);
  });

  testWidgets('tablet layout: rail with every destination except More', (tester) async {
    await pumpHubApp(tester, size: tabletSize);
    expect(find.byType(NavigationRail), findsOneWidget);
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.destinations, hasLength(11));
  });

  testWidgets('desktop layout: grouped side navigation', (tester) async {
    await pumpHubApp(tester, size: desktopSize);
    expect(find.byType(NavigationDrawer), findsOneWidget);
    for (final group in ['Overview', 'Downloads', 'Server']) {
      expect(find.descendant(of: find.byType(NavigationDrawer), matching: find.text(group)), findsOneWidget);
    }
    // "Media" is both a group header and a destination.
    expect(find.descendant(of: find.byType(NavigationDrawer), matching: find.text('Media')), findsNWidgets(2));
    expect(find.byType(NavigationDrawerDestination), findsNWidgets(11));
  });

  testWidgets('More lists the other destinations with live counts', (tester) async {
    final app = await pumpHubApp(tester);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('More')));
    await settle(tester);
    expect(location(app), '/more');
    expect(find.text('6 releases this week'), findsOneWidget);
    expect(find.text('21 running'), findsOneWidget);
    expect(find.text('1 failing'), findsOneWidget);
    expect(find.text('111 missing'), findsOneWidget);
    expect(find.text('13 apps · 12 up'), findsOneWidget);
    await tester.tap(find.text('Containers'));
    await settle(tester);
    expect(location(app), '/containers');
  });

  testWidgets('the badge poller asks for the six badge cards', (tester) async {
    final app = await pumpHubApp(tester, location: '/more');
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    final polls = app.api.requestsTo('/dashboard').where((r) => r.uri.queryParameters.containsKey('cards'));
    expect(polls, isNotEmpty);
    expect(polls.first.uri.queryParameters['cards'], 'requests,activity,calendar,containers,indexers,subtitles');
  });

  group('badges while Home is visible', () {
    /// Serves only the cards asked for; the badge poll gets [pending].
    FakeApi filteringApi(int Function() pending) {
      final api = buildCoreFakeApi();
      api.on('GET', '/dashboard', (r) {
        final keys = r.uri.queryParameters['cards']?.split(',');
        final all = buildDashboardJson(cards: rawCards(pending: pending()));
        final cards = (all['cards']! as Map<String, Object?>);
        return FakeResponse({
          ...all,
          'cards': keys == null ? cards : {for (final k in keys) if (cards.containsKey(k)) k: cards[k]},
        });
      });
      return api;
    }

    bool isBadgePoll(Uri uri) => uri.queryParameters['cards'] == NavBadges.cardKeys.join(',');

    testWidgets('a hidden badge card is still polled and its badge updates', (tester) async {
      var pending = 3;
      final api = filteringApi(() => pending);
      final app = await pumpHubApp(
        tester,
        api: api,
        location: '/home',
        prefsValues: {AppSettingsController.storageKey: '{"hiddenCards": ["requests"]}'},
      );
      await settle(tester);
      final full = api.requestsTo('/dashboard').where((r) => !isBadgePoll(r.uri)).first;
      expect(full.uri.queryParameters['cards'], isNot(contains('requests')));

      pending = 9;
      // Several fast (5 s) and full (15 s) dashboard refreshes seed the
      // badges meanwhile; none of them carries the requests card.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 5));
      }
      await settle(tester);
      expect(api.requestsTo('/dashboard').where((r) => isBadgePoll(r.uri)), isNotEmpty);
      expect(app.container.read(navBadgesProvider).requestsPending, 9);
    });

    testWidgets('no extra badge poll when the dashboard carries every badge card', (tester) async {
      final api = filteringApi(() => 3);
      await pumpHubApp(tester, api: api, location: '/home');
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 5));
      }
      await settle(tester);
      expect(api.requestsTo('/dashboard').where((r) => isBadgePoll(r.uri)), isEmpty);
    });
  });

  testWidgets('admin-only routes send members to the parent with "Admins only"', (tester) async {
    final app = await pumpHubApp(tester, role: Role.member, location: '/library/add');
    expect(location(app), '/library');
    expect(find.text('Admins only'), findsOneWidget);
  });

  testWidgets('admins reach admin-only routes', (tester) async {
    final app = await pumpHubApp(tester, location: '/containers/sonarr/logs');
    expect(location(app), '/containers/sonarr/logs');
    expect(find.textContaining('Logs'), findsWidgets);
  });

  testWidgets('web apps screen', (tester) async {
    final app = await pumpHubApp(tester, location: '/home/apps', size: desktopSize);
    expect(location(app), '/home/apps');
    for (final group in ['Media', 'Automation', 'Downloads', 'System']) {
      expect(find.text(group), findsWidgets);
    }
    expect(find.text('Portainer'), findsOneWidget);
  });

  testWidgets('hidden launcher apps are left out', (tester) async {
    await pumpHubApp(
      tester,
      location: '/home/apps',
      prefsValues: {
        AppSettingsController.storageKey: '{"hiddenLauncherApps": ["portainer", "jellystat"]}',
      },
    );
    expect(find.text('Portainer'), findsNothing);
    expect(find.text('Jellystat'), findsNothing);
    expect(find.text('Sonarr'), findsOneWidget);
  });

  testWidgets('unreachable server: offline banner with retry', (tester) async {
    final profile = buildProfile();
    await pumpHubApp(
      tester,
      profile: profile,
      connection: ServerConnection(status: ConnectionStatus.unreachable, profile: profile),
    );
    expect(find.text("Can't reach Zenith (tried LAN and Tailscale)"), findsOneWidget);
    expect(find.text('Retry'), findsWidgets);
  });

  testWidgets('only server-proof failures: the banner offers signing in again', (tester) async {
    final profile = buildProfile();
    await pumpHubApp(
      tester,
      profile: profile,
      connection: ServerConnection(
        status: ConnectionStatus.unreachable,
        profile: profile,
        failures: {for (final u in profile.urls) u: ServerResolver.proofFailedMessage},
      ),
    );
    expect(find.text("Can't verify Zenith: your session may have ended"), findsOneWidget);
    expect(find.text('Sign in again'), findsOneWidget);
  });

  testWidgets('dashboard failure without data shows the error view', (tester) async {
    final api = buildCoreFakeApi()
      ..on('GET', '/dashboard', (_) => FakeResponse.error(500, ApiErrorCode.internal, message: 'Boom'));
    await pumpHubApp(tester, api: api);
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Server settings'), findsOneWidget);
  });

  testWidgets('unknown routes show the not-found screen', (tester) async {
    final app = await pumpHubApp(tester);
    app.container.read(routerProvider).go('/definitely/not/here');
    await settle(tester);
    expect(find.text('Page not found'), findsOneWidget);
    expect(find.byType(GoRouter), findsNothing);
  });
}
