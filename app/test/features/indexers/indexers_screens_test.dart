import 'dart:convert';

import 'package:dio/dio.dart' as dio;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/routing/router.dart';
import 'package:yams_hub/features/indexers/providers/indexers_providers.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'indexers_test_data.dart';

String _location(HubTestApp app) => app.container
    .read(routerProvider)
    .routerDelegate
    .currentConfiguration
    .uri
    .toString();

Object? _body(dio.RequestOptions r) =>
    r.data is String ? jsonDecode(r.data as String) : r.data;

FakeApi _api({Role role = Role.admin, IndexerList? list}) =>
    buildCoreFakeApi(role: role)
      ..getJson('/indexers', (list ?? buildIndexerList()).toJson());

void main() {
  group('Indexers list', () {
    testWidgets('shows health, status chips, stats and admin switches', (
      tester,
    ) async {
      await pumpHubApp(tester, api: _api(), location: '/indexers');

      expect(find.text('Indexers'), findsWidgets);
      expect(
        find.text(
          'Indexers unavailable due to failures for more than 6 hours: Uindex',
        ),
        findsOneWidget,
      );
      expect(find.text('1337x'), findsOneWidget);
      expect(find.text('Bangumi Moe'), findsOneWidget);
      expect(find.textContaining('Failing until'), findsOneWidget);
      expect(find.text('Disabled'), findsOneWidget);
      expect(find.text('Priority 10'), findsOneWidget);
      expect(find.textContaining('11,713 queries · 8 grabs'), findsWidgets);
      expect(find.text('No activity in the last 30 days'), findsOneWidget);
      expect(
        find.text('3 of 4 enabled · 1 failing · stats for the last 30 days'),
        findsOneWidget,
      );
      expect(find.byType(Switch), findsNWidgets(4));
      expect(find.byTooltip('Test all'), findsOneWidget);
      expect(find.byTooltip('Search'), findsOneWidget);
      expect(find.byTooltip('History'), findsOneWidget);
    });

    testWidgets('members see no switches, tests or search', (tester) async {
      await pumpHubApp(
        tester,
        api: _api(role: Role.member),
        role: Role.member,
        location: '/indexers',
      );
      expect(find.text('1337x'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      expect(find.byTooltip('Test all'), findsNothing);
      expect(find.byTooltip('Search'), findsNothing);
      expect(find.byTooltip('History'), findsOneWidget);
    });

    testWidgets('empty state', (tester) async {
      await pumpHubApp(
        tester,
        api: _api(
          list: buildIndexerList(items: const [], health: const []),
        ),
        location: '/indexers',
      );
      expect(find.text('No indexers configured in Prowlarr'), findsOneWidget);
    });

    testWidgets('first-load error shows the error view with retry', (
      tester,
    ) async {
      final api = buildCoreFakeApi()
        ..on(
          'GET',
          '/indexers',
          (_) => FakeResponse.error(
            503,
            ApiErrorCode.upstreamUnavailable,
            message: 'Prowlarr is not reachable.',
          ),
        );
      await pumpHubApp(tester, api: api, location: '/indexers');
      expect(find.text('Prowlarr is not reachable.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('the switch disables optimistically and sends PATCH', (
      tester,
    ) async {
      final api = _api()
        ..on('PATCH', '/indexers', (r) {
          final items = [
            for (final i in buildIndexers())
              i.id == 4 ? i.withEnabled(false) : i,
          ];
          return FakeResponse(buildIndexerList(items: items).toJson());
        });
      await pumpHubApp(tester, api: api, location: '/indexers');

      await tester.tap(find.byType(Switch).first);
      await settle(tester);

      final patch = api.requestsTo('/indexers', method: 'PATCH').single;
      expect(_body(patch), {
        'ids': [4],
        'enabled': false,
      });
      expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);
      expect(find.text('Disabled'), findsNWidgets(2));
    });

    testWidgets('a failed toggle rolls back and shows the error', (
      tester,
    ) async {
      final api = _api()
        ..on(
          'PATCH',
          '/indexers',
          (_) => FakeResponse.error(
            502,
            ApiErrorCode.upstreamError,
            message: 'Prowlarr returned an error (500).',
          ),
        );
      await pumpHubApp(tester, api: api, location: '/indexers');

      await tester.tap(find.byType(Switch).first);
      await settle(tester);

      expect(tester.widget<Switch>(find.byType(Switch).first).value, isTrue);
      expect(find.text('Prowlarr returned an error (500).'), findsOneWidget);
    });

    testWidgets('long-press selects; bulk disable and priority', (
      tester,
    ) async {
      final api = _api()
        ..on(
          'PATCH',
          '/indexers',
          (_) => FakeResponse(buildIndexerList().toJson()),
        );
      await pumpHubApp(tester, api: api, location: '/indexers');

      await tester.longPress(find.text('1337x'));
      await settle(tester);
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.text('Nyaa.si'));
      await settle(tester);
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(find.byTooltip('Disable'));
      await settle(tester);
      expect(_body(api.requestsTo('/indexers', method: 'PATCH').last), {
        'ids': [4, 5],
        'enabled': false,
      });
      expect(find.text('2 selected'), findsNothing);

      await tester.longPress(find.text('Uindex'));
      await settle(tester);
      await tester.tap(find.byTooltip('Set priority'));
      await settle(tester);
      await tester.enterText(find.byType(TextField), '7');
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(_body(api.requestsTo('/indexers', method: 'PATCH').last), {
        'ids': [15],
        'priority': 7,
      });
    });

    testWidgets('Test all runs a job and lists the results', (tester) async {
      final api = _api()
        ..postJson('/indexers/test-all', {
          'job': buildTestJob(status: JobStatus.running).toJson(),
        }, status: 202)
        ..getJson('/jobs/j_test00000001', {
          'job': buildTestJob(
            result: ItemList(const [
              IndexerTestResult(id: 4, valid: true),
              IndexerTestResult(
                id: 15,
                valid: false,
                failures: ['Unable to connect to indexer'],
              ),
            ]).toJson((r) => r.toJson()),
          ).toJson(),
        });
      await pumpHubApp(tester, api: api, location: '/indexers');

      await tester.tap(find.byTooltip('Test all'));
      await settle(tester, frames: 10);

      expect(
        api.requestsTo('/indexers/test-all', method: 'POST'),
        hasLength(1),
      );
      expect(find.text('1 of 2 passed'), findsOneWidget);
      expect(find.text('Unable to connect to indexer'), findsOneWidget);
      expect(find.byIcon(Icons.cancel), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsWidgets);
    });

    testWidgets('a Test all job the hub forgot (404) gives the button back', (
      tester,
    ) async {
      final api = _api()
        ..postJson('/indexers/test-all', {
          'job': buildTestJob(status: JobStatus.running).toJson(),
        }, status: 202)
        ..on(
          'GET',
          '/jobs/j_test00000001',
          (_) => FakeResponse.error(
            404,
            ApiErrorCode.notFound,
            message: 'Job not found or expired',
          ),
        );
      await pumpHubApp(tester, api: api, location: '/indexers');

      await tester.tap(find.byTooltip('Test all'));
      await settle(tester, frames: 10);

      expect(
        find.text('Lost track of the test. Refresh to check the result.'),
        findsOneWidget,
      );
      final button = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.fact_check_outlined),
      );
      expect(button.onPressed, isNotNull);
      expect(find.byType(Chip), findsNothing);
    });

    testWidgets('a lost Test selected job still finishes the batch', (
      tester,
    ) async {
      final api = _api()
        ..postJson('/indexers/4/test', {
          'job': buildTestJob(
            id: 'j_single000004',
            kind: 'indexers.test',
            status: JobStatus.running,
          ).toJson(),
        }, status: 202)
        ..on(
          'GET',
          '/jobs/j_single000004',
          (_) => FakeResponse.error(404, ApiErrorCode.notFound),
        );
      await pumpHubApp(tester, api: api, location: '/indexers');

      await tester.longPress(find.text('1337x'));
      await settle(tester);
      await tester.tap(find.byTooltip('Test selected'));
      await settle(tester, frames: 10);

      expect(api.requestsTo('/indexers/4/test', method: 'POST'), hasLength(1));
      expect(
        find.textContaining('Lost track of the test'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.fact_check_outlined),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets(
      'tapping a row opens the detail; app bar opens history and search',
      (tester) async {
        final api = _api()
          ..getJson(
            '/indexers/4',
            buildIndexer(description: 'Public tracker').toJson(),
          );
        final app = await pumpHubApp(tester, api: api, location: '/indexers');
        await tester.tap(find.text('1337x'));
        await settle(tester);
        expect(_location(app), '/indexers/4');
        expect(find.text('Public tracker'), findsOneWidget);
      },
    );
  });

  group('Indexer detail', () {
    FakeApi detailApi() => buildCoreFakeApi()
      ..getJson(
        '/indexers/15',
        buildIndexer(
          id: 15,
          name: 'Uindex',
          status: IndexerStatus.failing,
          flare: true,
          disabledTill: uindexRetry,
          description: 'Uindex is a public torrent indexer',
          categories: const ['TV', 'Movies'],
        ).toJson(),
      );

    testWidgets('shows fields, failures, stats and categories', (tester) async {
      await pumpHubApp(tester, api: detailApi(), location: '/indexers/15');
      expect(find.text('Uindex'), findsWidgets);
      expect(find.text('Uindex is a public torrent indexer'), findsOneWidget);
      expect(find.text('Failing since'), findsOneWidget);
      expect(find.text('Next retry'), findsOneWidget);
      expect(find.text('Enabled'), findsOneWidget);
      await tester.dragUntilVisible(
        find.text('Movies'),
        find.byType(ListView).first,
        const Offset(0, -300),
      );
      expect(find.text('https://uindex.example.org/'), findsOneWidget);
      expect(find.text('TV'), findsOneWidget);
      expect(find.text('flaresolverr'), findsOneWidget);
    });

    testWidgets('Test runs a job and shows the failure', (tester) async {
      final api = detailApi()
        ..postJson('/indexers/15/test', {
          'job': buildTestJob(
            id: 'j_single000001',
            kind: 'indexers.test',
            status: JobStatus.running,
          ).toJson(),
        }, status: 202)
        ..getJson('/jobs/j_single000001', {
          'job': buildTestJob(
            id: 'j_single000001',
            kind: 'indexers.test',
            result: const IndexerTestResult(
              id: 15,
              valid: false,
              failures: ['Blocked by CloudFlare'],
            ).toJson(),
          ).toJson(),
        });
      await pumpHubApp(tester, api: api, location: '/indexers/15');
      await tester.tap(find.text('Test'));
      await settle(tester, frames: 10);
      expect(api.requestsTo('/indexers/15/test', method: 'POST'), hasLength(1));
      expect(find.text('Blocked by CloudFlare'), findsOneWidget);
    });

    testWidgets('a lost Test job brings the Test button back', (tester) async {
      final api = detailApi()
        ..postJson('/indexers/15/test', {
          'job': buildTestJob(
            id: 'j_single000001',
            kind: 'indexers.test',
            status: JobStatus.running,
          ).toJson(),
        }, status: 202)
        ..on(
          'GET',
          '/jobs/j_single000001',
          (_) => FakeResponse.error(404, ApiErrorCode.notFound),
        );
      await pumpHubApp(tester, api: api, location: '/indexers/15');
      await tester.tap(find.text('Test'));
      await settle(tester, frames: 10);
      expect(
        find.text('Lost track of the test. Refresh to check the result.'),
        findsOneWidget,
      );
      expect(find.text('Test'), findsOneWidget);
      expect(find.byType(Chip), findsNothing);
    });

    testWidgets('members do not see settings', (tester) async {
      final api = buildCoreFakeApi(role: Role.member)
        ..getJson('/indexers/4', buildIndexer().toJson());
      await pumpHubApp(
        tester,
        api: api,
        role: Role.member,
        location: '/indexers/4',
      );
      expect(find.text('1337x'), findsWidgets);
      expect(find.text('Test'), findsNothing);
      expect(find.byType(Switch), findsNothing);
    });

    testWidgets('unknown indexer shows the error', (tester) async {
      final api = buildCoreFakeApi()
        ..on(
          'GET',
          '/indexers/99',
          (_) => FakeResponse.error(
            404,
            ApiErrorCode.notFound,
            message: 'Indexer not found.',
          ),
        );
      await pumpHubApp(tester, api: api, location: '/indexers/99');
      expect(find.text('Indexer not found.'), findsOneWidget);
    });
  });

  group('History', () {
    testWidgets('lists records and filters by type', (tester) async {
      final api = _api()
        ..on('GET', '/indexers/history', (r) {
          final type = r.uri.queryParameters['type'];
          final items = [
            IndexerHistoryItem(
              id: 1,
              indexerId: 5,
              indexerName: 'Nyaa.si',
              date: DateTime.now().subtract(const Duration(minutes: 5)),
              successful: false,
              type: IndexerHistoryType.grabbed,
              source: 'Sonarr',
              grabTitle: '[SubsPlease] Example Show - 01 (1080p)',
            ),
            if (type == null)
              IndexerHistoryItem(
                id: 2,
                indexerId: 4,
                indexerName: '1337x',
                date: DateTime.now().subtract(const Duration(hours: 1)),
                successful: true,
                type: IndexerHistoryType.rss,
                source: 'Sonarr',
                results: 20,
                elapsedMs: 993,
              ),
          ];
          return FakeResponse(
            PagedList.of(
              items: items,
              page: 1,
              pageSize: 50,
              total: items.length,
            ).toJson((i) => i.toJson()),
          );
        });
      await pumpHubApp(tester, api: api, location: '/indexers/history');

      expect(
        find.text('[SubsPlease] Example Show - 01 (1080p)'),
        findsOneWidget,
      );
      expect(find.text('RSS sync'), findsOneWidget);
      expect(find.text('1337x · Sonarr · 20 results · 993 ms'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);

      await tester.tap(find.text('Grabs'));
      await settle(tester);
      expect(
        api.requestsTo('/indexers/history').last.uri.queryParameters['type'],
        'grabbed',
      );
      expect(find.text('RSS sync'), findsNothing);

      await tester.ensureVisible(find.text('Failed only'));
      await tester.tap(find.text('Failed only'));
      await settle(tester);
      expect(
        api
            .requestsTo('/indexers/history')
            .last
            .uri
            .queryParameters['successful'],
        'false',
      );
    });
  });

  group('Manual search', () {
    FakeApi searchApi() => _api()
      ..getJson(
        '/indexers/categories',
        ItemList(const [
          IndexerCategory(
            id: 7000,
            name: 'Books',
            subCategories: [IndexerSubcategory(id: 7020, name: 'Books/EBook')],
          ),
        ]).toJson((c) => c.toJson()),
      )
      ..getJson('/transfer/categories', {
        'categories': [
          {'name': 'tv-sonarr', 'readOnly': true},
          {'name': 'books', 'readOnly': true},
          {'name': 'radarr', 'readOnly': true},
        ],
        'tags': <Object?>[],
      })
      ..getJson(
        '/indexers/search',
        ReleaseList(
          items: [
            buildRelease(),
            buildRelease(
              id: 'rel_bbbbbbbbbbbbbbbbbbbbbbbb',
              title: 'Popular Book',
              seeders: 900,
              magnet: true,
            ),
          ],
          tookMs: 5321,
        ).toJson(),
      );

    testWidgets('searches explicitly, sorts by seeders and grabs', (
      tester,
    ) async {
      final api = searchApi()
        ..postJson('/indexers/grab', {'ok': true}, status: 201);
      await pumpHubApp(tester, api: api, location: '/indexers/search');

      expect(
        find.text(
          'For TV and movies prefer the Library search, so Sonarr/Radarr track the download.',
        ),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), 'example book');
      await settle(tester);
      expect(
        api.requestsTo('/indexers/search'),
        isEmpty,
        reason: 'never search-as-you-type',
      );

      await tester.tap(find.text('Book'));
      await tester.tap(find.widgetWithText(FilledButton, 'Search'));
      await settle(tester);

      final q = api.requestsTo('/indexers/search').single.uri.queryParameters;
      expect(q['q'], 'example book');
      expect(q['type'], 'book');
      expect(find.text('2 releases · 5.3 s'), findsOneWidget);
      // Most seeders first.
      final popular = tester.getTopLeft(find.text('Popular Book')).dy;
      final example = tester
          .getTopLeft(find.text('Example Author - Example Book (2025) EPUB'))
          .dy;
      expect(popular, lessThan(example));

      await tester.tap(find.text('Example Author - Example Book (2025) EPUB'));
      await settle(tester);
      expect(find.text('Grab to qBittorrent'), findsOneWidget);
      expect(find.text('Open info page'), findsOneWidget);
      expect(find.text('manual'), findsOneWidget);

      await tester.tap(find.text('Grab to qBittorrent'));
      await settle(tester);
      expect(_body(api.requestsTo('/indexers/grab', method: 'POST').single), {
        'releaseId': 'rel_aaaaaaaaaaaaaaaaaaaaaaaa',
        'category': 'manual',
      });
      expect(find.text('Sent to qBittorrent (manual)'), findsOneWidget);
      expect(find.text('Grab to qBittorrent'), findsNothing);
    });

    testWidgets('the grab sheet offers non-*arr categories only', (
      tester,
    ) async {
      final api = searchApi()
        ..postJson('/indexers/grab', {'ok': true}, status: 201);
      await pumpHubApp(tester, api: api, location: '/indexers/search');
      await tester.enterText(find.byType(TextField), 'book');
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Search'));
      await settle(tester);
      await tester.tap(find.text('Popular Book'));
      await settle(tester);
      await tester.tap(find.text('manual'));
      await settle(tester);
      expect(find.text('books'), findsWidgets);
      expect(find.text('tv-sonarr'), findsNothing);
      expect(find.text('radarr'), findsNothing);
      await tester.tap(find.text('books').last);
      await settle(tester);
      await tester.tap(find.text('Grab to qBittorrent'));
      await settle(tester);
      expect(
        (_body(api.requestsTo('/indexers/grab', method: 'POST').single)!
            as Map)['category'],
        'books',
      );
    });

    testWidgets('an expired release explains what to do', (tester) async {
      final api = searchApi()
        ..on(
          'POST',
          '/indexers/grab',
          (_) => FakeResponse.error(
            404,
            ApiErrorCode.notFound,
            message: 'Release expired, search again',
          ),
        );
      await pumpHubApp(tester, api: api, location: '/indexers/search');
      await tester.enterText(find.byType(TextField), 'book');
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Search'));
      await settle(tester);
      await tester.tap(find.text('Popular Book'));
      await settle(tester);
      await tester.tap(find.text('Grab to qBittorrent'));
      await settle(tester);
      expect(
        find.text('This result expired. Search again to grab it.'),
        findsOneWidget,
      );
    });

    testWidgets('no results', (tester) async {
      final api = searchApi()
        ..getJson(
          '/indexers/search',
          const ReleaseList(items: [], tookMs: 800).toJson(),
        );
      await pumpHubApp(tester, api: api, location: '/indexers/search');
      await tester.enterText(find.byType(TextField), 'nothing');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settle(tester);
      expect(find.text('No releases found'), findsOneWidget);
    });

    testWidgets('members are redirected to the list', (tester) async {
      final app = await pumpHubApp(
        tester,
        api: _api(role: Role.member),
        role: Role.member,
        location: '/indexers/search',
      );
      expect(_location(app), '/indexers');
      expect(find.text('Manual search'), findsNothing);
    });
  });

  group('providers', () {
    testWidgets('grab categories: manual first, no *arr categories', (
      tester,
    ) async {
      final app = await pumpHubApp(
        tester,
        api: buildCoreFakeApi()
          ..getJson('/transfer/categories', {
            'categories': [
              {'name': 'tv-sonarr'},
              {'name': 'books'},
              {'name': 'manual'},
              {'name': 'radarr'},
            ],
          }),
      );
      final sub = app.container.listen(grabCategoriesProvider, (_, _) {});
      addTearDown(sub.close);
      await settle(tester);
      expect(sub.read().value, ['manual', 'books']);
    });

    testWidgets('grab categories fall back to manual', (tester) async {
      final app = await pumpHubApp(tester);
      final sub = app.container.listen(grabCategoriesProvider, (_, _) {});
      addTearDown(sub.close);
      await settle(tester);
      expect(sub.read().value, ['manual']);
    });
  });
}
