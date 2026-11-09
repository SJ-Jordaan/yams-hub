import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:yams_hub_gateway/yams_hub_gateway.dart';
import 'package:yams_models/yams_models.dart';

import '../support/fake_upstreams.dart';
import '../support/fixtures.dart';

void main() {
  late FakeUpstreams fakes;
  late Upstreams up;
  late FakeClock clock;

  setUp(() {
    fakes = FakeUpstreams();
    clock = FakeClock();
    up = Upstreams(
      config: ConfigLoader.load(fakes.env()),
      client: fakes.client,
      clock: clock,
    );
  });

  group(
    'upstream paths (absolute from the service root, with the API prefix)',
    () {
      final cases = <(ServiceId, String, String, String?)>[
        // service, call path, expected wire path, auth header
        (ServiceId.sonarr, '/api/v3/series', '/api/v3/series', 'x-api-key'),
        (ServiceId.radarr, '/api/v3/movie', '/api/v3/movie', 'x-api-key'),
        (ServiceId.prowlarr, '/api/v1/indexer', '/api/v1/indexer', 'x-api-key'),
        (ServiceId.bazarr, '/api/badges', '/api/badges', 'x-api-key'),
        (
          ServiceId.seerr,
          '/api/v1/discover/trending',
          '/api/v1/discover/trending',
          'x-api-key',
        ),
        (ServiceId.jellyfin, '/Sessions', '/Sessions', 'authorization'),
        (
          ServiceId.jellystat,
          '/stats/getViewsOverTime',
          '/stats/getViewsOverTime',
          'x-api-token',
        ),
        (
          ServiceId.qbittorrent,
          '/api/v2/torrents/info',
          '/api/v2/torrents/info',
          'cookie',
        ),
        (ServiceId.gluetun, '/v1/publicip/ip', '/v1/publicip/ip', null),
        (ServiceId.docker, '/containers/json', '/v1.54/containers/json', null),
        (ServiceId.watchtower, '/v1/metrics', '/v1/metrics', 'authorization'),
        (
          ServiceId.updater,
          '/update/sonarr',
          '/update/sonarr',
          'authorization',
        ),
        (
          ServiceId.uptimeKuma,
          '/api/status-page/zenith',
          '/api/status-page/zenith',
          null,
        ),
        (
          ServiceId.audiobookshelf,
          '/api/libraries',
          '/api/libraries',
          'authorization',
        ),
        (
          ServiceId.kavita,
          '/api/Library/libraries',
          '/api/Library/libraries',
          'x-api-key',
        ),
        (ServiceId.shelfmark, '/api/stats', '/api/stats', null),
      ];
      for (final (service, path, wire, authHeader) in cases) {
        test('${service.name} $path', () async {
          fakes.on(
            service,
            'GET',
            wire,
            (_) => FakeResponse.json({'ok': true}),
          );
          final body = await up[service].getJson(path);
          expect(body, {'ok': true});
          final call = fakes.callsTo(service).last;
          expect(call.method, 'GET');
          expect(call.path, wire);
          expect(call.headers['accept'], 'application/json');
          expect(call.headers.containsKey('origin'), isFalse);
          expect(call.headers.containsKey('referer'), isFalse);
          if (authHeader != null) {
            expect(
              call.headers[authHeader],
              '***',
              reason: 'credentials sent and redacted in the recording',
            );
          } else {
            expect(call.headers.containsKey('x-api-key'), isFalse);
            expect(call.headers.containsKey('authorization'), isFalse);
          }
        });
      }

      test('auth header values', () async {
        final seen = <ServiceId, Map<String, String>>{};
        for (final s in [
          ServiceId.sonarr,
          ServiceId.jellyfin,
          ServiceId.jellystat,
          ServiceId.watchtower,
          ServiceId.kavita,
        ]) {
          fakes.on(s, 'GET', '/x', (r) {
            seen[s] = r.headers;
            return FakeResponse.json(null);
          });
          await up[s].getJson('/x');
        }
        expect(
          seen[ServiceId.sonarr]!['x-api-key'],
          fakeSecret(ServiceId.sonarr),
        );
        expect(
          seen[ServiceId.jellyfin]!['authorization'],
          'MediaBrowser Client="YAMS Hub", Device="yams-hub", DeviceId="yams-hub-gateway", '
          'Version="$hubVersion", Token="${fakeSecret(ServiceId.jellyfin)}"',
        );
        expect(
          seen[ServiceId.jellystat]!['x-api-token'],
          fakeSecret(ServiceId.jellystat),
        );
        expect(
          seen[ServiceId.watchtower]!['authorization'],
          'Bearer ${fakeSecret(ServiceId.watchtower)}',
        );
        expect(
          seen[ServiceId.kavita]!['x-api-key'],
          fakeSecret(ServiceId.kavita),
        );
      });

      test(
        'query maps: repeated keys, numbers, booleans; rawQuery passes through',
        () async {
          fakes.on(
            ServiceId.sonarr,
            'GET',
            '/api/v3/history',
            (_) => FakeResponse.json([]),
          );
          await up.sonarr.getJson(
            '/api/v3/history',
            query: {
              'eventType': [1, 3],
              'page': 2,
              'includeSeries': true,
              'skip': null,
            },
          );
          final q = fakes.callsTo(ServiceId.sonarr).last.query;
          expect(q['eventType'], ['1', '3']);
          expect(q['page'], ['2']);
          expect(q['includeSeries'], ['true']);
          expect(q.containsKey('skip'), isFalse);

          fakes.on(
            ServiceId.seerr,
            'GET',
            '/api/v1/search',
            (r) => FakeResponse.json({'raw': r.uri.query}),
          );
          final r = await up.seerr.getJson(
            '/api/v1/search',
            rawQuery: 'query=grey%27s%20anatomy&page=1',
          );
          expect((r! as Map)['raw'], 'query=grey%27s%20anatomy&page=1');
        },
      );

      test('path segments are encoded, dot segments and queries in paths are refused', () {
        final uri = up.sonarr.buildUri('/api/v3/series/a b');
        expect(uri.path, '/api/v3/series/a%20b');
        expect(() => up.sonarr.buildUri('/api/v3/../x'), throwsArgumentError);
        expect(
          () => up.sonarr.buildUri('/api/v3/series?x=1'),
          throwsArgumentError,
        );
      });
    },
  );

  group('errors', () {
    test(
      'Servarr validation arrays become 422 validation_failed with fields',
      () async {
        fakes.onFixture(
          ServiceId.sonarr,
          'POST',
          '/api/v3/series',
          'arr/sonarr_error_400_validation.json',
          status: 400,
        );
        try {
          await up.sonarr.sendJson('POST', '/api/v3/series', body: {});
          fail('expected an exception');
        } on UpstreamException catch (e) {
          expect(e.status, 400);
          expect(e.validation, isNotEmpty);
          final api = e.toApiException();
          expect(api.status, 422);
          expect(api.code, 'validation_failed');
          expect(api.fields, isNotEmpty);
        }
      },
    );

    test('Allowed Hosts: "400 Invalid Hostname" from an *arr names the cause (issue #2)', () async {
      FakeResponse invalidHostname(FakeRequest _) => FakeResponse.bytes(
        fixtureBytes('arr/servarr_error_400_invalid_hostname.html'),
        status: 400,
        contentType: 'text/html',
      );
      for (final (svc, path, host) in [
        (ServiceId.sonarr, '/api/v3/calendar', 'sonarr.test'),
        (ServiceId.radarr, '/api/v3/movie', 'radarr.test'),
        (ServiceId.prowlarr, '/api/v1/indexer', 'prowlarr.test'),
      ]) {
        fakes.on(svc, 'GET', path, invalidHostname);
        try {
          await up[svc].getJson(path);
          fail('expected an exception');
        } on UpstreamHostRejected catch (e) {
          expect(e.status, 400);
          expect(e.host, host);
          final api = e.toApiException(resourceNotFound: false);
          expect(api.status, 502);
          expect(api.code, ApiErrorCode.upstreamHostRejected);
          expect(api.service, svc);
          expect(api.details, {'upstreamStatus': 400, 'host': host});
          final name = svc.displayName;
          expect(
            api.message,
            "$name rejects the hub's hostname '$host'. In $name → Settings "
            '→ General → Allowed Hosts, add $host (or clear the list), then '
            'restart $name.',
          );
        }
      }
      // Raw responses say so too (the health probe reads them).
      final r = await up.sonarr.send('GET', '/api/v3/calendar');
      expect(r.isHostRejected, isTrue);
      expect(r.host, 'sonarr.test');

      // Other 400s and other services keep the generic mapping.
      fakes.on(
        ServiceId.sonarr,
        'GET',
        '/api/v3/episode',
        (_) => FakeResponse.fixture(
          'arr/sonarr_error_400_badrequest.json',
          status: 400,
        ),
      );
      await expectLater(
        up.sonarr.getJson('/api/v3/episode'),
        throwsA(
          isA<UpstreamException>()
              .having((e) => e is UpstreamHostRejected, 'host', isFalse)
              .having(
                (e) => e.toApiException().code,
                'code',
                ApiErrorCode.upstreamError,
              ),
        ),
      );
      fakes.on(ServiceId.bazarr, 'GET', '/api/badges', invalidHostname);
      await expectLater(
        up.bazarr.getJson('/api/badges'),
        throwsA(isNot(isA<UpstreamHostRejected>())),
      );
    });

    test('Allowed Hosts matching follows the *arrs', () {
      // Checked against Sonarr 4 / Radarr 6 / Prowlarr 2 (tool/sandbox).
      final cases = <(String, String, bool)>[
        ('', 'sonarr', true),
        ('  ', 'sonarr', true),
        ('localhost', 'sonarr', false),
        ('localhost', 'localhost', true),
        ('foo', '127.0.0.1', true),
        ('foo', '[::1]', true),
        ('localhost, sonarr', 'sonarr', true),
        ('foo;Sonarr', 'sonarr', true),
        ('SONARR', 'sonarr', true),
        (' foo , bar ', 'bar', true),
        ('*.example.com', 'a.example.com', true),
        ('*.example.com', 'example.com', false),
        ('*', 'sonarr', true),
        ('10.0.0.1', '172.17.0.2', false),
        ('172.17.0.2', '172.17.0.2', true),
        ('sonarr.lan', 'sonarr', false),
      ];
      for (final (list, host, accepted) in cases) {
        expect(
          allowedHostsAccepts(list, host),
          accepted,
          reason: '"$list" vs $host',
        );
      }
      expect(isInvalidHostnameResponse(400, utf8.encode('{}')), isFalse);
      expect(
        isInvalidHostnameResponse(
          403,
          fixtureBytes('arr/servarr_error_400_invalid_hostname.html'),
        ),
        isFalse,
      );
    });

    test('mapping table', () async {
      Future<ApiException> mapped(int status, Object body) async {
        fakes.on(
          ServiceId.radarr,
          'GET',
          '/api/v3/movie/1',
          (_) => FakeResponse.json(body, status: status),
        );
        try {
          await up.radarr.getJson('/api/v3/movie/1');
        } on UpstreamException catch (e) {
          return e.toApiException();
        }
        throw StateError('no error');
      }

      expect(
        (await mapped(401, {'message': 'nope'})).code,
        'upstream_auth_failed',
      );
      expect((await mapped(403, {'message': 'nope'})).status, 502);
      expect((await mapped(404, {'message': 'NotFound'})).code, 'not_found');
      final other4xx = await mapped(409, {'message': 'conflict'});
      expect(other4xx.code, 'upstream_error');
      expect(other4xx.details, {'upstreamStatus': 409});
      expect((await mapped(500, {'message': 'boom'})).status, 502);
      final long = await mapped(500, {
        'message': 'x' * 400,
        'description': 'stack...',
      });
      expect(long.message, isNot(contains('xxxxxxxxxx')));
    });

    test('messages are redacted and stack traces dropped', () async {
      fakes.on(
        ServiceId.prowlarr,
        'GET',
        '/api/v1/indexer/1',
        (_) => FakeResponse.json({
          'message': 'failed http://x/download?apikey=SECRETKEY123',
        }, status: 500),
      );
      try {
        await up.prowlarr.getJson('/api/v1/indexer/1');
      } on UpstreamException catch (e) {
        expect(e.message, isNot(contains('SECRETKEY123')));
        expect(e.toApiException().message, isNot(contains('SECRETKEY123')));
      }
      final extracted = extractUpstreamError(
        500,
        utf8.encode(
          '{"message":"Error\\n   at Foo.Bar() in /src/x.cs:line 12"}',
        ),
      );
      expect(extracted.message, isNull);
      expect(
        extractUpstreamError(
          403,
          utf8.encode('<html><body>403 Forbidden</body></html>'),
        ).message,
        'denied by socket proxy',
      );
      expect(
        extractUpstreamError(
          403,
          utf8.encode('{"status":403,"error":"You do not have permission"}'),
        ).message,
        'You do not have permission',
      );
      expect(
        extractUpstreamError(
          503,
          utf8.encode('Days needs to be a number.'),
        ).message,
        'Days needs to be a number.',
      );
    });

    test(
      'transport exceptions never carry the URI or their own text',
      () async {
        final client = MockClient(
          (_) async => throw http.ClientException(
            'Connection refused',
            Uri.parse('http://sonarr:8989/api/v3/series?apikey=LEAKED'),
          ),
        );
        final broken = Upstreams(
          config: ConfigLoader.load(fakes.env()),
          client: client,
          clock: clock,
        );
        try {
          await broken.sonarr.getJson(
            '/api/v3/series',
            query: {'apikey': 'LEAKED'},
          );
          fail('expected an exception');
        } on UpstreamUnavailable catch (e) {
          expect(e.toString(), isNot(contains('LEAKED')));
          expect(e.toString(), isNot(contains('refused')));
          expect(e.path, '/api/v3/series');
          expect(e.toApiException().code, 'upstream_unavailable');
        }
        final sock = MockClient(
          (_) async =>
              throw const SocketException('Failed host lookup: sonarr'),
        );
        final s = Upstreams(
          config: ConfigLoader.load(fakes.env()),
          client: sock,
          clock: clock,
        );
        expect(
          () => s.sonarr.getJson('/x'),
          throwsA(isA<UpstreamUnavailable>()),
        );
      },
    );

    test('timeouts become UpstreamTimeout (504)', () async {
      fakes.on(ServiceId.sonarr, 'GET', '/slow', (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return FakeResponse.json({});
      });
      try {
        await up.sonarr.getJson(
          '/slow',
          timeout: const Duration(milliseconds: 50),
        );
        fail('expected a timeout');
      } on UpstreamTimeout catch (e) {
        expect(e.toApiException().status, 504);
      }
    });

    test('maxBytes aborts the stream', () async {
      var cancelled = false;
      final controller = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      fakes.on(ServiceId.sonarr, 'GET', '/big', (_) {
        Timer.run(() async {
          for (var i = 0; i < 100 && !cancelled; i++) {
            controller.add(List.filled(1024, 1));
            await Future<void>.delayed(Duration.zero);
          }
        });
        return FakeResponse.chunked(controller.stream);
      });
      try {
        await up.sonarr.send('GET', '/big', maxBytes: 4096);
        fail('expected an exception');
      } on UpstreamBadResponse catch (e) {
        expect(e.reason, 'response too large');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(cancelled, isTrue);
    });

    test(
      'invalid JSON is upstream_bad_response; not configured is 503',
      () async {
        fakes.on(
          ServiceId.bazarr,
          'GET',
          '/api/badges',
          (_) => FakeResponse.text('not json'),
        );
        expect(
          () => up.bazarr.getJson('/api/badges'),
          throwsA(isA<UpstreamBadResponse>()),
        );
        final unconf = Upstreams(
          config: ConfigLoader.load({}),
          client: fakes.client,
          clock: clock,
        );
        try {
          await unconf.sonarr.getJson('/api/v3/series');
        } on UpstreamNotConfigured catch (e) {
          expect(e.toApiException().code, 'service_not_configured');
        }
      },
    );

    test('multipart bodies', () async {
      late FakeRequest seen;
      fakes.on(ServiceId.qbittorrent, 'POST', '/api/v2/torrents/add', (r) {
        seen = r;
        return FakeResponse.text('Ok.');
      });
      final r = await up.qbittorrent.send(
        'POST',
        '/api/v2/torrents/add',
        multipart: [
          const MultipartPart.field('category', 'manual'),
          MultipartPart.file(
            'torrents',
            'x.torrent',
            utf8.encode('d8:announce'),
            'application/x-bittorrent',
          ),
        ],
      );
      expect(r.status, 200);
      expect(
        seen.headers['content-type'],
        startsWith('multipart/form-data; boundary='),
      );
      expect(seen.body, contains('name="category"\r\n\r\nmanual'));
      expect(seen.body, contains('filename="x.torrent"'));
    });
  });

  group('QbitSession', () {
    test('logs in once, parses the cookie name, re-logs in on 403 and retries once', () async {
      var logins = 0;
      fakes.on(ServiceId.qbittorrent, 'POST', '/api/v2/auth/login', (r) {
        logins++;
        expect(r.form, {'username': 'qbit-user', 'password': 'qbit-pass'});
        expect(r.headers.containsKey('origin'), isFalse);
        return FakeResponse(
          204,
          headers: {'set-cookie': 'QBT_SID_9999=sid$logins; HttpOnly; path=/'},
        );
      });
      var calls = 0;
      fakes.on(ServiceId.qbittorrent, 'GET', '/api/v2/app/version', (r) {
        calls++;
        if (r.headers['cookie'] == 'QBT_SID_9999=sid1' && calls == 2) {
          return FakeResponse.text('Forbidden', status: 403);
        }
        return FakeResponse.text('v5.3.0');
      });
      final results = await Future.wait([
        up.qbittorrent.send('GET', '/api/v2/app/version'),
        up.qbittorrent.send('GET', '/api/v2/app/version'),
      ]);
      expect(results.map((r) => r.status), everyElement(200));
      expect(up.qbitSession.sessionGeneration, greaterThanOrEqualTo(1));
      final r = await up.qbittorrent.send('GET', '/api/v2/app/version');
      expect(r.text(), 'v5.3.0');
      expect(logins, lessThanOrEqualTo(2));
    });

    test('a 401 login backs off for 10 minutes and fails fast', () async {
      var logins = 0;
      fakes.on(ServiceId.qbittorrent, 'POST', '/api/v2/auth/login', (_) {
        logins++;
        return FakeResponse.text('Unauthorized', status: 401);
      });
      for (var i = 0; i < 3; i++) {
        try {
          await up.qbittorrent.getJson('/api/v2/torrents/info');
          fail('expected an exception');
        } on UpstreamCredentialsRejected catch (e) {
          expect(e.toApiException().code, 'upstream_auth_failed');
        }
      }
      expect(logins, 1);
      expect(up.qbitSession.credentialsRejected, isTrue);
      clock.advance(const Duration(minutes: 11));
      expect(up.qbitSession.credentialsRejected, isFalse);
      await expectLater(
        up.qbittorrent.getJson('/api/v2/torrents/info'),
        throwsA(isA<UpstreamCredentialsRejected>()),
      );
      expect(logins, 2);
    });

    test('cookie parsing', () {
      expect(
        parseQbitCookie('QBT_SID_8081=abc; HttpOnly; SameSite=Lax; path=/'),
        'QBT_SID_8081=abc',
      );
      expect(
        parseQbitCookie('other=1; path=/, QBT_SID_8080=xyz; HttpOnly'),
        'QBT_SID_8080=xyz',
      );
      expect(parseQbitCookie('SID=legacy; path=/'), 'SID=legacy');
      expect(parseQbitCookie('nothing=here'), isNull);
    });
  });

  group('RemoteFetcher', () {
    late RemoteFetcher fetcher;
    setUp(() => fetcher = fakes.remoteFetcher());

    test('a redirect to http://socket-proxy:2375 is refused', () async {
      fakes.onRemote(
        'tracker.example.org',
        'GET',
        '/dl',
        (_) => FakeResponse(
          302,
          headers: {'location': 'http://socket-proxy:2375/containers/json'},
        ),
      );
      await expectLater(
        fetcher.fetch(
          Uri.parse('https://tracker.example.org/dl'),
          allowHttp: true,
        ),
        throwsA(
          isA<RemoteFetchException>().having(
            (e) => e.failure,
            'failure',
            RemoteFailure.notAllowed,
          ),
        ),
      );
      expect(fakes.calls.where((c) => c.host == 'socket-proxy'), isEmpty);
    });

    test(
      'private addresses, http and single-label hosts are refused',
      () async {
        fakes.dns['internal.example.org'] = [InternetAddress('172.28.0.40')];
        for (final url in [
          'https://internal.example.org/x',
          'https://192.168.10.183/x',
          'https://127.0.0.1/x',
          'https://[::1]/x',
          'https://100.100.1.1/x',
          'https://169.254.169.254/latest',
          'http://public.example.org/x',
          'https://sonarr/x',
          'https://user:pw@public.example.org/x',
        ]) {
          await expectLater(
            fetcher.fetch(Uri.parse(url)),
            throwsA(
              isA<RemoteFetchException>().having(
                (e) => e.failure,
                'failure',
                RemoteFailure.notAllowed,
              ),
            ),
            reason: url,
          );
        }
        expect(fakes.calls, isEmpty);
      },
    );

    test(
      'follows at most maxRedirects, returns magnet redirects, caps the body',
      () async {
        fakes.onRemote(
          'a.example.org',
          'GET',
          '/1',
          (_) => FakeResponse(301, headers: {'location': '/2'}),
        );
        fakes.onRemote(
          'a.example.org',
          'GET',
          '/2',
          (_) => FakeResponse(
            302,
            headers: {'location': 'https://b.example.org/3'},
          ),
        );
        fakes.onRemote(
          'b.example.org',
          'GET',
          '/3',
          (_) => FakeResponse.bytes([
            1,
            2,
            3,
          ], contentType: 'application/x-bittorrent'),
        );
        final ok = await fetcher.fetch(Uri.parse('https://a.example.org/1'));
        expect(
          ok,
          isA<RemoteBody>().having((b) => b.bytes, 'bytes', [1, 2, 3]),
        );
        await expectLater(
          fetcher.fetch(Uri.parse('https://a.example.org/1'), maxRedirects: 1),
          throwsA(
            isA<RemoteFetchException>().having(
              (e) => e.failure,
              'failure',
              RemoteFailure.tooManyRedirects,
            ),
          ),
        );
        fakes.onRemote(
          'm.example.org',
          'GET',
          '/m',
          (_) => FakeResponse(
            302,
            headers: {'location': 'magnet:?xt=urn:btih:abc'},
          ),
        );
        final magnet = await fetcher.fetch(
          Uri.parse('https://m.example.org/m'),
        );
        expect(magnet, isA<RemoteMagnet>());
        fakes.onRemote(
          'big.example.org',
          'GET',
          '/b',
          (_) => FakeResponse.bytes(List.filled(5000, 0)),
        );
        await expectLater(
          fetcher.fetch(Uri.parse('https://big.example.org/b'), maxBytes: 1000),
          throwsA(
            isA<RemoteFetchException>().having(
              (e) => e.failure,
              'failure',
              RemoteFailure.tooLarge,
            ),
          ),
        );
      },
    );

    test('isPublicAddress', () {
      for (final ip in [
        '10.0.0.1',
        '172.16.0.1',
        '172.31.255.255',
        '192.168.1.1',
        '100.64.0.1',
        '127.0.0.1',
        '0.0.0.0',
        '169.254.1.1',
        '::1',
        'fe80::1',
        'fd00::1',
        '::ffff:192.168.1.1',
        '224.0.0.1',
      ]) {
        expect(isPublicAddress(InternetAddress(ip)), isFalse, reason: ip);
      }
      for (final ip in [
        '93.184.216.34',
        '8.8.8.8',
        '2606:4700::1111',
        '172.32.0.1',
      ]) {
        expect(isPublicAddress(InternetAddress(ip)), isTrue, reason: ip);
      }
    });
  });
}
