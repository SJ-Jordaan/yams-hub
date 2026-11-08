import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/routing/router.dart';
import 'package:yams_hub/features/indexers/indexers_dashboard_card.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import '../../support/pump_hub_app.dart';

Future<HubTestApp> _pumpWith(WidgetTester tester, JsonMap card) {
  final api = buildCoreFakeApi()
    ..getJson(
      '/dashboard',
      buildDashboardJson(
        cards: {
          ...rawCards(),
          DashboardCardKeys.indexers: buildSection(card).toJson(),
        },
      ),
    );
  return pumpHubApp(tester, api: api);
}

Future<void> _showCard(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byType(IndexersDashboardCard),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await settle(tester);
}

void main() {
  testWidgets('shows enabled/total, failing indexers and 24 h numbers', (
    tester,
  ) async {
    final retry = DateTime.now().add(const Duration(hours: 1));
    await _pumpWith(
      tester,
      IndexersCard(
        total: 10,
        enabled: 9,
        failing: [
          IndexersCardFailing(id: 15, name: 'Uindex', disabledTill: retry),
        ],
        grabs24h: 12,
        queries24h: 340,
      ).toJson(),
    );
    await _showCard(tester);

    final card = find.byType(IndexersDashboardCard);
    expect(find.descendant(of: card, matching: find.text('9')), findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.text(' / 10 enabled')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('12 grabs · 340 queries')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('Uindex')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.textContaining('retry at ')),
      findsOneWidget,
    );
  });

  testWidgets('all healthy, without 24 h stats', (tester) async {
    await _pumpWith(tester, const IndexersCard(total: 5, enabled: 5).toJson());
    await _showCard(tester);
    final card = find.byType(IndexersDashboardCard);
    expect(
      find.descendant(of: card, matching: find.text('All indexers working')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.textContaining('grabs')),
      findsNothing,
    );
  });

  testWidgets('many failing indexers collapse into "+N more"', (tester) async {
    await _pumpWith(
      tester,
      IndexersCard(
        total: 10,
        enabled: 10,
        failing: [
          for (var i = 1; i <= 6; i++)
            IndexersCardFailing(id: i, name: 'Indexer $i'),
        ],
      ).toJson(),
    );
    await _showCard(tester);
    expect(find.text('+2 more failing'), findsOneWidget);
    expect(find.text('Indexer 5'), findsNothing);
  });

  testWidgets('tapping the card opens /indexers', (tester) async {
    final app = await _pumpWith(
      tester,
      const IndexersCard(total: 5, enabled: 5).toJson(),
    );
    await _showCard(tester);
    await tester.tap(find.text('All indexers working'));
    await settle(tester);
    expect(
      app.container
          .read(routerProvider)
          .routerDelegate
          .currentConfiguration
          .uri
          .path,
      '/indexers',
    );
  });

  testWidgets('a card without data says so', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: IndexersDashboardCard(
              section: buildSection(const {'total': 0, 'enabled': 0}),
            ),
          ),
        ),
      ),
    );
    expect(find.text('No indexers configured in Prowlarr'), findsOneWidget);
  });
}
