import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/settings/app_settings.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import '../../support/pump_hub_app.dart';
import 'settings_fixtures.dart';

AppSettings settingsOf(HubTestApp app) => app.container.read(appSettingsProvider);

void main() {
  group('appearance', () {
    testWidgets('theme mode, accent and density are stored', (tester) async {
      final app = await pumpHubApp(tester, location: '/settings/appearance');
      await tester.tap(find.text('Light'));
      await tester.pump();
      expect(settingsOf(app).themeMode, ThemeMode.light);

      await tester.tap(find.byKey(const Key('seed-Teal')));
      await tester.pump();
      expect(settingsOf(app).seedColor, accentSeeds[2].toARGB32());

      await tester.tap(find.text('Compact'));
      await tester.pump();
      expect(settingsOf(app).listDensity, ListDensity.compact);
      expect(app.prefs.getString(AppSettingsController.storageKey), contains('"themeMode":"light"'));
    });

    testWidgets('dynamic color switch on Android', (tester) async {
      final app = await pumpHubApp(tester, location: '/settings/appearance');
      final toggle = find.byKey(const Key('appearance-dynamic-color'));
      expect(toggle, findsOneWidget);
      final before = settingsOf(app).dynamicColor;
      await tester.tap(toggle);
      await tester.pump();
      expect(settingsOf(app).dynamicColor, !before);
    });

    testWidgets('dashboard cards can be hidden and reset', (tester) async {
      final app = await pumpHubApp(tester, location: '/settings/appearance');
      final check = find.byKey(const Key('card-check-${DashboardCardKeys.calendar}'));
      await scrollToCenter(tester, check);
      await tester.tap(check);
      await tester.pump();
      expect(settingsOf(app).hiddenCards, {DashboardCardKeys.calendar});
      expect(settingsOf(app).visibleCards, isNot(contains(DashboardCardKeys.calendar)));

      final reset = find.text('Reset cards');
      await scrollToCenter(tester, reset);
      await tester.tap(reset);
      await tester.pump();
      expect(settingsOf(app).hiddenCards, isEmpty);
    });

    testWidgets('cards reorder by dragging the handle', (tester) async {
      final app = await pumpHubApp(tester, location: '/settings/appearance');
      final systemTile = find.byKey(const ValueKey('card-${DashboardCardKeys.system}'));
      await scrollToCenter(tester, systemTile);
      await tester.pumpAndSettle();
      final handle = find.descendant(of: systemTile, matching: find.byIcon(Icons.drag_handle));
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveBy(const Offset(0, 140));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();
      final order = settingsOf(app).orderedCards;
      expect(order.first, isNot(DashboardCardKeys.system));
      expect(order.indexOf(DashboardCardKeys.system), greaterThan(0));
    });

    testWidgets('web apps checklist writes hiddenLauncherApps', (tester) async {
      final app = await pumpHubApp(tester, location: '/settings/appearance');
      final portainer = find.byKey(const Key('launcher-app-portainer'));
      await scrollToCenter(tester, portainer);
      await tester.tap(portainer);
      await tester.pump();
      expect(settingsOf(app).hiddenLauncherApps, {ExternalApp.portainer});

      await tester.tap(portainer);
      await tester.pump();
      expect(settingsOf(app).hiddenLauncherApps, isEmpty);
    });
  });

  group('refresh', () {
    testWidgets('choosing a preset updates the interval table', (tester) async {
      final app = await pumpHubApp(tester, location: '/settings/refresh');
      expect(find.text('Every 15 s'), findsOneWidget);

      await tester.tap(find.byKey(const Key('preset-batterySaver')));
      await tester.pump();
      expect(settingsOf(app).refreshPreset, RefreshPreset.batterySaver);
      await scrollToCenter(tester, find.text('Every 45 s'));
      expect(find.text('Intervals (Battery saver)'), findsOneWidget);

      await scrollToCenter(tester, find.byKey(const Key('preset-manual')), delta: -200);
      await tester.tap(find.byKey(const Key('preset-manual')));
      await tester.pump();
      await scrollToCenter(tester, find.byKey(const Key('refresh-table')));
      expect(find.text('Pull to refresh'), findsNWidgets(refreshRowsCount));
    });

    testWidgets('refresh on resume can be turned off', (tester) async {
      final app = await pumpHubApp(tester, location: '/settings/refresh');
      await tester.tap(find.byKey(const Key('refresh-on-resume')));
      await tester.pump();
      expect(settingsOf(app).refreshOnResume, isFalse);
    });
  });

  group('media apps', () {
    testWidgets('lists every app with its derived address', (tester) async {
      await pumpHubApp(tester, location: '/settings/apps');
      expect(find.text('http://192.168.10.183:8096'), findsOneWidget);
      await scrollToCenter(tester, find.byKey(const Key('media-app-portainer')));
      expect(find.text('http://192.168.10.183:9000'), findsOneWidget);
    });

    testWidgets('an override and a scheme are saved; invalid input is rejected', (tester) async {
      final app = await pumpHubApp(tester, location: '/settings/apps');
      await tester.tap(find.byKey(const Key('media-app-jellyfin')));
      await settle(tester);
      expect(find.text('Leave empty for http://192.168.10.183:8096'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('app-base-url')), 'ftp://nas');
      await tester.tap(find.byKey(const Key('app-save')));
      await tester.pump();
      expect(find.textContaining('Enter an http(s) address'), findsOneWidget);
      expect(settingsOf(app).externalBaseUrls, isEmpty);

      await tester.enterText(find.byKey(const Key('app-base-url')), 'http://jellyfin.example.ts.net:8096');
      await tester.enterText(find.byKey(const Key('app-scheme')), 'jellyfin://');
      await tester.pump();
      expect(find.text('Test app'), findsOneWidget);
      await tester.tap(find.byKey(const Key('app-save')));
      await settle(tester);

      expect(settingsOf(app).externalBaseUrls, {ExternalApp.jellyfin: 'http://jellyfin.example.ts.net:8096'});
      expect(settingsOf(app).appSchemes, {ExternalApp.jellyfin: 'jellyfin://'});
      expect(find.text('http://jellyfin.example.ts.net:8096 · app link jellyfin://'), findsOneWidget);
      expect(find.text('Custom'), findsOneWidget);
    });

    testWidgets('admin web UIs have no scheme field', (tester) async {
      await pumpHubApp(tester, location: '/settings/apps');
      await tester.tap(find.byKey(const Key('media-app-sonarr')));
      await settle(tester);
      expect(find.byKey(const Key('app-base-url')), findsOneWidget);
      expect(find.byKey(const Key('app-scheme')), findsNothing);
    });
  });

  group('about', () {
    testWidgets('versions, health, addresses and the Tailscale note', (tester) async {
      await pumpHubApp(tester, api: settingsFakeApi(), location: '/settings/about');
      expect(find.text('1.0.0'), findsWidgets);
      expect(find.text('v1'), findsOneWidget);
      expect(find.text(testInstanceId), findsOneWidget);
      expect(find.byKey(const Key('about-health-overall')), findsOneWidget);
      expect(find.textContaining('services up'), findsOneWidget);

      await scrollToCenter(tester, find.text('On untrusted Wi-Fi, use the Tailscale URL'));
      expect(find.byKey(Key('about-url-$testLanUrl')), findsOneWidget);
      expect(find.byKey(Key('about-url-$testTailscaleUrl')), findsOneWidget);
      expect(find.text('Tailscale'), findsOneWidget);
      expect(find.byKey(const Key('about-licenses')), findsOneWidget);
    });

    testWidgets('a degraded service is listed with its message', (tester) async {
      final api = settingsFakeApi()
        ..getJson('/health', buildHealth(down: {ServiceId.kavita}).toJson());
      await pumpHubApp(tester, api: api, location: '/settings/about');
      expect(find.text('Kavita'), findsOneWidget);
      expect(find.text('Down'), findsOneWidget);
    });
  });
}

/// Rows of the interval table (APP.md §14).
const refreshRowsCount = 11;
