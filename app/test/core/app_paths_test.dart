import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/routing/router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GoRouter router;
  setUp(() => router = GoRouter(routes: buildAppRoutes()));
  tearDown(() => router.dispose());

  /// The route pattern [location] resolves to, or null when it matches none.
  String? patternOf(String location) {
    final match = router.configuration.findMatch(Uri.parse(location));
    if (match.isError || match.matches.isEmpty) return null;
    return match.fullPath;
  }

  const hash = 'e66aac4c7d8a4f813a4e5b3a63c1bb52beee342e';
  const magnet = 'magnet:?xt=urn:btih:e66aac4c7d8a4f813a4e5b3a63c1bb52beee342e&dn=Some+Show&tr=udp://x:1/a';

  // Every AppPaths helper (ARCHITECTURE §7.3) → the route it must land on.
  final cases = <String, String>{
    AppPaths.home(): '/home',
    AppPaths.webApps(): '/home/apps',
    AppPaths.requests(): '/requests',
    AppPaths.requestsSearch('dune part two'): '/requests/search',
    AppPaths.requestsDiscover('trending'): '/requests/discover/:slider',
    AppPaths.title('movie', 438631): '/requests/title/:mediaType/:tmdbId',
    AppPaths.requestsList(): '/requests/list',
    AppPaths.requestsList(tab: 'pending'): '/requests/list',
    AppPaths.requestDetail(12): '/requests/list/:id',
    AppPaths.issues(): '/requests/issues',
    AppPaths.issueDetail(3): '/requests/issues/:id',
    AppPaths.library(): '/library',
    AppPaths.library(tab: 'wanted'): '/library',
    AppPaths.seriesDetail(54): '/library/tv/:id',
    AppPaths.seasonDetail(54, 1): '/library/tv/:id/season/:n',
    AppPaths.movieDetail(9): '/library/movies/:id',
    AppPaths.libraryAdd(kind: 'tv', term: 'the expanse'): '/library/add',
    AppPaths.libraryHistory('sonarr', 54): '/library/history/:service/:id',
    AppPaths.activity(): '/activity',
    AppPaths.activity(tab: 'queue', importKey: 'sonarr:123'): '/activity',
    AppPaths.torrent(hash): '/activity/torrent/:hash',
    AppPaths.activityTransfer(): '/activity/transfer',
    AppPaths.activityAdd(url: magnet): '/activity/add',
    AppPaths.calendar(): '/calendar',
    AppPaths.media(): '/media',
    AppPaths.media(tab: 'stats'): '/media',
    AppPaths.mediaJellyfin(): '/media/jellyfin',
    AppPaths.mediaAudiobooks(): '/media/audiobooks',
    AppPaths.mediaBooks(): '/media/books',
    AppPaths.mediaShelfmark(): '/media/shelfmark',
    AppPaths.mediaStatsUsers(): '/media/stats/users',
    AppPaths.containers(): '/containers',
    AppPaths.container('sonarr'): '/containers/:name',
    AppPaths.container('jellystat-db'): '/containers/:name',
    AppPaths.containerLogs('sonarr'): '/containers/:name/logs',
    AppPaths.containersUpdates(): '/containers/updates',
    AppPaths.containersMaintenance(): '/containers/maintenance',
    AppPaths.indexers(): '/indexers',
    AppPaths.indexer(4): '/indexers/:id',
    AppPaths.indexersHistory(): '/indexers/history',
    AppPaths.indexersSearch(): '/indexers/search',
    AppPaths.subtitles(): '/subtitles',
    AppPaths.subtitles(tab: 'movies'): '/subtitles',
    AppPaths.system(): '/system',
    AppPaths.settings(): '/settings',
    AppPaths.settingsServers(): '/settings/servers',
    AppPaths.settingsServer('p_1'): '/settings/servers/:id',
    AppPaths.settingsAccount(): '/settings/account',
    AppPaths.settingsSessions(): '/settings/sessions',
    AppPaths.settingsUsers(): '/settings/users',
    AppPaths.settingsUser('u_1a2b3c4d5e6f'): '/settings/users/:id',
    AppPaths.settingsAudit(): '/settings/audit',
    AppPaths.settingsAppearance(): '/settings/appearance',
    AppPaths.settingsRefresh(): '/settings/refresh',
    AppPaths.settingsApps(): '/settings/apps',
    AppPaths.settingsAbout(): '/settings/about',
    AppPaths.more(): '/more',
    AppPaths.login(from: '/library/tv/54'): '/login',
    AppPaths.onboarding(): '/onboarding',
  };

  test('every AppPaths helper resolves to its registered route', () {
    for (final MapEntry(key: location, value: pattern) in cases.entries) {
      expect(patternOf(location), pattern, reason: location);
    }
  });

  test('static sub-routes win over parameterised siblings', () {
    expect(patternOf('/indexers/history'), '/indexers/history');
    expect(patternOf('/indexers/search'), '/indexers/search');
    expect(patternOf('/containers/updates'), '/containers/updates');
    expect(patternOf('/containers/maintenance'), '/containers/maintenance');
    expect(patternOf('/library/add'), '/library/add');
  });

  test('query values are encoded and null arguments omitted', () {
    expect(AppPaths.requestsList(), '/requests/list');
    expect(AppPaths.libraryAdd(), '/library/add');
    expect(AppPaths.activity(tab: 'queue', importKey: 'sonarr:1'), '/activity?tab=queue&import=sonarr%3A1');
    expect(Uri.parse(AppPaths.activityAdd(url: magnet)).queryParameters['url'], magnet);
    expect(Uri.parse(AppPaths.requestsSearch('a&b c')).queryParameters['q'], 'a&b c');
    expect(AppPaths.container('a b'), '/containers/a%20b');
  });

  test('unknown paths do not match', () {
    expect(patternOf('/nope'), isNull);
    expect(patternOf('/library/tv'), isNull);
  });

  group('alert routes in API.md', () {
    final apiDoc = File('../docs/API.md');

    List<String> alertRoutes() {
      final text = apiDoc.readAsStringSync();
      final routes = <String>{
        // `route `/indexers``, `route `/activity?tab=queue&import=<key>``
        for (final m in RegExp(r'route\s+`(/[^`]*)`').allMatches(text)) m[1]!,
        // MediaApp.route examples: `"route": string (..., e.g. "/media/audiobooks", ...)`
        for (final line in text.split('\n').where((l) => l.contains('"route": string')))
          for (final m in RegExp(r'"(/[a-z][^"\s]*)"').allMatches(line)) m[1]!,
        // Alert.route example in §1.8.
        for (final m in RegExp(r'app route to open, e\.g\. "(/[^"]+)"').allMatches(text)) m[1]!,
      };
      return [for (final r in routes) r.replaceAll('<key>', 'sonarr%3A123')];
    }

    test('the document is found and lists the alert routes', () {
      expect(apiDoc.existsSync(), isTrue, reason: 'run the tests from app/');
      final routes = alertRoutes();
      expect(
        routes,
        containsAll(<String>[
          '/requests/list?tab=pending',
          '/requests/list?tab=failed',
          '/library',
          '/activity',
          '/activity?tab=queue&import=sonarr%3A123',
          '/indexers',
          '/containers/updates',
          '/system',
          '/media/books',
          '/media/shelfmark',
          '/containers/jellyfin',
        ]),
      );
    });

    test('every alert route parses to a registered route', () {
      for (final route in alertRoutes()) {
        expect(patternOf(route), isNotNull, reason: route);
      }
    });
  });
}
