import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/core/images/image_cache.dart';
import 'package:yams_hub_gateway/src/core/images/image_routes.dart';
import 'package:yams_hub_gateway/src/core/images/image_spec.dart';

import '../support/test_hub.dart';

const _hosts = [
  'artworks.thetvdb.com',
  'image.tmdb.org',
  'assets.fanart.tv',
  'static.tvmaze.com',
  'www.gravatar.com',
];

final _jpeg = [0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(64, 7)];
final _png = [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  ...List.filled(64, 1),
];
final _webp = [
  ...ascii.encode('RIFF'),
  0,
  0,
  0,
  0,
  ...ascii.encode('WEBP'),
  ...List.filled(32, 2),
];
final _svg = utf8.encode(
  '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>',
);

/// Parses a builder's output the way the route does.
ImageSpec _parse(String path) {
  final uri = Uri.parse(path);
  final segments = uri.pathSegments;
  expect(segments.take(3), ['api', 'v1', 'img']);
  final kind = segments[3];
  final params = switch (kind) {
    'arr' => {'svc': segments[4], 'id': segments[5], 'coverType': segments[6]},
    'tmdb' => {'size': segments[4], 'file': segments[5]},
    'jellyfin' => {'itemId': segments[4], 'imageType': segments[5]},
    'jellyfin-user' => {'userId': segments[4]},
    'abs' => {'itemId': segments[4]},
    'kavita' => {'seriesId': segments[5]},
    'seerr-avatar' => {'seerrUserId': segments[4]},
    _ => <String, String>{},
  };
  return ImageSpec.parse(
    kind,
    params,
    uri.queryParameters,
    remoteHosts: _hosts,
  );
}

void main() {
  group('ImageUrls round trips', () {
    final urls = ImageUrls(_hosts);

    void roundTrip(String? path, {String? expected}) {
      expect(path, isNotNull);
      if (expected != null) expect(path, expected);
      expect(_parse(path!).path, path, reason: 'parse(path).path == path');
    }

    test('arr', () {
      roundTrip(
        urls.arr(
          ArrService.sonarr,
          54,
          'poster',
          size: 250,
          version: '639055',
          fallbackUrl: 'https://artworks.thetvdb.com/banners/p.jpg',
        ),
        expected: '/api/v1/img/arr/sonarr/54/poster?size=250&v=639055&fallback=https%3A%2F%2Fartworks.thetvdb.com%2Fbanners%2Fp.jpg',
      );
      roundTrip(
        urls.arr(ArrService.radarr, 3, 'fanart', size: 1000),
        expected: '/api/v1/img/arr/radarr/3/fanart?size=full',
      );
      roundTrip(
        urls.arr(ArrService.radarr, 3, 'clearlogo'),
        expected: '/api/v1/img/arr/radarr/3/clearlogo?size=full',
      );
      expect(
        urls.arr(
          ArrService.sonarr,
          1,
          'poster',
          fallbackUrl: 'https://evil.example/x.jpg',
        ),
        '/api/v1/img/arr/sonarr/1/poster?size=500',
      );
      expect(urls.arr(ArrService.unknown, 1, 'poster'), isNull);
      expect(urls.arr(ArrService.sonarr, 0, 'poster'), isNull);
      expect(urls.arr(ArrService.sonarr, 1, 'thumb'), isNull);
    });

    test('remote', () {
      roundTrip(
        urls.remote('https://image.tmdb.org/t/p/original/abc.jpg', width: 300),
        expected: '/api/v1/img/remote?u=https%3A%2F%2Fimage.tmdb.org%2Ft%2Fp%2Foriginal%2Fabc.jpg&w=342',
      );
      expect(urls.remote('http://image.tmdb.org/x.jpg'), isNull);
      expect(urls.remote('https://evil.example/x.jpg'), isNull);
      expect(urls.remote(null), isNull);
    });

    test('tmdb', () {
      roundTrip(
        urls.tmdb('/n8V61f1v7idya4WJzGEJNoIp9iL.jpg', 'w342'),
        expected: '/api/v1/img/tmdb/w342/n8V61f1v7idya4WJzGEJNoIp9iL.jpg',
      );
      roundTrip(urls.tmdb('abc.png', 'original'));
      expect(urls.tmdb('/../x.jpg', 'w342'), isNull);
      expect(urls.tmdb('/x.svg', 'w342'), isNull);
      expect(urls.tmdb('/x.jpg', 'w999'), isNull);
    });

    test('jellyfin', () {
      roundTrip(
        urls.jellyfin(
          '4F5731B2-C357-273B-F400-2DD8D042A856',
          'Primary',
          tag: 'abc',
          fillHeight: 300,
          quality: 99,
          index: 2,
        ),
        expected: '/api/v1/img/jellyfin/4f5731b2c357273bf4002dd8d042a856/Primary?tag=abc&fillHeight=342&index=2&quality=90',
      );
      roundTrip(
        urls.jellyfin(
          '4f5731b2c357273bf4002dd8d042a856',
          'Backdrop',
          maxWidth: 2000,
          fillWidth: 50,
        ),
      );
      expect(urls.jellyfin('nope', 'Primary'), isNull);
      expect(
        urls.jellyfin('4f5731b2c357273bf4002dd8d042a856', 'Banner'),
        isNull,
      );
      expect(
        urls.jellyfin('4f5731b2c357273bf4002dd8d042a856', 'Primary', index: 21),
        isNull,
      );
    });

    test('jellyfinUser, abs, kavitaSeries, seerrAvatar', () {
      roundTrip(
        urls.jellyfinUser('4c0628aacef24bdfacd40f946ea33ee7', tag: 't1'),
        expected:
            '/api/v1/img/jellyfin-user/4c0628aacef24bdfacd40f946ea33ee7?tag=t1',
      );
      roundTrip(
        urls.abs('li_abc-123', version: '1794118925'),
        expected: '/api/v1/img/abs/li_abc-123?w=500&v=1794118925',
      );
      roundTrip(
        urls.abs('li_abc', width: 96),
        expected: '/api/v1/img/abs/li_abc?w=96',
      );
      roundTrip(
        urls.kavitaSeries(12, version: 'x'),
        expected: '/api/v1/img/kavita/series/12?v=x',
      );
      roundTrip(
        urls.seerrAvatar(2, version: '1783334055000'),
        expected: '/api/v1/img/seerr-avatar/2?v=1783334055000',
      );
      expect(urls.jellyfinUser(null), isNull);
      expect(urls.abs('bad/id'), isNull);
      expect(urls.kavitaSeries(null), isNull);
      expect(urls.seerrAvatar(0), isNull);
    });

    test('size buckets snap up', () {
      expect(snapImageSize(1), 96);
      expect(snapImageSize(96), 96);
      expect(snapImageSize(97), 160);
      expect(snapImageSize(500), 500);
      expect(snapImageSize(5000), 1280);
    });

    test('the parser rejects bad parameters with 400', () {
      void bad(
        String kind,
        Map<String, String> params, [
        Map<String, String> query = const {},
      ]) {
        expect(
          () => ImageSpec.parse(kind, params, query, remoteHosts: _hosts),
          throwsA(isA<ApiException>().having((e) => e.status, 'status', 400)),
          reason: '$kind $params $query',
        );
      }

      bad('arr', {'svc': 'lidarr', 'id': '1', 'coverType': 'poster'});
      bad('arr', {'svc': 'sonarr', 'id': '-1', 'coverType': 'poster'});
      bad('arr', {'svc': 'sonarr', 'id': '01', 'coverType': 'poster'});
      bad(
        'arr',
        {'svc': 'sonarr', 'id': '1', 'coverType': 'poster'},
        {'size': '9000'},
      );
      bad(
        'arr',
        {'svc': 'sonarr', 'id': '1', 'coverType': 'poster'},
        {'fallback': 'https://evil.example/x.jpg'},
      );
      bad('remote', {}, {'u': 'https://evil.example/x.jpg'});
      bad('remote', {}, {'u': 'http://image.tmdb.org/x.jpg'});
      bad('tmdb', {'size': 'w342', 'file': '..%2Fx.jpg'});
      bad('jellyfin', {'itemId': '../../System', 'imageType': 'Primary'});
      bad(
        'jellyfin',
        {'itemId': '4f5731b2c357273bf4002dd8d042a856', 'imageType': 'Primary'},
        {'index': '21'},
      );
      bad('abs', {'itemId': 'a/b'});
      bad('kavita', {'seriesId': 'x'});
      bad('seerr-avatar', {'seerrUserId': '0'});
    });
  });

  group('image routes', () {
    late TestHub hub;
    setUp(() => hub = TestHub());
    tearDown(() => hub.close());

    test(
      'arr cover: upstream file, headers, disk cache, versioned replace',
      () async {
        var calls = 0;
        hub.fakes.on(ServiceId.sonarr, 'GET', '/MediaCover/54/poster-250.jpg', (
          _,
        ) {
          calls++;
          return FakeResponse.bytes(_jpeg, contentType: 'image/jpeg');
        });
        final r = await hub.get(
          '/api/v1/img/arr/sonarr/54/poster?size=250&v=1',
        );
        expect(r.status, 200, reason: r.body);
        expect(r.bodyBytes, _jpeg);
        expect(r.headers['content-type'], 'image/jpeg');
        expect(
          r.headers['content-security-policy'],
          "default-src 'none'; sandbox",
        );
        expect(r.headers['x-content-type-options'], 'nosniff');
        expect(r.headers['cross-origin-resource-policy'], 'same-origin');
        expect(r.headers['content-disposition'], 'inline');
        expect(
          r.headers['cache-control'],
          'private, max-age=31536000, immutable',
        );
        final etag = r.headers['etag']!;

        await hub.get('/api/v1/img/arr/sonarr/54/poster?size=250&v=1');
        expect(calls, 1, reason: 'served from the disk cache');
        final notModified = await hub.get(
          '/api/v1/img/arr/sonarr/54/poster?size=250&v=1',
          headers: {'if-none-match': etag},
        );
        expect(notModified.status, 304);

        await hub.get('/api/v1/img/arr/sonarr/54/poster?size=250&v=2');
        expect(calls, 2, reason: 'a newer v replaces the entry');
        expect(
          hub.hub.imageService.cache.entryCount,
          1,
          reason: 'v does not multiply entries',
        );

        final unversioned = await hub.get(
          '/api/v1/img/arr/sonarr/54/poster?size=250',
        );
        expect(unversioned.headers['cache-control'], 'private, max-age=86400');
        expect(calls, 2);
      },
    );

    test('fanart/banner size variants and clearlogo', () async {
      hub.fakes.on(
        ServiceId.radarr,
        'GET',
        '/MediaCover/3/fanart-360.jpg',
        (_) => FakeResponse.bytes(_jpeg, contentType: 'image/jpeg'),
      );
      hub.fakes.on(
        ServiceId.radarr,
        'GET',
        '/MediaCover/3/clearlogo.png',
        (_) => FakeResponse.bytes(_png, contentType: 'image/png'),
      );
      expect(
        (await hub.get('/api/v1/img/arr/radarr/3/fanart?size=500')).status,
        200,
      );
      final logo = await hub.get('/api/v1/img/arr/radarr/3/clearlogo');
      expect(logo.headers['content-type'], 'image/png');
    });

    test('an arr 404 falls back to the allow-listed remote URL; 404s are never cached', () async {
      var upstream = 0;
      hub.fakes.on(ServiceId.sonarr, 'GET', '/MediaCover/7/poster-500.jpg', (
        _,
      ) {
        upstream++;
        return FakeResponse.json({'message': 'NotFound'}, status: 404);
      });
      hub.fakes.onRemote(
        'artworks.thetvdb.com',
        'GET',
        '/banners/7.jpg',
        (_) => FakeResponse.bytes(_webp, contentType: 'image/webp'),
      );
      final fallback = Uri.encodeQueryComponent(
        'https://artworks.thetvdb.com/banners/7.jpg',
      );
      final r = await hub.get(
        '/api/v1/img/arr/sonarr/7/poster?fallback=$fallback',
      );
      expect(r.status, 200);
      expect(r.headers['content-type'], 'image/webp');
      final none = await hub.get('/api/v1/img/arr/sonarr/8/poster');
      expect(none.status, 404);
      expect(none.errorCode, 'not_found');
      await hub.get('/api/v1/img/arr/sonarr/8/poster');
      expect(
        upstream,
        1 + 0,
        reason: 'the /7 poster upstream call happened once',
      );
    });

    test('an arr fallback is fetched at the requested size bucket', () async {
      hub.fakes.on(
        ServiceId.radarr,
        'GET',
        RegExp(r'^/MediaCover/'),
        (_) => FakeResponse.json({'message': 'NotFound'}, status: 404),
      );
      for (final w in ['w342', 'w500', 'original']) {
        hub.fakes.onRemote(
          'image.tmdb.org',
          'GET',
          '/t/p/$w/x.jpg',
          (_) => FakeResponse.bytes(_jpeg, contentType: 'image/jpeg'),
        );
      }
      final fallback = Uri.encodeQueryComponent(
        'https://image.tmdb.org/t/p/original/x.jpg',
      );
      Future<String> fetched(String size) async {
        hub.fakes.clearCalls();
        final r = await hub.get(
          '/api/v1/img/arr/radarr/9/poster?size=$size&fallback=$fallback',
        );
        expect(r.status, 200, reason: r.body);
        return hub.fakes.remoteCalls('image.tmdb.org').single.path;
      }

      expect(await fetched('250'), '/t/p/w342/x.jpg');
      expect(await fetched('500'), '/t/p/w500/x.jpg');
      expect(await fetched('full'), '/t/p/original/x.jpg');
      // The cache key stays the arr spec: one entry per size.
      expect(hub.hub.imageService.cache.entryCount, 3);
      hub.fakes.clearCalls();
      await hub.get(
        '/api/v1/img/arr/radarr/9/poster?size=250&fallback=$fallback',
      );
      expect(hub.fakes.remoteCalls('image.tmdb.org'), isEmpty);
    });

    test(
      'an image 404 may be cached briefly by the browser; 502 may not',
      () async {
        final missing = await hub.get('/api/v1/img/arr/sonarr/8/poster');
        expect(missing.status, 404);
        expect(missing.errorCode, 'not_found');
        expect(missing.headers['cache-control'], imageNotFoundCacheControl);
        expect(imageNotFoundCacheControl, 'private, max-age=300');
        // An upstream 404 (unmatched fake) is the same.
        final upstream = await hub.get('/api/v1/img/kavita/series/77');
        expect(upstream.status, 404, reason: upstream.body);
        expect(upstream.headers['cache-control'], imageNotFoundCacheControl);

        hub.fakes.onRemote(
          'image.tmdb.org',
          'GET',
          '/t/p/w342/broken.png',
          (_) => FakeResponse.bytes(_svg, contentType: 'image/svg+xml'),
        );
        final bad = await hub.get('/api/v1/img/tmdb/w342/broken.png');
        expect(bad.status, 502);
        expect(bad.headers['cache-control'], 'no-store');
        // Validation errors and authentication failures stay uncacheable.
        final invalid = await hub.get('/api/v1/img/tmdb/w1/x.jpg');
        expect(invalid.status, 400);
        expect(invalid.headers['cache-control'], 'no-store');
        final anon = await hub.get(
          '/api/v1/img/abs/li_1',
          as: TestAs.anonymous,
        );
        expect(anon.status, 401);
        expect(anon.headers['cache-control'], 'no-store');
      },
    );

    test('an SVG upstream image gives 502 and is not cached', () async {
      var calls = 0;
      hub.fakes.onRemote('image.tmdb.org', 'GET', '/t/p/w342/logo.png', (_) {
        calls++;
        return FakeResponse.bytes(_svg, contentType: 'image/svg+xml');
      });
      for (var i = 0; i < 2; i++) {
        final r = await hub.get('/api/v1/img/tmdb/w342/logo.png');
        expect(r.status, 502);
        expect(r.errorCode, 'upstream_bad_response');
      }
      expect(calls, 2, reason: 'nothing was cached');
      expect(hub.hub.imageService.cache.entryCount, 0);
      // An SVG body labelled as PNG is refused by the magic-byte check too.
      hub.fakes.onRemote(
        'image.tmdb.org',
        'GET',
        '/t/p/w342/fake.png',
        (_) => FakeResponse.bytes(_svg, contentType: 'image/png'),
      );
      expect((await hub.get('/api/v1/img/tmdb/w342/fake.png')).status, 502);
    });

    test('an oversized image stream is aborted', () async {
      var cancelled = false;
      var sent = 0;
      hub.fakes.on(ServiceId.jellyfin, 'GET', RegExp(r'^/Items/.*'), (_) {
        late StreamController<List<int>> c;
        c = StreamController<List<int>>(
          onListen: () async {
            c.add(_jpeg);
            while (!cancelled && sent < 40 * 1024 * 1024) {
              c.add(List.filled(1024 * 1024, 0));
              sent += 1024 * 1024;
              await Future<void>.delayed(Duration.zero);
            }
            await c.close();
          },
          onCancel: () => cancelled = true,
        );
        return FakeResponse.chunked(
          c.stream,
          headers: {'content-type': 'image/jpeg', 'content-length': '1000'},
        );
      });
      final r = await hub.get(
        '/api/v1/img/jellyfin/4f5731b2c357273bf4002dd8d042a856/Primary',
      );
      expect(r.status, 502);
      expect(cancelled, isTrue);
      expect(sent, lessThan(20 * 1024 * 1024));
      expect(hub.hub.imageService.cache.entryCount, 0);
    });

    test(
      'jellyfin, abs and kavita upstream URIs come from validated segments',
      () async {
        hub.fakes.on(
          ServiceId.jellyfin,
          'GET',
          '/Items/4f5731b2c357273bf4002dd8d042a856/Images/Backdrop/1',
          (_) => FakeResponse.bytes(_jpeg),
        );
        hub.fakes.on(
          ServiceId.audiobookshelf,
          'GET',
          '/api/items/li_1/cover',
          (_) => FakeResponse.bytes(_webp, contentType: 'image/webp'),
        );
        hub.fakes.on(
          ServiceId.kavita,
          'GET',
          '/api/Image/series-cover',
          (_) => FakeResponse.bytes(_png, contentType: 'image/png'),
        );
        expect(
          (await hub.get(
            '/api/v1/img/jellyfin/4F5731B2-C357-273B-F400-2DD8D042A856/Backdrop?index=1&fillWidth=700&quality=10',
          )).status,
          200,
        );
        final jf = hub.fakes.callsTo(ServiceId.jellyfin).last;
        expect(jf.query['fillWidth'], ['780']);
        expect(jf.query['quality'], ['60']);
        expect((await hub.get('/api/v1/img/abs/li_1?w=300')).status, 200);
        final abs = hub.fakes.callsTo(ServiceId.audiobookshelf).last;
        expect(abs.query, {
          'width': ['342'],
          'format': ['webp'],
        });
        expect(abs.headers['authorization'], '***');
        expect((await hub.get('/api/v1/img/kavita/series/12')).status, 200);
        expect(hub.fakes.callsTo(ServiceId.kavita).last.query['seriesId'], [
          '12',
        ]);
        expect(
          (await hub.get('/api/v1/img/jellyfin/..%2F..%2FSystem/Primary'))
              .status,
          400,
        );
      },
    );

    test(
      'remote images: allow-list, width rewrite for TMDB originals',
      () async {
        hub.fakes.onRemote(
          'image.tmdb.org',
          'GET',
          '/t/p/w500/abc.jpg',
          (_) => FakeResponse.bytes(_jpeg, contentType: 'image/jpeg'),
        );
        final u = Uri.encodeQueryComponent(
          'https://image.tmdb.org/t/p/original/abc.jpg',
        );
        final r = await hub.get('/api/v1/img/remote?u=$u&w=400');
        expect(r.status, 200);
        final evil = Uri.encodeQueryComponent('https://evil.example/x.jpg');
        expect((await hub.get('/api/v1/img/remote?u=$evil')).status, 400);
      },
    );

    test('Seerr avatars: same-host proxy paths, gravatar via the allow-list, others 404', () async {
      hub.fakes.on(
        ServiceId.seerr,
        'GET',
        '/api/v1/user',
        (_) => FakeResponse.json({
          'pageInfo': {'results': 4},
          'results': [
            {
              'id': 1,
              'displayName': 'Paul',
              'avatar': '/avatarproxy/4c0628aacef24bdfacd40f946ea33ee7?v=1791693617000',
              'permissions': 2,
            },
            {
              'id': 2,
              'displayName': 'G',
              'avatar': 'https://www.gravatar.com/avatar/abc?d=mm',
              'permissions': 32,
            },
            {
              'id': 3,
              'displayName': 'Evil',
              'avatar': '//evil.example/x.png',
              'permissions': 32,
            },
            {
              'id': 4,
              'displayName': 'Evil2',
              'avatar': 'http://169.254.169.254/latest',
              'permissions': 32,
            },
          ],
        }),
      );
      hub.fakes.on(
        ServiceId.seerr,
        'GET',
        '/avatarproxy/4c0628aacef24bdfacd40f946ea33ee7',
        (_) => FakeResponse.bytes(_png, contentType: 'image/png'),
      );
      hub.fakes.onRemote(
        'www.gravatar.com',
        'GET',
        '/avatar/abc',
        (_) => FakeResponse.bytes(_jpeg, contentType: 'image/jpeg'),
      );
      final own = await hub.get('/api/v1/img/seerr-avatar/1?v=1791693617000');
      expect(own.status, 200);
      expect(hub.fakes.callsTo(ServiceId.seerr).last.query['v'], [
        '1791693617000',
      ]);
      expect((await hub.get('/api/v1/img/seerr-avatar/2')).status, 200);
      expect((await hub.get('/api/v1/img/seerr-avatar/3')).status, 404);
      expect((await hub.get('/api/v1/img/seerr-avatar/4')).status, 404);
      expect((await hub.get('/api/v1/img/seerr-avatar/99')).status, 404);
      expect(
        hub.fakes.calls.where(
          (c) => c.host == 'evil.example' || c.host == '169.254.169.254',
        ),
        isEmpty,
      );
    });

    test('images need authentication', () async {
      expect(
        (await hub.get('/api/v1/img/abs/li_1', as: TestAs.anonymous)).status,
        401,
      );
    });
  });

  group('disk cache growth control', () {
    test('evicts least recently used entries above maxBytes', () async {
      final hub = TestHub();
      addTearDown(hub.close);
      await hub.ready;
      final cache = ImageDiskCache(
        dir: '${hub.dataDir.path}/c',
        maxBytes: 300,
        clock: hub.clock,
      );
      await cache.scan();
      final data = List.filled(100, 1);
      for (var i = 0; i < 5; i++) {
        expect(
          await cache.write(
            'k$i',
            Uint8List.fromList(data),
            contentType: 'image/png',
          ),
          isTrue,
        );
      }
      expect(cache.totalBytes, lessThanOrEqualTo(300));
      expect(await cache.read('k0'), isNull);
      expect(await cache.read('k4'), isNotNull);
      expect(
        await cache.write('huge', Uint8List(1000), contentType: 'image/png'),
        isFalse,
      );
      final rescanned = ImageDiskCache(
        dir: '${hub.dataDir.path}/c',
        maxBytes: 300,
        clock: hub.clock,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await rescanned.scan();
      expect(rescanned.totalBytes, cache.totalBytes);
    });

    test('sniffing', () {
      expect(sniffImageType(_jpeg), 'image/jpeg');
      expect(sniffImageType(_png), 'image/png');
      expect(sniffImageType(_webp), 'image/webp');
      expect(sniffImageType(ascii.encode('GIF89a....')), 'image/gif');
      expect(
        sniffImageType([0, 0, 0, 0x1c, ...ascii.encode('ftypavif'), 0, 0]),
        'image/avif',
      );
      expect(sniffImageType(_svg), isNull);
      expect(acceptableUpstreamImageType('image/svg+xml'), isFalse);
      expect(acceptableUpstreamImageType('text/html; charset=utf-8'), isFalse);
      expect(acceptableUpstreamImageType('image/jpeg'), isTrue);
      expect(acceptableUpstreamImageType(null), isTrue);
    });
  });
}
