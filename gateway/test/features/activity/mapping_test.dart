import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/features/activity/arr_mapping.dart';
import 'package:yams_hub_gateway/src/features/activity/maindata.dart';
import 'package:yams_hub_gateway/src/features/activity/qbit_mapping.dart';
import 'package:yams_hub_gateway/src/features/activity/unified_queue.dart';
import 'package:yams_hub_gateway/src/features/activity/vpn_status.dart';

import '../../support/test_hub.dart';
import 'activity_support.dart';

JsonMap _map(Object? v) => readMap(v)!;

List<JsonMap> _list(Object? v) => [for (final e in v! as List) _map(e)];

void main() {
  group('torrent state mapping (downloads.md §1.6)', () {
    test('every v5 state maps to its UI group', () {
      const cases = {
        'downloading': TorrentState.downloading,
        'forcedDL': TorrentState.downloading,
        'metaDL': TorrentState.metadata,
        'forcedMetaDL': TorrentState.metadata,
        'uploading': TorrentState.seeding,
        'forcedUP': TorrentState.seeding,
        'stalledDL': TorrentState.stalled,
        'stalledUP': TorrentState.stalled,
        'stoppedDL': TorrentState.stopped,
        'stoppedUP': TorrentState.stopped,
        'queuedDL': TorrentState.queued,
        'queuedUP': TorrentState.queued,
        'checkingDL': TorrentState.checking,
        'checkingUP': TorrentState.checking,
        'queuedForChecking': TorrentState.checking,
        'checkingResumeData': TorrentState.checking,
        'moving': TorrentState.moving,
        'error': TorrentState.error,
        'missingFiles': TorrentState.error,
        'unknown': TorrentState.error,
        'somethingNew': TorrentState.unknown,
      };
      cases.forEach((raw, state) {
        expect(torrentStateOf(raw), state, reason: raw);
      });
    });

    test('direction follows DL/UP', () {
      expect(torrentDirectionOf('metaDL', 0), TorrentDirection.download);
      expect(torrentDirectionOf('downloading', 0.2), TorrentDirection.download);
      expect(torrentDirectionOf('stoppedUP', 1), TorrentDirection.upload);
      expect(torrentDirectionOf('uploading', 1), TorrentDirection.upload);
      expect(torrentDirectionOf('moving', 1), TorrentDirection.upload);
      expect(torrentDirectionOf('error', 0.4), TorrentDirection.download);
    });
  });

  group('TorrentSummary from the maindata fixture', () {
    final full = _map(fixture('downloads/qbittorrent_sync_maindata_full.json'));
    final torrents = _map(full['torrents']);

    test('maps fields, sentinels and tags', () {
      final t = torrentSummaryOf(sonarrHash, _map(torrents[sonarrHash]))!;
      expect(t.state, TorrentState.queued);
      expect(t.stateRaw, 'queuedUP');
      expect(t.direction, TorrentDirection.upload);
      expect(t.managedBy, ArrService.sonarr);
      expect(t.category, 'tv-sonarr');
      expect(t.tags, isEmpty);
      expect(t.protected, isFalse);
      expect(t.etaSeconds, 1418371);
      expect(t.ratio, 0.267);
      expect(t.queuePosition, isNull);
      expect(t.addedAt, DateTime.utc(2026, 11, 6, 15, 6, 17));
      expect(t.sizeBytes, 920507089);
    });

    test('eta 8640000 is null; Keep tag protects', () {
      final raw = {
        ..._map(torrents['2b96b8269b32cb9c44bf8808eca92aaad3e2b015']),
        'tags': 'Keep, Obsolete',
        'priority': 3,
        'category': '',
        'completion_on': -1,
      };
      final t = torrentSummaryOf(
        '2B96B8269B32CB9C44BF8808ECA92AAAD3E2B015',
        raw,
      )!;
      expect(t.hash, '2b96b8269b32cb9c44bf8808eca92aaad3e2b015');
      expect(t.etaSeconds, isNull);
      expect(t.tags, ['Keep', 'Obsolete']);
      expect(t.protected, isTrue);
      expect(t.queuePosition, 3);
      expect(t.category, isNull);
      expect(t.managedBy, isNull);
      expect(t.completedAt, isNull);
    });

    test('incomplete delta entries are skipped', () {
      expect(torrentSummaryOf('ab', {'upspeed': 4}), isNull);
    });

    test('filters follow the WebUI semantics', () {
      final all = [
        for (final e in torrents.entries)
          torrentSummaryOf(e.key, _map(e.value))!,
      ];
      int count(String f) =>
          all.where((t) => torrentMatchesFilter(f, t)).length;
      expect(count('all'), 5);
      expect(count('seeding'), 4); // queuedUP counts as seeding
      expect(count('stopped'), 1);
      expect(count('running'), 4);
      expect(count('completed'), 5);
      expect(count('downloading'), 0);
      expect(count('errored'), 0);
    });
  });

  group('maindata merge', () {
    test('full update, deltas and removals', () async {
      final hub = activityHub();
      addTearDown(hub.close);
      await hub.ready;
      final m = QbitMaindata(hub.ctx);
      addTearDown(m.stop);
      m.apply(_map(fixture('downloads/qbittorrent_sync_maindata_full.json')));
      var v = m.view(stale: false);
      expect(v.torrents, hasLength(5));
      expect(v.categories.keys, containsAll(['tv-sonarr', 'radarr']));
      expect(v.tags, ['Keep', 'Obsolete']);
      expect(v.serverState['dl_rate_limit'], 10240000);

      m.apply(_map(fixture('downloads/qbittorrent_sync_maindata_delta.json')));
      v = m.view(stale: false);
      // Server state is merged field by field.
      expect(v.serverState['up_info_speed'], 906283);
      expect(v.serverState['connection_status'], 'connected');
      // Unknown hashes of the trimmed fixture are kept but not listed.
      expect(v.summaries(), hasLength(5));

      m.apply({
        'rid': 7,
        'torrents': {
          sonarrHash: {'upspeed': 1234, 'state': 'uploading'},
        },
        'torrents_removed': [plainHash],
        'tags_removed': ['Obsolete'],
        'categories_removed': ['lidarr'],
      });
      v = m.view(stale: false);
      final t = v.summaries().firstWhere((t) => t.hash == sonarrHash);
      expect(t.upBps, 1234);
      expect(t.state, TorrentState.seeding);
      expect(t.name, contains('Apothecary'));
      expect(v.torrents.containsKey(plainHash), isFalse);
      expect(v.tags, ['Keep']);
      expect(v.categories.containsKey('lidarr'), isFalse);
    });
  });

  group('transfer', () {
    test('server_state → TransferState', () {
      final full = _map(
        fixture('downloads/qbittorrent_sync_maindata_full.json'),
      );
      final limits = transferLimitsOf(
        _map(fixture('downloads/qbittorrent_transfer_getSpeedLimits.json')),
      );
      final prefs = whitelistPreferences(
        _map(fixture('downloads/qbittorrent_app_preferences.json')),
      );
      final t = transferStateOf(
        _map(full['server_state']),
        updatedAt: DateTime.utc(2026, 11, 8, 9),
        limits: limits,
        schedule: transferScheduleOf(prefs),
      );
      expect(t.upBps, 935671);
      expect(t.dlLimitBps, 10240000);
      expect(t.altSpeedEnabled, isTrue);
      expect(t.globalRatio, 0.92);
      expect(t.connectionStatus, TransferConnectionStatus.connected);
      expect(t.freeSpaceBytes, 4048915001344);
      expect(t.allTimeDownloadedBytes, 8030115406493);
      expect(t.sessionPaused, isFalse);
      expect(t.limits!.altUpBps, 10240000);
      expect(t.limits!.dlBps, 0);
      expect(t.schedule!.enabled, isTrue);
      expect(t.schedule!.from, '08:00');
      expect(t.schedule!.to, '17:00');
      expect(t.schedule!.days, TransferScheduleDays.everyDay);
    });

    test('preferences are whitelisted (no secrets)', () {
      final prefs = whitelistPreferences(
        _map(fixture('downloads/qbittorrent_app_preferences.json')),
      );
      expect(prefs.keys, everyElement(isIn(preferenceKeys)));
      expect(prefs.containsKey('web_ui_username'), isFalse);
      expect(prefs['listen_port'], 36681);
      expect(globalRatioLimit(prefs), 1.0);
      expect(globalSeedingMinutes(prefs), -1);
    });
  });

  group('torrent detail parts', () {
    test('trackers drop DHT/PeX/LSD rows, endpoints and URL paths', () {
      final trackers = trackersOf(
        _list(fixture('downloads/qbittorrent_torrents_trackers.json')),
      );
      expect(trackers.map((t) => t.url), [
        'http://nyaa.tracker.wf:7777',
        'udp://open.stealth.si:80',
      ]);
      expect(trackers.first.status, TrackerInfoStatus.working);
      expect(trackers.first.seeds, 305);
      expect(trackers.first.downloaded, 796);
      expect(trackers.last.downloaded, isNull);
      expect(trackers.first.toJson().containsKey('endpoints'), isFalse);
    });

    test('private announce URLs lose their passkey', () {
      expect(
        reduceTrackerUrl(
          'https://tracker.example.org/abcdef0123/announce?pk=1',
        ),
        'https://tracker.example.org',
      );
      expect(
        reduceTrackerUrl('udp://[2001:db8::1]:6969/announce'),
        'udp://[2001:db8::1]:6969',
      );
      expect(reduceTrackerUrl('** [DHT] **'), isNull);
    });

    test('files map priorities and availability', () {
      final files = [
        for (final f in _list(
          fixture('downloads/qbittorrent_torrents_files.json'),
        ))
          torrentFileOf(f),
      ];
      expect(files, hasLength(5));
      expect(files.first.index, 0);
      expect(files.first.priority, TorrentFilePriority.normal);
      expect(files.first.availability, isNull);
      expect(files.first.name, contains('/'));
    });

    test('share limits from snapshot fields', () {
      final full = _map(
        fixture('downloads/qbittorrent_sync_maindata_full.json'),
      );
      final t = _map(_map(full['torrents'])[sonarrHash]);
      final s = shareLimitsOf(t);
      expect(s.mode, ShareLimitsMode.global);
      expect(s.action, ShareLimitsAction.byDefault);
      expect(s.effectiveRatio, 1.0);
      expect(s.effectiveSeedingMinutes, -1);
      final custom = shareLimitsOf({
        ...t,
        'ratio_limit': 2,
        'seeding_time_limit': -1,
        'inactive_seeding_time_limit': -2,
        'share_limit_action': 'RemoveWithContent',
      });
      expect(custom.mode, ShareLimitsMode.custom);
      expect(custom.ratio, 2.0);
      expect(custom.seedingMinutes, isNull);
      expect(custom.action, ShareLimitsAction.removeWithContent);
      expect(
        shareLimitsOf({
          ...t,
          'ratio_limit': -1,
          'seeding_time_limit': -1,
          'inactive_seeding_time_limit': -1,
        }).mode,
        ShareLimitsMode.unlimited,
      );
    });
  });

  group('*arr mapping', () {
    final images = ImageUrls(const ['artworks.thetvdb.com', 'image.tmdb.org']);

    test('history records: anime labels, data strings, no secrets', () {
      final sonarr = _list(_map(fixture('arr/sonarr_history.json'))['records']);
      final item = historyItemOf(ArrService.sonarr, sonarr.first, images)!;
      expect(item.id, startsWith('sonarr:'));
      expect(item.type, ArrHistoryType.imported);
      expect(item.episode!.label, 'S03E17 (065)');
      expect(item.sizeBytes, 1496206957);
      expect(item.customFormatScore, 200);
      expect(item.downloadId, 'b3cf3baaffb64c08105d1e2152685b3b158e4ef4');
      expect(item.quality.name, 'HDTV-1080p');
      expect(item.quality.revision, 2);
      expect(item.posterPath, startsWith('/api/v1/img/arr/sonarr/54/poster'));
      expect(item.downloadClient, 'qBittorrent');

      final radarr = _list(_map(fixture('arr/radarr_history.json'))['records']);
      final grabbed = radarr
          .map((r) => historyItemOf(ArrService.radarr, r, images)!)
          .firstWhere((i) => i.type == ArrHistoryType.grabbed);
      expect(grabbed.movieId, isNotNull);
      expect(grabbed.seriesId, isNull);
      expect(grabbed.indexer, isNotNull);
      expect(grabbed.releaseSource, isNotNull);
      final json = grabbed.toJson().toString();
      expect(json, isNot(contains('apikey')));
      expect(json, isNot(contains('magnet:')));
      expect(json, isNot(contains('/data/')));
    });

    test('deleted records keep the reason', () {
      final sonarr = _list(_map(fixture('arr/sonarr_history.json'))['records']);
      final deleted = sonarr
          .map((r) => historyItemOf(ArrService.sonarr, r, images)!)
          .firstWhere((i) => i.type == ArrHistoryType.deleted);
      expect(deleted.reason, isNotNull);
    });

    test('episode labels', () {
      expect(episodesLabelOf([(4, 1)]), 'S04E01');
      expect(episodesLabelOf([(4, 24), (4, 1), (4, 2)]), 'S04E01–E24');
      expect(episodesLabelOf([(1, 9), (2, 3)]), 'S01E09–S02E03');
      expect(episodesLabelOf([]), isNull);
    });

    test('TimeSpan parsing', () {
      expect(timeSpanSeconds('00:41:10'), 2470);
      expect(timeSpanSeconds('1.02:00:00'), 93600);
      expect(timeSpanSeconds('00:00:00.0008733'), 0);
      expect(timeSpanSeconds('garbage'), isNull);
    });

    test('quality objects', () {
      final q = arrQualityOf({
        'quality': {
          'name': 'WEBRip-2160p',
          'source': 'webrip',
          'resolution': 2160,
          'modifier': 'none',
        },
        'revision': {'version': 1, 'real': 0, 'isRepack': false},
      });
      expect(q.name, 'WEBRip-2160p');
      expect(q.modifier, isNull);
      expect(q.revision, isNull);
    });

    test('queue groups: season packs collapse into one entry', () {
      final sonarr = _list(
        _map(synthetic('sonarr_queue.synthetic.json'))['records'],
      );
      final groups = groupQueueRecords([
        ArrQueueResult(ArrService.sonarr, sonarr, null, false),
      ]);
      expect(groups, hasLength(2));
      final pack = groups.firstWhere((g) => g.hash == sonarrHash);
      final admin = queueArrEntryOf(pack, images, admin: true);
      expect(admin.queueIds, [123456, 123457]);
      expect(admin.episodeIds, [5580, 5581]);
      expect(admin.episodesLabel, 'S04E01–E02');
      expect(admin.trackedState, QueueTrackedState.importPending);
      expect(admin.trackedStatus, QueueTrackedStatus.warning);
      expect(admin.messages, hasLength(1));
      expect(admin.canManualImport, isTrue);
      expect(admin.links.single.path, '/activity/queue');
      expect(admin.downloadId, '0985D9EFDF7508DB837E629AE8F40EE8B56F4D71');
      expect(admin.posterPath, contains('v=639058149420070772'));
      final member = queueArrEntryOf(pack, images, admin: false);
      expect(member.canManualImport, isFalse);
      expect(member.links, isEmpty);
    });
  });

  test('gluetun health from the container list', () {
    expect(
      gluetunHealthOf({
        'State': 'running',
        'Health': {'Status': 'healthy'},
      }),
      VpnGluetunHealth.healthy,
    );
    expect(
      gluetunHealthOf({'State': 'running', 'Status': 'Up 1 hour (unhealthy)'}),
      VpnGluetunHealth.unhealthy,
    );
    expect(
      gluetunHealthOf({'State': 'running', 'Status': 'Up 1 hour'}),
      VpnGluetunHealth.none,
    );
    expect(
      gluetunHealthOf({'State': 'exited', 'Status': 'Exited (1)'}),
      VpnGluetunHealth.unhealthy,
    );
  });
}
