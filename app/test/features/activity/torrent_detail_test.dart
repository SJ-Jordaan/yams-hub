import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'activity_samples.dart';

JsonMap _body(RequestOptions r) => readMap(r.data)!;

/// The vertical scrollable of the list keyed [key] (text fields and
/// selectable text add scrollables of their own).
Finder _scrollOf(String key) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Scrollable)).first;

void main() {
  group('torrent detail', () {
    testWidgets('shows general info, share limits, files and trackers', (tester) async {
      final api = activityFakeApi()..getJson('/torrents/$seedHash', buildDetail().toJson());
      await pumpHubApp(tester, api: api, location: '/activity/torrent/$seedHash');
      expect(find.text('Cyberpunk.Edgerunners.S02E01.1080p.WEB-DL'), findsWidgets);
      expect(find.text('Seeding'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('/data/downloads/torrents'),
        200,
        scrollable: _scrollOf('torrentDetailList'),
      );
      expect(find.text('/data/downloads/torrents'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Use global limits'), 200, scrollable: _scrollOf('torrentDetailList'));
      expect(find.text('Use global limits'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('http://nyaa.tracker.wf:7777'),
        300,
        scrollable: _scrollOf('torrentDetailList'),
      );
      expect(find.text('http://nyaa.tracker.wf:7777'), findsOneWidget);
      expect(find.text('Working'), findsOneWidget);
      expect(find.text('E01.mkv', findRichText: true), findsNothing);
    });

    group('tracker error chip (issue #1)', () {
      const working = TrackerInfo(url: 'udp://ok.example:80', tier: 0, status: TrackerInfoStatus.working);
      const dead = TrackerInfo(url: 'udp://dead.example:80', tier: 1, status: TrackerInfoStatus.trackerError);
      const down = TrackerInfo(url: 'udp://down.example:80', tier: 2, status: TrackerInfoStatus.unreachable);

      Future<void> pumpDetail(WidgetTester tester, {required bool flag, required List<TrackerInfo> trackers}) async {
        final detail = buildDetail(
          summary: buildTorrent(hasTrackerError: flag),
          trackers: trackers,
        );
        final api = activityFakeApi()..getJson('/torrents/$seedHash', detail.toJson());
        await pumpHubApp(tester, api: api, location: '/activity/torrent/$seedHash');
      }

      Future<void> scrollToTrackers(WidgetTester tester) => tester.scrollUntilVisible(
        find.text('udp://dead.example:80'),
        300,
        scrollable: _scrollOf('torrentDetailList'),
      );

      testWidgets('no chip while another tracker works, even with the raw flag of an older gateway', (tester) async {
        await pumpDetail(tester, flag: true, trackers: const [working, dead, down]);
        expect(find.byKey(const ValueKey('torrentTrackerError')), findsNothing);
        await scrollToTrackers(tester);
        // The softer signal: a quiet count on the trackers card and each tracker's own status.
        expect(find.text('2 of 3 failing'), findsOneWidget);
        expect(find.text('Tracker error'), findsOneWidget);
        expect(find.text('Unreachable'), findsOneWidget);
      });

      testWidgets('the chip shows when no tracker works', (tester) async {
        await pumpDetail(tester, flag: true, trackers: const [dead, down]);
        expect(find.byKey(const ValueKey('torrentTrackerError')), findsOneWidget);
        await scrollToTrackers(tester);
        expect(find.text('2 of 2 failing'), findsOneWidget);
      });

      testWidgets('healthy trackers: no chip and no count', (tester) async {
        await pumpDetail(tester, flag: false, trackers: const [working]);
        expect(find.byKey(const ValueKey('torrentTrackerError')), findsNothing);
        await tester.scrollUntilVisible(
          find.text('udp://ok.example:80'),
          300,
          scrollable: _scrollOf('torrentDetailList'),
        );
        expect(find.byKey(const ValueKey('trackersFailing')), findsNothing);
      });
    });

    testWidgets('404 says the torrent no longer exists', (tester) async {
      final api = activityFakeApi()
        ..on(
          'GET',
          '/torrents/$seedHash',
          (_) => FakeResponse.error(404, ApiErrorCode.notFound, message: 'Torrent no longer exists.'),
        );
      await pumpHubApp(tester, api: api, location: '/activity/torrent/$seedHash');
      expect(find.text('Torrent no longer exists'), findsOneWidget);
      expect(find.text('Back'), findsOneWidget);
    });

    testWidgets('members get no actions', (tester) async {
      final api = activityFakeApi(role: Role.member)..getJson('/torrents/$seedHash', buildDetail().toJson());
      await pumpHubApp(tester, api: api, role: Role.member, location: '/activity/torrent/$seedHash');
      expect(find.byKey(const ValueKey('torrentStop')), findsNothing);
      expect(find.byKey(const ValueKey('editShareLimits')), findsNothing);
    });

    testWidgets('stop sends the torrent action', (tester) async {
      final api = activityFakeApi()
        ..getJson('/torrents/$seedHash', buildDetail().toJson())
        ..postJson('/torrents/actions', {'ok': true});
      await pumpHubApp(tester, api: api, location: '/activity/torrent/$seedHash');
      await tester.tap(find.byKey(const ValueKey('torrentStop')));
      await settle(tester);
      expect(_body(api.requestsTo('/torrents/actions', method: 'POST').single), {
        'hashes': [seedHash],
        'action': 'stop',
      });
      expect(find.text('Stopped'), findsWidgets);
    });

    testWidgets('delete of an *arr-managed torrent offers the *arr removal', (tester) async {
      final summary = buildTorrent(hash: sonarrHash, category: 'tv-sonarr', name: 'Slime S4 Batch');
      var deletes = 0;
      final api = activityFakeApi()
        ..getJson('/torrents/$sonarrHash', buildDetail(summary: summary, arr: [buildArrEntry()]).toJson())
        ..on('POST', '/torrents/actions', (_) {
          deletes++;
          return FakeResponse.error(
            409,
            ApiErrorCode.managedByArr,
            message: 'Sonarr still tracks this download.',
            details: {
              'items': [
                {
                  'hash': sonarrHash,
                  'service': 'sonarr',
                  'queueIds': [123456, 123457],
                },
              ],
            },
          );
        })
        ..postJson('/activity/queue/remove', {'removed': 2, 'alreadyGone': 0});
      await pumpHubApp(tester, api: api, location: '/activity/torrent/$sonarrHash');
      expect(find.text('Tracked by Sonarr'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const ValueKey('torrentDelete')));
      await tester.tap(find.byKey(const ValueKey('torrentDelete')));
      await settle(tester);
      expect(find.text('Delete torrent?'), findsOneWidget);
      await tester.tap(find.text('Delete files (permanent)'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await settle(tester);
      expect(deletes, 1);
      expect(_body(api.requestsTo('/torrents/actions', method: 'POST').single), {
        'hashes': [sonarrHash],
        'action': 'delete',
        'deleteFiles': true,
        'confirm': true,
      });

      expect(find.text('Sonarr still tracks this download'), findsOneWidget);
      await tester.tap(find.text('Remove via Sonarr instead'));
      await settle(tester);
      expect(find.text('Remove from Sonarr queue?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await settle(tester);
      expect(_body(api.requestsTo('/activity/queue/remove', method: 'POST').single)['items'], [
        {
          'service': 'sonarr',
          'queueIds': [123456, 123457],
        },
      ]);
    });

    testWidgets('a removing share limit goes through the gateway confirmation', (tester) async {
      final api = activityFakeApi()..getJson('/torrents/$seedHash', buildDetail().toJson());
      final bodies = <JsonMap>[];
      api.on('PUT', '/torrents/$seedHash/share-limits', (r) {
        final body = _body(r);
        bodies.add(body);
        if (body['confirm'] != true) {
          return FakeResponse.error(
            428,
            ApiErrorCode.confirmationRequired,
            message: 'This action needs confirmation.',
            details: {'impact': 'qBittorrent will delete Cyberpunk and its files once ratio ≥ 2.0'},
          );
        }
        return FakeResponse(
          const ShareLimits(
            mode: ShareLimitsMode.custom,
            ratio: 2,
            action: ShareLimitsAction.removeWithContent,
            effectiveRatio: 2,
            effectiveSeedingMinutes: -1,
          ).toJson(),
        );
      });
      await pumpHubApp(tester, api: api, location: '/activity/torrent/$seedHash');
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('editShareLimits')),
        200,
        scrollable: _scrollOf('torrentDetailList'),
      );
      await tester.tap(find.byKey(const ValueKey('editShareLimits')));
      await settle(tester);
      await tester.tap(find.text('Custom'));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('shareRatio')), '2');
      await tester.tap(find.byKey(const ValueKey('shareAction')));
      await settle(tester);
      await tester.tap(find.text('Remove with files').last);
      await settle(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('saveShareLimits')));
      await tester.tap(find.byKey(const ValueKey('saveShareLimits')));
      await settle(tester);
      expect(find.text('qBittorrent will delete Cyberpunk and its files once ratio ≥ 2.0'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await settle(tester);
      expect(bodies, [
        {'mode': 'custom', 'ratio': 2.0, 'action': 'removeWithContent'},
        {'mode': 'custom', 'ratio': 2.0, 'action': 'removeWithContent', 'confirm': true},
      ]);
      expect(find.text('Share limits saved'), findsOneWidget);
    });
  });

  group('transfer settings', () {
    testWidgets('saves limits in B/s and toggles the session', (tester) async {
      final api = activityFakeApi()
        ..on('PUT', '/transfer/limits', (_) => FakeResponse(buildTransfer().toJson()))
        ..on('PUT', '/transfer/session', (_) => FakeResponse(buildTransfer().toJson()));
      await pumpHubApp(tester, api: api, location: '/activity/transfer');
      expect(find.text('Speed & session'), findsOneWidget);
      expect(find.text('10000'), findsNWidgets(2));
      await tester.enterText(find.byKey(const ValueKey('limit_up')), '512');
      await tester.tap(find.byKey(const ValueKey('saveLimits')));
      await settle(tester);
      expect(_body(api.requestsTo('/transfer/limits', method: 'PUT').single), {
        'dlBps': 0,
        'upBps': 524288,
        'altDlBps': 10240000,
        'altUpBps': 10240000,
      });
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('sessionSwitch')),
        200,
        scrollable: _scrollOf('transferSettingsList'),
      );
      await tester.drag(find.byType(ListView).first, const Offset(0, -150));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('sessionSwitch')));
      await settle(tester);
      expect(_body(api.requestsTo('/transfer/session', method: 'PUT').single), {'paused': true});
    });

    testWidgets('unknown limits are never saved as unlimited', (tester) async {
      final api = activityFakeApi()
        ..getJson('/transfer', {...buildTransfer().toJson()}..remove('limits'))
        ..on('PUT', '/transfer/limits', (_) => FakeResponse(buildTransfer().toJson()));
      await pumpHubApp(tester, api: api, location: '/activity/transfer');
      expect(find.text("Couldn't read the current limits."), findsOneWidget);
      FilledButton save() => tester.widget<FilledButton>(find.byKey(const ValueKey('saveLimits')));
      expect(save().onPressed, isNull);
      for (final (key, kib) in [('dl', '0'), ('up', '512'), ('altDl', '10000'), ('altUp', '10000')]) {
        await tester.enterText(find.byKey(ValueKey('limit_$key')), kib);
      }
      await tester.pump();
      expect(save().onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('saveLimits')));
      await settle(tester);
      expect(_body(api.requestsTo('/transfer/limits', method: 'PUT').single), {
        'dlBps': 0,
        'upBps': 524288,
        'altDlBps': 10240000,
        'altUpBps': 10240000,
      });
    });

    testWidgets('members are redirected', (tester) async {
      await pumpHubApp(
        tester,
        api: activityFakeApi(role: Role.member),
        role: Role.member,
        location: '/activity/transfer',
      );
      expect(find.text('Speed & session'), findsNothing);
      expect(find.text('Admins only'), findsOneWidget);
    });
  });

  group('add torrent page', () {
    testWidgets('pre-fills the magnet link from the route', (tester) async {
      const magnet = 'magnet:?xt=urn:btih:$seedHash&dn=x';
      final api = activityFakeApi()..postJson('/torrents/add', {'ok': true}, status: 201);
      await pumpHubApp(
        tester,
        api: api,
        location: Uri(path: '/activity/add', queryParameters: {'url': magnet}).toString(),
      );
      expect(find.text(magnet), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('torrentCategory')));
      await settle(tester);
      // Read-only categories are not offered (Sonarr/Radarr ones are, with a warning).
      expect(find.text('books'), findsNothing);
      expect(find.text('lidarr'), findsNothing);
      await tester.tap(find.text('tv-sonarr').last);
      await settle(tester);
      expect(find.textContaining('Sonarr/Radarr did not grab this'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('addTorrentButton')));
      await settle(tester);
      expect(_body(api.requestsTo('/torrents/add', method: 'POST').single), {
        'urls': [magnet],
        'category': 'tv-sonarr',
      });
    });

    testWidgets('a 422 from qBittorrent is shown inline', (tester) async {
      final api = activityFakeApi()
        ..on('POST', '/torrents/add', (_) {
          final e = ApiError(
            code: ApiErrorCode.validationFailed,
            message: 'qBittorrent rejected this torrent.',
            status: 422,
            service: ServiceId.qbittorrent,
          );
          return FakeResponse(e.toResponseBody(), status: 422);
        });
      await pumpHubApp(tester, api: api, location: '/activity/add?url=magnet%3A%3Fxt%3Durn%3Abtih%3A$seedHash');
      await tester.tap(find.byKey(const ValueKey('addTorrentButton')));
      await settle(tester);
      expect(find.text('qBittorrent rejected this torrent'), findsOneWidget);
    });

    testWidgets('members get Admins only', (tester) async {
      await pumpHubApp(
        tester,
        api: activityFakeApi(role: Role.member),
        role: Role.member,
        location: '/activity/add',
      );
      expect(find.byKey(const ValueKey('addTorrentButton')), findsNothing);
      expect(find.text('Admins only'), findsOneWidget);
    });
  });
}
