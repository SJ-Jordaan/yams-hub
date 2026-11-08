import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/auth/token_manager.dart';
import 'package:yams_hub/core/servers/server_connection.dart';
import 'package:yams_hub/core/widgets/hub_image.dart';
import 'package:yams_hub/features/library/screens/library_screen.dart';
import 'package:yams_hub/features/library/widgets/library_tiles.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'library_test_data.dart';

void main() {
  group('local filters', () {
    test('series filters, diacritics-insensitive search and sorts', () {
      final all = buildSeriesList();
      List<int> ids(List<SeriesSummary> l) => [for (final s in l) s.id];
      expect(ids(applySeriesView(all, filter: SeriesFilter.anime)), [25, 54]);
      expect(ids(applySeriesView(all, filter: SeriesFilter.missing, sort: SeriesSort.missing)), [54, 61, 2]);
      expect(ids(applySeriesView(all, filter: SeriesFilter.ended)), [61]);
      expect(ids(applySeriesView(all, q: 'FRÏEREN')), [25]);
      expect(ids(applySeriesView(all)), [2, 25, 61, 54]);
    });

    test('movie filters follow the gateway rules', () {
      final all = buildMovieList();
      List<int> ids(List<MovieSummary> l) => [for (final m in l) m.id];
      expect(ids(applyMovieView(all, filter: MovieFilter.missing)), [227]);
      expect(ids(applyMovieView(all, filter: MovieFilter.unreleased)), [246]);
      expect(ids(applyMovieView(all, filter: MovieFilter.available)), [1]);
    });
  });

  testWidgets('TV tab: header, poster grid with badges, filters', (tester) async {
    final api = buildLibraryFakeApi();
    await pumpHubApp(tester, api: api, location: '/library');

    expect(find.text('Library'), findsWidgets);
    expect(find.textContaining('4 series · 892 missing'), findsOneWidget);
    expect(find.byType(SeriesGridTile), findsNWidgets(4));
    // Missing badge on Slime (96 - 48).
    expect(find.text('48'), findsOneWidget);
    expect(find.text('Add series'), findsOneWidget, reason: 'admin FAB');

    await tester.ensureVisible(find.widgetWithText(FilterChip, 'Anime'));
    await tester.tap(find.widgetWithText(FilterChip, 'Anime'));
    await settle(tester);
    expect(find.byType(SeriesGridTile), findsNWidgets(2));

    await tester.enterText(find.byType(TextField).first, 'zzz');
    await settle(tester);
    expect(find.text('No series match these filters'), findsOneWidget);
    await tester.tap(find.text('Clear filters'));
    await settle(tester);
    expect(find.byType(SeriesGridTile), findsNWidgets(4));
    expect(api.requestsTo('/library/tv'), hasLength(1), reason: 'filtering is local');
  });

  testWidgets('the grid/list choice is remembered', (tester) async {
    final app = await pumpHubApp(tester, api: buildLibraryFakeApi(), location: '/library');
    await tester.tap(find.byTooltip('Show as list'));
    await settle(tester);
    expect(find.byType(SeriesListRow), findsNWidgets(4));
    expect(app.prefs.getString('library.viewMode'), 'list');
  });

  testWidgets('Movies tab with the missing filter', (tester) async {
    await pumpHubApp(tester, api: buildLibraryFakeApi(), location: '/library?tab=movies');
    expect(find.byType(MovieGridTile), findsNWidgets(3));
    expect(find.text('Not released'), findsOneWidget);
    expect(find.text('Add movie'), findsOneWidget);
    await tester.ensureVisible(find.widgetWithText(FilterChip, 'Missing'));
    await tester.tap(find.widgetWithText(FilterChip, 'Missing'));
    await settle(tester);
    expect(find.byType(MovieGridTile), findsOneWidget);
    expect(find.text('Winnie the Pooh: Seasons of Giving'), findsOneWidget);
  });

  testWidgets('members get no add button', (tester) async {
    await pumpHubApp(
      tester,
      api: buildLibraryFakeApi(role: Role.member),
      role: Role.member,
      location: '/library',
    );
    expect(find.byType(SeriesGridTile), findsNWidgets(4));
    expect(find.text('Add series'), findsNothing);
  });

  testWidgets('empty library and failed first load', (tester) async {
    final api = buildLibraryFakeApi()
      ..getJson('/library/tv', {'items': <Object>[]})
      ..on(
        'GET',
        '/library/movies',
        (_) => FakeResponse.error(503, ApiErrorCode.upstreamUnavailable, message: 'Radarr is not reachable.'),
      );
    await pumpHubApp(tester, api: api, location: '/library');
    expect(find.text('No series yet'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Add series'), findsOneWidget);

    await tester.tap(find.text('Movies'));
    await settle(tester);
    expect(find.textContaining('Radarr is not reachable.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('health icon opens the health sheet', (tester) async {
    await pumpHubApp(tester, api: buildLibraryFakeApi(), location: '/library');
    await tester.tap(find.byTooltip('1 health warning').first);
    await settle(tester);
    expect(find.text('Sonarr health'), findsOneWidget);
    expect(find.text('Allowed Hosts is not configured'), findsOneWidget);
  });

  testWidgets('tapping a tile opens the series', (tester) async {
    await pumpHubApp(tester, api: buildLibraryFakeApi(), location: '/library');
    await tester.tap(find.text('That Time I Got Reincarnated as a Slime'));
    await settle(tester);
    expect(find.text('Seasons'), findsOneWidget);
  });

  group('unmonitored dimming', () {
    Future<void> pumpTiles(WidgetTester tester, List<Widget> children) => tester.pumpWidget(
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
          home: Scaffold(body: SingleChildScrollView(child: Column(children: children))),
        ),
      ),
    );

    testWidgets('poster tiles and list rows dim the image, not with an Opacity layer', (tester) async {
      await pumpTiles(tester, [
        SizedBox(width: 150, height: 260, child: SeriesGridTile(series: buildSeries(monitored: false))),
        SizedBox(width: 150, height: 260, child: MovieGridTile(movie: buildMovie(monitored: false))),
        SeriesListRow(series: buildSeries(id: 2, monitored: false)),
        MovieListRow(movie: buildMovie(id: 2, monitored: false)),
        SeriesListRow(series: buildSeries(id: 3)),
      ]);
      expect(find.descendant(of: find.byType(SingleChildScrollView), matching: find.byType(Opacity)), findsNothing);
      final opacities = [for (final i in tester.widgetList<HubImage>(find.byType(HubImage))) i.opacity];
      expect(opacities, [.45, .45, .45, .45, 1]);
    });
  });
}
