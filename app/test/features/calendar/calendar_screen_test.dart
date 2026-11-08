import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/routing/router.dart';
import 'package:yams_hub/core/widgets/skeleton.dart';
import 'package:yams_hub/features/calendar/providers/calendar_providers.dart';
import 'package:yams_hub/features/calendar/screens/calendar_screen.dart';
import 'package:yams_hub/features/calendar/widgets/calendar_month_grid.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'calendar_samples.dart';

String _location(HubTestApp app) =>
    app.container.read(routerProvider).routerDelegate.currentConfiguration.uri.toString();

Future<HubTestApp> _pump(WidgetTester tester, FakeApi api, {Size size = phoneSize}) => pumpHubApp(
  tester,
  api: api,
  location: '/calendar',
  size: size,
  overrides: [calendarClockProvider.overrideWithValue(() => calendarTestNow)],
);

Future<void> _tapChip(WidgetTester tester, String label) async {
  final chip = find.widgetWithText(FilterChip, label);
  await tester.ensureVisible(chip);
  await tester.tap(chip);
  await settle(tester);
}

void main() {
  testWidgets('shows the agenda grouped by day with sticky headers', (tester) async {
    final api = buildCoreFakeApi();
    final windows = serveCalendar(api, sampleItems());
    await _pump(tester, api);

    expect(find.byType(CalendarScreen), findsOneWidget);
    expect(windows, [('2026-11-07', '2026-11-27')]);
    final request = api.requestsTo('/calendar').single;
    expect(request.uri.queryParameters['unmonitored'], 'true');

    expect(find.text('Yesterday · Sat 7 Nov'), findsOneWidget);
    expect(find.text('Today · Sun 8 Nov'), findsOneWidget);
    expect(find.text('Tue 10 Nov'), findsOneWidget);
    expect(find.text('The Apothecary Diaries'), findsOneWidget);
    expect(find.text('S02E07 (021) · TBA'), findsOneWidget);
    expect(find.text('Season finale'), findsOneWidget);
    expect(find.byTooltip('Downloading'), findsOneWidget);
    expect(find.byTooltip('Downloaded'), findsOneWidget);
    // Unmonitored items are hidden by default.
    expect(find.text('Frieren'), findsNothing);

    await tester.scrollUntilVisible(find.text('The Odyssey'), 200, scrollable: find.byType(Scrollable).last);
    expect(find.text('Digital'), findsOneWidget);
    expect(find.text('Digital release'), findsOneWidget);
  });

  testWidgets('filter chips hide kinds and show unmonitored items without a reload', (tester) async {
    final api = buildCoreFakeApi();
    serveCalendar(api, sampleItems());
    await _pump(tester, api);

    await _tapChip(tester, 'Show unmonitored');
    expect(find.text('Frieren'), findsOneWidget);
    expect(find.byTooltip('Not aired yet · unmonitored'), findsOneWidget);

    await _tapChip(tester, 'Episodes');
    expect(find.text('The Apothecary Diaries'), findsNothing);
    expect(find.text('The Odyssey'), findsOneWidget);

    await _tapChip(tester, 'Movies');
    expect(find.text('Nothing airing in this period'), findsOneWidget);
    expect(find.text('Turn on Episodes or Movies to see the agenda.'), findsOneWidget);
    expect(api.requestsTo('/calendar'), hasLength(1));
  });

  testWidgets('empty period offers to look further', (tester) async {
    final api = buildCoreFakeApi();
    final windows = serveCalendar(api, [movie(1, day(12, 1))]);
    await _pump(tester, api);

    expect(find.text('Nothing airing in this period'), findsOneWidget);
    await tester.tap(find.text('Look 2 weeks further'));
    await settle(tester);
    expect(windows, [('2026-11-07', '2026-11-27'), ('2026-11-28', '2026-12-11')]);
    expect(find.text('The Odyssey'), findsOneWidget);
  });

  testWidgets('loading shows a skeleton', (tester) async {
    final api = buildCoreFakeApi();
    final pending = Completer<FakeResponse>();
    api.on('GET', '/calendar', (_) => pending.future);
    await _pump(tester, api);
    expect(find.byType(SkeletonList), findsOneWidget);
    pending.complete(FakeResponse.error(503, ApiErrorCode.upstreamUnavailable));
    await settle(tester);
  });

  testWidgets('a failed first load shows the error with retry', (tester) async {
    final api = buildCoreFakeApi();
    var fail = true;
    api.on(
      'GET',
      '/calendar',
      (r) => fail
          ? FakeResponse.error(503, ApiErrorCode.upstreamUnavailable, message: 'Sonarr is not reachable.')
          : FakeResponse(
              CalendarResponse(start: day(11, 7), end: day(11, 27), items: sampleItems().take(2).toList()).toJson(),
            ),
    );
    await _pump(tester, api);
    expect(find.text('Sonarr is not reachable.'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('Retry'));
    await settle(tester);
    expect(find.text('Today · Sun 8 Nov'), findsOneWidget);
  });

  testWidgets('a failing source is called out', (tester) async {
    final api = buildCoreFakeApi();
    serveCalendar(
      api,
      sampleItems().where((i) => i.isEpisode).toList(),
      sources: const CalendarSources(
        sonarr: SectionStatus.ok(),
        radarr: SectionStatus.failure(ApiError(code: 'upstream_unavailable', message: 'x', status: 503)),
      ),
    );
    await _pump(tester, api);
    expect(find.textContaining("Radarr couldn't be loaded"), findsOneWidget);
    expect(find.text('The Apothecary Diaries'), findsOneWidget);
  });

  testWidgets('tapping a row opens the series or movie', (tester) async {
    final api = buildCoreFakeApi();
    serveCalendar(api, sampleItems());
    final app = await _pump(tester, api);
    await tester.tap(find.text('S03E07 · The Bet'));
    await settle(tester);
    expect(_location(app), '/library/tv/159');
  });

  testWidgets('scrolling to the end loads the next 2 weeks; pull to refresh refetches', (tester) async {
    final api = buildCoreFakeApi();
    final windows = serveCalendar(api, [
      ...sampleItems(),
      for (var i = 0; i < 12; i++) episode(500 + i, day(11, 20 + (i % 7)), title: 'Filler $i'),
      movie(77, day(12, 3), title: 'December Movie'),
    ]);
    await _pump(tester, api);

    await tester.fling(find.byType(CustomScrollView), const Offset(0, -4000), 3000);
    await settle(tester, frames: 20);
    expect(windows, contains(('2026-11-28', '2026-12-11')));
    await tester.scrollUntilVisible(find.text('December Movie'), 300, scrollable: find.byType(Scrollable).last);
    expect(find.text('December Movie'), findsOneWidget);

    final before = api.requestsTo('/calendar').length;
    await tester.fling(find.byType(CustomScrollView), const Offset(0, 6000), 3000);
    await settle(tester, frames: 20);
    await tester.fling(find.byType(CustomScrollView), const Offset(0, 400), 1500);
    await settle(tester, frames: 30);
    expect(api.requestsTo('/calendar').length, greaterThan(before));
  });

  testWidgets('the Today button scrolls back to today', (tester) async {
    final api = buildCoreFakeApi();
    serveCalendar(api, [
      for (var i = 0; i < 20; i++) episode(100 + i, day(11, 7), title: 'Yesterday $i', hour: 1 + i % 20),
      episode(7669, day(11, 8), title: 'Airing Today'),
      for (var i = 0; i < 20; i++) episode(300 + i, day(11, 11), title: 'Later $i'),
    ]);
    await _pump(tester, api);

    // Today is below 20 rows of yesterday.
    expect(find.text('Airing Today'), findsNothing);
    expect(find.text('Today'), findsOneWidget);
    await tester.tap(find.text('Today'));
    await settle(tester, frames: 20);
    expect(find.text('Airing Today'), findsOneWidget);
    expect(find.text('Today · Sun 8 Nov'), findsOneWidget);
    expect(find.widgetWithText(FloatingActionButton, 'Today'), findsNothing);
  });

  testWidgets('wide layout shows a month grid that jumps the agenda', (tester) async {
    final api = buildCoreFakeApi();
    final windows = serveCalendar(api, [
      ...sampleItems(),
      for (var i = 0; i < 15; i++) episode(600 + i, day(11, 9), title: 'Monday $i'),
      movie(88, day(12, 5), title: 'December Movie'),
    ]);
    await _pump(tester, api, size: tabletSize);

    expect(find.byType(CalendarMonthGrid), findsOneWidget);
    expect(find.text('November 2026'), findsOneWidget);
    expect(find.text('The Odyssey'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('calendar-day-2026-11-17')));
    await settle(tester, frames: 20);
    expect(find.text('The Odyssey'), findsOneWidget);

    await tester.tap(find.byTooltip('Next month'));
    await settle(tester);
    expect(find.text('December 2026'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('calendar-day-2026-12-05')));
    await settle(tester, frames: 20);
    expect(windows, contains(('2026-11-28', '2026-12-11')));
    expect(find.text('December Movie'), findsOneWidget);
  });

  testWidgets('rows grow with large text instead of clipping', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final api = buildCoreFakeApi();
    serveCalendar(api, sampleItems());
    await _pump(tester, api);
    expect(find.text('Today · Sun 8 Nov'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
