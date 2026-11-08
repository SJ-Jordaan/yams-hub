import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/features/library/widgets/release_picker_sheet.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'library_test_data.dart';

Object? _body(RequestOptions r) => r.data is String ? jsonDecode(r.data as String) : r.data;

void main() {
  testWidgets('series detail: header, chips, stats, seasons, history', (tester) async {
    await pumpHubApp(tester, api: buildLibraryFakeApi(), location: '/library/tv/54');
    expect(find.text('That Time I Got Reincarnated as a Slime'), findsWidgets);
    expect(find.text('[Anime] Remux-1080p'), findsOneWidget);
    expect(find.text('Anime'), findsOneWidget, reason: 'series type chip');
    expect(find.text('anime'), findsOneWidget, reason: 'tag chip');
    expect(find.text('kids'), findsOneWidget);
    expect(find.text('48/96'), findsOneWidget);
    expect(find.text('Season 3'), findsOneWidget);
    expect(find.text('Specials'), findsOneWidget);
    // Specials are listed after the regular seasons.
    expect(tester.getTopLeft(find.text('Specials')).dy, greaterThan(tester.getTopLeft(find.text('Season 3')).dy));
    await tester.scrollUntilVisible(find.text('Recent history'), 300);
    expect(find.text('[SubsPlease] Slime - 49 (1080p)'), findsOneWidget);
    expect(find.text('See all'), findsOneWidget);
  });

  testWidgets('monitor toggle is optimistic and rolls back on failure', (tester) async {
    final api = buildLibraryFakeApi()
      ..on(
        'PATCH',
        '/library/tv/54',
        (_) => FakeResponse.error(502, ApiErrorCode.upstreamError, message: 'Sonarr returned an error.'),
      );
    await pumpHubApp(tester, api: api, location: '/library/tv/54');
    await tester.tap(find.byTooltip('Monitored · tap to unmonitor').first);
    await settle(tester);
    final patch = api.requestsTo('/library/tv/54', method: 'PATCH').single;
    expect(_body(patch), {'monitored': false});
    expect(find.text('Sonarr returned an error.'), findsOneWidget);
    expect(find.byTooltip('Monitored · tap to unmonitor'), findsWidgets, reason: 'rolled back');
  });

  testWidgets('search menu starts a command and reports when it is done', (tester) async {
    var polls = 0;
    final api = buildLibraryFakeApi()
      ..on(
        'POST',
        '/library/tv/54/search',
        (_) => FakeResponse(buildCommandJson(name: 'MissingEpisodeSearch'), status: 202),
      )
      ..on('GET', '/library/commands/sonarr/5000', (_) {
        polls++;
        return FakeResponse(
          buildCommandJson(name: 'MissingEpisodeSearch', status: polls < 2 ? 'started' : 'completed'),
        );
      });
    await pumpHubApp(tester, api: api, location: '/library/tv/54');
    await tester.tap(find.text('Search'));
    await settle(tester);
    await tester.tap(find.text('Search missing'));
    await settle(tester);
    expect(_body(api.requestsTo('/library/tv/54/search').single), {'scope': 'missing'});
    expect(find.text('Search missing started'), findsOneWidget);
    expect(find.textContaining('Search missing · queued'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect(polls, 2);
    // The result SnackBar replaces "started" once that one has animated out.
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(find.text('Search missing: done'), findsOneWidget);
    expect(find.textContaining('Search missing · '), findsNothing);
  });

  testWidgets('season screen: anime labels, multi-select monitor', (tester) async {
    final api = buildLibraryFakeApi()..on('PATCH', '/library/tv/episodes', (_) => const FakeResponse({'items': []}));
    await pumpHubApp(tester, api: api, location: '/library/tv/54/season/3');
    expect(find.text('Season 3'), findsOneWidget);
    expect(find.textContaining('S03E01 (049)'), findsOneWidget);
    expect(find.textContaining('S03E02 (050)'), findsOneWidget);

    await tester.longPress(find.textContaining('S03E01 (049)'));
    await settle(tester);
    await tester.tap(find.textContaining('S03E02 (050)'));
    await settle(tester);
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.byTooltip('Unmonitor'));
    await settle(tester);
    final body = _body(api.requestsTo('/library/tv/episodes', method: 'PATCH').single)! as Map;
    expect((body['episodeIds'] as List).toSet(), {2447, 2448});
    expect(body['monitored'], isFalse);
  });

  testWidgets('choose release: rejected releases greyed, confirmed, grabbed', (tester) async {
    final api = buildLibraryFakeApi()
      ..getJson(
        '/library/tv/episodes/2448/releases',
        ReleaseChoiceList(
          items: [
            buildRelease(),
            buildRelease(
              id: 'rl_rej',
              title: 'Slime S03E02 HDTV',
              approved: false,
              rejected: true,
              rejections: ['Existing file on disk is of equal or higher preference'],
              score: -200,
            ),
          ],
          tookMs: 4200,
        ).toJson(),
      )
      ..on(
        'POST',
        '/library/releases/grab',
        (_) => const FakeResponse({'ok': true, 'title': 'Slime S03E02 HDTV'}, status: 201),
      );
    await pumpHubApp(tester, api: api, location: '/library/tv/54/season/3');
    await tester.tap(find.byTooltip('Episode actions').last);
    await settle(tester);
    await tester.tap(find.text('Choose release…'));
    await settle(tester);

    expect(find.text('Choose release'), findsOneWidget);
    expect(find.textContaining('2 releases · 1 approved'), findsOneWidget);
    expect(find.text('Score 1400'), findsOneWidget);
    final rejectedOpacity = tester.widget<Opacity>(
      find.ancestor(of: find.text('Slime S03E02 HDTV'), matching: find.byType(Opacity)).first,
    );
    expect(rejectedOpacity.opacity, lessThan(1));
    expect(api.requestsTo('/library/tv/episodes/2448/releases').single.receiveTimeout, const Duration(seconds: 160));

    await tester.tap(find.text('Slime S03E02 HDTV'));
    await settle(tester);
    await tester.tap(find.text('Grab anyway'));
    await settle(tester);
    expect(find.text('Grab anyway?'), findsOneWidget);
    expect(find.textContaining('equal or higher preference'), findsWidgets);
    await tester.tap(find.widgetWithText(FilledButton, 'Grab anyway').last);
    await settle(tester);
    expect(_body(api.requestsTo('/library/releases/grab').single), {'releaseId': 'rl_rej'});
    expect(find.text('Sent to qBittorrent via Sonarr'), findsOneWidget);
    expect(find.text('Choose release'), findsNothing);
  });

  testWidgets('an expired release asks to search again', (tester) async {
    final api = buildLibraryFakeApi()
      ..getJson('/library/tv/54/seasons/3/releases', ReleaseChoiceList(items: [buildRelease()]).toJson())
      ..on(
        'POST',
        '/library/releases/grab',
        (_) => FakeResponse.error(404, ApiErrorCode.notFound, message: 'Release expired, search again.'),
      );
    await pumpHubApp(tester, api: api, location: '/library/tv/54/season/3');
    await tester.tap(find.byTooltip('Season actions'));
    await settle(tester);
    await tester.tap(find.text('Choose release…'));
    await settle(tester);
    await tester.tap(find.text('[SubsPlease] Slime - 49 (1080p)'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Grab'));
    await settle(tester);
    expect(find.text('Results expired, search again'), findsOneWidget);
    expect(find.text('Choose release'), findsOneWidget, reason: 'the sheet stays open');
  });

  test('release sorting keeps rejected releases last', () {
    final items = [
      buildRelease(id: 'a', size: 1, seeders: 5, age: 10),
      buildRelease(id: 'r', approved: false, rejected: true, size: 999, seeders: 999, age: 1),
      buildRelease(id: 'b', size: 5, seeders: 50, age: 100),
    ];
    List<String> ids(ReleaseSort s) => [for (final r in sortReleases(items, s)) r.releaseId];
    expect(ids(ReleaseSort.score), ['a', 'b', 'r']);
    expect(ids(ReleaseSort.size), ['b', 'a', 'r']);
    expect(ids(ReleaseSort.seeders), ['b', 'a', 'r']);
    expect(ids(ReleaseSort.age), ['a', 'b', 'r']);
    expect(releaseAge(30), '30 h');
    expect(releaseAge(24 * 5), '5 d');
  });

  testWidgets('delete with files needs the typed title', (tester) async {
    final api = buildLibraryFakeApi()..on('DELETE', '/library/tv/54', (_) => const FakeResponse.noContent());
    await pumpHubApp(tester, api: api, location: '/library/tv/54');
    await tester.tap(find.byTooltip('Series actions'));
    await settle(tester);
    await tester.tap(find.text('Delete…'));
    await settle(tester);
    expect(find.textContaining('Files stay on disk.'), findsOneWidget);
    await tester.tap(find.textContaining('Also delete 48 files'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await settle(tester);

    expect(find.text('Delete files permanently'), findsOneWidget);
    expect(find.textContaining('There is no recycle bin.'), findsOneWidget);
    final delete = find.widgetWithText(FilledButton, 'Delete');
    expect(tester.widget<FilledButton>(delete).onPressed, isNull);
    await tester.enterText(find.byType(TextField).last, 'That Time I Got Reincarnated as a Slime');
    await settle(tester);
    await tester.tap(delete);
    await settle(tester);
    final call = api.requestsTo('/library/tv/54', method: 'DELETE').single;
    expect(call.queryParameters, {'deleteFiles': true, 'addExclusion': false, 'confirm': true});
    expect(find.textContaining('and its files deleted'), findsOneWidget);
  });

  testWidgets('without the delete-files policy only removal is offered', (tester) async {
    final api = buildLibraryFakeApi(allowDeleteFiles: false)
      ..on('DELETE', '/library/tv/54', (_) => const FakeResponse.noContent());
    await pumpHubApp(tester, api: api, location: '/library/tv/54');
    await tester.tap(find.byTooltip('Series actions'));
    await settle(tester);
    await tester.tap(find.text('Delete…'));
    await settle(tester);
    expect(find.textContaining('Also delete'), findsNothing);
    await tester.tap(find.text('Add to import exclusion list'));
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await settle(tester);
    expect(api.requestsTo('/library/tv/54', method: 'DELETE').single.queryParameters, {
      'deleteFiles': false,
      'addExclusion': true,
      'confirm': true,
    });
  });

  testWidgets('members see no admin actions', (tester) async {
    await pumpHubApp(
      tester,
      api: buildLibraryFakeApi(role: Role.member),
      role: Role.member,
      location: '/library/tv/54',
    );
    expect(find.text('Search'), findsNothing);
    expect(find.byTooltip('Series actions'), findsNothing);
    expect(find.byTooltip('Season actions'), findsNothing);
    expect(find.text('48/96'), findsOneWidget);
  });

  testWidgets('a deleted series shows an empty state', (tester) async {
    final api = buildLibraryFakeApi()
      ..on(
        'GET',
        '/library/tv/54',
        (_) => FakeResponse.error(404, ApiErrorCode.notFound, message: 'Series not found.'),
      );
    await pumpHubApp(tester, api: api, location: '/library/tv/54');
    expect(find.text('Series not found'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
  });
}
