import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/features/requests/screens/title_screen.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'requests_samples.dart';

void main() {
  testWidgets('shows the carousels, hides the empty watchlist, badges pending', (tester) async {
    final api = buildCoreFakeApi();
    serveDiscover(api);
    await pumpHubApp(tester, api: api, location: '/requests');

    expect(find.text('Discover'), findsWidgets);
    expect(find.text('Trending'), findsOneWidget);
    expect(find.text('Popular movies'), findsOneWidget);
    expect(find.text('Dune'), findsWidgets);
    expect(find.byTooltip('Available'), findsWidgets);
    expect(find.text('Your watchlist'), findsNothing);
    // Admin: the Requests action carries the pending count.
    final inbox = find.byIcon(Icons.inbox_outlined);
    expect(inbox, findsOneWidget);
    expect(
      find.descendant(
        of: find.ancestor(of: inbox, matching: find.byType(Badge)),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a failing carousel shows an inline retry, the others stay', (tester) async {
    final api = buildCoreFakeApi();
    serveDiscover(api);
    api.on(
      'GET',
      '/discover/popular-movies',
      (_) => FakeResponse.error(503, ApiErrorCode.upstreamUnavailable, message: 'Seerr is not reachable.'),
    );
    await pumpHubApp(tester, api: api, location: '/requests');
    expect(find.text('Seerr is not reachable.'), findsOneWidget);
    expect(find.text('Trending'), findsOneWidget);
    expect(find.text('Dune'), findsWidgets);

    api.getJson('/discover/popular-movies', page([card(9, 'Heat')]));
    await tester.tap(find.text('Retry').first);
    await settle(tester);
    expect(find.text('Seerr is not reachable.'), findsNothing);
  });

  testWidgets('filter chips narrow trending to movies', (tester) async {
    final api = buildCoreFakeApi();
    serveDiscover(api);
    await pumpHubApp(tester, api: api, location: '/requests');
    await tester.tap(find.widgetWithText(FilterChip, 'Movies'));
    await settle(tester);
    expect(find.text('Trending movies'), findsOneWidget);
    expect(find.text('Popular series'), findsNothing);
    expect(api.requestsTo('/discover/trending').last.uri.queryParameters['mediaType'], 'movie');
  });

  testWidgets('members get "My requests" and the watchlist when it has titles', (tester) async {
    final api = buildCoreFakeApi(role: Role.member);
    serveDiscover(api);
    api.getJson('/discover/watchlist', page([card(260463, 'Daemons of the Shadow Realm', type: MediaType.tv)]));
    await pumpHubApp(tester, api: api, role: Role.member, location: '/requests');
    expect(find.text('My requests'), findsOneWidget);
    expect(find.byIcon(Icons.inbox_outlined), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Your watchlist'),
      300,
      scrollable: find.descendant(of: find.byType(RefreshIndicator), matching: find.byType(Scrollable)).first,
    );
    expect(find.text('Daemons of the Shadow Realm'), findsOneWidget);
  });

  testWidgets('tapping a poster opens the title page', (tester) async {
    final api = buildCoreFakeApi();
    serveDiscover(api, items: [card(603, 'The Matrix')]);
    api.getJson('/titles/movie/603', movie().toJson());
    await pumpHubApp(tester, api: api, location: '/requests');
    await tester.tap(find.text('The Matrix').first);
    await settle(tester);
    expect(find.byType(TitleScreen), findsOneWidget);
    expect(find.text('Welcome to the Real World.'), findsOneWidget);
  });

  group('search', () {
    testWidgets('submitting the field opens results with the prefix tip', (tester) async {
      final api = buildCoreFakeApi();
      serveDiscover(api);
      api.getJson('/search', page([card(438631, 'Dune'), card(90228, 'Dune: Prophecy', type: MediaType.tv)]));
      await pumpHubApp(tester, api: api, location: '/requests');
      await tester.enterText(find.byType(TextField).first, "grey's");
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settle(tester);
      expect(api.requestsTo('/search').single.uri.queryParameters, {'q': "grey's", 'page': '1'});
      expect(find.text('Dune: Prophecy'), findsOneWidget);
      expect(find.textContaining('tmdb:603'), findsOneWidget);
    });

    testWidgets('no results', (tester) async {
      final api = buildCoreFakeApi()..getJson('/search', page(const []));
      await pumpHubApp(tester, api: api, location: '/requests/search?q=zzzz');
      expect(find.text("No titles match 'zzzz'"), findsOneWidget);
    });

    testWidgets('loads the next page and stops at totalPages', (tester) async {
      final api = buildCoreFakeApi();
      api.on('GET', '/search', (r) {
        final p = int.parse(r.uri.queryParameters['page']!);
        return FakeResponse(
          TitlePage(
            page: p,
            totalPages: 2,
            totalResults: 40,
            items: [for (var i = 0; i < 20; i++) card(p * 100 + i, 'Title ${p * 100 + i}')],
          ).toJson(),
        );
      });
      await pumpHubApp(tester, api: api, location: '/requests/search?q=title');
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -6000));
      await settle(tester);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -6000));
      await settle(tester);
      final pages = api.requestsTo('/search').map((r) => r.uri.queryParameters['page']).toList();
      expect(pages, ['1', '2']);
    });
  });
}
