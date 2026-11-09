// Issue #1: qBittorrent's `has_tracker_error` is set when any one tracker
// fails; the hub only reports a tracker error when no tracker works.
import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/features/activity/tracker_health.dart';

import '../../support/test_hub.dart';
import 'activity_support.dart';

const _q = ServiceId.qbittorrent;

/// A `torrents/trackers` row (qBittorrent status integers).
JsonMap _tracker(String host, int status, {int tier = 0}) => {
  'url': 'udp://$host:80/announce',
  'tier': tier,
  'status': status,
  'msg': status == 5 ? 'torrent not registered' : '',
  'num_seeds': 1,
  'num_peers': 2,
  'num_leeches': 0,
  'num_downloaded': 0,
};

/// The DHT/PeX/LSD pseudo rows always say "working".
final _pseudo = [
  for (final n in ['DHT', 'PeX', 'LSD'])
    {'url': '** [$n] **', 'tier': -1, 'status': 2, 'msg': ''},
];

void main() {
  late TestHub hub;

  /// Tracker rows per hash; hashes without rows answer 500.
  late Map<String, List<JsonMap>> trackers;

  setUp(() {
    hub = activityHub();
    trackers = {};
    // plainHash (untracked, stoppedUP) and radarrHash carry the flag.
    hub.fakes
      ..on(_q, 'GET', '/api/v2/sync/maindata', (_) {
        final m = Map<String, Object?>.of(
          fixture('downloads/qbittorrent_sync_maindata_full.json')! as JsonMap,
        );
        final ts = Map<String, Object?>.of(m['torrents']! as JsonMap);
        for (final h in [plainHash, radarrHash]) {
          ts[h] = {...ts[h]! as JsonMap, 'has_tracker_error': true};
        }
        m['torrents'] = ts;
        return FakeResponse.json(m);
      })
      ..on(_q, 'GET', '/api/v2/torrents/trackers', (r) {
        final rows = trackers[r.query['hash']?.single];
        if (rows == null) return FakeResponse.text('boom', status: 500);
        return FakeResponse.json([..._pseudo, ...rows]);
      });
  });
  tearDown(() => hub.close());

  Future<Map<String, bool>> torrentErrors() async {
    final r = await hub.get('/api/v1/torrents');
    expect(r.status, 200, reason: r.body);
    return {
      for (final t in TorrentList.fromJson(r.map).items)
        if (t.hasTrackerError) t.hash: true,
    };
  }

  int trackerCalls([String? hash]) => hub.fakes
      .callsTo(_q)
      .where(
        (c) =>
            c.path == '/api/v2/torrents/trackers' &&
            (hash == null || c.query['hash']?.single == hash),
      )
      .length;

  test('one failing tracker among working ones is not an error', () async {
    trackers[plainHash] = [
      _tracker('dead', 5),
      for (var i = 0; i < 5; i++) _tracker('ok$i', 2, tier: i + 1),
    ];
    trackers[radarrHash] = [_tracker('dead', 5), _tracker('down', 4)];
    expect(await torrentErrors(), {radarrHash: true});
    // Only the flagged torrents' trackers are read.
    expect(trackerCalls(), 2);
  });

  test('updating and not-contacted trackers do not count as working', () async {
    trackers[plainHash] = [
      _tracker('dead', 5),
      _tracker('busy', 3),
      _tracker('new', 1),
      _tracker('off', 0),
    ];
    trackers[radarrHash] = [_tracker('ok', 2), _tracker('dead', 5)];
    expect(await torrentErrors(), {plainHash: true});
  });

  test('the unified queue and the dashboard use the same rule', () async {
    trackers[plainHash] = [_tracker('dead', 5), _tracker('ok', 2)];
    trackers[radarrHash] = [_tracker('dead', 5)];
    var r = await hub.get('/api/v1/activity/queue?filter=all');
    expect(r.status, 200, reason: r.body);
    var q = QueueResponse.fromJson(r.map);
    QueueItem item(String key) => q.items.firstWhere((i) => i.key == key);
    expect(item(plainHash).attention, isNull);
    expect(item(plainHash).needsAttention, isFalse);
    expect(item(plainHash).torrent!.hasTrackerError, isFalse);
    expect(item(radarrHash).torrent!.hasTrackerError, isTrue);
    final attention = q.summary.attention;

    r = await hub.get('/api/v1/activity/queue?filter=attention');
    q = QueueResponse.fromJson(r.map);
    expect(q.items.map((i) => i.key), isNot(contains(plainHash)));

    r = await hub.get('/api/v1/dashboard?cards=activity');
    final card = Section.fromJson(
      readMap(readMap(r.map['cards'])!['activity'])!,
    ).decode(ActivityCard.fromJson)!;
    expect(card.counts.attention, attention);
    expect(card.top.map((i) => i.key), isNot(contains(plainHash)));
  });

  test(
    'an untracked torrent with no working tracker needs attention',
    () async {
      trackers[plainHash] = [_tracker('dead', 5), _tracker('down', 6)];
      trackers[radarrHash] = [_tracker('ok', 2), _tracker('dead', 5)];
      final r = await hub.get('/api/v1/activity/queue?filter=attention');
      final q = QueueResponse.fromJson(r.map);
      final plain = q.items.singleWhere((i) => i.key == plainHash);
      expect(plain.attention, QueueAttention.trackerError);
      expect(q.items.map((i) => i.key), isNot(contains(radarrHash)));
    },
  );

  test('the detail route decides from the trackers it reads', () async {
    for (final (path, file) in [
      ('/api/v2/torrents/properties', 'qbittorrent_torrents_properties.json'),
      ('/api/v2/torrents/files', 'qbittorrent_torrents_files.json'),
    ]) {
      hub.fakes.onFixture(_q, 'GET', path, 'downloads/$file');
    }
    trackers[plainHash] = [_tracker('dead', 5), _tracker('ok', 2)];
    var r = await hub.get('/api/v1/torrents/$plainHash');
    expect(r.status, 200, reason: r.body);
    var d = TorrentDetail.fromJson(r.map);
    expect(d.summary.hasTrackerError, isFalse);
    expect(d.trackers.map((t) => t.status), [
      TrackerInfoStatus.trackerError,
      TrackerInfoStatus.working,
    ]);

    trackers[plainHash] = [_tracker('dead', 5)];
    r = await hub.get('/api/v1/torrents/$plainHash');
    d = TorrentDetail.fromJson(r.map);
    expect(d.summary.hasTrackerError, isTrue);
    // The list reuses the verdict the detail read just recorded.
    trackers[radarrHash] = [_tracker('dead', 5)];
    final before = trackerCalls(plainHash);
    expect(await torrentErrors(), {plainHash: true, radarrHash: true});
    expect(trackerCalls(plainHash), before);
  });

  test('a failed tracker read keeps the flag and is retried', () async {
    // No rows for either hash: torrents/trackers answers 500.
    expect(await torrentErrors(), {plainHash: true, radarrHash: true});
    trackers[plainHash] = [_tracker('dead', 5), _tracker('ok', 2)];
    // Not before the retry delay...
    expect(await torrentErrors(), {plainHash: true, radarrHash: true});
    expect(trackerCalls(plainHash), 1);
    hub.clock.advance(trackerHealthRetry);
    // ...then in the background (the last verdict is served meanwhile).
    await torrentErrors();
    await pumpEventQueue();
    expect(await torrentErrors(), {radarrHash: true});
  });

  test(
    'verdicts are cached and re-read in the background after the TTL',
    () async {
      trackers[plainHash] = [_tracker('dead', 5), _tracker('ok', 2)];
      trackers[radarrHash] = [_tracker('dead', 5)];
      expect(await torrentErrors(), {radarrHash: true});
      expect(await torrentErrors(), {radarrHash: true});
      expect(trackerCalls(), 2);

      // The working tracker fails too: noticed after the TTL.
      trackers[plainHash] = [_tracker('dead', 5), _tracker('ok', 4)];
      hub.clock.advance(trackerHealthTtl);
      expect(await torrentErrors(), {
        radarrHash: true,
      }, reason: 'stale verdict');
      await pumpEventQueue();
      expect(await torrentErrors(), {plainHash: true, radarrHash: true});
      expect(trackerCalls(), 4);
    },
  );
}
