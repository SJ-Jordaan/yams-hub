import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/dashboard/dashboard_card_frame.dart';
import 'package:yams_hub/core/dashboard/dashboard_cards.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_hub/features/subtitles/subtitles_dashboard_card.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';

Widget _wrap(Widget child) => ProviderScope(
  retry: (_, _) => null,
  child: MaterialApp(
    theme: buildHubTheme(seededScheme(const Color(0xFF7C4DFF), Brightness.dark)),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

Section _section({int episodes = 111, int movies = 3, int throttled = 0, bool signalrDown = false}) => buildSection(
  SubtitlesCard(
    missingEpisodes: episodes,
    missingMovies: movies,
    throttledProviders: throttled,
    signalrDown: signalrDown,
  ).toJson(),
);

void main() {
  testWidgets('missing counts', (tester) async {
    await tester.pumpWidget(_wrap(SubtitlesDashboardCard(section: _section())));
    expect(find.text('111'), findsOneWidget);
    expect(find.text('episodes missing'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('movies missing'), findsOneWidget);
    expect(find.byType(StatusChip), findsNothing);
  });

  testWidgets('warnings for SignalR and throttled providers', (tester) async {
    await tester.pumpWidget(_wrap(SubtitlesDashboardCard(section: _section(throttled: 2, signalrDown: true))));
    expect(find.text('Sonarr/Radarr link down'), findsOneWidget);
    expect(find.text('2 providers throttled'), findsOneWidget);
  });

  testWidgets('nothing missing', (tester) async {
    await tester.pumpWidget(_wrap(SubtitlesDashboardCard(section: _section(episodes: 0, movies: 0, throttled: 1))));
    expect(find.text('No missing subtitles'), findsOneWidget);
    expect(find.text('1 provider throttled'), findsOneWidget);
  });

  testWidgets('inside the core frame with the registered spec', (tester) async {
    final spec = dashboardCards[DashboardCardKeys.subtitles]!;
    await tester.pumpWidget(_wrap(DashboardCardView(spec: spec, section: _section(episodes: 7))));
    expect(find.text('Subtitles'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
  });
}
