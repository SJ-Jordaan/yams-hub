import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/core/static/static_handler.dart';

import '../support/test_hub.dart';

void main() {
  group('pipeline', () {
    late TestHub hub;
    setUpAll(
      () => hub = TestHub(
        env: {
          'YAMS_HUB_CORS_ORIGINS': 'http://localhost:5173',
          'YAMS_HUB_ALLOWED_HOSTS': 'hub.lan',
        },
      ),
    );
    tearDownAll(() => hub.close());

    test('request ids are reused when valid, generated otherwise, and in error bodies', () async {
      final a = await hub.get(
        '/api/v1/nope',
        headers: {'x-request-id': 'abcdef12-3456'},
      );
      expect(a.headers['x-request-id'], 'abcdef12-3456');
      expect(readMap(a.map['error'])!['requestId'], 'abcdef12-3456');
      final b = await hub.get(
        '/api/v1/nope',
        headers: {'x-request-id': 'bad id!'},
      );
      expect(b.headers['x-request-id'], matches(RegExp(r'^[0-9a-f]{16}$')));
    });

    test('host check: allowed hosts pass, others get 421', () async {
      for (final host in [
        '192.168.10.183:8090',
        '100.101.102.103:8090',
        'zenith.tail1234.ts.net:8090',
        'localhost:8090',
        '127.0.0.1',
        'hub.lan:8090',
        '[::1]:8090',
      ]) {
        final r = await hub.request('GET', '/api/v1/server', host: host);
        expect(r.status, 200, reason: host);
      }
      for (final host in [
        'attacker.example',
        'attacker.example:8090',
        '8.8.8.8',
        'yams-hub:8080',
      ]) {
        final r = await hub.request('GET', '/api/v1/server', host: host);
        expect(r.status, 421, reason: host);
        expect(r.errorCode, 'bad_request');
        expect(r.headers['cross-origin-resource-policy'], 'same-origin');
        expect(r.headers['x-content-type-options'], 'nosniff');
        expect(r.headers['cache-control'], 'no-store');
        expect(r.headers['x-request-id'], isNotNull);
      }
    });

    test('security headers on API responses', () async {
      final r = await hub.get('/api/v1/server');
      expect(r.headers['x-content-type-options'], 'nosniff');
      expect(r.headers['referrer-policy'], 'no-referrer');
      expect(r.headers['x-frame-options'], 'DENY');
      expect(r.headers['cross-origin-resource-policy'], 'same-origin');
      expect(r.headers['cache-control'], 'no-store');
      expect(
        r.headers['content-security-policy'],
        "default-src 'none'; frame-ancestors 'none'",
      );
      expect(r.headers['content-type'], 'application/json; charset=utf-8');
    });

    test(
      'GET JSON gets a weak ETag and 304; large bodies are gzipped',
      () async {
        final r = await hub.get('/api/v1/server');
        final etag = r.headers['etag']!;
        expect(etag, startsWith('W/"'));
        final again = await hub.get(
          '/api/v1/server',
          headers: {'if-none-match': etag},
        );
        expect(again.status, 304);
        expect(again.bodyBytes, isEmpty);
        final gz = await hub.get(
          '/api/v1/server',
          headers: {'accept-encoding': 'gzip'},
        );
        expect(r.bodyBytes.length, greaterThan(1024));
        expect(gz.headers['content-encoding'], 'gzip');
        expect(jsonDecode(utf8.decode(gzip.decode(gz.bodyBytes))), r.json);
      },
    );

    test(
      'CORS: allowed origin preflight, unknown origin gets nothing',
      () async {
        final ok = await hub.request(
          'OPTIONS',
          '/api/v1/auth/me',
          as: TestAs.anonymous,
          headers: {
            'origin': 'http://localhost:5173',
            'access-control-request-method': 'GET',
          },
        );
        expect(ok.status, 204);
        expect(
          ok.headers['access-control-allow-origin'],
          'http://localhost:5173',
        );
        expect(
          ok.headers['access-control-allow-methods'],
          'GET, POST, PUT, PATCH, DELETE',
        );
        expect(
          ok.headers['access-control-allow-headers'],
          'Authorization, Content-Type, X-YAMS-Client, X-Request-Id',
        );
        expect(ok.headers['access-control-max-age'], '600');
        expect(
          ok.headers.containsKey('access-control-allow-credentials'),
          isFalse,
        );
        final evil = await hub.request(
          'OPTIONS',
          '/api/v1/auth/me',
          as: TestAs.anonymous,
          headers: {'origin': 'http://evil.example'},
        );
        expect(
          evil.headers.containsKey('access-control-allow-origin'),
          isFalse,
        );
        final get = await hub.get(
          '/api/v1/server',
          headers: {'origin': 'http://localhost:5173'},
        );
        expect(
          get.headers['access-control-allow-origin'],
          'http://localhost:5173',
        );
      },
    );

    test('errors never leak exception text', () async {
      final r = await hub.post(
        '/api/v1/auth/login',
        body: '{"username": ',
        as: TestAs.anonymous,
      );
      expect(r.status, 400);
      expect(r.body, isNot(contains('FormatException')));
      expect(r.body, isNot(contains('#0')));
    });
  });

  group('/server and /health', () {
    late TestHub hub;
    setUp(() => hub = TestHub(unconfigured: {ServiceId.kavita}));
    tearDown(() => hub.close());

    test(
      '/server reports services, policy, features and Seerr flags',
      () async {
        hub.fakes.onFixture(
          ServiceId.jellyfin,
          'GET',
          '/System/Info/Public',
          'seerr/jellyfin_system_info_public.json',
        );
        hub.fakes.onFixture(
          ServiceId.seerr,
          'GET',
          '/api/v1/settings/public',
          'seerr/seerr_settings_public.json',
        );
        final r = await hub.get('/api/v1/server', as: TestAs.member);
        expect(r.status, 200);
        final s = ServerConfig.fromJson(r.map);
        expect(s.version, hubVersion);
        expect(s.instanceId, hub.hub.instanceId);
        expect(s.jellyfinServerId, '79315eab3c4c401f8391d5c26210b6d7');
        expect(s.isConfigured(ServiceId.sonarr), isTrue);
        expect(s.isConfigured(ServiceId.kavita), isFalse);
        expect(s.externalApps[ExternalApp.jellystat]!.port, 3002);
        expect(s.policy.lockedContainers, contains('socket-proxy-hub'));
        expect(
          s.features.containerActions,
          isFalse,
          reason: 'self-test not run',
        );
        expect(s.seerr.partialRequestsEnabled, isTrue);
        expect(s.seerr.fourKEnabled, isFalse);
      },
    );

    test('probes: capability flags and the docker proxy self-test', () async {
      hub.fakes.on(
        ServiceId.docker,
        '*',
        RegExp(
          r'^/v1\.54/(containers/create|images/create|containers/yams-hub-selftest-nonexistent)$',
        ),
        (_) => FakeResponse.text(
          '<html><body><h1>403 Forbidden</h1></body></html>',
          status: 403,
          contentType: 'text/html',
        ),
      );
      hub.fakes.on(
        ServiceId.docker,
        'GET',
        '/v1.54/containers/yams-hub/logs',
        (_) => FakeResponse.bytes([1, 0, 0, 0, 0, 0, 0, 2, 104, 105]),
      );
      hub.fakes.on(
        ServiceId.watchtower,
        'GET',
        '/v1/containers/details',
        (_) => FakeResponse.json([]),
      );
      hub.fakes.on(
        ServiceId.updater,
        'GET',
        '/healthz',
        (_) => FakeResponse.json({'status': 'ok', 'version': '1.0.0'}),
      );
      await hub.ready;
      await hub.hub.health.refreshProbes();
      expect(
        hub.fakes.callsTo(ServiceId.watchtower).map((c) => c.path),
        isNot(contains('/v1/check')),
      );
      final s = ServerConfig.fromJson((await hub.get('/api/v1/server')).map);
      expect(s.features.containerActions, isTrue);
      expect(s.features.containerLogs, isTrue);
      expect(s.features.watchtowerCheck, isTrue);
      expect(s.features.updater, isTrue);

      // A proxy that lets a write through disables container actions.
      hub.fakes.on(
        ServiceId.docker,
        'POST',
        '/v1.54/containers/create',
        (_) => FakeResponse.json({'message': 'invalid body'}, status: 400),
      );
      await hub.hub.health.refreshProbes();
      expect(hub.hub.health.dockerProxy.actionsAllowed, isFalse);
      expect(
        () => hub.hub.health.dockerProxy.ensureActionsAllowed(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'service_not_configured')
              .having((e) => e.message, 'message', contains('not restricted')),
        ),
      );
      hub.fakes.on(
        ServiceId.docker,
        'GET',
        '/v1.54/_ping',
        (_) => FakeResponse.text('OK'),
      );
      hub.fakes.onFixture(
        ServiceId.docker,
        'GET',
        '/v1.54/version',
        'system/docker_version.json',
      );
      final health = HealthReport.fromJson(
        (await hub.get('/api/v1/health')).map,
      );
      final docker = health.of(ServiceId.docker)!;
      expect(docker.status, ServiceHealthStatus.degraded);
      expect(docker.version, '29.4.3');
      expect(docker.message, contains('container actions disabled'));
    });

    test('an unreachable Docker proxy is self-tested again soon', () async {
      await hub.ready;
      final config = hub.config;
      final caches = CacheFactory(hub.clock);
      final health = HealthService(
        config: config,
        upstreams: hub.hub.upstreams,
        clock: hub.clock,
        caches: caches,
        dockerProxy: ProxySelfTest(hub.hub.upstreams.docker, hub.clock),
        selfTestRetryInterval: const Duration(milliseconds: 20),
      );
      addTearDown(health.stop);
      var reachable = false;
      hub.fakes.on(ServiceId.docker, '*', RegExp(r'^/v1\.54/'), (_) {
        if (!reachable) {
          throw http.ClientException('connection refused');
        }
        return FakeResponse.text('denied', status: 403);
      });
      await health.start();
      expect(health.dockerProxy.state, ProxySelfTestState.unreachable);
      expect(health.dockerProxy.actionsAllowed, isFalse);
      reachable = true;
      for (var i = 0; i < 100 && !health.dockerProxy.actionsAllowed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(health.dockerProxy.state, ProxySelfTestState.passed);
      expect(health.dockerProxy.actionsAllowed, isTrue);
    });

    test('/health probes every service; statuses and versions', () async {
      final f = hub.fakes;
      f.on(
        ServiceId.sonarr,
        'GET',
        '/ping',
        (_) => FakeResponse.json({'status': 'OK'}),
      );
      f.onFixture(
        ServiceId.sonarr,
        'GET',
        '/api/v3/system/status',
        'arr/sonarr_system_status.json',
      );
      f.on(
        ServiceId.radarr,
        'GET',
        '/ping',
        (_) => FakeResponse.json({'status': 'OK'}),
      );
      f.on(
        ServiceId.radarr,
        'GET',
        '/api/v3/system/status',
        (_) => FakeResponse.json({'message': 'Unauthorized'}, status: 401),
      );
      f.on(
        ServiceId.bazarr,
        'GET',
        '/api/system/ping',
        (_) => FakeResponse.json({'status': 'OK'}),
      );
      f.onFixture(
        ServiceId.bazarr,
        'GET',
        '/api/system/status',
        'downloads/bazarr_system_status.json',
      );
      f.onFixture(
        ServiceId.seerr,
        'GET',
        '/api/v1/status',
        'seerr/seerr_status.json',
      );
      f.onFixture(
        ServiceId.jellyfin,
        'GET',
        '/System/Info/Public',
        'seerr/jellyfin_system_info_public.json',
      );
      f.onFixture(
        ServiceId.jellystat,
        'GET',
        '/auth/isConfigured',
        'seerr/jellystat_auth_isConfigured.json',
      );
      f.on(
        ServiceId.qbittorrent,
        'GET',
        '/api/v2/app/version',
        (_) => FakeResponse.text('v5.3.0'),
      );
      f.onFixture(
        ServiceId.gluetun,
        'GET',
        '/v1/openvpn/portforwarded',
        'downloads/gluetun_openvpn_portforwarded.json',
      );
      f.on(
        ServiceId.watchtower,
        'GET',
        '/v1/metrics',
        (_) =>
            FakeResponse.text(fixtureText('system/watchtower_v1_metrics.txt')),
      );
      f.onFixture(
        ServiceId.audiobookshelf,
        'GET',
        '/status',
        'system/audiobookshelf_status.json',
      );
      f.on(
        ServiceId.shelfmark,
        'GET',
        '/api/health',
        (_) => FakeResponse.json({
          'status': 'error',
          'coordinator': 'stopped',
        }, status: 503),
      );
      f.on(
        ServiceId.uptimeKuma,
        'GET',
        '/api/status-page/zenith',
        (_) => FakeResponse.fixture('system/uptimekuma_status_page.json'),
      );

      final r = await hub.get('/api/v1/health', as: TestAs.member);
      expect(r.status, 200);
      final h = HealthReport.fromJson(r.map);
      expect(h.of(ServiceId.sonarr)!.status, ServiceHealthStatus.up);
      expect(h.of(ServiceId.sonarr)!.version, '4.0.20.3014');
      expect(h.of(ServiceId.radarr)!.status, ServiceHealthStatus.degraded);
      expect(h.of(ServiceId.bazarr)!.version, '1.6.2');
      expect(h.of(ServiceId.seerr)!.version, '3.5.1');
      expect(h.of(ServiceId.jellyfin)!.version, '12.4.0');
      expect(h.of(ServiceId.jellystat)!.version, '1.1.12');
      expect(h.of(ServiceId.qbittorrent)!.version, '5.3.0');
      expect(h.of(ServiceId.gluetun)!.status, ServiceHealthStatus.up);
      expect(h.of(ServiceId.watchtower)!.status, ServiceHealthStatus.up);
      expect(h.of(ServiceId.audiobookshelf)!.version, '2.37.2');
      expect(h.of(ServiceId.shelfmark)!.status, ServiceHealthStatus.degraded);
      expect(h.of(ServiceId.shelfmark)!.message, contains('coordinator'));
      expect(h.of(ServiceId.kavita)!.status, ServiceHealthStatus.disabled);
      expect(h.of(ServiceId.prowlarr)!.status, ServiceHealthStatus.down);
      expect(h.of(ServiceId.host)!.status, ServiceHealthStatus.up);
      expect(h.overall, ServiceHealthStatus.degraded);
      expect(
        h.services.map((s) => s.id),
        containsAll([ServiceId.shelfmark, ServiceId.updater, ServiceId.docker]),
      );
      expect(hub.fakes.callsTo(ServiceId.shelfmark).map((c) => c.path), [
        '/api/health',
      ]);

      // Cached for 30 s.
      final calls = hub.fakes.calls.length;
      await hub.get('/api/v1/health');
      expect(hub.fakes.calls.length, calls);
      expect(
        hub.ctx.health.of(ServiceId.sonarr)!.status,
        ServiceHealthStatus.up,
      );
    });
  });

  group('static web', () {
    late Directory web;
    late Handler handler;
    setUpAll(() async {
      web = await Directory.systemTemp.createTemp('yams-hub-web-');
      File(p.join(web.path, 'index.html'))
          .writeAsStringSync('<!doctype html><title>hub</title>');
      File(p.join(web.path, 'main.dart.js'))
          .writeAsStringSync('console.log(1);' * 200);
      Directory(p.join(web.path, 'assets')).createSync();
      File(p.join(web.path, 'assets', 'AssetManifest.json'))
          .writeAsStringSync('{}');
      File(p.join(web.parent.path, 'secret.txt'))
          .writeAsStringSync('top secret');
      handler = createWebHandler(web.path);
    });
    tearDownAll(() async {
      await web.delete(recursive: true);
      final s = File(p.join(web.parent.path, 'secret.txt'));
      if (s.existsSync()) s.deleteSync();
    });

    Future<Response> get(
      String path, {
      Map<String, String> headers = const {},
    }) async => handler(
      Request(
        'GET',
        Uri.parse('http://192.168.10.183:8090$path'),
        headers: headers,
      ),
    );

    test('serves files with no-cache and an ETag; 304 on match', () async {
      final r = await get('/main.dart.js');
      expect(r.statusCode, 200);
      expect(r.headers['cache-control'], 'no-cache');
      final etag = r.headers['etag']!;
      final again = await get(
        '/main.dart.js',
        headers: {'if-none-match': etag},
      );
      expect(again.statusCode, 304);
    });

    test('gzips compressible files', () async {
      final r = await get(
        '/main.dart.js',
        headers: {'accept-encoding': 'gzip'},
      );
      expect(r.headers['content-encoding'], 'gzip');
      final body = await r.read().expand((c) => c).toList();
      expect(utf8.decode(gzip.decode(body)), startsWith('console.log(1);'));
    });

    test(
      'SPA fallback for extension-less paths, 404 for missing files',
      () async {
        final r = await get('/library/tv/54');
        expect(r.statusCode, 200);
        expect(await r.readAsString(), contains('<title>hub</title>'));
        expect((await get('/missing.js')).statusCode, 404);
      },
    );

    test('path traversal is refused', () async {
      for (final path in [
        '/..%2f..%2fetc/passwd',
        '/..%2fsecret.txt',
        '/assets/..%2F..%2Fsecret.txt',
        '/%2e%2e%2fsecret.txt',
        '/assets%5c..%5c..%5csecret.txt',
      ]) {
        final r = await get(path);
        expect(r.statusCode, 404, reason: path);
        expect(await r.readAsString(), isNot(contains('top secret')));
      }
      // Dot segments are normalised away by the URI parser before they reach
      // the handler; the result never leaves the web root.
      final normalised = await get('/%2e%2e/%2e%2e/secret.txt');
      expect(await normalised.readAsString(), isNot(contains('top secret')));
      expect(isTraversalPath('/%2e%2e/'), isTrue);
      expect(isTraversalPath('/assets/main.js'), isFalse);
    });

    test('HTML gets the web CSP through the pipeline; no web build gives a plain page', () async {
      final hub = TestHub(env: {'YAMS_HUB_WEB_DIR': web.path});
      addTearDown(hub.close);
      final r = await hub.get('/', as: TestAs.anonymous);
      expect(r.status, 200);
      expect(
        r.headers['content-security-policy'],
        contains("script-src 'self' 'wasm-unsafe-eval'"),
      );
      expect(
        r.headers['content-security-policy'],
        contains("frame-ancestors 'none'"),
      );
      // Flutter web's <base href="/"> must stay effective on deep links.
      expect(r.headers['content-security-policy'], contains("base-uri 'self'"));
      expect(r.headers['x-frame-options'], 'DENY');
      final none = createWebHandler(p.join(web.path, 'nope'));
      final page = await none(Request('GET', Uri.parse('http://h/')));
      expect(await page.readAsString(), contains('web build not installed'));
    });
  });
}
