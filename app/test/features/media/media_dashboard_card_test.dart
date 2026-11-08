import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/auth/token_manager.dart';
import 'package:yams_hub/core/servers/server_connection.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/features/media/media_dashboard_card.dart';
import 'package:yams_hub/features/media/widgets/session_card.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import '../../support/pump_hub_app.dart';
import 'media_samples.dart';

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
      ],
      child: MaterialApp(
        theme: buildHubTheme(ColorScheme.fromSeed(seedColor: const Color(0xFF7C4DFF), brightness: Brightness.dark)),
        home: Scaffold(
          body: SingleChildScrollView(child: MediaDashboardCard(section: section)),
        ),
      ),
    ),
  );
  await tester.pump();
}

MediaCard _card({List<NowPlayingSession>? sessions, BooksAuth booksAuth = BooksAuth.ok}) => MediaCard(
  nowPlaying: sessions ?? [episodeSession(), transcodingSession()],
  transcoding: 1,
  counts: const MediaCardCounts(movies: 179, series: 54, episodes: 1694),
  audiobooks: const MediaCardAudiobooks(items: 247, inProgress: 1),
  books: MediaCardBooks(series: 3, auth: booksAuth),
  shelfmark: const MediaCardShelfmark(active: 2, queued: 1),
  recentlyAdded: const [],
);

void main() {
  testWidgets('one row per session with method chips and counts', (tester) async {
    await _pumpCard(tester, buildSection(_card().toJson()));
    expect(find.byType(SessionRow), findsNWidgets(2));
    expect(find.text('Desperate Housewives · S05E18'), findsOneWidget);
    expect(find.text('Zenith Greyrat · Xiaomi TV Box'), findsOneWidget);
    expect(find.text('Direct play'), findsOneWidget);
    expect(find.text('Transcode · QSV'), findsOneWidget);
    expect(find.text('2 playing · 1 transcoding'), findsOneWidget);
    expect(find.text('179 movies · 54 shows · 1,694 episodes'), findsOneWidget);
    expect(find.text('247 audiobooks · 1 in progress'), findsOneWidget);
    expect(find.text('3 book series'), findsOneWidget);
    expect(find.text('2 downloading · 1 queued'), findsOneWidget);
  });

  testWidgets('paused sessions show the paused icon', (tester) async {
    await _pumpCard(tester, buildSection(_card(sessions: [episodeSession(paused: true)]).toJson()));
    expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);
  });

  testWidgets('nothing playing', (tester) async {
    await _pumpCard(tester, buildSection(_card(sessions: const [], booksAuth: BooksAuth.missingKey).toJson()));
    expect(find.text('Nothing playing'), findsOneWidget);
    expect(find.text('Kavita needs a key'), findsOneWidget);
  });

  testWidgets('a malformed section does not crash', (tester) async {
    await _pumpCard(
      tester,
      buildSection({
        'nowPlaying': [
          {'title': 'no id'},
        ],
      }),
    );
    expect(find.textContaining('does not understand'), findsOneWidget);
  });

  testWidgets('on the dashboard: tap a session opens Media, counts open Jellyfin', (tester) async {
    final api = buildCoreFakeApi();
    serveMedia(api);
    api.getJson(
      '/dashboard',
      buildDashboardJson(cards: {...rawCards(), DashboardCardKeys.media: buildSection(_card().toJson()).toJson()}),
    );
    await pumpHubApp(tester, api: api, size: const Size(400, 2000));
    expect(find.text('Now playing'), findsWidgets);
    await tester.tap(find.text('179 movies · 54 shows · 1,694 episodes'));
    await settle(tester);
    expect(find.text('Zenith · v12.4.0 · Transcoding: QSV'), findsOneWidget);
  });
}
