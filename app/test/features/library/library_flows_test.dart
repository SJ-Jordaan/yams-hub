import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/features/library/library_dashboard_card.dart';
import 'package:yams_hub/features/library/widgets/library_widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'library_test_data.dart';

Object? _body(RequestOptions r) => r.data is String ? jsonDecode(r.data as String) : r.data;

/// A paged wanted answer: [items] on page 1, nothing after, [total] rows.
FakeHandler _wantedPage(List<WantedItem> items, {int? total}) => (r) {
  final page = int.tryParse('${r.queryParameters['page'] ?? 1}') ?? 1;
  final size = int.tryParse('${r.queryParameters['pageSize'] ?? 25}') ?? 25;
  return FakeResponse(
    PagedList.of(
      items: page == 1 ? items.take(size).toList() : const <WantedItem>[],
      page: page,
      pageSize: size,
      total: total ?? items.length,
    ).toJson((w) => w.toJson()),
  );
};

void main() {
  group('Wanted tab', () {
    final rows = [
      WantedItem(
        service: ArrService.sonarr,
        id: 7110,
        seriesId: 38,
        title: "It's Always Sunny in Philadelphia",
        episodeLabel: 'S18E08',
        episodeTitle: 'Mac and Dennis Tear Their ACLs',
        airDateUtc: DateTime.utc(2026, 9, 29, 2),
        monitored: true,
      ),
      WantedItem(
        service: ArrService.sonarr,
        id: 7111,
        seriesId: 38,
        title: "It's Always Sunny in Philadelphia",
        episodeLabel: 'S18E07',
        monitored: true,
        lastSearchTime: testNow,
      ),
    ];

    testWidgets('rows, long-press multi-select and "Search selected"', (tester) async {
      final api = buildLibraryFakeApi()
        ..on('GET', '/library/wanted/missing', _wantedPage(rows))
        ..on(
          'POST',
          '/library/wanted/search',
          (_) => FakeResponse(buildCommandJson(name: 'EpisodeSearch'), status: 202),
        );
      await pumpHubApp(tester, api: api, location: '/library?tab=wanted');
      expect(find.textContaining('S18E08 · Mac and Dennis'), findsOneWidget);
      expect(find.textContaining('Never searched'), findsOneWidget);
      expect(find.text('Search all'), findsNothing, reason: 'global search is off by policy');
      expect(api.requestsTo('/library/wanted/missing').single.uri.queryParameters['service'], 'sonarr');

      await tester.longPress(find.textContaining('S18E08'));
      await settle(tester);
      await tester.tap(find.textContaining('S18E07'));
      await settle(tester);
      expect(find.text('2 selected'), findsOneWidget);
      await tester.tap(find.text('Search selected'));
      await settle(tester);
      expect(_body(api.requestsTo('/library/wanted/search').single), {
        'service': 'sonarr',
        'ids': [7110, 7111],
      });
      expect(find.text('Search 2 episodes started'), findsOneWidget);
      expect(find.text('2 selected'), findsNothing);
    });

    testWidgets('Radarr cutoff rows and the typed "search all"', (tester) async {
      final api = buildLibraryFakeApi(allowGlobalSearch: true)
        ..on(
          'GET',
          '/library/wanted/cutoff',
          _wantedPage([
            const WantedItem(
              service: ArrService.radarr,
              id: 1,
              title: 'Zootopia 2',
              year: 2025,
              releaseDate: '2026-01-26',
              monitored: true,
              currentQuality: 'WEBRip-1080p',
              cutoffQuality: 'Bluray-1080p',
            ),
          ], total: 139),
        )
        ..on('GET', '/library/wanted/missing', _wantedPage(const []))
        ..on(
          'POST',
          '/library/wanted/search-all',
          (_) => FakeResponse(buildCommandJson(name: 'CutoffUnmetMoviesSearch'), status: 202),
        );
      await pumpHubApp(tester, api: api, location: '/library?tab=wanted');
      expect(find.text('Nothing missing'), findsOneWidget);
      await tester.tap(find.text('Radarr'));
      await settle(tester);
      await tester.tap(find.text('Cutoff unmet'));
      await settle(tester);
      expect(find.textContaining('WEBRip-1080p → Bluray-1080p'), findsOneWidget);

      await tester.tap(find.text('Search all'));
      await settle(tester);
      expect(find.textContaining('139 movies'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'SEARCH');
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Search all'));
      await settle(tester);
      expect(_body(api.requestsTo('/library/wanted/search-all').single), {
        'service': 'radarr',
        'kind': 'cutoff',
        'confirm': true,
      });
    });
  });

  group('Add new', () {
    final lookups = [
      const SeriesLookup(
        tvdbId: 424536,
        title: "Frieren: Beyond Journey's End",
        year: 2023,
        status: 'continuing',
        network: 'Nippon TV',
        isAnime: true,
        inLibrary: true,
        libraryId: 25,
        suggested: SeriesLookupSuggestion(
          seriesType: LibrarySeriesType.anime,
          qualityProfileId: 7,
          rootFolderPath: '/data/tvshows',
        ),
      ),
      const SeriesLookup(
        tvdbId: 391612,
        title: 'Labyrinth of Peace',
        year: 2020,
        status: 'ended',
        overview: 'Switzerland, 1945.',
        suggested: SeriesLookupSuggestion(
          seriesType: LibrarySeriesType.standard,
          qualityProfileId: 9,
          rootFolderPath: '/data/tvshows',
        ),
      ),
    ];

    testWidgets('lookup, in-library chip, add sheet with defaults, POST', (tester) async {
      final api = buildLibraryFakeApi()
        ..getJson('/library/tv/lookup', {
          'items': [for (final l in lookups) l.toJson()],
        })
        ..on(
          'POST',
          '/library/tv',
          (_) => FakeResponse(buildSeries(id: 54, title: 'Labyrinth of Peace', anime: false).toJson(), status: 201),
        );
      await pumpHubApp(tester, api: api, location: '/library/add?kind=tv&term=peace');
      expect(api.requestsTo('/library/tv/lookup').single.uri.queryParameters['term'], 'peace');
      expect(find.text('In library'), findsOneWidget);
      await tester.tap(find.textContaining('Labyrinth of Peace'));
      await settle(tester);

      expect(find.text('Add Labyrinth of Peace (2020)'), findsOneWidget);
      expect(find.text('WEB-1080p'), findsOneWidget, reason: 'suggested profile preselected');
      expect(find.textContaining('/data/tvshows'), findsOneWidget);
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Add'));
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await settle(tester);
      expect(_body(api.requestsTo('/library/tv', method: 'POST').single), {
        'tvdbId': 391612,
        'qualityProfileId': 9,
        'rootFolderPath': '/data/tvshows',
        'seriesType': 'standard',
        'seasonFolder': true,
        'monitor': 'all',
        'monitorNewItems': 'all',
        'searchForMissing': true,
        'searchForCutoffUnmet': false,
      });
      expect(find.text('Seasons'), findsOneWidget, reason: 'navigated to the new series');
    });

    testWidgets('already_exists offers to open the existing item', (tester) async {
      final api = buildLibraryFakeApi()
        ..getJson('/library/tv/lookup', {
          'items': [lookups.last.toJson()],
        })
        ..on(
          'POST',
          '/library/tv',
          (_) =>
              FakeResponse.error(409, ApiErrorCode.alreadyExists, message: 'Already there', details: {'libraryId': 54}),
        );
      await pumpHubApp(tester, api: api, location: '/library/add?kind=tv&term=peace');
      await tester.tap(find.textContaining('Labyrinth of Peace'));
      await settle(tester);
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Add'));
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await settle(tester);
      expect(find.text('Already in your library'), findsOneWidget);
      await tester.tap(find.text('Open'));
      await settle(tester);
      expect(find.text('Seasons'), findsOneWidget);
    });

    testWidgets('no results', (tester) async {
      final api = buildLibraryFakeApi()..getJson('/library/movies/lookup', {'items': <Object>[]});
      await pumpHubApp(tester, api: api, location: '/library/add?kind=movie&term=qwerty');
      expect(find.text("Nothing found for 'qwerty'"), findsOneWidget);
      expect(find.text('Add movie'), findsOneWidget);
    });

    testWidgets('members are sent back to the library', (tester) async {
      await pumpHubApp(
        tester,
        api: buildLibraryFakeApi(role: Role.member),
        role: Role.member,
        location: '/library/add?kind=tv',
      );
      expect(find.text('Find a series to add'), findsNothing);
      expect(find.text('Library'), findsWidgets);
    });
  });

  group('Movie detail', () {
    testWidgets('dates, file card, queue progress, actions', (tester) async {
      final api = buildLibraryFakeApi()
        ..getJson(
          '/library/movies/1',
          MovieDetail(
            movie: buildMovie().copyWithMonitored(true),
            overview: 'Judy and Nick are back.',
            files: [
              const MediaFileInfo(
                id: 947,
                relativePath: 'Zootopia 2 (2025) - [WEBRip-1080p].mkv',
                sizeBytes: 2561322154,
                quality: QualityInfo(name: 'WEBRip-1080p'),
                cutoffNotMet: true,
                customFormatScore: -10000,
              ),
            ],
            queue: const EpisodeQueueState(
              status: 'downloading',
              trackedState: 'downloading',
              progress: 0.5,
              etaSeconds: 600,
            ),
            youTubeTrailerId: 'sEgPQ7HKoBA',
          ).toJson(),
        )
        ..getJson(
          '/library/movies/1/history',
          PagedList<ArrHistoryItem>.of(items: const [], page: 1, pageSize: 5, total: 0).toJson((i) => i.toJson()),
        )
        ..on(
          'POST',
          '/library/movies/1/search',
          (_) => FakeResponse(buildCommandJson(name: 'MoviesSearch'), status: 202),
        );
      await pumpHubApp(tester, api: api, location: '/library/movies/1');
      expect(find.text('Zootopia 2'), findsWidgets);
      expect(find.text('Downloaded'), findsOneWidget);
      expect(find.textContaining('Downloading'), findsOneWidget);
      expect(find.text('Trailer'), findsOneWidget);
      expect(find.text('Choose release'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Search'));
      await settle(tester);
      expect(api.requestsTo('/library/movies/1/search'), hasLength(1));
      await tester.scrollUntilVisible(
        find.textContaining('Zootopia 2 (2025) - [WEBRip-1080p].mkv'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('Zootopia 2 (2025) - [WEBRip-1080p].mkv'), findsOneWidget);
      expect(find.textContaining('Below the quality cutoff'), findsOneWidget);
    });

    testWidgets('choose release searches Radarr and grabs', (tester) async {
      final api = buildLibraryFakeApi()
        ..getJson('/library/movies/1', MovieDetail(movie: buildMovie()).toJson())
        ..getJson(
          '/library/movies/1/history',
          PagedList<ArrHistoryItem>.of(items: const [], page: 1, pageSize: 5, total: 0).toJson((i) => i.toJson()),
        )
        ..getJson(
          '/library/movies/1/releases',
          ReleaseChoiceList(
            items: [buildRelease(id: 'rl_m', title: 'Zootopia.2.2025.1080p.BluRay.x264-GRP')],
            tookMs: 9000,
          ).toJson(),
        )
        ..on(
          'POST',
          '/library/releases/grab',
          (_) => const FakeResponse({'ok': true, 'title': 'Zootopia.2.2025.1080p.BluRay.x264-GRP'}, status: 201),
        );
      await pumpHubApp(tester, api: api, location: '/library/movies/1');
      await tester.tap(find.text('Choose release'));
      await settle(tester);
      expect(api.requestsTo('/library/movies/1/releases'), hasLength(1));
      expect(find.textContaining('1 releases · 1 approved · 9.0 s'), findsOneWidget);
      await tester.tap(find.text('Zootopia.2.2025.1080p.BluRay.x264-GRP'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Grab'));
      await settle(tester);
      expect(_body(api.requestsTo('/library/releases/grab').single), {'releaseId': 'rl_m'});
      expect(find.text('Sent to qBittorrent via Radarr'), findsOneWidget);
    });

    testWidgets('a second concurrent search shows the gateway message', (tester) async {
      final api = buildLibraryFakeApi()
        ..getJson('/library/movies/1', MovieDetail(movie: buildMovie()).toJson())
        ..getJson(
          '/library/movies/1/history',
          PagedList<ArrHistoryItem>.of(items: const [], page: 1, pageSize: 5, total: 0).toJson((i) => i.toJson()),
        )
        ..on(
          'GET',
          '/library/movies/1/releases',
          (_) => FakeResponse.error(
            409,
            ApiErrorCode.jobRunning,
            message: 'A release search is already running; wait for it to finish.',
          ),
        );
      await pumpHubApp(tester, api: api, location: '/library/movies/1');
      await tester.tap(find.text('Choose release'));
      await settle(tester);
      expect(find.textContaining('already running'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('a failed refresh keeps the page and shows the stale banner', (tester) async {
      var calls = 0;
      final api = buildLibraryFakeApi()
        ..on('GET', '/library/tv/54', (_) {
          calls++;
          return calls == 1
              ? FakeResponse(buildSeriesDetail().toJson())
              : FakeResponse.error(503, ApiErrorCode.upstreamUnavailable, message: 'Sonarr is unreachable.');
        });
      await pumpHubApp(tester, api: api, location: '/library/tv/54');
      expect(find.text('48/96'), findsOneWidget);
      await tester.fling(find.byType(Scrollable).first, const Offset(0, 400), 1000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await settle(tester, frames: 20);
      expect(calls, greaterThanOrEqualTo(2));
      expect(find.textContaining("Couldn't refresh"), findsOneWidget);
      expect(find.text('48/96'), findsOneWidget, reason: 'the old data stays');
    });
  });

  testWidgets('history screen pages ArrHistoryItems', (tester) async {
    final api = buildLibraryFakeApi()
      ..getJson(
        '/library/movies/9/history',
        PagedList<ArrHistoryItem>.of(
          items: [
            ArrHistoryItem(
              id: 'radarr:955',
              service: ArrService.radarr,
              type: ArrHistoryType.deleted,
              date: testNow,
              sourceTitle: 'Dune.Part.Two.2024.2160p',
              quality: const QualityInfo(name: 'WEBRip-2160p'),
              reason: 'Upgrade',
            ),
          ],
          page: 1,
          pageSize: 25,
          total: 1,
        ).toJson((i) => i.toJson()),
      )
      ..getJson('/library/movies/9', MovieDetail(movie: buildMovie(id: 9, title: 'Dune: Part Two')).toJson());
    await pumpHubApp(tester, api: api, location: '/library/history/radarr/9');
    expect(find.text('History'), findsOneWidget);
    expect(find.text('Dune.Part.Two.2024.2160p'), findsOneWidget);
    expect(find.textContaining('Deleted'), findsOneWidget);
    expect(find.textContaining('Upgrade'), findsOneWidget);
  });

  group('dashboard card', () {
    Future<void> pumpCard(WidgetTester tester, Section section) => tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(extensions: const [StatusColors.dark]),
          home: Scaffold(body: LibraryDashboardCard(section: section)),
        ),
      ),
    );

    testWidgets('one line per app with health and queue errors', (tester) async {
      final card = LibraryCard(
        sonarr: buildArrSummary(queueErrors: true),
        radarr: buildArrSummary(items: 3, missing: 1),
      );
      await pumpCard(tester, buildSection(card.toJson()));
      expect(find.byType(LibrarySummaryLine), findsNWidgets(2));
      expect(find.textContaining('4 series · 892 missing'), findsOneWidget);
      expect(find.textContaining('3 movies · 1 missing'), findsOneWidget);
      expect(find.text('Download errors'), findsOneWidget);
      expect(find.text('2 queued'), findsOneWidget);
      expect(find.byTooltip('1 health warning'), findsNWidgets(2));
    });

    testWidgets('an unconfigured app is left out', (tester) async {
      final card = LibraryCard(sonarr: buildArrSummary(), radarr: const ArrSummary.notConfigured());
      await pumpCard(tester, buildSection(card.toJson()));
      expect(find.byType(LibrarySummaryLine), findsOneWidget);
    });

    testWidgets('the dashboard shows the card', (tester) async {
      final api = buildCoreFakeApi()
        ..getJson(
          '/dashboard',
          buildDashboardJson(
            cards: {
              'library': Section.ok(
                LibraryCard.fromSummary(buildLibrarySummary()).toJson(),
                fetchedAt: testNow,
              ).toJson(),
            },
          ),
        );
      await pumpHubApp(tester, api: api);
      await tester.scrollUntilVisible(
        find.textContaining('892 missing').first,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('892 missing'), findsWidgets);
    });
  });
}
