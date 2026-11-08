import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/features/media/screens/apps_tab.dart';
import 'package:yams_hub/features/media/screens/stats_users_screen.dart';
import 'package:yams_hub/features/media/widgets/session_card.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'media_samples.dart';

FakeApi _api({Role role = Role.admin}) {
  final api = buildCoreFakeApi(role: role);
  serveMedia(api);
  return api;
}

Map<String, Object?> _body(RequestOptions r) {
  final d = r.data;
  return d is String ? jsonDecode(d) as Map<String, Object?> : (d as Map).cast<String, Object?>();
}

/// The vertical scrollable of the visible screen.
final _vertical = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);

Future<void> _scrollTo(WidgetTester tester, Finder finder) =>
    tester.scrollUntilVisible(finder, 200, scrollable: _vertical.last);

void main() {
  group('Now playing', () {
    testWidgets('shows each session with its details', (tester) async {
      await pumpHubApp(tester, api: _api(), location: '/media');
      expect(find.text('Now playing'), findsWidgets);
      expect(find.text('2 streams · 1 transcoding · HW: QSV'), findsOneWidget);
      expect(find.text('Desperate Housewives'), findsOneWidget);
      expect(find.text('S05E18 · A Spark. To Pierce the Dark.'), findsOneWidget);
      expect(find.text('Zenith Greyrat'), findsOneWidget);
      expect(find.text('Jellyfin Android TV · Xiaomi TV Box · 192.168.10.160'), findsOneWidget);
      expect(find.text('2:45 / 43:03'), findsOneWidget);
      expect(find.text('Direct play'), findsOneWidget);
      // The transcoding movie: QSV chip and expandable details.
      await _scrollTo(tester, find.text('Transcoding details'));
      expect(find.text('Transcode · QSV'), findsOneWidget);
      await tester.tap(find.text('Transcoding details'));
      await settle(tester);
      expect(find.text('→ h264'), findsOneWidget);
      expect(find.text('Direct (aac)'), findsOneWidget);
      expect(find.text('8.0 Mbps'), findsOneWidget);
      expect(find.text('Video codec not supported'), findsOneWidget);
    });

    testWidgets('admins pause, stop (confirmed) and message', (tester) async {
      final api = _api();
      final sid = episodeSession().id;
      api
        ..on('POST', '/media/sessions/$sid/playback', (_) => const FakeResponse.noContent())
        ..on('POST', '/media/sessions/$sid/message', (_) => const FakeResponse.noContent());
      await pumpHubApp(tester, api: api, location: '/media');
      final card = find.ancestor(of: find.text('Desperate Housewives'), matching: find.byType(SessionCard));

      await tester.tap(find.descendant(of: card, matching: find.text('Pause')));
      await settle(tester);
      expect(_body(api.requestsTo('/media/sessions/$sid/playback').single), {'command': 'pause'});

      await tester.tap(find.descendant(of: card, matching: find.text('Stop')));
      await settle(tester);
      expect(find.text('Stop playback for Zenith Greyrat on Xiaomi TV Box?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
      await settle(tester);
      expect(api.requestsTo('/media/sessions/$sid/playback').map(_body).last, {'command': 'stop'});
      expect(find.text('Playback stopped'), findsOneWidget);

      await tester.tap(find.descendant(of: card, matching: find.text('Message')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('media.message.text')), 'Server restarting in 5 min');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await settle(tester);
      expect(_body(api.requestsTo('/media/sessions/$sid/message').single), {
        'text': 'Server restarting in 5 min',
        'header': 'YAMS Hub',
      });
    });

    testWidgets('cancelling the stop dialog sends nothing', (tester) async {
      final api = _api();
      await pumpHubApp(tester, api: api, location: '/media');
      final card = find.ancestor(of: find.text('Desperate Housewives'), matching: find.byType(SessionCard));
      await tester.tap(find.descendant(of: card, matching: find.text('Stop')));
      await settle(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(api.requestsTo('/media/sessions/${episodeSession().id}/playback'), isEmpty);
    });

    testWidgets('members see no playback controls', (tester) async {
      final api = buildCoreFakeApi(role: Role.member);
      serveMedia(api, nowPlaying: NowPlaying(sessions: [episodeSession(canControl: false)]));
      await pumpHubApp(tester, api: api, role: Role.member, location: '/media');
      expect(find.text('Desperate Housewives'), findsOneWidget);
      expect(find.text('Pause'), findsNothing);
      expect(find.text('Stop'), findsNothing);
      expect(find.text('Message'), findsNothing);
    });

    testWidgets('empty: nothing playing with continue watching', (tester) async {
      final api = buildCoreFakeApi();
      serveMedia(api, nowPlaying: const NowPlaying());
      await pumpHubApp(tester, api: api, location: '/media');
      expect(find.text('Nothing is playing right now'), findsOneWidget);
      expect(find.text('Continue watching'), findsOneWidget);
      expect(find.text('Clevatess'), findsOneWidget);
    });

    testWidgets('error: Jellyfin unreachable with retry', (tester) async {
      final api = buildCoreFakeApi();
      serveMedia(api);
      api.on(
        'GET',
        '/media/now-playing',
        (_) => FakeResponse.error(503, ApiErrorCode.upstreamUnavailable, message: 'Jellyfin is not reachable.'),
      );
      await pumpHubApp(tester, api: api, location: '/media');
      expect(find.textContaining('Jellyfin is not reachable.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('Stats', () {
    testWidgets('charts, totals and period selector', (tester) async {
      final api = _api();
      await pumpHubApp(tester, api: api, location: '/media?tab=stats');
      expect(find.text('Views over time'), findsOneWidget);
      expect(find.text('3'), findsWidgets);
      expect(find.text('3h 12m'), findsOneWidget);
      // Legend names the libraries.
      expect(find.text('Movies'), findsOneWidget);
      expect(find.text('Shows'), findsOneWidget);
      expect(api.requestsTo('/media/stats').last.uri.queryParameters['days'], '30');

      await tester.tap(find.text('7d'));
      await settle(tester);
      expect(api.requestsTo('/media/stats').last.uri.queryParameters['days'], '7');
      expect(find.text('Plays · 7 days'), findsOneWidget);

      await _scrollTo(tester, find.text('Top users'));
      expect(find.text('Desperate Housewives'), findsOneWidget);
      expect(find.text('Jellyfin Android TV'), findsOneWidget);
    });

    testWidgets('empty history keeps the chart frames', (tester) async {
      final api = buildCoreFakeApi();
      serveMedia(api, stats: (d) => watchStats(days: d, empty: true));
      await pumpHubApp(tester, api: api, location: '/media?tab=stats');
      expect(find.text('Not enough watch history yet'), findsOneWidget);
      expect(find.text('Stats fill in as people watch.'), findsOneWidget);
      expect(find.text('Views over time'), findsOneWidget);
    });

    testWidgets('Users opens the per-user screen and history', (tester) async {
      final api = _api();
      await pumpHubApp(tester, api: api, location: '/media?tab=stats');
      await tester.tap(find.text('Users'));
      await settle(tester);
      expect(find.text('Watch stats by user'), findsOneWidget);
      final screen = find.byType(StatsUsersScreen);
      expect(find.descendant(of: screen, matching: find.text('Zenith Greyrat')), findsOneWidget);
      expect(find.descendant(of: screen, matching: find.textContaining('1 play · 25m')), findsOneWidget);
      await tester.tap(find.descendant(of: screen, matching: find.text('Zenith Greyrat')));
      await settle(tester);
      expect(find.text('Zenith Greyrat · history'), findsOneWidget);
      expect(find.text('Desperate Housewives · The Story of Lucy and Jessie'), findsOneWidget);
      expect(
        api.requestsTo('/media/stats/history').single.uri.queryParameters['userId'],
        '8bed8d8cccf249548eb6a39fd6a7e54b',
      );
    });
  });

  group('Apps', () {
    testWidgets('five rich tiles; tile body opens the details', (tester) async {
      await pumpHubApp(tester, api: _api(), location: '/media?tab=apps', size: const Size(400, 1400));
      expect(find.byType(MediaAppTile), findsNWidgets(5));
      expect(find.text('179 movies · 54 shows · 1,694 episodes'), findsOneWidget);
      expect(find.text('Up · v12.4.0'), findsOneWidget);
      // Shelfmark is web only.
      final shelfmark = find.ancestor(of: find.text('Shelfmark'), matching: find.byType(MediaAppTile));
      expect(find.descendant(of: shelfmark, matching: find.text('Open app')), findsNothing);
      expect(find.descendant(of: shelfmark, matching: find.text('Open web')), findsOneWidget);
      expect(find.text('Open app'), findsNWidgets(4));

      await tester.tap(find.text('Shelfmark'));
      await settle(tester);
      expect(find.text('Open Shelfmark to find books'), findsOneWidget);
    });

    testWidgets('returning from a detail screen keeps the tab the user picked', (tester) async {
      await pumpHubApp(tester, api: _api(), location: '/media?tab=stats', size: const Size(400, 1400));
      expect(find.text('Views over time'), findsOneWidget);
      await tester.tap(find.widgetWithText(Tab, 'Apps'));
      await settle(tester, frames: 16);
      expect(find.byType(MediaAppTile), findsNWidgets(5));
      await tester.tap(find.descendant(of: find.byType(MediaAppTile), matching: find.text('Shelfmark')));
      await settle(tester);
      expect(find.text('Open Shelfmark to find books'), findsOneWidget);
      await tester.pageBack();
      await settle(tester);
      expect(find.byType(MediaAppTile), findsNWidgets(5));
    });

    testWidgets('All web apps goes to the launcher', (tester) async {
      await pumpHubApp(tester, api: _api(), location: '/media?tab=apps', size: tabletSize);
      await tester.tap(find.text('All web apps'));
      await settle(tester);
      expect(find.text('Web apps'), findsWidgets);
    });
  });
}
