import 'dart:convert';

import 'package:dio/dio.dart' as dio;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/features/subtitles/providers/subtitles_providers.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';

const _english = SubtitleLanguage(code: 'en', name: 'English');

/// Gateway-shaped samples (API.md §12) matching the Bazarr captures.
final _summary = SubtitlesSummary(
  missingEpisodes: 111,
  missingMovies: 3,
  throttledProviders: 1,
  providers: const [
    SubtitleProvider(name: 'opensubtitlescom', status: 'Good', ok: true),
    SubtitleProvider(name: 'tvsubtitles', status: 'TooManyRequests', retry: 'in 2 hours', ok: false),
  ],
  signalr: const SubtitleSignalr(sonarr: SubtitleSignalrState.live, radarr: SubtitleSignalrState.down),
  health: const [SubtitleHealthIssue(object: 'Sonarr', issue: 'Unable to connect to Sonarr')],
  version: '1.6.2',
  tasks: const [
    SubtitleTask(
      id: 'update_release',
      name: 'Update Release Info',
      interval: 'every 3 hours',
      nextRun: 'in 20 minutes',
      running: false,
    ),
    SubtitleTask(
      id: 'update_series',
      name: 'Sync with Sonarr',
      interval: 'every 60 minutes',
      nextRun: 'in 24 minutes',
      running: true,
    ),
  ],
);

const _gachiakuta = WantedSubtitle(
  type: SubtitleMediaType.episode,
  title: 'Gachiakuta',
  episodeLabel: 'S01E11',
  episodeTitle: "Amo's Hospitality",
  seriesId: 164,
  episodeId: 7941,
  missing: [
    _english,
    SubtitleLanguage(code: 'fr', name: 'French', hi: true),
  ],
  seriesType: 'anime',
);

const _hotel = WantedSubtitle(type: SubtitleMediaType.movie, title: 'Hotel', movieId: 190, missing: [_english]);

final _history = SubtitleHistoryItem(
  type: SubtitleMediaType.episode,
  title: 'That Time I Got Reincarnated as a Slime',
  episodeLabel: 'S03E17',
  action: SubtitleHistoryAction.downloaded,
  language: _english,
  provider: 'embeddedsubtitles',
  score: '100.0%',
  description: 'English subtitles downloaded from embeddedsubtitles with a score of 100.0%.',
  at: DateTime.utc(2026, 11, 8, 7, 53, 14),
);

JsonMap _page<T>(List<T> items, JsonMap Function(T) codec, {int? total}) =>
    PagedList.of(items: items, page: 1, pageSize: 25, total: total ?? items.length).toJson(codec);

JsonMap _jobs(List<SubtitleJob> jobs) => ItemList(jobs).toJson((j) => j.toJson());

/// The core fakes plus every subtitles endpoint.
FakeApi _api({
  Role role = Role.admin,
  List<WantedSubtitle> episodes = const [_gachiakuta],
  List<WantedSubtitle> movies = const [_hotel],
}) {
  final api = buildCoreFakeApi(role: role)
    ..getJson('/subtitles/summary', _summary.toJson())
    ..on('GET', '/subtitles/wanted', (dio.RequestOptions r) {
      final isMovies = r.uri.queryParameters['type'] == 'movies';
      return FakeResponse(_page(isMovies ? movies : episodes, (w) => w.toJson()));
    })
    ..on('GET', '/subtitles/history', (dio.RequestOptions r) {
      final isMovies = r.uri.queryParameters['type'] == 'movies';
      final item = isMovies
          ? SubtitleHistoryItem(
              type: SubtitleMediaType.movie,
              title: 'Dune: Part Two',
              action: SubtitleHistoryAction.upgraded,
              language: _english,
              at: DateTime.utc(2026, 11, 6, 9, 26, 8),
            )
          : _history;
      return FakeResponse(_page([item], (h) => h.toJson()));
    })
    ..getJson('/subtitles/jobs', _jobs(const []))
    ..on('POST', '/subtitles/search', (_) => const FakeResponse({'queued': true}, status: 202))
    ..on('POST', '/subtitles/search-item', (_) => const FakeResponse({'queued': true}, status: 202))
    ..on('POST', '/subtitles/search-all', (_) => const FakeResponse({'queued': true}, status: 202))
    ..on('POST', '/subtitles/providers/reset', (_) => const FakeResponse.noContent())
    ..on('POST', '/subtitles/tasks/update_release/run', (_) => const FakeResponse({'queued': true}, status: 202));
  return api;
}

JsonMap _body(dio.RequestOptions r) {
  final d = r.data;
  return (d is String ? jsonDecode(d) : d) as JsonMap;
}

void main() {
  testWidgets('admin: header, tabs with counts and wanted episodes', (tester) async {
    final app = await pumpHubApp(tester, api: _api(), location: '/subtitles');

    expect(find.text('Subtitles'), findsWidgets);
    expect(find.text('Episodes · 111'), findsOneWidget);
    expect(find.text('Movies · 3'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);

    // Header: counts, SignalR, providers, health.
    expect(find.text('Bazarr 1.6.2'), findsOneWidget);
    expect(find.text('Sonarr live'), findsOneWidget);
    expect(find.text('Radarr down'), findsOneWidget);
    expect(find.text('Providers · 1 throttled'), findsOneWidget);
    expect(find.text('opensubtitlescom'), findsOneWidget);
    expect(find.text('tvsubtitles'), findsOneWidget);
    expect(find.text('tvsubtitles · TooManyRequests · retry in 2 hours'), findsOneWidget);
    expect(find.textContaining('Unable to connect to Sonarr'), findsOneWidget);

    // Row: title, episode label + title, language chips with markers.
    expect(find.text('Gachiakuta'), findsOneWidget);
    expect(find.text("S01E11 · Amo's Hospitality"), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'English'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'French · HI'), findsOneWidget);
    expect(find.byKey(const ValueKey('subtitles-admin-menu')), findsOneWidget);

    expect(app.api.requestsTo('/subtitles/wanted').first.uri.queryParameters, {
      'type': 'episodes',
      'page': '1',
      'pageSize': '25',
    });
    expect(app.api.requestsTo('/subtitles/summary'), hasLength(1));
  });

  testWidgets('member: chips are read-only and admin actions are hidden', (tester) async {
    await pumpHubApp(
      tester,
      api: _api(role: Role.member),
      role: Role.member,
      location: '/subtitles',
    );
    expect(find.text('Gachiakuta'), findsOneWidget);
    expect(find.widgetWithText(Chip, 'English'), findsOneWidget);
    expect(find.byType(ActionChip), findsNothing);
    expect(find.byKey(const ValueKey('subtitles-admin-menu')), findsNothing);
    expect(find.byTooltip('Search options'), findsNothing);
  });

  testWidgets('tapping a language searches it and polls jobs until Bazarr is idle', (tester) async {
    final api = _api();
    var running = true;
    api.on('GET', '/subtitles/jobs', (dio.RequestOptions r) {
      final status = r.uri.queryParameters['status'];
      if (running && status == 'running') {
        return FakeResponse(
          _jobs(const [
            SubtitleJob(
              id: 31,
              name: 'Searching missing subtitles',
              status: 'running',
              progress: 0.5,
              message: 'Gachiakuta',
            ),
          ]),
        );
      }
      return FakeResponse(_jobs(const []));
    });
    final app = await pumpHubApp(tester, api: api, location: '/subtitles');

    await tester.tap(find.widgetWithText(ActionChip, 'French · HI'));
    await settle(tester);
    final post = app.api.requestsTo('/subtitles/search', method: 'POST').single;
    expect(_body(post), {
      'type': 'episode',
      'seriesId': 164,
      'episodeId': 7941,
      'language': 'fr',
      'forced': false,
      'hi': true,
    });
    expect(find.text('Search started'), findsOneWidget);
    // The chip shows a spinner and cannot be tapped twice.
    final chip = tester.widget<ActionChip>(find.widgetWithText(ActionChip, 'French · HI'));
    expect(chip.onPressed, isNull);
    expect(find.text('Searching subtitles…'), findsOneWidget);

    // Polled every 3 s while the search runs.
    expect(app.api.requestsTo('/subtitles/jobs'), isEmpty);
    await tester.pump(subtitleJobPollInterval);
    await settle(tester);
    final polled = app.api
        .requestsTo('/subtitles/jobs')
        .map((dio.RequestOptions r) => r.uri.queryParameters['status'])
        .toSet();
    expect(polled, {'running', 'pending'});
    expect(find.textContaining('Searching missing subtitles · Gachiakuta'), findsOneWidget);

    // Bazarr's queue drains: the search finishes and the list reloads.
    final wantedBefore = app.api.requestsTo('/subtitles/wanted').length;
    running = false;
    await tester.pump(subtitleJobPollInterval);
    await settle(tester);
    expect(find.text('Subtitle search finished'), findsOneWidget);
    expect(find.text('Searching subtitles…'), findsNothing);
    expect(app.api.requestsTo('/subtitles/wanted').length, greaterThan(wantedBefore));
    expect(tester.widget<ActionChip>(find.widgetWithText(ActionChip, 'French · HI')).onPressed, isNotNull);

    // No more polling once idle.
    final polls = app.api.requestsTo('/subtitles/jobs').length;
    await tester.pump(subtitleJobPollInterval * 2);
    await settle(tester);
    expect(app.api.requestsTo('/subtitles/jobs'), hasLength(polls));
  });

  testWidgets('job polling pauses while the app is in the background', (tester) async {
    final api = _api();
    var polls = 0;
    api.on('GET', '/subtitles/jobs', (dio.RequestOptions r) {
      polls++;
      return FakeResponse(_jobs(const [SubtitleJob(id: 31, name: 'Searching missing subtitles', status: 'running')]));
    });
    await pumpHubApp(tester, api: api, location: '/subtitles');
    await tester.tap(find.widgetWithText(ActionChip, 'English'));
    await settle(tester);

    // Valid lifecycle transitions only (AppLifecycleListener asserts them).
    for (final state in const [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump(subtitleJobPollInterval * 2);
    await settle(tester);
    expect(polls, 0);
    expect(find.text('Searching subtitles…'), findsOneWidget);

    for (final state in const [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump(subtitleJobPollInterval);
    await settle(tester);
    expect(polls, greaterThan(0));
  });

  testWidgets('a failed summary refresh keeps the header with a stale banner', (tester) async {
    final api = _api();
    var fail = false;
    api.on(
      'GET',
      '/subtitles/summary',
      (_) => fail
          ? FakeResponse.error(503, ApiErrorCode.upstreamUnavailable, message: 'Bazarr is not reachable.')
          : FakeResponse(_summary.toJson()),
    );
    await pumpHubApp(tester, api: api, location: '/subtitles');
    expect(find.text('Bazarr 1.6.2'), findsOneWidget);

    fail = true;
    await tester.fling(find.text('Gachiakuta'), const Offset(0, 400), 1000);
    await settle(tester);
    expect(find.textContaining("Couldn't refresh"), findsOneWidget);
    expect(find.text('Bazarr 1.6.2'), findsOneWidget);
  });

  testWidgets('a failed search releases the chip and shows the error', (tester) async {
    final api = _api()
      ..on(
        'POST',
        '/subtitles/search',
        (_) => FakeResponse.error(503, ApiErrorCode.upstreamUnavailable, message: 'Bazarr is not reachable.'),
      );
    await pumpHubApp(tester, api: api, location: '/subtitles');
    await tester.tap(find.widgetWithText(ActionChip, 'English'));
    await settle(tester);
    expect(find.text('Bazarr is not reachable.'), findsOneWidget);
    expect(tester.widget<ActionChip>(find.widgetWithText(ActionChip, 'English')).onPressed, isNotNull);
    expect(find.text('Searching subtitles…'), findsNothing);
  });

  testWidgets('row overflow searches the whole series', (tester) async {
    final app = await pumpHubApp(tester, api: _api(), location: '/subtitles');
    await tester.tap(find.byKey(const ValueKey('subtitle-item-menu-episode:7941')));
    await settle(tester);
    await tester.tap(find.text('Search all for this series'));
    await settle(tester);
    expect(_body(app.api.requestsTo('/subtitles/search-item', method: 'POST').single), {'type': 'series', 'id': 164});
    expect(find.text('Search started'), findsOneWidget);
  });

  testWidgets('movies tab', (tester) async {
    final app = await pumpHubApp(tester, api: _api(), location: '/subtitles?tab=movies');
    expect(find.text('Hotel'), findsOneWidget);
    expect(
      app.api.requestsTo('/subtitles/wanted').map((dio.RequestOptions r) => r.uri.queryParameters['type']),
      contains('movies'),
    );
  });

  testWidgets('empty: "No missing subtitles"', (tester) async {
    await pumpHubApp(
      tester,
      api: _api(episodes: const []),
      location: '/subtitles',
    );
    expect(find.text('No missing subtitles'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
  });

  testWidgets('error on first load shows the error view with Retry', (tester) async {
    final api = _api();
    var fail = true;
    api
      ..on(
        'GET',
        '/subtitles/summary',
        (_) => fail
            ? FakeResponse.error(503, ApiErrorCode.upstreamUnavailable, message: 'Bazarr is not reachable.')
            : FakeResponse(_summary.toJson()),
      )
      ..on(
        'GET',
        '/subtitles/wanted',
        (_) => fail
            ? FakeResponse.error(503, ApiErrorCode.upstreamUnavailable, message: 'Bazarr is not reachable.')
            : FakeResponse(_page([_gachiakuta], (w) => w.toJson())),
      );
    await pumpHubApp(tester, api: api, location: '/subtitles');
    expect(find.textContaining('Bazarr is not reachable.'), findsWidgets);
    expect(find.text('Retry'), findsWidgets);

    fail = false;
    await tester.tap(find.text('Retry').last);
    await settle(tester);
    expect(find.text('Gachiakuta'), findsOneWidget);
  });

  testWidgets('search all asks for confirmation with the count, then sends confirm=true', (tester) async {
    final app = await pumpHubApp(tester, api: _api(), location: '/subtitles');
    await tester.tap(find.byKey(const ValueKey('subtitles-admin-menu')));
    await settle(tester);
    await tester.tap(find.text('Search all missing episodes'));
    await settle(tester);
    expect(find.text('Search providers for 111 episodes?'), findsOneWidget);

    // Cancel sends nothing.
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(app.api.requestsTo('/subtitles/search-all'), isEmpty);

    await tester.tap(find.byKey(const ValueKey('subtitles-admin-menu')));
    await settle(tester);
    await tester.tap(find.text('Search all missing episodes'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Search'));
    await settle(tester);
    expect(_body(app.api.requestsTo('/subtitles/search-all', method: 'POST').single), {
      'type': 'episodes',
      'confirm': true,
    });
    expect(find.text('Search started'), findsOneWidget);
  });

  testWidgets('reset providers asks first', (tester) async {
    final app = await pumpHubApp(tester, api: _api(), location: '/subtitles');
    await tester.tap(find.byKey(const ValueKey('subtitles-admin-menu')));
    await settle(tester);
    await tester.tap(find.text('Reset providers'));
    await settle(tester);
    expect(find.text('Reset throttled providers?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
    await settle(tester);
    expect(app.api.requestsTo('/subtitles/providers/reset', method: 'POST'), hasLength(1));
    expect(find.text('Providers reset'), findsOneWidget);
  });

  testWidgets('tasks sheet: interval, next run, running spinner and Run now', (tester) async {
    final app = await pumpHubApp(tester, api: _api(), location: '/subtitles');
    await tester.tap(find.byKey(const ValueKey('subtitles-admin-menu')));
    await settle(tester);
    await tester.tap(find.text('Tasks'));
    await settle(tester);

    expect(find.text('Bazarr tasks'), findsOneWidget);
    expect(find.text('Update Release Info'), findsOneWidget);
    expect(find.text('every 3 hours · next in 20 minutes'), findsOneWidget);
    expect(find.text('every 60 minutes · running now'), findsOneWidget);
    final running = find.byKey(const ValueKey('subtitle-task-update_series'));
    expect(find.descendant(of: running, matching: find.byType(CircularProgressIndicator)), findsOneWidget);
    expect(find.descendant(of: running, matching: find.text('Run now')), findsNothing);

    await tester.tap(find.text('Run now'));
    await settle(tester);
    expect(app.api.requestsTo('/subtitles/tasks/update_release/run', method: 'POST'), hasLength(1));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('subtitle-task-update_release')),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
  });

  testWidgets('history: action, language, provider, score and the movies toggle', (tester) async {
    final app = await pumpHubApp(tester, api: _api(), location: '/subtitles?tab=history');
    expect(find.text('That Time I Got Reincarnated as a Slime · S03E17'), findsOneWidget);
    expect(find.text('Downloaded · English · embeddedsubtitles · 100.0%'), findsOneWidget);
    expect(find.textContaining('with a score of 100.0%'), findsOneWidget);
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);

    await tester.tap(find.text('Movies').last);
    await settle(tester);
    expect(find.text('Dune: Part Two'), findsOneWidget);
    expect(find.text('Upgraded · English'), findsOneWidget);
    expect(app.api.requestsTo('/subtitles/history').map((dio.RequestOptions r) => r.uri.queryParameters['type']), [
      'episodes',
      'movies',
    ]);
  });
}
