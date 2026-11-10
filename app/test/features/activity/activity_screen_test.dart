import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'activity_samples.dart';

JsonMap _body(RequestOptions r) => readMap(r.data)!;

void main() {
  group('queue tab', () {
    testWidgets('attention tiles offer Import… and Open in Sonarr to admins', (tester) async {
      final api = activityFakeApi();
      await pumpHubApp(tester, api: api, location: '/activity');

      expect(find.text('Activity'), findsWidgets);
      expect(find.text('That Time I Got Reincarnated as a Slime'), findsOneWidget);
      expect(find.text('Sonarr · S04E01–E02'), findsOneWidget);
      expect(find.text('Import pending'), findsOneWidget);
      expect(find.textContaining('Manual import needed: No files found'), findsOneWidget);
      expect(find.text('Import…'), findsOneWidget);
      expect(find.text('Open in Sonarr'), findsOneWidget);
      expect(find.text('Dune: Part Two'), findsOneWidget);
      // Header: speeds, schedule caption and VPN chip.
      expect(find.text('Alt speed on · Scheduled 08:00–17:00'), findsOneWidget);
      expect(find.text('France'), findsOneWidget);
      expect(api.requestsTo('/activity/queue').first.uri.queryParameters['filter'], 'active');
    });

    testWidgets('members see the queue without admin actions', (tester) async {
      await pumpHubApp(
        tester,
        api: activityFakeApi(role: Role.member),
        role: Role.member,
        location: '/activity',
      );
      expect(find.text('That Time I Got Reincarnated as a Slime'), findsOneWidget);
      expect(find.text('Import…'), findsNothing);
      expect(find.byTooltip('Actions'), findsNothing);
      expect(find.byKey(const ValueKey('activityMenu')), findsNothing);
    });

    testWidgets('filter chips query the gateway', (tester) async {
      final api = activityFakeApi();
      await pumpHubApp(tester, api: api, location: '/activity');
      await tester.ensureVisible(find.text('Needs attention'));
      await tester.tap(find.text('Needs attention'));
      await settle(tester);
      expect(api.requestsTo('/activity/queue').last.uri.queryParameters['filter'], 'attention');
    });

    testWidgets('empty queue links to the seeding torrents', (tester) async {
      final api = activityFakeApi(queue: buildQueue(items: const [], seeding: 12));
      await pumpHubApp(tester, api: api, location: '/activity');
      expect(find.text('No active downloads'), findsOneWidget);
      await tester.tap(find.text('Seeding: 12'));
      await settle(tester);
      expect(find.text('Cyberpunk.Edgerunners.S02E01.1080p.WEB-DL'), findsOneWidget);
    });

    testWidgets('a failing source shows a banner, a failed first load the error view', (tester) async {
      final api = activityFakeApi(
        queue: buildQueue(
          radarr: const SectionStatus.failure(
            ApiError(code: ApiErrorCode.upstreamUnavailable, message: 'Radarr is not reachable.', status: 503),
          ),
        ),
      );
      await pumpHubApp(tester, api: api, location: '/activity');
      expect(find.text("Radarr unreachable, its queue isn't shown"), findsOneWidget);

      api.on(
        'GET',
        '/activity/queue',
        (_) => FakeResponse.error(503, ApiErrorCode.upstreamUnavailable, message: 'qBittorrent is not reachable.'),
      );
      await tester.ensureVisible(find.text('All'));
      await tester.tap(find.text('All'));
      await settle(tester);
      expect(find.text('qBittorrent is not reachable.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('manual import', () {
    FakeApi importApi() {
      final api = activityFakeApi()
        ..getJson('/activity/queue/sonarr/123456/import', buildCandidates().toJson())
        ..postJson('/activity/queue/import', {
          'command': const CommandRef(
            service: ServiceId.sonarr,
            id: 77,
            name: 'ManualImport',
            status: CommandStatus.completed,
            result: CommandResult.successful,
          ).toJson(),
        }, status: 202)
        ..getJson('/library/commands/sonarr/77', {
          'command': const CommandRef(
            service: ServiceId.sonarr,
            id: 77,
            name: 'ManualImport',
            status: CommandStatus.completed,
            result: CommandResult.successful,
          ).toJson(),
        });
      return api;
    }

    testWidgets('Import… lists candidates and imports the checked files', (tester) async {
      final api = importApi();
      await pumpHubApp(tester, api: api, location: '/activity');
      await tester.tap(find.text('Import…'));
      await settle(tester);

      expect(find.text('Manual import'), findsOneWidget);
      expect(find.text('[SubsPlease] Tensei Shitara Slime Datta Ken - 73 (1080p).mkv'), findsOneWidget);
      expect(find.text('S04E01 (073) · Episode 1'), findsOneWidget);
      expect(find.text('Unable to determine if file is a sample'), findsOneWidget);
      expect(find.text('Import 1 file'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('importButton')));
      await settle(tester, frames: 10);
      final sent = _body(api.requestsTo('/activity/queue/import', method: 'POST').single);
      expect(sent, {
        'service': 'sonarr',
        'queueId': 123456,
        'importMode': 'auto',
        'files': [
          {'fileId': 'mi_1'},
        ],
      });
      expect(find.text('Import finished'), findsOneWidget);
      expect(find.text('Manual import'), findsNothing);
    });

    testWidgets('Move asks for confirmation', (tester) async {
      final api = importApi();
      await pumpHubApp(tester, api: api, location: '/activity');
      await tester.tap(find.text('Import…'));
      await settle(tester);
      await tester.tap(find.text('Move'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('importButton')));
      await settle(tester);
      expect(find.text('Files are moved out of the download folder; the torrent stops seeding them.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(api.requestsTo('/activity/queue/import', method: 'POST'), isEmpty);
    });

    testWidgets('the import= link opens the sheet; a gone item says Already resolved', (tester) async {
      final api = importApi();
      await pumpHubApp(tester, api: api, location: '/activity?tab=queue&import=$sonarrHash');
      await settle(tester);
      expect(find.text('Manual import'), findsOneWidget);
      expect(api.requestsTo('/activity/queue/sonarr/123456/import'), hasLength(1));
    });

    testWidgets('a resolved item from an old alert', (tester) async {
      await pumpHubApp(tester, api: activityFakeApi(), location: '/activity?import=sonarr:${'c' * 40}');
      await settle(tester);
      expect(find.text('Already resolved'), findsOneWidget);
      expect(find.text('Manual import'), findsNothing);
    });

    testWidgets('no candidates', (tester) async {
      final api = activityFakeApi()
        ..getJson(
          '/activity/queue/sonarr/123456/import',
          const ManualImportCandidates(
            service: ArrService.sonarr,
            queueId: 123456,
            downloadId: 'X',
            title: 't',
          ).toJson(),
        );
      await pumpHubApp(tester, api: api, location: '/activity');
      await tester.tap(find.text('Import…'));
      await settle(tester);
      expect(find.text('Sonarr found no files to import'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Open in Sonarr'), findsOneWidget);
    });
  });

  group('queue actions', () {
    testWidgets('Remove… sends the dialog options with confirm', (tester) async {
      final api = activityFakeApi()..postJson('/activity/queue/remove', {'removed': 2, 'alreadyGone': 0});
      await pumpHubApp(tester, api: api, location: '/activity');
      await tester.tap(find.byTooltip('Actions').first);
      await settle(tester);
      // The action list scrolls inside the sheet.
      await tester.drag(find.text('Open in Library'), const Offset(0, -300));
      await settle(tester);
      await tester.tap(find.text('Remove…'));
      await settle(tester);
      expect(find.text('Remove from Sonarr queue?'), findsOneWidget);
      // Search again is disabled until the release is blocklisted.
      final search = tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Search again'));
      expect(search.onChanged, isNull);
      await tester.tap(find.text('Blocklist release'));
      await settle(tester);
      await tester.tap(find.text('Search again'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await settle(tester);
      expect(_body(api.requestsTo('/activity/queue/remove', method: 'POST').single), {
        'items': [
          {
            'service': 'sonarr',
            'queueIds': [123456, 123457],
          },
        ],
        'removeFromClient': true,
        'blocklist': true,
        'searchAgain': true,
        'confirm': true,
      });
      expect(find.text('Removed from Sonarr'), findsOneWidget);
    });
  });

  group('torrents tab', () {
    testWidgets('lists torrents with the admin FAB and opens the add sheet', (tester) async {
      final api = activityFakeApi()..postJson('/torrents/add', {'ok': true}, status: 201);
      await pumpHubApp(tester, api: api, location: '/activity?tab=torrents');
      await settle(tester);
      expect(find.text('Cyberpunk.Edgerunners.S02E01.1080p.WEB-DL'), findsOneWidget);
      expect(find.text('[ToonsHub] The Apothecary Diaries S03E06 1080p'), findsOneWidget);
      expect(find.byKey(const ValueKey('addTorrentFab')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('addTorrentFab')));
      await settle(tester);
      expect(find.text('Add torrent'), findsWidgets);
      await tester.enterText(find.byKey(const ValueKey('torrentUrls')), 'not a link');
      await tester.tap(find.byKey(const ValueKey('addTorrentButton')));
      await settle(tester);
      expect(find.textContaining('Not a magnet link'), findsOneWidget);
      expect(api.requestsTo('/torrents/add'), isEmpty);

      const magnet = 'magnet:?xt=urn:btih:$seedHash&dn=x';
      await tester.enterText(find.byKey(const ValueKey('torrentUrls')), magnet);
      await tester.tap(find.byKey(const ValueKey('addTorrentButton')));
      await settle(tester);
      expect(_body(api.requestsTo('/torrents/add', method: 'POST').single), {
        'urls': [magnet],
        'category': 'manual',
      });
      expect(find.text('Added to qBittorrent'), findsOneWidget);
    });

    testWidgets('the tracker error icon follows the gateway flag', (tester) async {
      final api = activityFakeApi()
        ..getJson(
          '/torrents',
          buildTorrentList(
            items: [
              buildTorrent(hasTrackerError: true),
              buildTorrent(hash: sonarrHash, name: 'Healthy trackers', category: 'tv-sonarr'),
            ],
          ).toJson(),
        );
      await pumpHubApp(tester, api: api, location: '/activity?tab=torrents');
      await settle(tester);
      expect(find.byIcon(Icons.wifi_tethering_error), findsOneWidget);
      expect(tester.widget<Icon>(find.byIcon(Icons.wifi_tethering_error)).semanticLabel, 'Tracker error');
      final row = find.ancestor(of: find.byIcon(Icons.wifi_tethering_error), matching: find.byType(ListTile));
      expect(
        find.descendant(of: row, matching: find.text('Cyberpunk.Edgerunners.S02E01.1080p.WEB-DL')),
        findsOneWidget,
      );
    });

    testWidgets('search filters locally; members get no FAB', (tester) async {
      final api = activityFakeApi(role: Role.member);
      await pumpHubApp(tester, api: api, role: Role.member, location: '/activity?tab=torrents');
      await settle(tester);
      expect(find.byKey(const ValueKey('addTorrentFab')), findsNothing);
      await tester.enterText(find.byType(TextField).first, 'apothecary');
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(find.text('Cyberpunk.Edgerunners.S02E01.1080p.WEB-DL'), findsNothing);
      expect(find.text('[ToonsHub] The Apothecary Diaries S03E06 1080p'), findsOneWidget);
    });

    testWidgets('multi-select starts torrents', (tester) async {
      final api = activityFakeApi()..postJson('/torrents/actions', {'ok': true});
      await pumpHubApp(tester, api: api, location: '/activity?tab=torrents');
      await settle(tester);
      await tester.longPress(find.text('Cyberpunk.Edgerunners.S02E01.1080p.WEB-DL'));
      await settle(tester);
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.byTooltip('Start'));
      await settle(tester);
      expect(_body(api.requestsTo('/torrents/actions', method: 'POST').single), {
        'hashes': [seedHash],
        'action': 'start',
      });
      expect(find.text('1 selected'), findsNothing);
    });
  });

  group('header', () {
    testWidgets('the turtle sets alt speed explicitly', (tester) async {
      final api = activityFakeApi()
        ..on('PUT', '/transfer/alt-speed', (_) => FakeResponse(buildTransfer(alt: false).toJson()));
      await pumpHubApp(tester, api: api, location: '/activity');
      await tester.tap(find.byKey(const ValueKey('altSpeedToggle')));
      await settle(tester);
      expect(_body(api.requestsTo('/transfer/alt-speed', method: 'PUT').single), {'enabled': false});
    });

    testWidgets('VPN sheet and Restart VPN job', (tester) async {
      final api = activityFakeApi()
        ..postJson('/containers/gluetun/actions', {'job': buildJob(id: 'j_vpn').toJson()}, status: 202)
        ..getJson('/jobs/j_vpn', {'job': buildJob(id: 'j_vpn').toJson()});
      await pumpHubApp(tester, api: api, location: '/activity');
      await tester.tap(find.byKey(const ValueKey('vpnChip')));
      await settle(tester);
      expect(find.text('203.0.113.10'), findsOneWidget);
      expect(find.text('Marseille, France'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('restartVpn')));
      await settle(tester);
      expect(find.text('Restart VPN?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Restart'));
      await settle(tester);
      expect(_body(api.requestsTo('/containers/gluetun/actions', method: 'POST').single), {
        'action': 'restart',
        'confirm': true,
      });
      expect(find.byType(Chip), findsWidgets);
    });
  });

  group('history tab', () {
    testWidgets('lists merged events and filters by type and service', (tester) async {
      final api = activityFakeApi()
        ..getJson(
          '/activity/history',
          CursorPage<ArrHistoryItem>(
            items: [
              ArrHistoryItem(
                id: 'sonarr:1',
                service: ArrService.sonarr,
                type: ArrHistoryType.imported,
                date: testNow,
                sourceTitle: '[SubsPlease] Slime - 65v2 (1080p)',
                mediaTitle: 'That Time I Got Reincarnated as a Slime',
                seriesId: 54,
                episode: const ArrHistoryEpisode(id: 2463, seasonNumber: 3, episodeNumber: 17, label: 'S03E17 (065)'),
                quality: const QualityInfo(name: 'HDTV-1080p'),
                releaseGroup: 'SubsPlease',
                sizeBytes: 1496206957,
              ),
            ],
          ).toJson((i) => i.toJson()),
        );
      await pumpHubApp(tester, api: api, location: '/activity?tab=history');
      await settle(tester);
      expect(find.text('That Time I Got Reincarnated as a Slime · S03E17 (065)'), findsOneWidget);
      expect(find.text('HDTV-1080p'), findsOneWidget);
      await tester.tap(find.text('Imported').first);
      await settle(tester);
      expect(api.requestsTo('/activity/history').last.uri.queryParameters['types'], 'imported');
      await tester.tap(find.text('Radarr'));
      await settle(tester);
      expect(api.requestsTo('/activity/history').last.uri.queryParameters['service'], 'radarr');
    });
  });
}
