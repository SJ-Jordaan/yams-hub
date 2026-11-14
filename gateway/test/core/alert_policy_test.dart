import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/core/dashboard/alert_policy.dart';

import '../support/test_hub.dart';

Alert _alert(
  String id, {
  AlertSeverity severity = AlertSeverity.warning,
  ServiceId source = ServiceId.sonarr,
  DateTime? since,
}) => Alert(
  id: id,
  severity: severity,
  source: source,
  feature: 'activity',
  title: id,
  since: since,
);

/// A card whose alerts (and superseded ids) the test sets.
final class _AlertsModule extends FeatureModule {
  _AlertsModule(this.id);

  @override
  final String id;
  List<Alert> alerts = const [];
  Set<String> supersedes = const {};
  bool fail = false;

  @override
  void registerRoutes(ApiRouter router) {}

  @override
  Future<DashboardContribution?> dashboard(ApiRequest req) async {
    if (fail) throw ApiException.internal();
    return DashboardContribution(
      data: const {},
      alerts: alerts,
      supersedes: supersedes,
    );
  }
}

void main() {
  group('AlertTracker', () {
    late FakeClock clock;
    late AlertTracker tracker;
    setUp(() {
      clock = FakeClock();
      tracker = AlertTracker(clock);
    });

    List<String> ids(List<Alert> alerts) => [for (final a in alerts) a.id];

    List<Alert> poll(List<Alert> alerts, [String card = 'activity']) {
      return tracker.apply(tracker.observe(card, alerts));
    }

    test('transient alerts wait out the grace period', () {
      final down = [_alert('vpn.down', severity: AlertSeverity.error)];
      final start = clock.now();
      expect(poll(down), isEmpty);
      clock.advance(transientAlertGrace - const Duration(seconds: 1));
      expect(poll(down), isEmpty);
      clock.advance(const Duration(seconds: 1));
      final shown = poll(down);
      expect(ids(shown), ['vpn.down']);
      expect(shown.single.since, start, reason: 'since is the first sighting');
    });

    test('a problem that clears and comes back starts over', () {
      final stopped = [_alert('container.stopped.sonarr')];
      poll(stopped);
      clock.advance(const Duration(minutes: 4));
      expect(poll(const []), isEmpty);
      clock.advance(const Duration(minutes: 2));
      expect(poll(stopped), isEmpty, reason: 'forgotten while it was gone');
      clock.advance(transientAlertGrace);
      expect(ids(poll(stopped)), ['container.stopped.sonarr']);
    });

    test('a flapping problem reaches the panel and does not blink', () {
      // A container in a restart loop: stopped in two polls out of three
      // (one 30 s poll every cycle sees it running).
      final stopped = [_alert('container.stopped.sonarr')];
      final start = clock.now();
      final shownAt = <Duration>[];
      for (var i = 0; i < 24; i++) {
        final present = i % 3 != 2;
        final out = poll(present ? stopped : const []);
        if (out.isNotEmpty) shownAt.add(clock.now().difference(start));
        clock.advance(const Duration(seconds: 30));
      }
      expect(shownAt.first, transientAlertGrace);
      final last = const Duration(seconds: 30) * 23;
      expect(shownAt, [
        for (
          var t = transientAlertGrace;
          t <= last;
          t += const Duration(seconds: 30)
        )
          t,
      ], reason: 'shown in every poll from 5 min on, absent polls included');
      expect(poll(stopped).single.since, start);
    });

    test('a VPN that keeps reconnecting is shown after 5 min', () {
      final down = [_alert('vpn.down', severity: AlertSeverity.error)];
      // Down for 2 min, up for 1 min, again and again.
      for (var minute = 0; minute < 5; minute++) {
        expect(poll(minute % 3 == 2 ? const [] : down), isEmpty);
        clock.advance(const Duration(minutes: 1));
      }
      expect(ids(poll(down)), ['vpn.down']);
    });

    test('a cleared alert goes away after the absence grace', () {
      final down = [_alert('vpn.down', severity: AlertSeverity.error)];
      poll(down);
      clock.advance(transientAlertGrace);
      expect(ids(poll(down)), ['vpn.down']);
      clock.advance(const Duration(minutes: 2));
      expect(ids(poll(const [])), ['vpn.down'], reason: 'may come back');
      clock.advance(const Duration(minutes: 1));
      expect(ids(poll(const [])), ['vpn.down']);
      clock.advance(const Duration(seconds: 1));
      expect(poll(const []), isEmpty, reason: 'gone for over 3 min');
      expect(poll(down), isEmpty, reason: 'a new occurrence waits again');
    });

    test('a non-transient alert goes as soon as it clears', () {
      final auth = [_alert('qbittorrent.auth', severity: AlertSeverity.error)];
      expect(ids(poll(auth)), ['qbittorrent.auth']);
      clock.advance(const Duration(seconds: 30));
      expect(poll(const []), isEmpty);
    });

    test('critical and non-transient alerts show at once with a since', () {
      final start = clock.now();
      final shown = poll([
        _alert('raid.degraded', severity: AlertSeverity.critical),
        _alert('qbittorrent.auth', severity: AlertSeverity.error),
        _alert('kavita.auth'),
        _alert('uptime.down.3', severity: AlertSeverity.critical),
      ]);
      expect(ids(shown), [
        'raid.degraded',
        'qbittorrent.auth',
        'kavita.auth',
        'uptime.down.3',
      ]);
      expect(shown.every((a) => a.since == start), isTrue);
      clock.advance(const Duration(hours: 2));
      final later = poll([_alert('kavita.auth')]);
      expect(later.single.since, start, reason: '"for 2 h", not "just now"');
    });

    test("an upstream's earlier since counts towards the grace period", () {
      final downAt = clock.now().subtract(const Duration(minutes: 20));
      final shown = poll([
        _alert('uptime.down.14', severity: AlertSeverity.error, since: downAt),
        _alert('vpn.port', since: clock.now().add(const Duration(minutes: 1))),
      ]);
      expect(ids(shown), ['uptime.down.14']);
      expect(shown.single.since, downAt);
    });

    test('each card keeps its own first-seen times', () {
      poll([_alert('bazarr.signalr')], 'subtitles');
      clock.advance(transientAlertGrace);
      // Another card's poll does not forget the subtitles alert.
      poll(const [], 'activity');
      expect(ids(poll([_alert('bazarr.signalr')], 'subtitles')), [
        'bazarr.signalr',
      ]);
    });

    test('several manual imports become one alert to the queue', () {
      final start = clock.now();
      poll([_alert('queue.import.a')]);
      clock.advance(const Duration(minutes: 3));
      final imports = [
        _alert('queue.import.a'),
        _alert('queue.import.b', source: ServiceId.radarr),
        _alert('queue.import.c'),
        _alert('host.volume'),
      ];
      poll(imports);
      clock.advance(const Duration(minutes: 2));
      expect(ids(poll(imports)), ['queue.import.a', 'host.volume']);
      clock.advance(const Duration(minutes: 3));
      final shown = poll(imports);
      expect(ids(shown), ['host.volume', queueImportsAlertId]);
      final merged = shown.last;
      expect(merged.title, '3 downloads need manual import');
      expect(merged.route, '/activity?tab=queue');
      expect(merged.severity, AlertSeverity.warning);
      expect(merged.since, start, reason: 'the oldest import');
      expect(merged.message, contains('Radarr and Sonarr'));
    });

    test('one manual import keeps its own alert', () {
      final one = [_alert('queue.import.a')];
      poll(one);
      clock.advance(transientAlertGrace);
      expect(ids(poll(one)), ['queue.import.a']);
    });
  });

  test('transient ids', () {
    for (final id in [
      'vpn.down',
      'vpn.port',
      'bazarr.signalr',
      'container.stopped.x',
      'container.unhealthy.x',
      'uptime.down.1',
      'uptime.incident',
      'sonarr.queue.errors',
      'queue.import.abc',
    ]) {
      expect(isTransientAlert(id), isTrue, reason: id);
    }
    for (final id in [
      'raid.degraded',
      'qbittorrent.auth',
      'vpn.unreadable',
      'kavita.auth',
      'sonarr.allowedHosts',
      'updates.available',
      'seerr.failed',
      'host.volume',
    ]) {
      expect(isTransientAlert(id), isFalse, reason: id);
    }
  });

  test('fingerprinted dismissal keys follow the content', () {
    final a = fingerprintedDismissKey('updates.available', ['sonarr@sha:1']);
    expect(a, matches(RegExp(r'^updates\.available:[0-9a-f]{8}$')));
    expect(
      fingerprintedDismissKey('updates.available', ['sonarr@sha:1']),
      a,
      reason: 'stable',
    );
    expect(
      fingerprintedDismissKey('updates.available', ['sonarr@sha:2']),
      isNot(a),
    );
    expect(
      fingerprintedDismissKey('updates.available', ['sonarr@sha:1', 'radarr']),
      isNot(a),
    );
  });

  group('GET /dashboard', () {
    late _AlertsModule activity;
    late _AlertsModule library;
    late TestHub hub;
    setUp(() {
      activity = _AlertsModule('activity');
      library = _AlertsModule('library');
      hub = TestHub(modules: (ctx) => [activity, library]);
    });
    tearDown(() => hub.close());

    Future<List<Alert>> alerts() async {
      final r = await hub.get('/api/v1/dashboard?cards=activity,library');
      expect(r.status, 200, reason: r.body);
      return DashboardResponse.fromJson(r.map).alerts;
    }

    test('holds transient alerts back and dates every alert', () async {
      final start = hub.clock.now();
      activity.alerts = [
        _alert('vpn.down', severity: AlertSeverity.error),
        _alert('qbittorrent.auth', severity: AlertSeverity.error),
      ];
      expect((await alerts()).map((a) => a.id), ['qbittorrent.auth']);
      hub.clock.advance(transientAlertGrace);
      final shown = await alerts();
      expect(shown.map((a) => a.id), ['qbittorrent.auth', 'vpn.down']);
      expect(shown.every((a) => a.since == start), isTrue);
    });

    test("a member's polls do not reset admin-only alerts", () async {
      final start = hub.clock.now();
      activity.alerts = [_alert('vpn.port')];
      library.alerts = [_alert('privacy.jellyfin.libraries')];
      await alerts();
      // A member's dashboard leaves the admin-only alert out.
      library.alerts = const [];
      for (var i = 0; i < 5; i++) {
        hub.clock.advance(const Duration(minutes: 1));
        final r = await hub.get(
          '/api/v1/dashboard?cards=activity,library',
          as: TestAs.member,
        );
        final ids = DashboardResponse.fromJson(r.map).alerts.map((a) => a.id);
        expect(ids, isNot(contains('privacy.jellyfin.libraries')));
      }
      library.alerts = [_alert('privacy.jellyfin.libraries')];
      final shown = await alerts();
      expect(
        shown.firstWhere((a) => a.id == 'privacy.jellyfin.libraries').since,
        start,
        reason: 'the admin first saw it 5 min ago',
      );
      expect(shown.map((a) => a.id), contains('vpn.port'));
    });

    test('a card that fails keeps its first-seen times', () async {
      activity.alerts = [_alert('vpn.port')];
      await alerts();
      hub.clock.advance(const Duration(minutes: 3));
      activity.fail = true;
      await alerts();
      hub.clock.advance(const Duration(minutes: 2));
      activity.fail = false;
      expect((await alerts()).map((a) => a.id), ['vpn.port']);
    });

    test('superseded alerts are dropped', () async {
      library.alerts = [
        _alert('sonarr.queue.errors'),
        _alert('radarr.queue.errors'),
      ];
      activity.alerts = [_alert('queue.import.a')];
      activity.supersedes = {'sonarr.queue.errors'};
      await alerts();
      hub.clock.advance(transientAlertGrace);
      expect((await alerts()).map((a) => a.id).toSet(), {
        'radarr.queue.errors',
        'queue.import.a',
      });
      // Once the import is done the library alert is back (with its
      // original first-seen time: no new grace period).
      activity
        ..alerts = const []
        ..supersedes = const {};
      // The import alert lingers through the absence grace.
      expect((await alerts()).map((a) => a.id).toSet(), {
        'queue.import.a',
        'radarr.queue.errors',
        'sonarr.queue.errors',
      });
      hub.clock.advance(alertAbsenceGrace + const Duration(seconds: 1));
      expect((await alerts()).map((a) => a.id).toSet(), {
        'radarr.queue.errors',
        'sonarr.queue.errors',
      });
    });
  });
}
