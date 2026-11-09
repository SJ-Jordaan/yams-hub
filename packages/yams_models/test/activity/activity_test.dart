import 'package:test/test.dart';
import 'package:yams_models/yams_models.dart';

import '../core/round_trip.dart';

const _hash = 'e66aac4c7d8a4f813a4e5b3a63c1bb52beee342e';

/// Gateway-shaped samples (API.md §8.1), built from the documented examples
/// and the qBittorrent/Sonarr fixtures the gateway maps.
final JsonMap _torrent = {
  'hash': _hash,
  'name':
      '[SubsPlease] Tensei Shitara Slime Datta Ken S4 (01-24) (1080p) [Batch]',
  'state': 'seeding',
  'stateRaw': 'uploading',
  'direction': 'upload',
  'progress': 1.0,
  'sizeBytes': 35111357644,
  'downloadedBytes': 35111357644,
  'uploadedBytes': 15413602877,
  'amountLeftBytes': 0,
  'dlBps': 0,
  'upBps': 686561,
  'etaSeconds': 32732,
  'ratio': 0.438,
  'seeds': 3,
  'peers': 39,
  'category': 'tv-sonarr',
  'tags': ['Keep'],
  'addedAt': '2026-11-07T21:16:59Z',
  'completedAt': '2026-11-07T22:21:18Z',
  'lastActivityAt': '2026-11-08T07:32:49Z',
  'forceStart': false,
  'hasTrackerError': false,
  'hasTrackerWarning': false,
  'protected': true,
  'managedBy': 'sonarr',
};

final JsonMap _transfer = {
  'dlBps': 1234,
  'upBps': 906283,
  'dlLimitBps': 0,
  'upLimitBps': 0,
  'altSpeedEnabled': true,
  'limits': {
    'dlBps': 0,
    'upBps': 0,
    'altDlBps': 10240000,
    'altUpBps': 10240000,
  },
  'schedule': {
    'enabled': true,
    'from': '08:00',
    'to': '17:00',
    'days': 'everyDay',
  },
  'connectionStatus': 'connected',
  'dhtNodes': 312,
  'freeSpaceBytes': 4050000000000,
  'sessionPaused': false,
  'globalRatio': 0.92,
  'allTimeDownloadedBytes': 8030115506827,
  'allTimeUploadedBytes': 7409991435409,
  'sessionDownloadedBytes': 123,
  'sessionUploadedBytes': 456,
  'updatedAt': '2026-11-08T09:00:00Z',
  'stale': false,
};

final JsonMap _arrEntry = {
  'service': 'sonarr',
  'queueIds': [123456, 123457],
  'mediaTitle': 'That Time I Got Reincarnated as a Slime',
  'seriesId': 54,
  'episodeIds': [5580, 5581],
  'episodesLabel': 'S04E01–E24',
  'status': 'downloading',
  'trackedStatus': 'warning',
  'trackedState': 'importPending',
  'messages': ['No files found are eligible for import in ...'],
  'isUpgrade': false,
  'posterPath': '/api/v1/img/arr/sonarr/54/poster?size=250',
  'downloadId': 'E66AAC4C7D8A4F813A4E5B3A63C1BB52BEEE342E',
  'canManualImport': true,
  'links': [
    {'app': 'sonarr', 'path': '/activity/queue'},
  ],
};

final JsonMap _queueItem = {
  'key': _hash,
  'title': 'That Time I Got Reincarnated as a Slime',
  'subtitle': 'Sonarr · S04E01–E24',
  'state': 'importPending',
  'needsAttention': true,
  'attention': 'importPending',
  'progress': 0.66,
  'sizeBytes': 35111357644,
  'sizeLeftBytes': 12000000000,
  'etaSeconds': 2470,
  'dlBps': 4800000,
  'upBps': 120000,
  'torrent': _torrent,
  'arr': [_arrEntry],
};

final JsonMap _vpn = {
  'status': 'connected',
  'publicIp': '203.0.113.10',
  'country': 'France',
  'region': "Provence-Alpes-Côte d'Azur",
  'city': 'Marseille',
  'organization': 'AS212238 Datacamp Limited',
  'forwardedPort': 36681,
  'listenPort': 36681,
  'portInSync': true,
  'qbitConnection': 'connected',
  'gluetunHealth': 'healthy',
  'checkedAt': '2026-11-08T09:00:00Z',
};

void main() {
  group('TorrentSummary', () {
    test('round trips the documented example', () {
      final t = expectRoundTrip(
        _torrent,
        TorrentSummary.fromJson,
        (t) => t.toJson(),
      );
      expect(t.state, TorrentState.seeding);
      expect(t.direction, TorrentDirection.upload);
      expect(t.managedBy, ArrService.sonarr);
      expect(t.protected, isTrue);
      expect(t.addedAt.isUtc, isTrue);
    });

    test('optional fields are omitted and unknown enums tolerated', () {
      final minimal = {
        'hash': _hash,
        'name': 'x',
        'state': 'teleporting',
        'stateRaw': 'teleporting',
        'direction': 'sideways',
        'progress': 0.5,
        'sizeBytes': 1,
        'downloadedBytes': 0,
        'uploadedBytes': 0,
        'amountLeftBytes': 1,
        'dlBps': 0,
        'upBps': 0,
        'ratio': 0.0,
        'seeds': 0,
        'peers': 0,
        'tags': <String>[],
        'addedAt': '2026-11-07T21:16:59Z',
        'forceStart': false,
        'hasTrackerError': false,
        'hasTrackerWarning': false,
        'protected': false,
      };
      final t = TorrentSummary.fromJson(wire(minimal));
      expect(t.state, TorrentState.unknown);
      expect(t.direction, TorrentDirection.unknown);
      expect(t.etaSeconds, isNull);
      expect(t.toJson().containsKey('managedBy'), isFalse);
      expect(t.toJson().containsKey('queuePosition'), isFalse);
    });

    test('hash and addedAt are required', () {
      expect(
        () => TorrentSummary.fromJson({'name': 'x'}),
        throwsFormatException,
      );
    });
  });

  group('TransferState', () {
    test('round trips with limits and schedule', () {
      final t = expectRoundTrip(
        _transfer,
        TransferState.fromJson,
        (t) => t.toJson(),
      );
      expect(t.limits!.altDlBps, 10240000);
      expect(t.schedule!.days, TransferScheduleDays.everyDay);
      expect(t.connectionStatus, TransferConnectionStatus.connected);
    });

    test('limits and schedule are optional', () {
      final sample = Map<String, Object?>.of(_transfer)
        ..remove('limits')
        ..remove('schedule');
      final t = expectRoundTrip(
        sample,
        TransferState.fromJson,
        (t) => t.toJson(),
      );
      expect(t.limits, isNull);
      expect(t.schedule, isNull);
    });

    test('scheduler_days maps 0..9', () {
      expect(TransferScheduleDays.fromQbit(0), TransferScheduleDays.everyDay);
      expect(TransferScheduleDays.fromQbit(1), TransferScheduleDays.weekdays);
      expect(TransferScheduleDays.fromQbit(2), TransferScheduleDays.weekends);
      expect(TransferScheduleDays.fromQbit(3), TransferScheduleDays.monday);
      expect(TransferScheduleDays.fromQbit(9), TransferScheduleDays.sunday);
      expect(TransferScheduleDays.fromQbit(10), TransferScheduleDays.unknown);
      expect(TransferScheduleDays.fromQbit(null), TransferScheduleDays.unknown);
    });
  });

  group('queue', () {
    test('QueueItem round trips with torrent and arr entry', () {
      final item = expectRoundTrip(
        _queueItem,
        QueueItem.fromJson,
        (i) => i.toJson(),
      );
      expect(item.state, QueueItemState.importPending);
      expect(item.attention, QueueAttention.importPending);
      expect(item.attention!.isImport, isTrue);
      expect(item.importEntry!.queueIds, [123456, 123457]);
      expect(item.arr.single.trackedState.needsImport, isTrue);
      expect(item.arr.single.links.single.app, ExternalApp.sonarr);
    });

    test('QueueItem without a torrent', () {
      final sample = {
        'key': 'radarr:5e28b6504beb319aba494a3ab540ab434b697b65',
        'title': 'Dune: Part Two',
        'state': 'delayed',
        'needsAttention': false,
        'progress': 0.0,
        'sizeBytes': 0,
        'sizeLeftBytes': 0,
        'dlBps': 0,
        'upBps': 0,
        'arr': [
          {
            'service': 'radarr',
            'queueIds': [9],
            'movieId': 9,
            'episodeIds': <int>[],
            'status': 'delay',
            'trackedStatus': 'ok',
            'trackedState': 'downloading',
            'messages': <String>[],
            'isUpgrade': true,
            'canManualImport': false,
            'links': <Object?>[],
          },
        ],
      };
      final item = expectRoundTrip(
        sample,
        QueueItem.fromJson,
        (i) => i.toJson(),
      );
      expect(item.torrent, isNull);
      expect(item.importEntry, isNull);
      expect(item.arr.single.status, QueueArrStatus.delay);
    });

    test('QueueItemState follows the torrent state', () {
      for (final s in TorrentState.values) {
        expect(QueueItemState.fromTorrent(s).name, s.name);
      }
    });

    test('QueueResponse round trips the source statuses', () {
      final sample = {
        'items': [_queueItem],
        'summary': {
          'downloading': 1,
          'seeding': 12,
          'stalled': 1,
          'attention': 1,
          'dlBps': 4800000,
          'upBps': 906283,
        },
        'arr': {
          'sonarr': {'status': 'ok'},
          'radarr': {
            'status': 'error',
            'error': {
              'code': 'upstream_unavailable',
              'message': 'Radarr is not reachable.',
              'status': 503,
              'service': 'radarr',
              'requestId': 'r1',
              'fields': <Object?>[],
            },
          },
        },
        'qbittorrent': {'status': 'ok'},
        'stale': false,
      };
      final r = expectRoundTrip(
        sample,
        QueueResponse.fromJson,
        (r) => r.toJson(),
      );
      expect(r.statusOf(ArrService.sonarr).isOk, isTrue);
      expect(r.radarr.error!.code, ApiErrorCode.upstreamUnavailable);
      expect(r.summary.seeding, 12);
    });

    test('QueueRemoveRequest defaults and round trip', () {
      final r = QueueRemoveRequest.fromJson({
        'items': [
          {
            'service': 'sonarr',
            'queueIds': [1, 2],
          },
        ],
      });
      expect(r.removeFromClient, isTrue);
      expect(r.blocklist, isFalse);
      expect(r.searchAgain, isFalse);
      expectRoundTrip(
        {
          'items': [
            {
              'service': 'radarr',
              'queueIds': [3],
            },
          ],
          'removeFromClient': false,
          'blocklist': true,
          'searchAgain': true,
          'confirm': true,
        },
        QueueRemoveRequest.fromJson,
        (r) => r.toJson(),
      );
      expectRoundTrip(
        {'removed': 2, 'alreadyGone': 1},
        QueueRemoveResult.fromJson,
        (r) => r.toJson(),
      );
    });
  });

  group('manual import', () {
    final candidates = {
      'service': 'sonarr',
      'queueId': 123456,
      'downloadId': 'E66AAC4C7D8A4F813A4E5B3A63C1BB52BEEE342E',
      'title': '[SubsPlease] Tensei Shitara Slime Datta Ken S4 (01-24)',
      'items': [
        {
          'fileId': 'mi_0123456789abcdef',
          'relativePath': 'Slime S4/[SubsPlease] Slime - 01 (1080p).mkv',
          'sizeBytes': 1461367836,
          'quality': {
            'name': 'WEBDL-1080p',
            'source': 'web',
            'resolution': 1080,
            'isRepack': false,
          },
          'languages': ['Japanese'],
          'releaseGroup': 'SubsPlease',
          'seriesId': 54,
          'seasonNumber': 4,
          'episodes': [
            {'id': 5580, 'label': 'S04E01', 'title': 'Episode 1'},
          ],
          'customFormatScore': 200,
          'rejections': [
            {'reason': 'Not an upgrade', 'type': 'permanent'},
          ],
          'importable': true,
        },
      ],
    };

    test('ManualImportCandidates round trips', () {
      final c = expectRoundTrip(
        candidates,
        ManualImportCandidates.fromJson,
        (c) => c.toJson(),
      );
      final f = c.items.single;
      expect(f.importable, isTrue);
      expect(f.episodes.single.label, 'S04E01');
      expect(f.rejections.single.type, ManualImportFileRejectionType.permanent);
      expect(f.quality.resolution, 1080);
    });

    test('QueueImportRequest defaults the mode and keeps overrides', () {
      final r = QueueImportRequest.fromJson({
        'service': 'sonarr',
        'queueId': 1,
        'files': [
          {'fileId': 'mi_1'},
          {
            'fileId': 'mi_2',
            'seriesId': 54,
            'episodeIds': [5580],
          },
        ],
      });
      expect(r.importMode, QueueImportMode.auto);
      expect(r.files.first.episodeIds, isNull);
      expect(r.files.last.episodeIds, [5580]);
      expectRoundTrip(
        {
          'service': 'radarr',
          'queueId': 7,
          'importMode': 'move',
          'files': [
            {'fileId': 'mi_3', 'movieId': 9},
          ],
        },
        QueueImportRequest.fromJson,
        (r) => r.toJson(),
      );
    });
  });

  group('torrent detail', () {
    final detail = {
      'summary': _torrent,
      'savePath': '/data/downloads/torrents',
      'pieceSizeBytes': 1048576,
      'piecesHave': 33533,
      'piecesTotal': 33533,
      'timeActiveSeconds': 37378,
      'seedingTimeSeconds': 33520,
      'wastedBytes': 0,
      'avgDlBps': 9119879,
      'avgUpBps': 412370,
      'connections': 40,
      'seedsTotal': 315,
      'peersTotal': 118,
      'isPrivate': false,
      'shareLimits': {
        'mode': 'global',
        'action': 'default',
        'effectiveRatio': 1.0,
        'effectiveSeedingMinutes': -1,
      },
      'files': [
        {
          'index': 0,
          'name': 'Slime S4/01.mkv',
          'sizeBytes': 1461367836,
          'progress': 1.0,
          'priority': 'normal',
        },
      ],
      'trackers': [
        {
          'url': 'http://nyaa.tracker.wf:7777',
          'tier': 0,
          'status': 'working',
          'seeds': 305,
          'peers': 100,
          'downloaded': 796,
        },
      ],
      'arr': [_arrEntry],
    };

    test('round trips', () {
      final d = expectRoundTrip(
        detail,
        TorrentDetail.fromJson,
        (d) => d.toJson(),
      );
      expect(d.shareLimits.mode, ShareLimitsMode.global);
      expect(d.shareLimits.action, ShareLimitsAction.byDefault);
      expect(d.trackers.single.status, TrackerInfoStatus.working);
      expect(d.files.single.priority, TorrentFilePriority.normal);
    });

    test('a tracker error counts only when no tracker works (issue #1)', () {
      JsonMap tracker(String status) => {
        'url': 'udp://t$status.example:80',
        'tier': 0,
        'status': status,
      };
      TorrentDetail withTrackers(List<String> statuses, {bool flag = true}) =>
          TorrentDetail.fromJson({
            ...detail,
            'summary': {..._torrent, 'hasTrackerError': flag},
            'trackers': [for (final s in statuses) tracker(s)],
          });

      // One failing tracker next to a working one (an older gateway sends
      // qBittorrent's raw flag): no error, one failing tracker.
      final partial = withTrackers(['working', 'trackerError', 'notWorking']);
      expect(partial.summary.hasTrackerError, isTrue);
      expect(partial.hasTrackerError, isFalse);
      expect(partial.failingTrackers, 2);
      // Nothing works: the error stands.
      final none = withTrackers(['trackerError', 'updating', 'unreachable']);
      expect(none.hasTrackerError, isTrue);
      expect(none.failingTrackers, 2);
      // No flag, no error, whatever the trackers say.
      expect(
        withTrackers(['trackerError'], flag: false).hasTrackerError,
        false,
      );
      expect(anyTrackerWorking(const []), isFalse);
      expect(
        [
          for (final s in TrackerInfoStatus.values)
            if (s.isFailing) s.name,
        ],
        ['notWorking', 'trackerError', 'unreachable'],
      );
    });

    test('share-limit actions use their wire names', () {
      expect(ShareLimitsAction.byDefault.toJson(), 'default');
      expect(
        ShareLimitsAction.fromJson('removeWithContent'),
        ShareLimitsAction.removeWithContent,
      );
      expect(
        ShareLimitsAction.fromQbit('RemoveWithContent'),
        ShareLimitsAction.removeWithContent,
      );
      expect(ShareLimitsAction.tryParse('explode'), isNull);
      expect(ShareLimitsAction.remove.removes, isTrue);
      expect(ShareLimitsAction.stop.removes, isFalse);
      final u = expectRoundTrip(
        {
          'mode': 'custom',
          'ratio': 2.0,
          'seedingMinutes': 1440,
          'action': 'remove',
          'confirm': true,
        },
        ShareLimitsUpdate.fromJson,
        (u) => u.toJson(),
      );
      expect(u.action, ShareLimitsAction.remove);
      expect(
        ShareLimitsUpdate.fromJson({'mode': 'global'}).action,
        ShareLimitsAction.byDefault,
      );
    });

    test('qBittorrent priority and tracker status integers', () {
      expect(TorrentFilePriority.fromQbit(0), TorrentFilePriority.skip);
      expect(TorrentFilePriority.fromQbit(1), TorrentFilePriority.normal);
      expect(TorrentFilePriority.fromQbit(4), TorrentFilePriority.normal);
      expect(TorrentFilePriority.fromQbit(6), TorrentFilePriority.high);
      expect(TorrentFilePriority.fromQbit(7), TorrentFilePriority.max);
      expect(TorrentFilePriority.max.qbit, 7);
      expect(TrackerInfoStatus.fromQbit(5), TrackerInfoStatus.trackerError);
      expect(TrackerInfoStatus.fromQbit(6), TrackerInfoStatus.unreachable);
      expect(TrackerInfoStatus.fromQbit(-1), TrackerInfoStatus.unknown);
    });
  });

  group('requests', () {
    test('TorrentActionRequest round trips', () {
      final r = expectRoundTrip(
        {
          'hashes': [_hash],
          'action': 'delete',
          'deleteFiles': true,
          'force': false,
          'confirm': true,
        },
        TorrentActionRequest.fromJson,
        (r) => r.toJson(),
      );
      expect(r.action, TorrentAction.delete);
      expect(TorrentAction.fromJson('pause'), TorrentAction.unknown);
    });

    test('TorrentManagedByArr reads 409 details', () {
      final items = TorrentManagedByArr.listFromDetails({
        'items': [
          {
            'hash': _hash,
            'service': 'sonarr',
            'queueIds': [1, 2],
          },
        ],
      });
      expect(items.single.service, ArrService.sonarr);
      expect(items.single.queueIds, [1, 2]);
      expect(TorrentManagedByArr.listFromDetails(null), isEmpty);
    });

    test('TorrentAddRequest omits empty lists', () {
      final r = TorrentAddRequest(
        urls: const ['magnet:?xt=urn:btih:$_hash'],
        stopped: true,
      );
      expect(r.toJson(), {
        'urls': ['magnet:?xt=urn:btih:$_hash'],
        'stopped': true,
      });
      expectRoundTrip(
        {
          'urls': ['https://example.org/a.torrent'],
          'torrentFilesBase64': ['ZDQ6aW5mb2Vl'],
          'category': 'manual',
          'tags': ['Keep'],
          'stopped': false,
        },
        TorrentAddRequest.fromJson,
        (r) => r.toJson(),
      );
    });

    test('TorrentFilePriorityRequest and TransferLimits round trip', () {
      expectRoundTrip(
        {
          'indexes': [0, 3],
          'priority': 'skip',
        },
        TorrentFilePriorityRequest.fromJson,
        (r) => r.toJson(),
      );
      expectRoundTrip(
        {'dlBps': 0, 'upBps': 1024, 'altDlBps': 2048, 'altUpBps': 4096},
        TransferLimits.fromJson,
        (r) => r.toJson(),
      );
    });
  });

  test('CategoryList round trips', () {
    final c = expectRoundTrip(
      {
        'categories': [
          {'name': 'manual', 'readOnly': false},
          {'name': 'tv-sonarr', 'readOnly': true},
          {'name': 'books', 'savePath': '/data/books', 'readOnly': true},
        ],
        'tags': ['Keep', 'Obsolete'],
      },
      CategoryList.fromJson,
      (c) => c.toJson(),
    );
    expect(c.categories[1].readOnly, isTrue);
    expect(c.categories[2].savePath, '/data/books');
  });

  group('VpnStatus', () {
    test('round trips', () {
      final v = expectRoundTrip(_vpn, VpnStatus.fromJson, (v) => v.toJson());
      expect(v.status, VpnConnectionState.connected);
      expect(v.gluetunHealth, VpnGluetunHealth.healthy);
    });

    test('down with no address', () {
      final v = expectRoundTrip(
        {
          'status': 'down',
          'portInSync': false,
          'qbitConnection': 'unknown',
          'gluetunHealth': 'unknown',
          'checkedAt': '2026-11-08T09:00:00Z',
        },
        VpnStatus.fromJson,
        (v) => v.toJson(),
      );
      expect(v.publicIp, isNull);
      expect(v.forwardedPort, isNull);
    });
  });

  group('ActivityCard', () {
    test('round trips and keeps the raw attention key', () {
      final sample = {
        'transfer': {
          'dlBps': 4800000,
          'upBps': 906283,
          'altSpeedEnabled': true,
          'connectionStatus': 'connected',
        },
        'counts': {
          'downloading': 1,
          'seeding': 12,
          'stalled': 1,
          'attention': 1,
        },
        'top': [_queueItem],
        'vpn': _vpn,
      };
      final c = expectRoundTrip(
        sample,
        ActivityCard.fromJson,
        (c) => c.toJson(),
      );
      expect(c.counts.attention, 1);
      expect(c.toJson()['counts'], containsPair('attention', 1));
      expect(c.vpn!.forwardedPort, 36681);
    });

    test('decodes partial data (badge-only dashboards)', () {
      final c = ActivityCard.fromJson({
        'counts': {'attention': 2},
      });
      expect(c.counts.attention, 2);
      expect(c.top, isEmpty);
      expect(c.vpn, isNull);
      expect(c.transfer.connectionStatus, TransferConnectionStatus.unknown);
    });
  });
}
