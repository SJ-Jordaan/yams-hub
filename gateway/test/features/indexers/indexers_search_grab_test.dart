import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:test/test.dart';

import '../../support/test_hub.dart';
import 'indexers_test_support.dart';

const _apiKey = '0123456789abcdef0123456789abcdef';

/// One Prowlarr search result with the given links.
Map<String, Object?> _result({
  int indexerId = 4,
  String title = 'Example Author - Example Book (2025) EPUB',
  String? downloadUrl,
  String? magnetUrl,
  String protocol = 'torrent',
}) => {
  'guid': 'guid-$title',
  'indexerId': indexerId,
  'indexer': indexerId == 4 ? '1337x' : 'Other',
  'title': title,
  'size': 15728640,
  'ageHours': 2.5,
  'publishDate': '2026-11-08T06:30:00Z',
  'downloadUrl': ?downloadUrl,
  'magnetUrl': ?magnetUrl,
  'categories': [
    {'id': 7000, 'name': 'Books', 'subCategories': <Object?>[]},
  ],
  'protocol': protocol,
};

/// Answers the next search with [results].
void _searchReturns(FakeUpstreams f, List<Object?> results) => f.on(
  ServiceId.prowlarr,
  'GET',
  '/api/v1/search',
  (_) => FakeResponse.json(results),
);

/// Searches and returns the releases.
Future<List<Release>> _search(TestHub hub, [String q = 'example']) async {
  final r = await hub.get('/api/v1/indexers/search?q=$q');
  expect(r.status, 200, reason: r.body);
  return ReleaseList.fromJson(r.map).items;
}

Future<TestResponse> _grab(TestHub hub, Release r, {Object? category}) =>
    hub.post(
      '/api/v1/indexers/grab',
      body: {'releaseId': r.releaseId, 'category': ?category},
    );

void main() {
  late TestHub hub;
  late List<FakeRequest> adds;
  final logs = <LogRecord>[];
  StreamSubscription<LogRecord>? logSub;

  setUp(() {
    hub = TestHub();
    fakeProwlarrReads(hub.fakes);
    adds = fakeQbit(hub.fakes);
    logs.clear();
    Logger.root.level = Level.ALL;
    logSub = Logger.root.onRecord.listen(logs.add);
  });
  tearDown(() async {
    await logSub?.cancel();
    await hub.close();
  });

  void expectNoLeakInLogs(List<String> secrets) {
    final text = logs
        .map((l) => '${l.message} ${l.error ?? ''} ${l.object ?? ''}')
        .join('\n');
    for (final s in secrets) {
      expect(text, isNot(contains(s)), reason: 'logged $s');
    }
  }

  group('GET /indexers/search', () {
    test(
      'maps results, hides download links and sends repeated params',
      () async {
        hub.fakes.on(
          ServiceId.prowlarr,
          'GET',
          '/api/v1/search',
          (_) => FakeResponse.json(
            syntheticFixture('prowlarr_search.synthetic.json'),
          ),
        );
        final r = await hub.get(
          '/api/v1/indexers/search?q=example%20show&type=tvsearch&indexerIds=4,5&categories=5000,5070&limit=50',
        );
        expect(r.status, 200, reason: r.body);
        final list = ReleaseList.fromJson(r.map);
        expect(list.items, hasLength(3));
        expect(list.tookMs, greaterThanOrEqualTo(0));

        final nyaa = list.items[0];
        expect(nyaa.releaseId, startsWith('rel_'));
        expect(nyaa.indexer, 'Nyaa.si');
        expect(nyaa.indexerId, 5);
        expect(nyaa.sizeBytes, 1453267968);
        expect(nyaa.ageHours, 14);
        expect(nyaa.seeders, 812);
        expect(nyaa.leechers, 40);
        expect(nyaa.grabs, 3021);
        expect(nyaa.hasMagnet, isTrue);
        expect(nyaa.categories, ['TV/Anime', 'Anime/Anime']);
        expect(nyaa.infoUrl, 'https://nyaa.si/view/1890001');
        expect(nyaa.imdbId, isNull);
        expect(nyaa.tmdbId, isNull);
        expect(nyaa.publishDate, DateTime.utc(2026, 11, 7, 18, 22, 51));

        final book = list.items[1];
        expect(book.hasMagnet, isFalse);
        expect(book.categories, ['Books']);

        final movie = list.items[2];
        expect(movie.imdbId, 'tt0944947');
        expect(movie.tmdbId, 1399);
        expect(movie.tvdbId, 121361);
        // Info URLs carrying a passkey are dropped.
        expect(movie.infoUrl, isNull);

        expect(r.body, isNot(contains('downloadUrl')));
        expect(r.body, isNot(contains('magnetUrl')));
        expect(r.body, isNot(contains(_apiKey)));
        expect(r.body, isNot(contains('passkey')));
        expect(r.body, isNot(contains('btih')));

        final call = hub.fakes
            .callsTo(ServiceId.prowlarr)
            .singleWhere((c) => c.path == '/api/v1/search');
        expect(call.query, {
          'query': ['example show'],
          'type': ['tvsearch'],
          'indexerIds': ['4', '5'],
          'categories': ['5000', '5070'],
          'limit': ['50'],
        });
      },
    );

    test('validates parameters', () async {
      for (final q in [
        '',
        '?q=a',
        '?q=${'x' * 201}',
        '?q=ok&type=anime',
        '?q=ok&limit=101',
        '?q=ok&indexerIds=one',
        '?q=ok&categories=-1',
      ]) {
        final r = await hub.get('/api/v1/indexers/search$q');
        expect(r.status, 400, reason: q);
        expect(r.errorCode, 'bad_request');
      }
      expect(
        hub.fakes
            .callsTo(ServiceId.prowlarr)
            .where((c) => c.path == '/api/v1/search'),
        isEmpty,
      );
    });

    test('allows one search per user at a time', () async {
      final gate = Completer<void>();
      hub.fakes.on(ServiceId.prowlarr, 'GET', '/api/v1/search', (_) async {
        await gate.future;
        return FakeResponse.json(<Object?>[]);
      });
      final first = hub.get('/api/v1/indexers/search?q=first');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final second = await hub.get('/api/v1/indexers/search?q=second');
      expect(second.status, 409);
      expect(second.errorCode, 'job_running');
      gate.complete();
      expect((await first).status, 200);
      // Free again afterwards.
      expect((await hub.get('/api/v1/indexers/search?q=third')).status, 200);
    });

    test('a failed search frees the slot', () async {
      hub.fakes.on(
        ServiceId.prowlarr,
        'GET',
        '/api/v1/search',
        (_) => FakeResponse.json({'message': 'boom'}, status: 500),
      );
      expect((await hub.get('/api/v1/indexers/search?q=x1')).status, 502);
      expect((await hub.get('/api/v1/indexers/search?q=x2')).status, 502);
    });

    test('is admin only', () async {
      final r = await hub.get(
        '/api/v1/indexers/search?q=example',
        as: TestAs.member,
      );
      expect(r.status, 403);
    });
  });

  group('POST /indexers/grab', () {
    test('a magnet goes to qBittorrent urls= and creates "manual"', () async {
      _searchReturns(hub.fakes, [
        _result(
          downloadUrl:
              'http://192.168.10.183:9696/4/download?apikey=$_apiKey&link=x',
          magnetUrl:
              'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
        ),
      ]);
      final release = (await _search(hub)).single;
      final r = await hub.post(
        '/api/v1/indexers/grab',
        body: {
          'releaseId': release.releaseId,
          'tags': ['manual-grab'],
        },
      );
      expect(r.status, 201, reason: r.body);
      expect(r.map, {'ok': true});

      final create = hub.fakes
          .callsTo(ServiceId.qbittorrent)
          .singleWhere((c) => c.path == '/api/v2/torrents/createCategory');
      expect(Uri.splitQueryString(create.body), {
        'category': 'manual',
        'savePath': '',
      });
      final form = adds.single.form;
      expect(form['urls'], startsWith('magnet:?xt=urn:btih:0123'));
      expect(form['category'], 'manual');
      expect(form['tags'], 'manual-grab');
      // Nothing was downloaded.
      expect(
        hub.fakes
            .callsTo(ServiceId.prowlarr)
            .where((c) => c.path.endsWith('/download')),
        isEmpty,
      );
      expectNoLeakInLogs([_apiKey, 'btih']);
    });

    test('a Prowlarr download URL is rewritten to PROWLARR_URL without apikey', () async {
      _searchReturns(hub.fakes, [
        _result(
          downloadUrl:
              'http://192.168.10.183:9696/4/download?apikey=$_apiKey&link=WmRIUjh5&file=Example+Book',
        ),
      ]);
      hub.fakes.on(
        ServiceId.prowlarr,
        'GET',
        '/4/download',
        (_) => FakeResponse.bytes(
          torrentBytes(),
          contentType: 'application/x-bittorrent',
        ),
      );
      final release = (await _search(hub)).single;
      final r = await _grab(hub, release, category: 'books');
      expect(r.status, 201, reason: r.body);

      final dl = hub.fakes
          .callsTo(ServiceId.prowlarr)
          .singleWhere((c) => c.path == '/4/download');
      expect(dl.host, 'prowlarr.test');
      expect(dl.query, {
        'link': ['WmRIUjh5'],
        'file': ['Example Book'],
      });
      expect(dl.headers['x-api-key'], '***');
      // The advertised host was never contacted.
      expect(hub.fakes.calls.where((c) => c.host == '192.168.10.183'), isEmpty);

      final add = adds.single;
      expect(add.headers['content-type'], startsWith('multipart/form-data'));
      expect(add.body, contains('name="torrents"'));
      expect(add.body, contains('4:info'));
      expect(add.body, contains('books'));
      // `books` exists: no category is created.
      expect(
        hub.fakes
            .callsTo(ServiceId.qbittorrent)
            .where((c) => c.path.endsWith('createCategory')),
        isEmpty,
      );
      expectNoLeakInLogs([_apiKey, 'WmRIUjh5']);
    });

    test('a Prowlarr redirect to magnet: is handed to qBittorrent', () async {
      _searchReturns(hub.fakes, [
        _result(
          downloadUrl: 'http://prowlarr:9696/4/download?apikey=$_apiKey&link=m',
        ),
      ]);
      hub.fakes.on(
        ServiceId.prowlarr,
        'GET',
        '/4/download',
        (_) => FakeResponse(
          301,
          headers: {
            'location':
                'magnet:?xt=urn:btih:89abcdef0123456789abcdef0123456789abcdef',
          },
        ),
      );
      final release = (await _search(hub)).single;
      final r = await _grab(hub, release);
      expect(r.status, 201, reason: r.body);
      expect(adds.single.form['urls'], startsWith('magnet:?xt=urn:btih:89ab'));
    });

    test('a proxied Prowlarr magnetUrl (no downloadUrl) resolves to the magnet', () async {
      _searchReturns(hub.fakes, [
        _result(
          magnetUrl:
              'http://prowlarr:9696/4/download?apikey=$_apiKey&link=mg&file=x',
        ),
      ]);
      hub.fakes.on(
        ServiceId.prowlarr,
        'GET',
        '/4/download',
        (_) => FakeResponse(
          301,
          headers: {
            'location':
                'magnet:?xt=urn:btih:fedcba9876543210fedcba9876543210fedcba98',
          },
        ),
      );
      final release = (await _search(hub)).single;
      expect(release.hasMagnet, isTrue);
      final r = await _grab(hub, release);
      expect(r.status, 201, reason: r.body);
      final dl = hub.fakes
          .callsTo(ServiceId.prowlarr)
          .singleWhere((c) => c.path == '/4/download');
      expect(dl.query, {
        'link': ['mg'],
        'file': ['x'],
      });
      expect(adds.single.form['urls'], startsWith('magnet:?xt=urn:btih:fedc'));
      expectNoLeakInLogs([_apiKey]);
    });

    test('a magnet smuggling a second URL is refused', () async {
      _searchReturns(hub.fakes, [
        _result(
          magnetUrl:
              'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567'
              '\nhttp://socket-proxy:2375/v1.54/containers/json',
        ),
      ]);
      final release = (await _search(hub)).single;
      final r = await _grab(hub, release);
      expect(r.status, 422, reason: r.body);
      expect(
        r.map['error'],
        containsPair('message', 'Release URL not allowed'),
      );
      expect(adds, isEmpty);
    });

    test('a Prowlarr download error never echoes its message', () async {
      _searchReturns(hub.fakes, [
        _result(
          downloadUrl: 'http://prowlarr:9696/4/download?apikey=$_apiKey&link=e',
        ),
      ]);
      hub.fakes.on(
        ServiceId.prowlarr,
        'GET',
        '/4/download',
        (_) => FakeResponse.json({
          'message': 'Error downloading https://tracker.example.org/dl.php?id=9&hash=c0ffee',
        }, status: 500),
      );
      final release = (await _search(hub)).single;
      final r = await _grab(hub, release);
      expect(r.status, 502, reason: r.body);
      expect(r.errorCode, 'upstream_error');
      expect(r.body, isNot(contains('tracker.example.org')));
      expect(r.body, isNot(contains('c0ffee')));
      expect(adds, isEmpty);
      expectNoLeakInLogs(['tracker.example.org', 'c0ffee', _apiKey]);
    });

    test(
      'a Prowlarr redirect to a public https tracker is followed safely',
      () async {
        _searchReturns(hub.fakes, [
          _result(
            downloadUrl:
                'http://prowlarr:9696/4/download?apikey=$_apiKey&link=r',
          ),
        ]);
        hub.fakes
          ..on(
            ServiceId.prowlarr,
            'GET',
            '/4/download',
            (_) => FakeResponse(
              302,
              headers: {
                'location': 'https://tracker.example.org/get/1.torrent',
              },
            ),
          )
          ..onRemote(
            'tracker.example.org',
            'GET',
            '/get/1.torrent',
            (_) => FakeResponse.bytes(torrentBytes()),
          );
        final release = (await _search(hub)).single;
        expect((await _grab(hub, release)).status, 201);
        expect(hub.fakes.remoteCalls('tracker.example.org'), hasLength(1));
        expect(adds.single.body, contains('name="torrents"'));
      },
    );

    test('a redirect to http://socket-proxy:2375 is refused', () async {
      _searchReturns(hub.fakes, [
        _result(
          downloadUrl:
              'http://prowlarr:9696/4/download?apikey=$_apiKey&link=evil',
        ),
        _result(
          indexerId: 11,
          title: 'Evil public',
          downloadUrl: 'https://evil.example.com/t/1.torrent',
        ),
      ]);
      hub.fakes
        ..on(
          ServiceId.prowlarr,
          'GET',
          '/4/download',
          (_) => FakeResponse(
            302,
            headers: {
              'location': 'http://socket-proxy:2375/v1.54/containers/json',
            },
          ),
        )
        ..onRemote(
          'evil.example.com',
          'GET',
          '/t/1.torrent',
          (_) => FakeResponse(
            302,
            headers: {
              'location': 'http://socket-proxy:2375/v1.54/containers/json',
            },
          ),
        )
        ..onRemote(
          'socket-proxy',
          '*',
          RegExp('.*'),
          (_) => FakeResponse.json(<Object?>[]),
        );
      final releases = await _search(hub);
      for (final release in releases) {
        final r = await _grab(hub, release);
        expect(r.status, 422, reason: '${release.title}: ${r.body}');
        expect(r.errorCode, 'validation_failed');
        expect(
          r.map['error'],
          containsPair('message', 'Release URL not allowed'),
        );
      }
      expect(
        hub.fakes.calls.where((c) => c.host.startsWith('socket-proxy')),
        isEmpty,
      );
      expect(hub.fakes.callsTo(ServiceId.docker), isEmpty);
      expect(adds, isEmpty);
    });

    test(
      'refuses private, single-label and plain-http download URLs',
      () async {
        hub.fakes.dns['nas.example.org'] = [InternetAddress('192.168.10.183')];
        hub.fakes.dns['cgnat.example.org'] = [InternetAddress('100.100.1.1')];
        _searchReturns(hub.fakes, [
          for (final url in [
            'https://nas.example.org/a.torrent',
            'https://cgnat.example.org/a.torrent',
            'https://socket-proxy-hub:2375/containers/json',
            'https://172.28.0.5/a.torrent',
            'https://[::1]/a.torrent',
            'http://tracker.example.org/a.torrent',
            'file:///etc/passwd',
          ])
            _result(indexerId: 11, title: url, downloadUrl: url),
        ]);
        for (final release in await _search(hub)) {
          final r = await _grab(hub, release);
          expect(r.status, 422, reason: '${release.title}: ${r.body}');
        }
        expect(hub.fakes.calls.where((c) => c.service == null), isEmpty);
        expect(adds, isEmpty);
      },
    );

    test('a redirect to a private address is refused at the hop', () async {
      hub.fakes.dns['internal.example.org'] = [InternetAddress('10.0.0.8')];
      _searchReturns(hub.fakes, [
        _result(
          indexerId: 11,
          downloadUrl: 'https://tracker.example.org/a.torrent',
        ),
      ]);
      hub.fakes.onRemote(
        'tracker.example.org',
        'GET',
        '/a.torrent',
        (_) => FakeResponse(
          302,
          headers: {'location': 'https://internal.example.org/a.torrent'},
        ),
      );
      final r = await _grab(hub, (await _search(hub)).single);
      expect(r.status, 422);
      expect(hub.fakes.remoteCalls('internal.example.org'), isEmpty);
    });

    test('more than 3 redirects are refused', () async {
      _searchReturns(hub.fakes, [
        _result(indexerId: 11, downloadUrl: 'https://tracker.example.org/r/0'),
      ]);
      hub.fakes.onRemote(
        'tracker.example.org',
        'GET',
        RegExp(r'^/r/\d+$'),
        (req) => FakeResponse(
          302,
          headers: {
            'location': '/r/${int.parse(req.path.split('/').last) + 1}',
          },
        ),
      );
      final r = await _grab(hub, (await _search(hub)).single);
      expect(r.status, 422);
      expect(hub.fakes.remoteCalls('tracker.example.org'), hasLength(4));
    });

    test(
      'a public https download with a passkey works and is never logged',
      () async {
        const url =
            'https://tracker.example.org/dl/7.torrent?passkey=abcdef0123456789';
        _searchReturns(hub.fakes, [_result(indexerId: 11, downloadUrl: url)]);
        hub.fakes.onRemote(
          'tracker.example.org',
          'GET',
          '/dl/7.torrent',
          (_) => FakeResponse.bytes(torrentBytes()),
        );
        final r = await _grab(hub, (await _search(hub)).single);
        expect(r.status, 201, reason: r.body);
        expect(
          hub.fakes.remoteCalls('tracker.example.org').single.query['passkey'],
          ['abcdef0123456789'],
        );
        expectNoLeakInLogs(['abcdef0123456789', '/dl/7.torrent']);
      },
    );

    test('a remote magnet redirect is handed to qBittorrent', () async {
      _searchReturns(hub.fakes, [
        _result(indexerId: 11, downloadUrl: 'https://tracker.example.org/m'),
      ]);
      hub.fakes.onRemote(
        'tracker.example.org',
        'GET',
        '/m',
        (_) => FakeResponse(
          302,
          headers: {
            'location':
                'magnet:?xt=urn:btih:fedcba9876543210fedcba9876543210fedcba98',
          },
        ),
      );
      expect((await _grab(hub, (await _search(hub)).single)).status, 201);
      expect(adds.single.form['urls'], startsWith('magnet:?xt=urn:btih:fedc'));
    });

    test('bodies over 5 MB are aborted while streaming', () async {
      _searchReturns(hub.fakes, [
        _result(
          downloadUrl:
              'http://prowlarr:9696/4/download?apikey=$_apiKey&link=big',
        ),
        _result(
          indexerId: 11,
          title: 'remote big',
          downloadUrl: 'https://tracker.example.org/big',
        ),
      ]);
      var prowlarrChunks = 0;
      var remoteChunks = 0;
      Stream<List<int>> big(void Function() onChunk) async* {
        yield [0x64]; // "d"
        for (var i = 0; i < 100; i++) {
          onChunk();
          yield List.filled(256 * 1024, 0x30);
        }
      }

      hub.fakes
        ..on(
          ServiceId.prowlarr,
          'GET',
          '/4/download',
          (_) => FakeResponse.chunked(big(() => prowlarrChunks++)),
        )
        ..onRemote(
          'tracker.example.org',
          'GET',
          '/big',
          (_) => FakeResponse.chunked(big(() => remoteChunks++)),
        );
      for (final release in await _search(hub)) {
        final r = await _grab(hub, release);
        expect(r.status, 502, reason: r.body);
        expect(r.errorCode, 'upstream_bad_response');
      }
      // Stopped shortly after 5 MB (20 chunks of 256 KiB), not after 25 MB.
      expect(prowlarrChunks, lessThan(30));
      expect(remoteChunks, lessThan(30));
      expect(adds, isEmpty);
    });

    test('a body that is not a bencoded torrent is 502', () async {
      _searchReturns(hub.fakes, [
        _result(
          downloadUrl:
              'http://prowlarr:9696/4/download?apikey=$_apiKey&link=html',
        ),
      ]);
      hub.fakes.on(
        ServiceId.prowlarr,
        'GET',
        '/4/download',
        (_) => FakeResponse.text(
          '<html><body>Cloudflare</body></html>',
          contentType: 'text/html',
        ),
      );
      final r = await _grab(hub, (await _search(hub)).single);
      expect(r.status, 502);
      expect(r.errorCode, 'upstream_bad_response');
      expect(adds, isEmpty);
    });

    test('unknown or expired releases are 404', () async {
      final unknown = await hub.post(
        '/api/v1/indexers/grab',
        body: {'releaseId': 'rel_doesnotexist'},
      );
      expect(unknown.status, 404);
      expect(
        unknown.map['error'],
        containsPair('message', 'Release expired, search again'),
      );

      _searchReturns(hub.fakes, [
        _result(
          magnetUrl:
              'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
        ),
      ]);
      final release = (await _search(hub)).single;
      hub.clock.advance(const Duration(minutes: 31));
      final expired = await _grab(hub, release);
      expect(expired.status, 404);
      expect(adds, isEmpty);
    });

    test('validates the body', () async {
      _searchReturns(hub.fakes, [
        _result(
          magnetUrl:
              'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
        ),
      ]);
      final release = (await _search(hub)).single;
      for (final body in <Map<String, Object?>>[
        {},
        {'releaseId': 5},
        {'releaseId': release.releaseId, 'category': 'a//b'},
        {'releaseId': release.releaseId, 'category': 12},
        {
          'releaseId': release.releaseId,
          'tags': ['a,b'],
        },
        {'releaseId': release.releaseId, 'tags': 'x'},
      ]) {
        final r = await hub.post('/api/v1/indexers/grab', body: body);
        expect(r.status, 422, reason: '$body → ${r.body}');
      }
      expect(adds, isEmpty);
    });

    test('an unknown non-default category is not created', () async {
      _searchReturns(hub.fakes, [
        _result(
          magnetUrl:
              'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
        ),
      ]);
      final r = await _grab(
        hub,
        (await _search(hub)).single,
        category: 'movies-manual',
      );
      expect(r.status, 422);
      expect(
        hub.fakes
            .callsTo(ServiceId.qbittorrent)
            .where((c) => c.path.endsWith('createCategory')),
        isEmpty,
      );
      expect(adds, isEmpty);
    });

    test('qBittorrent 415 is 422 and "Fails." is 409', () async {
      _searchReturns(hub.fakes, [
        _result(
          magnetUrl:
              'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
        ),
      ]);
      final release = (await _search(hub)).single;
      hub.fakes.on(
        ServiceId.qbittorrent,
        'POST',
        '/api/v2/torrents/add',
        (_) => FakeResponse.text('Fails.', status: 415),
      );
      expect((await _grab(hub, release)).status, 422);
      hub.fakes.on(
        ServiceId.qbittorrent,
        'POST',
        '/api/v2/torrents/add',
        (_) => FakeResponse.text('Fails.'),
      );
      expect((await _grab(hub, release)).status, 409);
    });

    test('usenet releases cannot be grabbed', () async {
      _searchReturns(hub.fakes, [
        _result(
          protocol: 'usenet',
          downloadUrl: 'https://nzb.example.org/get/1.nzb',
        ),
      ]);
      final r = await _grab(hub, (await _search(hub)).single);
      expect(r.status, 422);
      expect(hub.fakes.calls.where((c) => c.service == null), isEmpty);
    });

    test('is admin only', () async {
      final r = await hub.post(
        '/api/v1/indexers/grab',
        body: {'releaseId': 'rel_x'},
        as: TestAs.member,
      );
      expect(r.status, 403);
    });
  });
}
