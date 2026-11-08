import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/features/media/media_module.dart';

import '../../support/test_hub.dart';
import 'media_fakes.dart';

void main() {
  group('GET /media/apps', () {
    test('five rich tiles with status, version and headlines', () async {
      final hub = TestHub();
      addTearDown(hub.close);
      hub.fakes.fakeAllMedia();
      hub.fakes.fakeShelfmark(stopped: true);
      final r = await hub.get('/api/v1/media/apps', as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      final apps = ItemList.fromJson(r.map, MediaApp.fromJson).items;
      expect(apps.map((a) => a.app), [
        MediaAppKind.jellyfin,
        MediaAppKind.audiobookshelf,
        MediaAppKind.kavita,
        MediaAppKind.seerr,
        MediaAppKind.shelfmark,
      ]);
      final byApp = {for (final a in apps) a.app: a};

      final jf = byApp[MediaAppKind.jellyfin]!;
      expect(jf.name, 'Jellyfin');
      expect(jf.status, MediaAppStatus.up);
      expect(jf.version, '12.4.0');
      expect(jf.headline, '179 movies · 54 shows · 1,694 episodes');
      expect(jf.route, '/media/jellyfin');
      expect(jf.web.app, ExternalApp.jellyfin);
      expect(jf.web.path, '/');

      final abs = byApp[MediaAppKind.audiobookshelf]!;
      expect(abs.version, '2.37.2');
      expect(abs.headline, '247 audiobooks · 83 authors · 1 in progress');
      expect(abs.route, '/media/audiobooks');

      final kavita = byApp[MediaAppKind.kavita]!;
      expect(kavita.status, MediaAppStatus.up);
      expect(kavita.version, '0.9.1.4');
      expect(kavita.headline, '3 series · 12 volumes');
      expect(kavita.route, '/media/books');

      final seerr = byApp[MediaAppKind.seerr]!;
      expect(seerr.headline, '0 pending · 3 processing · 1 available');
      expect(seerr.route, '/requests');

      final sm = byApp[MediaAppKind.shelfmark]!;
      expect(sm.status, MediaAppStatus.degraded);
      expect(sm.headline, '2 downloading · 1 queued · 5 added this week');
      expect(sm.route, '/media/shelfmark');
      expect(sm.web.app, ExternalApp.shelfmark);
    });

    test('unconfigured and unreachable apps keep a tile', () async {
      final hub = TestHub(
        unconfigured: {ServiceId.audiobookshelf},
        env: {'KAVITA_API_KEY': ''},
      );
      addTearDown(hub.close);
      hub.fakes
        ..fakeJellyfin()
        ..fakeShelfmark()
        ..fakeSeerrCounts();
      hub.fakes.on(
        ServiceId.jellyfin,
        'GET',
        '/Items/Counts',
        (_) => FakeResponse(500),
      );
      final r = await hub.get('/api/v1/media/apps');
      expect(r.status, 200, reason: r.body);
      final byApp = {
        for (final a in ItemList.fromJson(r.map, MediaApp.fromJson).items)
          a.app: a,
      };
      expect(
        byApp[MediaAppKind.audiobookshelf]!.status,
        MediaAppStatus.disabled,
      );
      expect(
        byApp[MediaAppKind.audiobookshelf]!.headline,
        'Not configured on the hub',
      );
      expect(byApp[MediaAppKind.kavita]!.headline, 'Needs an Auth Key');
      // Jellyfin answers its probe but the counts failed: no fake numbers.
      expect(byApp[MediaAppKind.jellyfin]!.status, MediaAppStatus.up);
      expect(byApp[MediaAppKind.jellyfin]!.headline, isNot(contains('movies')));
      expect(
        byApp[MediaAppKind.shelfmark]!.headline,
        '0 downloading · 0 queued · 0 added this week',
      );
    });
  });

  group('dashboard card media', () {
    test('now playing, counts, books, shelfmark and alerts', () async {
      final hub = TestHub();
      addTearDown(hub.close);
      hub.fakes.fakeAllMedia();
      hub.fakes.fakeShelfmark(stopped: true);
      hub.fakes.on(
        ServiceId.jellyfin,
        'GET',
        '/System/Info',
        (_) => FakeResponse.json({'HasPendingRestart': true}),
      );
      final r = await hub.get('/api/v1/dashboard?cards=media');
      expect(r.status, 200, reason: r.body);
      final dash = DashboardResponse.fromJson(r.map);
      final section = dash.cards['media']!;
      expect(section.status, SectionState.ok, reason: r.body);
      final card = section.decode(MediaCard.fromJson)!;
      expect(card.nowPlaying.single.title, 'A Spark. To Pierce the Dark.');
      expect(card.nowPlaying.single.remoteAddress, '192.168.10.160');
      expect(card.transcoding, 0);
      expect(card.counts!.movies, 179);
      expect(card.counts!.episodes, 1694);
      expect(card.audiobooks!.items, 247);
      expect(card.audiobooks!.inProgress, 1);
      expect(card.books!.series, 3);
      expect(card.books!.auth, BooksAuth.ok);
      expect(card.shelfmark!.active, 2);
      expect(card.shelfmark!.queued, 1);
      expect(card.shelfmark!.failed7d, 1);
      expect(card.recentlyAdded, hasLength(lessThanOrEqualTo(8)));
      expect(card.recentlyAdded, isNotEmpty);

      final ids = {for (final a in dash.alerts) a.id: a};
      expect(
        ids.keys,
        containsAll(['jellyfin.restart', 'shelfmark.coordinator']),
      );
      expect(ids['jellyfin.restart']!.route, '/containers/jellyfin');
      expect(ids['jellyfin.restart']!.severity, AlertSeverity.info);
      expect(ids['shelfmark.coordinator']!.route, '/media/shelfmark');
      expect(ids['shelfmark.coordinator']!.severity, AlertSeverity.warning);
      expect(ids.containsKey('kavita.auth'), isFalse);
    });

    test('members get the card without client addresses', () async {
      final hub = TestHub();
      addTearDown(hub.close);
      hub.fakes.fakeAllMedia();
      final r = await hub.get(
        '/api/v1/dashboard?cards=media',
        as: TestAs.member,
      );
      final card = DashboardResponse.fromJson(r.map).cards['media']!
          .decode(MediaCard.fromJson)!;
      expect(card.nowPlaying.single.remoteAddress, isNull);
      expect(card.nowPlaying.single.canControl, isFalse);
    });

    test('Kavita without a key raises kavita.auth', () async {
      final hub = TestHub(env: {'KAVITA_API_KEY': ''});
      addTearDown(hub.close);
      hub.fakes.fakeAllMedia();
      final r = await hub.get('/api/v1/dashboard?cards=media');
      final dash = DashboardResponse.fromJson(r.map);
      final card = dash.cards['media']!.decode(MediaCard.fromJson)!;
      expect(card.books!.auth, BooksAuth.missingKey);
      final alert = dash.alerts.firstWhere((a) => a.id == 'kavita.auth');
      expect(alert.severity, AlertSeverity.warning);
      expect(alert.route, '/media/books');
      expect(alert.title, 'Kavita needs an Auth Key');
    });

    test('optional parts fail without failing the card', () async {
      final hub = TestHub(unconfigured: {ServiceId.kavita});
      addTearDown(hub.close);
      hub.fakes.fakeJellyfin();
      hub.fakes.on(
        ServiceId.audiobookshelf,
        '*',
        RegExp('.*'),
        (_) => FakeResponse(500),
      );
      final r = await hub.get('/api/v1/dashboard?cards=media');
      final section = DashboardResponse.fromJson(r.map).cards['media']!;
      expect(section.status, SectionState.ok, reason: r.body);
      final card = section.decode(MediaCard.fromJson)!;
      expect(card.nowPlaying, hasLength(1));
      expect(card.audiobooks, isNull);
      expect(card.books, isNull);
      expect(card.shelfmark, isNull);
      expect(card.counts, isNotNull);
    });

    test('Jellyfin down fails the card', () async {
      final hub = TestHub();
      addTearDown(hub.close);
      hub.fakes.on(
        ServiceId.jellyfin,
        'GET',
        '/Sessions',
        (_) => FakeResponse(500),
      );
      final r = await hub.get('/api/v1/dashboard?cards=media');
      final section = DashboardResponse.fromJson(r.map).cards['media']!;
      expect(section.status, SectionState.error);
      expect(section.error!.code, 'upstream_error');
    });

    test('Jellyfin down keeps the Kavita and Shelfmark alerts', () async {
      final hub = TestHub(env: {'KAVITA_API_KEY': ''});
      addTearDown(hub.close);
      hub.fakes.fakeAllMedia();
      hub.fakes.fakeShelfmark(stopped: true);
      hub.fakes.on(
        ServiceId.jellyfin,
        'GET',
        '/Sessions',
        (_) => FakeResponse(500),
      );
      final r = await hub.get('/api/v1/dashboard?cards=media');
      final dash = DashboardResponse.fromJson(r.map);
      final section = dash.cards['media']!;
      expect(section.status, SectionState.error, reason: r.body);
      expect(section.error!.code, 'upstream_error');
      expect([
        for (final a in dash.alerts) a.id,
      ], containsAll(['kavita.auth', 'shelfmark.coordinator']));
    });

    test('Jellyfin not configured disables the card', () async {
      final hub = TestHub(unconfigured: {ServiceId.jellyfin});
      addTearDown(hub.close);
      final r = await hub.get('/api/v1/dashboard?cards=media');
      final section = DashboardResponse.fromJson(r.map).cards['media']!;
      expect(section.status, SectionState.disabled);
    });
  });

  test('mediaAlerts', () {
    const web = ExternalLink(ExternalApp.kavita, '/');
    final rejected = mediaAlerts(
      books: const BooksOverview(auth: BooksAuth.rejected, library: web),
    );
    expect(rejected.single.id, 'kavita.auth');
    expect(rejected.single.message, contains('rejected'));
    expect(
      mediaAlerts(
        books: const BooksOverview(auth: BooksAuth.ok, library: web),
      ),
      isEmpty,
    );
  });
}
