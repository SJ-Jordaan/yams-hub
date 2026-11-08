import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/core/auth/login_limiter.dart';
import 'package:yams_hub_gateway/src/core/auth/password_hasher.dart';
import 'package:yams_hub_gateway/src/core/auth/server_proof.dart';

import '../support/test_hub.dart';

Map<String, Object?> _login(
  String username,
  String password, {
  String transport = 'token',
}) => {
  'username': username,
  'password': password,
  'deviceName': 'Pixel 8',
  'platform': 'android',
  'transport': transport,
};

String? _cookieValue(List<String> setCookies, String name) {
  for (final c in setCookies) {
    if (c.startsWith('$name=')) {
      return c.split(';').first.substring(name.length + 1);
    }
  }
  return null;
}

void main() {
  group('bootstrap admin', () {
    test(
      'created from the hash on first start, ignored once users.json exists',
      () async {
        final dir = await Directory.systemTemp.createTemp('yams-hub-boot-');
        addTearDown(() => dir.delete(recursive: true));
        final fakes = FakeUpstreams();
        final hash = PasswordHasher.hashSync(
          'bootstrap-pass-1',
          minHashIterations,
        );
        final config = ConfigLoader.load({
          ...fakes.env(),
          'YAMS_HUB_DATA_DIR': '${dir.path}/data',
          'YAMS_HUB_WEB_DIR': '${dir.path}/web',
          'YAMS_HUB_ADMIN_USERNAME': 'boss',
          'YAMS_HUB_ADMIN_PASSWORD_HASH': hash,
        });
        Future<Hub> open() => Hub.create(
          config,
          upstreamClient: fakes.client,
          remoteFetcher: fakes.remoteFetcher(),
          clock: FakeClock(),
          hasher: PasswordHasher(iterations: minHashIterations),
          modules: (_) => const [],
        );

        var hub = await open();
        final boss = hub.auth.users.byUsername('boss');
        expect(boss?.role, Role.admin);
        expect(boss?.passwordHash, hash);
        await hub.stop();

        // A users.json without users (damaged or emptied) keeps the bootstrap
        // hash ignored: reset-admin is the recovery path.
        File('${dir.path}/data/users.json')
            .writeAsStringSync('{"version":1,"users":[]}');
        hub = await open();
        expect(hub.auth.users.isEmpty, isTrue);
        await hub.stop();
      },
    );
  });

  group('login', () {
    late TestHub hub;
    setUp(() => hub = TestHub());
    tearDown(() => hub.close());

    test(
      'bearer login returns tokens, the session and a server proof key',
      () async {
        final r = await hub.post(
          '/api/v1/auth/login',
          body: _login('admin', testAdminPassword),
          as: TestAs.anonymous,
        );
        expect(r.status, 200, reason: r.body);
        final login = LoginResponse.fromJson(r.map);
        expect(login.user.username, 'admin');
        expect(login.user.toJson().containsKey('passwordHash'), isFalse);
        expect(login.tokens!.accessToken, startsWith('yha_'));
        expect(
          login.tokens!.refreshToken,
          startsWith('yhr_${login.session.id}.'),
        );
        expect(login.serverProofKey, isNotNull);
        expect(login.session.platform, ClientPlatform.android);
        expect(login.session.lastIp, '192.168.10.50');

        // The token works and the ping proof verifies with the key.
        final me = await hub.get(
          '/api/v1/auth/me',
          token: login.tokens!.accessToken,
        );
        expect(me.status, 200);
        const nonce = 'abcdefghijklmnopqrstuvwx';
        final ping = await hub.get(
          '/api/v1/ping?nonce=$nonce&sid=${login.session.id}',
          as: TestAs.anonymous,
        );
        expect(ping.status, 200);
        expect(
          ping.map['proof'],
          computeServerProof(login.serverProofKey!, nonce),
        );
      },
    );

    test('wrong password and unknown user give the same 401', () async {
      final a = await hub.post(
        '/api/v1/auth/login',
        body: _login('admin', 'wrong-password'),
        as: TestAs.anonymous,
      );
      final b = await hub.post(
        '/api/v1/auth/login',
        body: _login('nobody', 'wrong-password'),
        as: TestAs.anonymous,
      );
      expect(a.status, 401);
      expect(b.status, 401);
      expect(a.errorCode, 'invalid_credentials');
      expect(
        readMap(a.map['error'])!['message'],
        readMap(b.map['error'])!['message'],
      );
      await hub.hub.audit.flush();
      final audit = await hub.hub.audit.query(
        actionPrefix: 'auth.login_failed',
      );
      expect(
        audit.items.map((e) => e.target),
        containsAll(['admin', 'nobody']),
      );
    });

    test(
      'a password typed into the username field is not stored in the audit log',
      () async {
        await hub.post(
          '/api/v1/auth/login',
          body: _login('My Secret Pass!', 'x'),
          as: TestAs.anonymous,
        );
        final audit = await hub.hub.audit.query(
          actionPrefix: 'auth.login_failed',
        );
        expect(audit.items.single.target, '<invalid>');
      },
    );

    test('a disabled account gets 403 "Account disabled"', () async {
      await hub.ready;
      await hub.hub.auth.users.put(
        hub.member.copyWith(disabled: true, updatedAt: hub.clock.now()),
      );
      final r = await hub.post(
        '/api/v1/auth/login',
        body: _login('member', testMemberPassword),
        as: TestAs.anonymous,
      );
      expect(r.status, 403);
      expect(readMap(r.map['error'])!['message'], 'Account disabled');
    });

    test(
      'the pair limit locks after 5 failures and refuses without hashing',
      () async {
        for (var i = 0; i < 5; i++) {
          final r = await hub.post(
            '/api/v1/auth/login',
            body: _login('admin', 'bad-$i'),
            as: TestAs.anonymous,
          );
          expect(r.status, 401);
        }
        final locked = await hub.post(
          '/api/v1/auth/login',
          body: _login('admin', testAdminPassword),
          as: TestAs.anonymous,
        );
        expect(locked.status, 429);
        expect(locked.errorCode, 'rate_limited');
        expect(int.parse(locked.headers['retry-after']!), greaterThan(800));
        // Another IP is not affected.
        final other = await hub.post(
          '/api/v1/auth/login',
          body: _login('admin', testAdminPassword),
          as: TestAs.anonymous,
          ip: '192.168.10.77',
        );
        expect(other.status, 200);
        hub.clock.advance(const Duration(minutes: 16));
        final later = await hub.post(
          '/api/v1/auth/login',
          body: _login('admin', testAdminPassword),
          as: TestAs.anonymous,
        );
        expect(later.status, 200);
      },
    );

    test('invalid bodies are rejected', () async {
      final r = await hub.post(
        '/api/v1/auth/login',
        body: {'username': 'admin'},
        as: TestAs.anonymous,
      );
      expect(r.status, 422);
      final t = await hub.post(
        '/api/v1/auth/login',
        body: _login('admin', 'x', transport: 'carrier-pigeon'),
        as: TestAs.anonymous,
      );
      expect(t.status, 400);
      final bad = await hub.post(
        '/api/v1/auth/login',
        body: '{not json',
        as: TestAs.anonymous,
      );
      expect(bad.status, 400);
      expect(bad.errorCode, 'bad_request');
    });
  });

  group('verification semaphore', () {
    test(
      '2 run, 8 wait, the 11th concurrent login gets 429 without hashing',
      () async {
        final release = Completer<void>();
        var started = 0;
        final hasher = PasswordHasher(
          iterations: minHashIterations,
          verifyFunction: (password, stored) async {
            started++;
            await release.future;
            return false;
          },
          hashFunction: (password, iterations) async =>
              PasswordHasher.hashSync(password, iterations),
        );
        final hub = TestHub(hasher: hasher, login: false);
        addTearDown(hub.close);
        await hub.ready;

        final futures = <Future<TestResponse>>[];
        for (var i = 0; i < 10; i++) {
          futures.add(
            hub.post(
              '/api/v1/auth/login',
              body: _login('admin', 'wrong-password-$i'),
              as: TestAs.anonymous,
              ip: '192.168.10.${100 + i}',
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 5));
          if (i == 2) {
            // The 3rd concurrent login waits for a slot.
            expect(started, 2);
            expect(hasher.gate.queued, 1);
          }
        }
        expect(hasher.gate.running, 2);
        expect(hasher.gate.queued, 8);

        final eleventh = await hub.post(
          '/api/v1/auth/login',
          body: _login('admin', 'wrong-password-10'),
          as: TestAs.anonymous,
          ip: '192.168.10.120',
        );
        expect(eleventh.status, 429);
        expect(eleventh.errorCode, 'rate_limited');
        expect(eleventh.headers['retry-after'], '2');
        expect(started, 2, reason: 'the rejected attempt did not hash');

        release.complete();
        final results = await Future.wait(futures);
        expect(results.map((r) => r.status), everyElement(401));
        expect(started, 10);
      },
    );
  });

  group('refresh', () {
    late TestHub hub;
    setUp(() => hub = TestHub());
    tearDown(() => hub.close());

    Future<LoginResponse> login() async {
      final r = await hub.post(
        '/api/v1/auth/login',
        body: _login('member', testMemberPassword),
        as: TestAs.anonymous,
      );
      return LoginResponse.fromJson(r.map);
    }

    Future<TestResponse> refresh(String token) => hub.post(
      '/api/v1/auth/refresh',
      body: {'refreshToken': token},
      as: TestAs.anonymous,
    );

    test(
      'rotates the pair; the previous token rotates again within 30 s',
      () async {
        final l = await login();
        final r1 = await refresh(l.tokens!.refreshToken);
        expect(r1.status, 200);
        final t1 = RefreshResponse.fromJson(r1.map).tokens;
        expect(t1.refreshToken, isNot(l.tokens!.refreshToken));
        // A racing request with the old token inside the grace window.
        hub.clock.advance(const Duration(seconds: 10));
        final race = await refresh(l.tokens!.refreshToken);
        expect(race.status, 200);
        final me = await hub.get(
          '/api/v1/auth/me',
          token: RefreshResponse.fromJson(race.map).tokens.accessToken,
        );
        expect(me.status, 200);
      },
    );

    test(
      'reuse of an old token after two rotations revokes the session',
      () async {
        final l = await login();
        final r1 = RefreshResponse.fromJson(
          (await refresh(l.tokens!.refreshToken)).map,
        ).tokens;
        hub.clock.advance(const Duration(minutes: 1));
        final r2 = RefreshResponse.fromJson(
          (await refresh(r1.refreshToken)).map,
        ).tokens;
        hub.clock.advance(const Duration(minutes: 1));

        final reuse = await refresh(l.tokens!.refreshToken);
        expect(reuse.status, 401);
        expect(reuse.errorCode, 'refresh_invalid');
        // The whole session is gone: the current tokens stop working at once.
        expect((await refresh(r2.refreshToken)).status, 401);
        final me = await hub.get('/api/v1/auth/me', token: r2.accessToken);
        expect(me.status, 401);
        final audit = await hub.hub.audit.query(
          actionPrefix: 'auth.refresh_reuse',
        );
        expect(audit.items, hasLength(1));
        expect(audit.items.single.target, l.session.id);
      },
    );

    test('malformed, unknown and expired tokens are refresh_invalid', () async {
      expect((await refresh('garbage')).errorCode, 'refresh_invalid');
      expect(
        (await refresh('yhr_s_000000000000.${'A' * 43}')).errorCode,
        'refresh_invalid',
      );
      final l = await login();
      hub.clock.advance(const Duration(days: 91));
      expect(
        (await refresh(l.tokens!.refreshToken)).errorCode,
        'refresh_invalid',
      );
    });

    test('admins get the shorter refresh TTL', () async {
      final r = await hub.post(
        '/api/v1/auth/login',
        body: _login('admin', testAdminPassword),
        as: TestAs.anonymous,
      );
      final l = LoginResponse.fromJson(r.map);
      expect(
        l.tokens!.refreshTokenExpiresAt.difference(hub.clock.now()),
        const Duration(days: 30),
      );
      final m = await login();
      expect(
        m.tokens!.refreshTokenExpiresAt.difference(hub.clock.now()),
        const Duration(days: 90),
      );
    });

    test('access tokens expire after 60 minutes (token_expired)', () async {
      final l = await login();
      hub.clock.advance(const Duration(minutes: 61));
      final me = await hub.get('/api/v1/auth/me', token: l.tokens!.accessToken);
      expect(me.status, 401);
      expect(me.errorCode, 'token_expired');
    });
  });

  group('per-request authentication', () {
    late TestHub hub;
    setUp(() => hub = TestHub());
    tearDown(() => hub.close());

    test('no or bad credentials are 401', () async {
      expect(
        (await hub.get('/api/v1/auth/me', as: TestAs.anonymous)).errorCode,
        'unauthorized',
      );
      expect(
        (await hub.get('/api/v1/auth/me', token: 'yha_unknown')).errorCode,
        'token_expired',
      );
      final basic = await hub.get(
        '/api/v1/auth/me',
        headers: {'authorization': 'Basic Zm9vOmJhcg=='},
      );
      expect(basic.status, 401);
    });

    test('role is read from the store on every request', () async {
      final before = await hub.get('/api/v1/admin/users');
      expect(before.status, 200);
      await hub.ready;
      final second = hub.hub.auth.users.byId(hub.admin.id)!;
      // Promote the member, demote nobody: the member's next request is admin.
      await hub.hub.auth.users.put(
        hub.member.copyWith(role: Role.admin, updatedAt: hub.clock.now()),
      );
      final promoted = await hub.get('/api/v1/admin/users', as: TestAs.member);
      expect(promoted.status, 200);
      await hub.hub.auth.users.put(
        hub.member.copyWith(role: Role.member, updatedAt: hub.clock.now()),
      );
      final demoted = await hub.get('/api/v1/admin/users', as: TestAs.member);
      expect(demoted.status, 403);
      expect(second.role, Role.admin);
    });

    test('a disabled user is 401 and the session is revoked', () async {
      await hub.ready;
      await hub.hub.auth.users.put(
        hub.member.copyWith(disabled: true, updatedAt: hub.clock.now()),
      );
      final r = await hub.get('/api/v1/auth/me', as: TestAs.member);
      expect(r.status, 401);
      expect(hub.hub.auth.sessions.byId(hub.memberSessionId), isNull);
    });

    test('logout revokes the session', () async {
      final r = await hub.post('/api/v1/auth/logout', as: TestAs.member);
      expect(r.status, 204);
      expect((await hub.get('/api/v1/auth/me', as: TestAs.member)).status, 401);
    });

    test('changing the password revokes the other sessions only', () async {
      final other = LoginResponse.fromJson(
        (await hub.post(
          '/api/v1/auth/login',
          body: _login('member', testMemberPassword),
          as: TestAs.anonymous,
        )).map,
      );
      final wrong = await hub.post(
        '/api/v1/auth/password',
        body: {
          'currentPassword': 'nope-nope-nope',
          'newPassword': 'a-brand-new-password',
        },
        as: TestAs.member,
      );
      expect(wrong.status, 401);
      final short = await hub.post(
        '/api/v1/auth/password',
        body: {'currentPassword': testMemberPassword, 'newPassword': 'short'},
        as: TestAs.member,
      );
      expect(short.status, 422);
      final ok = await hub.post(
        '/api/v1/auth/password',
        body: {
          'currentPassword': testMemberPassword,
          'newPassword': 'a-brand-new-password',
        },
        as: TestAs.member,
      );
      expect(ok.status, 204);
      expect((await hub.get('/api/v1/auth/me', as: TestAs.member)).status, 200);
      expect(
        (await hub.get(
          '/api/v1/auth/me',
          token: other.tokens!.accessToken,
        )).status,
        401,
      );
      final relogin = await hub.post(
        '/api/v1/auth/login',
        body: _login('member', 'a-brand-new-password'),
        as: TestAs.anonymous,
      );
      expect(relogin.status, 200);
    });

    test('sessions: own list, admin ?all=true, delete', () async {
      final mine = await hub.get('/api/v1/auth/sessions', as: TestAs.member);
      final items = readList(mine.map['items'], SessionInfo.fromJson);
      expect(items, hasLength(1));
      expect(items.single.current, isTrue);
      expect(
        (await hub.get(
          '/api/v1/auth/sessions?all=true',
          as: TestAs.member,
        )).status,
        403,
      );
      final all = await hub.get('/api/v1/auth/sessions?all=true');
      final allItems = readList(all.map['items'], SessionInfo.fromJson);
      expect(allItems.map((s) => s.username), containsAll(['admin', 'member']));
      // A member cannot see or revoke the admin's session.
      expect(
        (await hub.delete(
          '/api/v1/auth/sessions/${hub.adminSessionId}',
          as: TestAs.member,
        )).status,
        404,
      );
      expect(
        (await hub.delete('/api/v1/auth/sessions/${hub.memberSessionId}'))
            .status,
        204,
      );
      expect((await hub.get('/api/v1/auth/me', as: TestAs.member)).status, 401);
    });
  });

  group('cookie transport', () {
    late TestHub hub;
    setUp(() => hub = TestHub());
    tearDown(() => hub.close());

    Future<TestResponse> cookieLogin({
      Map<String, String> headers = const {
        'x-yams-client': 'yams-hub/1.0.0 (web)',
      },
    }) => hub.post(
      '/yh/api/v1/auth/login',
      body: _login('member', testMemberPassword, transport: 'cookie'),
      as: TestAs.anonymous,
      headers: headers,
    );

    test('login requires X-YAMS-Client and sets scoped cookies, no tokens in the body', () async {
      final csrf = await cookieLogin(headers: const {});
      expect(csrf.status, 403);
      expect(csrf.errorCode, 'csrf_rejected');

      final r = await cookieLogin();
      expect(r.status, 200, reason: r.body);
      expect(r.map.containsKey('tokens'), isFalse);
      expect(r.map.containsKey('serverProofKey'), isFalse);
      final at = r.setCookies.firstWhere((c) => c.startsWith('yh_at='));
      final rt = r.setCookies.firstWhere((c) => c.startsWith('yh_rt='));
      expect(at, contains('HttpOnly'));
      expect(at, contains('SameSite=Strict'));
      expect(at, contains('Path=/yh/api;'));
      expect(at, contains('Max-Age=3600'));
      expect(at, isNot(contains('Secure')));
      expect(rt, contains('Path=/yh/api/v1/auth/refresh'));
      expect(rt, contains('Max-Age=${const Duration(days: 90).inSeconds}'));
    });

    test('cookie login is only available on /yh/api/v1', () async {
      final r = await hub.post(
        '/api/v1/auth/login',
        body: _login('member', testMemberPassword, transport: 'cookie'),
        as: TestAs.anonymous,
        headers: const {'x-yams-client': 'x'},
      );
      expect(r.status, 400);
    });

    test('cookie requests need X-YAMS-Client except image GETs; /api/v1 ignores cookies', () async {
      final login = await cookieLogin();
      final at = _cookieValue(login.setCookies, 'yh_at')!;
      final cookie = {'cookie': 'yh_at=$at'};
      final noHeader = await hub.get(
        '/yh/api/v1/auth/me',
        as: TestAs.anonymous,
        headers: cookie,
      );
      expect(noHeader.status, 403);
      expect(noHeader.errorCode, 'csrf_rejected');
      final ok = await hub.get(
        '/yh/api/v1/auth/me',
        as: TestAs.anonymous,
        headers: {...cookie, 'x-yams-client': 'web'},
      );
      expect(ok.status, 200);
      final bearerMount = await hub.get(
        '/api/v1/auth/me',
        as: TestAs.anonymous,
        headers: {...cookie, 'x-yams-client': 'web'},
      );
      expect(bearerMount.status, 401);
      // Image GETs pass the CSRF rule (and then fail validation, not CSRF).
      final img = await hub.get(
        '/yh/api/v1/img/abs/!bad!',
        as: TestAs.anonymous,
        headers: cookie,
      );
      expect(img.status, 400);
      // Bearer tokens work on the cookie mount too.
      final bearer = await hub.get('/yh/api/v1/auth/me', as: TestAs.member);
      expect(bearer.status, 200);
    });

    test(
      'refresh with the cookie rotates both cookies; logout clears them',
      () async {
        final login = await cookieLogin();
        final rt = _cookieValue(login.setCookies, 'yh_rt')!;
        final at = _cookieValue(login.setCookies, 'yh_at')!;
        final noHeader = await hub.post(
          '/yh/api/v1/auth/refresh',
          as: TestAs.anonymous,
          headers: {'cookie': 'yh_rt=$rt'},
        );
        expect(noHeader.status, 403);
        final r = await hub.post(
          '/yh/api/v1/auth/refresh',
          as: TestAs.anonymous,
          headers: {'cookie': 'yh_rt=$rt', 'x-yams-client': 'web'},
        );
        expect(r.status, 200);
        final newAt = _cookieValue(r.setCookies, 'yh_at');
        expect(newAt, isNotNull);
        expect(_cookieValue(r.setCookies, 'yh_rt'), isNot(rt));
        expect(at, isNot(newAt));
        final out = await hub.post(
          '/yh/api/v1/auth/logout',
          as: TestAs.anonymous,
          headers: {'cookie': 'yh_at=$newAt', 'x-yams-client': 'web'},
        );
        expect(out.status, 204);
        expect(out.setCookies.every((c) => c.contains('Max-Age=0')), isTrue);
        expect(out.setCookies, hasLength(2));
      },
    );

    test('Secure is added behind a trusted HTTPS proxy', () async {
      final secureHub = TestHub(
        env: {
          'YAMS_HUB_TRUST_PROXY': 'true',
          // The test client's socket address is the proxy.
          'YAMS_HUB_TRUSTED_PROXIES': '192.168.10.0/24',
        },
      );
      addTearDown(secureHub.close);
      final r = await secureHub.post(
        '/yh/api/v1/auth/login',
        body: _login('member', testMemberPassword, transport: 'cookie'),
        as: TestAs.anonymous,
        headers: {'x-yams-client': 'web', 'x-forwarded-proto': 'https'},
      );
      expect(r.status, 200);
      expect(r.setCookies, everyElement(contains('Secure')));
    });
  });

  group('ping', () {
    late TestHub hub;
    setUpAll(() => hub = TestHub());
    tearDownAll(() => hub.close());

    test('is public, exempt from the host check and stable', () async {
      final r = await hub.get(
        '/api/v1/ping',
        as: TestAs.anonymous,
        headers: const {},
        ip: '127.0.0.1',
      );
      expect(r.status, 200);
      final ping = ServerPing.fromJson(r.map);
      expect(ping.name, 'yams-hub');
      expect(ping.apiVersion, 1);
      expect(ping.instanceId, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(ping.proof, isNull);
      final again = ServerPing.fromJson(
        (await hub.get('/api/v1/ping', as: TestAs.anonymous)).map,
      );
      expect(again.instanceId, ping.instanceId);
      final evil = await hub.request(
        'GET',
        '/api/v1/ping',
        as: TestAs.anonymous,
        host: 'attacker.example:8090',
      );
      expect(evil.status, 200);
    });

    test('proof only for a live session; invalid nonce is 400', () async {
      await hub.ready;
      const nonce = 'nonce-nonce-nonce-1234';
      final unknown = await hub.get(
        '/api/v1/ping?nonce=$nonce&sid=s_000000000000',
        as: TestAs.anonymous,
      );
      expect(unknown.map.containsKey('proof'), isFalse);
      final known = await hub.get(
        '/api/v1/ping?nonce=$nonce&sid=${hub.memberSessionId}',
        as: TestAs.anonymous,
      );
      final key = hub.hub.auth.sessions.byId(hub.memberSessionId)!.proofKey;
      expect(known.map['proof'], computeServerProof(key, nonce));
      expect(
        (await hub.get(
          '/api/v1/ping?nonce=short',
          as: TestAs.anonymous,
        )).status,
        400,
      );
    });
  });

  group('password timing and limits', () {
    test(
      'the dummy hash uses the requested (stored) iteration count',
      () async {
        final hashed = <int>[];
        final hasher = PasswordHasher(
          iterations: fallbackIterations,
          hashFunction: (pw, it) async {
            hashed.add(it);
            return PasswordHasher.hashSync(pw, minHashIterations);
          },
          verifyFunction: (pw, stored) async => false,
        );
        await hasher.verifyDummy('x', iterations: 600000);
        await hasher.verifyDummy('y', iterations: 600000);
        await hasher.verifyDummy('z');
        // One dummy per count, built once.
        expect(hashed, [600000, fallbackIterations]);
        expect(
          hasher.needsRehash('pbkdf2-sha256\$600000\$x\$y'),
          isFalse,
          reason: 'malformed hashes are never re-hashed',
        );
        final stored = PasswordHasher.hashSync('pw', minHashIterations);
        expect(hasher.needsRehash(stored), isTrue);
        expect(PasswordHasher.iterationsOf(stored), minHashIterations);
      },
    );

    test('unknown users are verified at the highest stored count', () async {
      final dummyCounts = <int>[];
      final hasher = PasswordHasher(
        iterations: minHashIterations,
        hashFunction: (pw, it) async {
          if (pw.startsWith('dummy-')) dummyCounts.add(it);
          return PasswordHasher.hashSync(pw, minHashIterations);
        },
        verifyFunction: (pw, stored) async =>
            PasswordHasher.verifySync(pw, stored),
      );
      final hub = TestHub(hasher: hasher, login: false);
      addTearDown(hub.close);
      await hub.ready;
      // An account created before an auto-tune fallback keeps 600 000.
      final slowHash = PasswordHasher.hashSync(
        'irrelevant',
        minHashIterations,
      ).replaceFirst('\$$minHashIterations\$', '\$600000\$');
      await hub.hub.auth.users.put(
        hub.member.copyWith(passwordHash: slowHash, updatedAt: hub.clock.now()),
      );
      expect(hub.hub.auth.dummyIterations(), 600000);
      final r = await hub.post(
        '/api/v1/auth/login',
        body: _login('nosuchuser', 'whatever-password'),
        as: TestAs.anonymous,
      );
      expect(r.status, 401);
      expect(dummyCounts, [600000]);
    });

    test('a successful login re-hashes at the current count', () async {
      const tuned = minHashIterations + 1;
      final hub = TestHub(
        hasher: PasswordHasher(
          iterations: tuned,
          hashFunction: (pw, it) async => PasswordHasher.hashSync(pw, it),
          verifyFunction: (pw, stored) async =>
              PasswordHasher.verifySync(pw, stored),
        ),
        login: false,
      );
      addTearDown(hub.close);
      await hub.ready;
      final before = hub.hub.auth.users.byUsername('member')!.passwordHash;
      expect(PasswordHasher.iterationsOf(before), minHashIterations);
      final r = await hub.post(
        '/api/v1/auth/login',
        body: _login('member', testMemberPassword),
        as: TestAs.anonymous,
      );
      expect(r.status, 200, reason: r.body);
      final after = hub.hub.auth.users.byUsername('member')!.passwordHash;
      expect(PasswordHasher.iterationsOf(after), tuned);
      expect(PasswordHasher.verifySync(testMemberPassword, after), isTrue);
      final again = await hub.post(
        '/api/v1/auth/login',
        body: _login('member', testMemberPassword),
        as: TestAs.anonymous,
      );
      expect(again.status, 200);
      expect(hub.hub.auth.users.byUsername('member')!.passwordHash, after);
    });

    test('POST /auth/password guesses go through the login limiter', () async {
      final hub = TestHub();
      addTearDown(hub.close);
      Future<TestResponse> guess(int i) => hub.post(
        '/api/v1/auth/password',
        body: {
          'currentPassword': 'wrong-guess-$i',
          'newPassword': 'attacker-chosen-password',
        },
        as: TestAs.member,
      );
      for (var i = 0; i < LoginLimiter.pairLimit; i++) {
        expect((await guess(i)).status, 401);
      }
      final locked = await guess(99);
      expect(locked.status, 429);
      expect(locked.errorCode, 'rate_limited');
      // Even the right password is refused while the pair is locked.
      final right = await hub.post(
        '/api/v1/auth/password',
        body: {
          'currentPassword': testMemberPassword,
          'newPassword': 'attacker-chosen-password',
        },
        as: TestAs.member,
      );
      expect(right.status, 429);
      final audit = await hub.get('/api/v1/admin/audit?action=auth.locked');
      expect(audit.body, contains('auth.locked'));
    });
  });
}
