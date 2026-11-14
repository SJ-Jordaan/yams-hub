// PRIVATE_QBIT_CATEGORIES: torrents in a private category are hidden from
// every list and count, and every per-torrent route answers 404.
import 'dart:convert';

import 'package:test/test.dart';

import '../../support/test_hub.dart';
import 'activity_support.dart';

const _q = ServiceId.qbittorrent;

/// A hash the snapshot does not know yet (just added).
const _newHash = 'abcdefabcdefabcdefabcdefabcdefabcdefabcd';

/// The fixture snapshot with [plainHash] moved into the `books` category.
FakeResponse _maindata() {
  final body = jsonDecode(
    utf8.decode(fixtureBytes('downloads/qbittorrent_sync_maindata_full.json')),
  ) as Map<String, Object?>;
  final torrents = Map<String, Object?>.of(
    body['torrents']! as Map<String, Object?>,
  );
  torrents[plainHash] = {
    ...(torrents[plainHash]! as Map<String, Object?>),
    'category': 'books',
  };
  return FakeResponse.json({...body, 'torrents': torrents});
}

TestHub _hub({Map<String, String> env = const {}}) {
  final f = FakeUpstreams();
  installActivityFakes(f);
  f
    ..on(_q, 'GET', '/api/v2/sync/maindata', (_) => _maindata())
    ..on(_q, 'GET', '/api/v2/torrents/info', (r) {
      return FakeResponse.json([
        {'hash': _newHash, 'category': 'books', 'name': 'secret'},
      ]);
    });
  return TestHub(fakes: f, env: env);
}

void main() {
  late TestHub hub;

  setUp(() => hub = _hub(env: const {'PRIVATE_QBIT_CATEGORIES': 'BOOKS'}));
  tearDown(() => hub.close());

  bool posted() => hub.fakes
      .callsTo(_q)
      .any((c) => c.method == 'POST' && c.path != '/api/v2/auth/login');

  test('GET /torrents leaves out private torrents and categories', () async {
    final r = await hub.get('/api/v1/torrents');
    expect(r.status, 200, reason: r.body);
    final list = TorrentList.fromJson(r.map);
    expect(list.items.map((t) => t.hash), isNot(contains(plainHash)));
    expect(list.items, hasLength(4));
    expect(list.categories, ['lidarr', 'radarr', 'tv-sonarr']);
  });

  test('the unified queue leaves out private torrents', () async {
    final r = await hub.get('/api/v1/activity/queue');
    expect(r.status, 200, reason: r.body);
    expect(r.body, isNot(contains(plainHash)));
    expect(r.body, isNot(contains('Cyberpunk')));
  });

  test('GET /transfer/categories leaves out private categories', () async {
    final r = await hub.get('/api/v1/transfer/categories');
    expect(r.status, 200, reason: r.body);
    expect(r.body, isNot(contains('books')));
    expect(r.body, contains('radarr'));
  });

  test('per-torrent routes answer 404', () async {
    final detail = await hub.get('/api/v1/torrents/$plainHash');
    expect(detail.status, 404);
    expect(
      hub.fakes
          .callsTo(_q)
          .where((c) => c.path == '/api/v2/torrents/properties'),
      isEmpty,
    );
    final share = await hub.put(
      '/api/v1/torrents/$plainHash/share-limits',
      body: {'mode': 'global'},
    );
    expect(share.status, 404);
    final prio = await hub.put(
      '/api/v1/torrents/$plainHash/files/priority',
      body: {
        'indexes': [0],
        'priority': 'max',
      },
    );
    expect(prio.status, 404);
    final action = await hub.post(
      '/api/v1/torrents/actions',
      body: {
        'action': 'stop',
        'hashes': [sonarrHash, plainHash],
      },
    );
    expect(action.status, 404);
    expect(posted(), isFalse);
  });

  test('a torrent the snapshot does not know yet is checked', () async {
    final r = await hub.post(
      '/api/v1/torrents/actions',
      body: {
        'action': 'stop',
        'hashes': [_newHash],
      },
    );
    expect(r.status, 404);
    expect(posted(), isFalse);
    final info = hub.fakes
        .callsTo(_q)
        .firstWhere((c) => c.path == '/api/v2/torrents/info');
    expect(info.query['hashes'], [_newHash]);
  });

  test('public torrents still work', () async {
    final r = await hub.post(
      '/api/v1/torrents/actions',
      body: {
        'action': 'stop',
        'hashes': [sonarrHash],
      },
    );
    expect(r.status, 200, reason: r.body);
  });

  test('without the setting nothing is hidden', () async {
    final plain = _hub();
    addTearDown(plain.close);
    final list = TorrentList.fromJson(
      (await plain.get('/api/v1/torrents')).map,
    );
    expect(list.items, hasLength(5));
    expect(list.categories, contains('books'));
    final r = await plain.post(
      '/api/v1/torrents/actions',
      body: {
        'action': 'stop',
        'hashes': [_newHash],
      },
    );
    expect(r.status, 200, reason: r.body);
    expect(
      plain.fakes.callsTo(_q).where((c) => c.path == '/api/v2/torrents/info'),
      isEmpty,
    );
  });
}
