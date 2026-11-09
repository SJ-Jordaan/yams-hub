import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/auth/token_manager.dart';
import 'package:yams_hub/core/servers/server_connection.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/hub_image.dart';
import 'package:yams_hub/features/calendar/calendar_dashboard_card.dart';
import 'package:yams_hub/features/calendar/providers/calendar_providers.dart';
import 'package:yams_hub/features/calendar/widgets/calendar_item_tile.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import 'calendar_samples.dart';

Future<void> _pumpCard(WidgetTester tester, Section section) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeServerProvider.overrideWith(
          () => ActiveServerController(
            fixed: ServerConnection(
              status: ConnectionStatus.connected,
              profile: buildProfile(),
              baseUrl: testLanUrl,
              ping: buildPing(),
            ),
          ),
        ),
        accessTokenProvider.overrideWithValue('yha_access1'),
        calendarClockProvider.overrideWithValue(() => calendarTestNow),
      ],
      child: MaterialApp(
        theme: buildHubTheme(ColorScheme.fromSeed(seedColor: const Color(0xFF7C4DFF), brightness: Brightness.dark)),
        home: Scaffold(
          body: SingleChildScrollView(child: CalendarDashboardCard(section: section)),
        ),
      ),
    ),
  );
  await tester.pump();
}

Section _section(List<CalendarItem> items, int count) =>
    buildSection(CalendarCard(items: items, countNext7Days: count).toJson());

void main() {
  testWidgets('groups the week by Today / Tomorrow / weekday', (tester) async {
    await _pumpCard(
      tester,
      _section([
        episode(1, day(11, 8), title: 'The Apothecary Diaries'),
        episode(2, day(11, 9), title: 'The Ramparts of Ice', subtitle: 'S02E07 (021) · TBA', downloading: true),
        movie(3, day(11, 11)),
      ], 6),
    );
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Tomorrow'), findsOneWidget);
    expect(find.text('Wednesday'), findsOneWidget);
    expect(find.text('The Apothecary Diaries'), findsOneWidget);
    expect(find.text('S02E07 (021) · TBA'), findsOneWidget);
    expect(find.text('Digital'), findsOneWidget);
    expect(find.byTooltip('Downloading'), findsOneWidget);
    expect(find.text('+3 more this week'), findsOneWidget);
  });

  testWidgets('empty week', (tester) async {
    await _pumpCard(tester, _section(const [], 0));
    expect(find.text('Nothing scheduled this week'), findsOneWidget);
  });

  testWidgets('names a source that failed while the other loaded', (tester) async {
    await _pumpCard(
      tester,
      Section.ok(
        const CalendarCard(items: [], countNext7Days: 0).toJson(),
        fetchedAt: calendarTestNow.toUtc(),
        error: const ApiError(
          code: 'upstream_unavailable',
          message: 'Radarr is not reachable.',
          status: 503,
          service: ServiceId.radarr,
        ),
      ),
    );
    expect(find.text('Nothing scheduled this week'), findsOneWidget);
    expect(find.text("Radarr couldn't be loaded · its items are missing"), findsOneWidget);
  });

  testWidgets('a source refused by Allowed Hosts shows the fix instead (issue #2)', (tester) async {
    const message = "Sonarr rejects the hub's hostname 'sonarr'. In Sonarr → Settings → General → Allowed Hosts, add sonarr (or clear the list), then restart Sonarr.";
    await _pumpCard(
      tester,
      Section.ok(
        const CalendarCard(items: [], countNext7Days: 0).toJson(),
        fetchedAt: calendarTestNow.toUtc(),
        error: const ApiError(
          code: ApiErrorCode.upstreamHostRejected,
          message: message,
          status: 502,
          service: ServiceId.sonarr,
        ),
      ),
    );
    expect(find.text(message), findsOneWidget);
    expect(find.textContaining("couldn't be loaded"), findsNothing);
  });

  testWidgets('a stale card shows no failure note (the frame badges it)', (tester) async {
    await _pumpCard(
      tester,
      Section.ok(
        CalendarCard(items: [episode(1, day(11, 8))], countNext7Days: 1).toJson(),
        fetchedAt: calendarTestNow.toUtc(),
        stale: true,
        error: const ApiError(code: 'upstream_error', message: 'x', status: 502, service: ServiceId.sonarr),
      ),
    );
    expect(find.textContaining("couldn't be loaded"), findsNothing);
  });

  testWidgets('undecodable data does not crash the dashboard', (tester) async {
    await _pumpCard(
      tester,
      buildSection({
        'items': [
          {'kind': 'episode'},
        ],
        'countNext7Days': 1,
      }),
    );
    expect(find.text('Unexpected data from the hub'), findsOneWidget);
  });

  testWidgets('large text does not overflow', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpCard(
      tester,
      _section([
        episode(1, day(11, 8), title: 'The Apothecary Diaries', finaleType: 'season'),
        movie(3, day(11, 11), type: CalendarReleaseType.physical),
      ], 2),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unmonitored row dims its poster without an Opacity layer', (tester) async {
    await _pumpCard(
      tester,
      _section([
        episode(1, day(11, 8), title: 'The Apothecary Diaries'),
        episode(9001, day(11, 12), title: 'Frieren', monitored: false),
      ], 2),
    );
    expect(find.byType(Opacity), findsNothing);
    HubImage imageOf(String title) => tester.widget<HubImage>(
      find.descendant(
        of: find.ancestor(of: find.text(title), matching: find.byType(Row)).last,
        matching: find.byType(HubImage),
      ),
    );
    expect(imageOf('Frieren').opacity, calendarDimmedOpacity);
    expect(imageOf('The Apothecary Diaries').opacity, 1);
  });

  testWidgets('an unmonitored agenda tile dims its poster without an Opacity layer', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeServerProvider.overrideWith(
            () => ActiveServerController(
              fixed: ServerConnection(status: ConnectionStatus.connected, baseUrl: testLanUrl),
            ),
          ),
          accessTokenProvider.overrideWithValue('yha_access1'),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                CalendarItemTile(
                  item: episode(9001, day(11, 12), title: 'Frieren', monitored: false),
                  now: calendarTestNow,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.descendant(of: find.byType(CalendarItemTile), matching: find.byType(Opacity)), findsNothing);
    expect(tester.widget<HubImage>(find.byType(HubImage)).opacity, calendarDimmedOpacity);
  });
}
