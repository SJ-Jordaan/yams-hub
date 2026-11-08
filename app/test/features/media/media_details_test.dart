import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/features/media/providers/media_providers.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'media_samples.dart';

final _vertical = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);

Future<void> _scrollTo(WidgetTester tester, Finder finder) =>
    tester.scrollUntilVisible(finder, 200, scrollable: _vertical.last);

FakeApi _api({Role role = Role.admin, BooksOverview? books, ShelfmarkStatus? shelfmark, JellyfinOverview? jellyfin}) {
  final api = buildCoreFakeApi(role: role);
  serveMedia(api, books: books, shelfmark: shelfmark, jellyfin: jellyfin);
  return api;
}

void main() {
  group('Jellyfin', () {
    testWidgets('counts, libraries and rows; admins scan', (tester) async {
      final api = _api();
      api.on('POST', '/media/jellyfin/library/refresh', (_) => const FakeResponse({'queued': true}, status: 202));
      await pumpHubApp(tester, api: api, location: '/media/jellyfin');
      expect(find.text('Zenith · v12.4.0 · Transcoding: QSV'), findsOneWidget);
      expect(find.text('179'), findsOneWidget);
      expect(find.text('1,694'), findsOneWidget);
      expect(find.text('Shows'), findsWidgets);
      expect(find.text('54 items · 1,695 files · 2.5 TiB'), findsOneWidget);
      expect(find.byTooltip('Scanning'), findsOneWidget, reason: 'Movies is refreshing');
      await _scrollTo(tester, find.text('Continue watching'));
      expect(find.text('Clevatess'), findsOneWidget);

      await tester.tap(find.byTooltip('Scan libraries'));
      await settle(tester);
      expect(api.requestsTo('/media/jellyfin/library/refresh', method: 'POST'), hasLength(1));
      expect(find.text('Library scan started'), findsOneWidget);
    });

    testWidgets('members cannot scan', (tester) async {
      await pumpHubApp(
        tester,
        api: _api(role: Role.member),
        role: Role.member,
        location: '/media/jellyfin',
      );
      expect(find.text('Recently added'), findsOneWidget);
      expect(find.byTooltip('Scan libraries'), findsNothing);
    });

    testWidgets('a failed first load shows the error view', (tester) async {
      final api = _api();
      api.on(
        'GET',
        '/media/jellyfin',
        (_) => FakeResponse.error(503, ApiErrorCode.serviceNotConfigured, message: 'Jellyfin is not configured.'),
      );
      await pumpHubApp(tester, api: api, location: '/media/jellyfin');
      expect(find.text('Not configured on the hub'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });
  });

  group('Audiobookshelf', () {
    testWidgets('stats, continue listening, hint and listening chart', (tester) async {
      final app = await pumpHubApp(tester, api: _api(), location: '/media/audiobooks');
      expect(find.text('247'), findsOneWidget);
      expect(find.text('83'), findsOneWidget);
      expect(find.text('Lonely Castle in the Mirror'), findsOneWidget);
      expect(find.text('9h 23m left'), findsOneWidget);
      expect(find.text('Some authors and narrators look swapped'), findsOneWidget);

      await tester.tap(find.byTooltip('Dismiss'));
      await settle(tester);
      expect(find.text('Some authors and narrators look swapped'), findsNothing);
      expect(app.prefs.getBool(AbsNamingHintController.storageKey), isTrue);

      await _scrollTo(tester, find.text('Today 16m'));
      expect(find.textContaining('Minutes per day'), findsOneWidget);
    });
  });

  group('Kavita', () {
    testWidgets('stats, on deck and recently added', (tester) async {
      await pumpHubApp(tester, api: _api(), location: '/media/books');
      expect(find.text('Series'), findsOneWidget);
      expect(find.text('On deck'), findsOneWidget);
      expect(find.text('Mushoku Tensei'), findsOneWidget);
      expect(find.text('Ascendance of a Bookworm'), findsOneWidget);
    });

    testWidgets('missing key shows the setup card', (tester) async {
      await pumpHubApp(
        tester,
        api: _api(books: booksOverview(auth: BooksAuth.missingKey)),
        location: '/media/books',
      );
      expect(find.byKey(const Key('media.books.setup')), findsOneWidget);
      expect(find.text('Kavita needs an Auth Key'), findsOneWidget);
      expect(find.textContaining('KAVITA_API_KEY'), findsOneWidget);
    });

    testWidgets('rejected key', (tester) async {
      await pumpHubApp(
        tester,
        api: _api(books: booksOverview(auth: BooksAuth.rejected)),
        location: '/media/books',
      );
      expect(find.text('Kavita rejected the key'), findsOneWidget);
    });

    testWidgets('no series: the folder hint', (tester) async {
      await pumpHubApp(
        tester,
        api: _api(books: booksOverview(noSeries: true)),
        location: '/media/books',
      );
      expect(find.text('Kavita needs one folder per series'), findsOneWidget);
      expect(find.textContaining('books/lightnovels/<Series>'), findsOneWidget);
    });
  });

  group('Shelfmark', () {
    testWidgets('stopped coordinator: banner and counts', (tester) async {
      await pumpHubApp(
        tester,
        api: _api(shelfmark: shelfmarkStatus(stopped: true)),
        location: '/media/shelfmark',
      );
      expect(find.text('The download coordinator is stopped'), findsOneWidget);
      expect(find.text('Downloads stopped'), findsOneWidget);
      expect(find.text('Degraded'), findsOneWidget);
      expect(find.text('Downloading'), findsOneWidget);
      expect(find.text('Awaiting pickup'), findsOneWidget);
      await _scrollTo(tester, find.text('Open Shelfmark to find books'));
      expect(find.text('1 failed download in the last 7 days'), findsOneWidget);
      expect(find.text('Ebooks'), findsOneWidget);
      expect(find.textContaining('land in Audiobookshelf and Kavita'), findsOneWidget);
    });

    testWidgets('empty: no book downloads yet, still offers Shelfmark', (tester) async {
      await pumpHubApp(
        tester,
        api: _api(shelfmark: shelfmarkStatus(empty: true)),
        location: '/media/shelfmark',
      );
      expect(find.text('No book downloads yet'), findsOneWidget);
      expect(find.text('Healthy'), findsOneWidget);
      expect(find.text('Downloads running'), findsOneWidget);
      expect(find.text('The download coordinator is stopped'), findsNothing);
      await _scrollTo(tester, find.text('Open Shelfmark to find books'));
      expect(find.text('Open Shelfmark to find books'), findsOneWidget);
    });
  });
}
