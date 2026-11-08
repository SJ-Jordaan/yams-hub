import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/core/auth/login_limiter.dart';
import 'package:yams_hub_gateway/src/core/auth/password_hasher.dart';

import '../support/test_hub.dart';

/// A module with a configurable dashboard card (stands in for a feature).
final class _CardModule extends FeatureModule {
  _CardModule(this.id, this.card);

  @override
  final String id;
  final Future<DashboardContribution?> Function() card;

  @override
  void registerRoutes(ApiRouter router) {}

  @override
  Future<DashboardContribution?> dashboard(ApiRequest req) => card();
}

void main() {
  group('admin users', () {
    late TestHub hub;
    setUp(() => hub = TestHub());
    tearDown(() => hub.close());

    test('create, list, update, delete with the invalidation rules', () async {
      final created = await hub.post(
        '/api/v1/admin/users',
        body: {
          'username': 'Zonika',
          'displayName': 'Zonika',
          'password': 'zonika-password',
          'role': 'member',
          'jellyfinUserId': '8BED8D8C-CCF2-4954-8EB6-A39FD6A7E54B',
        },
      );
      expect(created.status, 201, reason: created.body);
      final user = User.fromJson(created.map);
      expect(user.username, 'zonika');
      expect(user.jellyfinUserId, '8bed8d8cccf249548eb6a39fd6a7e54b');
      expect(created.body, isNot(contains('pbkdf2')));

      expect(
        (await hub.post(
          '/api/v1/admin/users',
          body: {
            'username': 'zonika',
            'displayName': 'Z',
            'password': 'zonika-password',
            'role': 'member',
          },
        )).errorCode,
        'already_exists',
      );
      final invalid = await hub.post(
        '/api/v1/admin/users',
        body: {
          'username': 'x',
          'displayName': '',
          'password': 'short',
          'role': 'king',
        },
      );
      expect(invalid.status, 422);
      expect(
        readList(
          readMap(invalid.map['error'])!['fields'],
          ApiFieldError.fromJson,
        ).map((f) => f.field),
        containsAll(['username', 'displayName', 'password', 'role']),
      );
      expect(
        (await hub.get('/api/v1/admin/users', as: TestAs.member)).status,
        403,
      );

      final list = await hub.get('/api/v1/admin/users');
      expect(
        readList(list.map['items'], User.fromJson).map((u) => u.username),
        ['admin', 'member', 'zonika'],
      );

      // Log zonika in, then reset the password as admin: all sessions end.
      final login = await hub.post(
        '/api/v1/auth/login',
        body: {
          'username': 'zonika',
          'password': 'zonika-password',
          'deviceName': 'p',
          'platform': 'ios',
        },
        as: TestAs.anonymous,
      );
      final token = LoginResponse.fromJson(login.map).tokens!.accessToken;
      final reset = await hub.patch(
        '/api/v1/admin/users/${user.id}',
        body: {'password': 'another-password'},
      );
      expect(reset.status, 200);
      expect((await hub.get('/api/v1/auth/me', token: token)).status, 401);

      final cleared = await hub.patch(
        '/api/v1/admin/users/${user.id}',
        body: {'jellyfinUserId': '', 'displayName': 'Zoni'},
      );
      expect(User.fromJson(cleared.map).jellyfinUserId, isNull);
      expect(User.fromJson(cleared.map).displayName, 'Zoni');

      final noConfirm = await hub.delete('/api/v1/admin/users/${user.id}');
      expect(noConfirm.status, 428);
      expect(
        readMap(readMap(noConfirm.map['error'])!['details'])!['impact'],
        contains('zonika'),
      );
      expect(
        (await hub.delete('/api/v1/admin/users/${user.id}?confirm=true'))
            .status,
        204,
      );
      expect((await hub.get('/api/v1/admin/users')).map['items'], hasLength(2));

      final audit = await hub.get('/api/v1/admin/audit?action=admin.user.');
      final entries = readList(audit.map['items'], AuditEntry.fromJson);
      expect(entries.map((e) => e.action), [
        'admin.user.delete',
        'admin.user.update',
        'admin.user.update',
        'admin.user.create',
      ]);
      expect(entries.first.username, 'admin');
      expect(
        entries
            .firstWhere((e) => e.params?.containsKey('password') ?? false)
            .params!['password'],
        '***',
      );
    });

    test(
      'the last active admin cannot be demoted, disabled or delete themselves',
      () async {
        await hub.ready;
        final id = hub.admin.id;
        expect(
          (await hub.patch(
            '/api/v1/admin/users/$id',
            body: {'role': 'member'},
          )).errorCode,
          'invalid_state',
        );
        expect(
          (await hub.patch(
            '/api/v1/admin/users/$id',
            body: {'disabled': true},
          )).errorCode,
          'invalid_state',
        );
        expect(
          (await hub.delete('/api/v1/admin/users/$id?confirm=true')).errorCode,
          'invalid_state',
        );
        // With a second admin, demoting is fine.
        await hub.patch(
          '/api/v1/admin/users/${hub.member.id}',
          body: {'role': 'admin'},
        );
        expect(
          (await hub.patch(
            '/api/v1/admin/users/$id',
            body: {'role': 'member'},
          )).status,
          200,
        );
      },
    );

    test('disabling a user revokes their sessions', () async {
      await hub.ready;
      final r = await hub.patch(
        '/api/v1/admin/users/${hub.member.id}',
        body: {'disabled': true},
      );
      expect(r.status, 200);
      expect(hub.hub.auth.sessions.forUser(hub.member.id), isEmpty);
    });

    test('jellyfin users joined with Seerr; import-to-seerr', () async {
      hub.fakes.onFixture(
        ServiceId.jellyfin,
        'GET',
        '/Users',
        'seerr/jellyfin_users.json',
      );
      hub.fakes.onFixture(
        ServiceId.seerr,
        'GET',
        '/api/v1/user',
        'seerr/seerr_user_list.json',
      );
      final r = await hub.get('/api/v1/admin/jellyfin-users');
      expect(r.status, 200, reason: r.body);
      final options = readList(r.map['items'], JellyfinUserOption.fromJson);
      final paul = options.firstWhere(
        (o) => o.jellyfinUserId == '4c0628aacef24bdfacd40f946ea33ee7',
      );
      expect(paul.isAdministrator, isTrue);
      expect(paul.seerrUserId, 1);
      expect(
        paul.avatarPath,
        startsWith(
          '/api/v1/img/jellyfin-user/4c0628aacef24bdfacd40f946ea33ee7',
        ),
      );
      final zenith = options.firstWhere(
        (o) => o.jellyfinUserId == testMemberJellyfinId,
      );
      expect(zenith.linkedHubUserId, hub.member.id);
      final unlinked = options.firstWhere((o) => o.seerrUserId == null);

      var imported = false;
      hub.fakes.on(
        ServiceId.seerr,
        'POST',
        '/api/v1/user/import-from-jellyfin',
        (req) {
          expect(req.json(), {
            'jellyfinUserIds': [unlinked.jellyfinUserId],
          });
          imported = true;
          return FakeResponse.json([], status: 201);
        },
      );
      final users = fixture('seerr/seerr_user_list.json')! as Map;
      hub.fakes.on(
        ServiceId.seerr,
        'GET',
        '/api/v1/user',
        (_) => FakeResponse.json(
          imported
              ? {
                  ...users,
                  'results': [
                    ...users['results'] as List,
                    {
                      'id': 9,
                      'displayName': unlinked.name,
                      'jellyfinUserId': unlinked.jellyfinUserId,
                      'permissions': 32,
                    },
                  ],
                }
              : users,
        ),
      );
      final imp = await hub.post(
        '/api/v1/admin/jellyfin-users/${unlinked.jellyfinUserId}/import-to-seerr',
      );
      expect(imp.status, 200, reason: imp.body);
      expect(JellyfinUserOption.fromJson(imp.map).seerrUserId, 9);
      expect(
        (await hub.post(
          '/api/v1/admin/jellyfin-users/ffffffffffffffffffffffffffffffff/import-to-seerr',
        )).status,
        404,
      );
      final audit = await hub.hub.audit.query(
        actionPrefix: 'admin.seerr_import',
      );
      expect(audit.items, hasLength(1));
    });
  });

  group('/auth/me Seerr link', () {
    late TestHub hub;
    setUp(() => hub = TestHub());
    tearDown(() => hub.close());

    test('members resolve through their Jellyfin id; quota limit 0 means unlimited', () async {
      hub.fakes.onFixture(
        ServiceId.seerr,
        'GET',
        '/api/v1/user/jellyfin/$testMemberJellyfinId',
        'seerr/seerr_user_by_jellyfin_id.json',
      );
      hub.fakes.onFixture(
        ServiceId.seerr,
        'GET',
        '/api/v1/user/2/quota',
        'seerr/seerr_user_quota.json',
      );
      final me = MeResponse.fromJson(
        (await hub.get('/api/v1/auth/me', as: TestAs.member)).map,
      );
      expect(me.user.username, 'member');
      expect(me.session.current, isTrue);
      expect(me.seerr.linked, isTrue);
      expect(me.seerr.seerrUserId, 2);
      expect(me.seerr.canAutoApprove, isFalse);
      expect(me.seerr.quota!.movie.isUnlimited, isTrue);
      expect(me.seerr.quota!.movie.remaining, isNull);
      // Cached 1 h.
      await hub.get('/api/v1/auth/me', as: TestAs.member);
      expect(
        hub.fakes
            .callsTo(ServiceId.seerr)
            .where((c) => c.path.contains('/user/jellyfin/')),
        hasLength(1),
      );
    });

    test('admins without a link act as Seerr user 1; unlinked members are unlinked', () async {
      hub.fakes.on(
        ServiceId.seerr,
        'GET',
        '/api/v1/user/1',
        (_) => FakeResponse.json({
          'id': 1,
          'displayName': 'Paul Greyrat',
          'permissions': 2,
        }),
      );
      final me = MeResponse.fromJson((await hub.get('/api/v1/auth/me')).map);
      expect(me.seerr.seerrUserId, 1);
      expect(me.seerr.canAutoApprove, isTrue);
      hub.fakes.on(
        ServiceId.seerr,
        'GET',
        RegExp(r'^/api/v1/user/jellyfin/'),
        (_) => FakeResponse.json({'message': 'User not found.'}, status: 404),
      );
      await hub.ready;
      hub.ctx.seerrIdentity.invalidate(hub.member.id);
      final m = MeResponse.fromJson(
        (await hub.get('/api/v1/auth/me', as: TestAs.member)).map,
      );
      expect(m.seerr.linked, isFalse);
    });
  });

  group('jobs', () {
    late TestHub hub;
    setUp(() => hub = TestHub());
    tearDown(() => hub.close());

    test(
      'run, dedupe per (kind, target), redact, audit, member filter',
      () async {
        await hub.ready;
        final gate = Completer<void>();
        final job = hub.ctx.jobs.start(
          kind: 'containers.restart',
          target: 'sonarr',
          userId: hub.admin.id,
          run: (h) async {
            h.step('Restarting sonarr');
            h.log('GET http://x/?apikey=SECRET123');
            await gate.future;
            return {'state': 'running', 'note': 'token=abc'};
          },
        );
        final again = hub.ctx.jobs.start(
          kind: 'containers.restart',
          target: 'sonarr',
          run: (_) async => null,
        );
        expect(again.id, job.id);
        await Future<void>.delayed(Duration.zero);
        final running = await hub.get('/api/v1/jobs?active=true');
        expect(
          readList(running.map['items'], Job.fromJson).single.status,
          JobStatus.running,
        );
        expect(
          (await hub.get('/api/v1/jobs/${job.id}', as: TestAs.member)).status,
          403,
        );
        expect(
          readList(
            (await hub.get(
              '/api/v1/jobs?active=true',
              as: TestAs.member,
            )).map['items'],
            Job.fromJson,
          ),
          isEmpty,
        );

        gate.complete();
        await job.done;
        final r = await hub.get('/api/v1/jobs/${job.id}');
        final dto = Job.fromJson(readMap(r.map['job'])!);
        expect(dto.status, JobStatus.succeeded);
        expect(dto.steps.single.status, JobStatus.succeeded);
        expect(dto.log.single, isNot(contains('SECRET123')));
        expect(dto.result!['note'], 'token=***');
        final audit = await hub.hub.audit.query(
          actionPrefix: 'containers.restart',
        );
        expect(audit.items.single.outcome, AuditOutcome.ok);
        expect(audit.items.single.username, 'admin');
        expect((await hub.get('/api/v1/jobs/j_000000000000')).status, 404);
      },
    );

    test('a failing job keeps the mapped error', () async {
      await hub.ready;
      final job = hub.ctx.jobs.start(
        kind: 'indexers.test',
        target: '3',
        userId: hub.member.id,
        run: (_) async => throw UpstreamUnavailable(
          service: ServiceId.prowlarr,
          method: 'POST',
          path: '/api/v1/indexer/test',
        ),
      );
      await job.done;
      final dto = Job.fromJson(
        readMap(
          (await hub.get(
            '/api/v1/jobs/${job.id}',
            as: TestAs.member,
          )).map['job'],
        )!,
      );
      expect(dto.status, JobStatus.failed);
      expect(dto.error!.code, 'upstream_unavailable');
      expect(dto.error!.service, ServiceId.prowlarr);
    });

    test('finished jobs expire after 24 h', () async {
      await hub.ready;
      final job = hub.ctx.jobs.start(kind: 'x.y', run: (_) async => null);
      await job.done;
      hub.clock.advance(const Duration(hours: 25));
      expect(hub.ctx.jobs.get(job.id), isNull);
    });
  });

  group('dashboard aggregation', () {
    test('cards: ok, disabled, error, timeout (load continues), alerts merged and sorted', () async {
      var slowFinished = false;
      final hub = TestHub(
        modules: (ctx) => [
          _CardModule(
            'system',
            () async => DashboardContribution(
              data: {'cpuPercent': 3.5},
              alerts: [
                Alert(
                  id: 'raid.noRedundancy',
                  severity: AlertSeverity.info,
                  source: ServiceId.host,
                  feature: 'system',
                  title: 'RAID0',
                ),
                Alert(
                  id: 'dup',
                  severity: AlertSeverity.warning,
                  source: ServiceId.host,
                  feature: 'system',
                  title: 'first',
                ),
              ],
            ),
          ),
          _CardModule(
            'activity',
            () async =>
                throw ApiException.serviceNotConfigured(ServiceId.qbittorrent),
          ),
          _CardModule(
            'media',
            () async => throw UpstreamUnavailable(
              service: ServiceId.jellyfin,
              method: 'GET',
              path: '/Sessions',
            ),
          ),
          _CardModule('calendar', () async {
            await Future<void>.delayed(const Duration(milliseconds: 4300));
            slowFinished = true;
            return const DashboardContribution(data: {'countNext7Days': 6});
          }),
          _CardModule(
            'requests',
            () async => DashboardContribution(
              data: {
                'counts': {'pending': 2},
              },
              alerts: [
                Alert(
                  id: 'seerr.failed',
                  severity: AlertSeverity.warning,
                  source: ServiceId.seerr,
                  feature: 'requests',
                  title: 'x',
                ),
                Alert(
                  id: 'dup',
                  severity: AlertSeverity.warning,
                  source: ServiceId.seerr,
                  feature: 'requests',
                  title: 'second',
                ),
                Alert(
                  id: 'vpn.down',
                  severity: AlertSeverity.error,
                  source: ServiceId.gluetun,
                  feature: 'activity',
                  title: 'VPN',
                ),
              ],
            ),
          ),
          _CardModule('library', () async => null),
        ],
      );
      addTearDown(hub.close);
      final r = await hub.get('/api/v1/dashboard', as: TestAs.member);
      expect(r.status, 200);
      final d = DashboardResponse.fromJson(r.map);
      expect(d.card('system')!.status, SectionState.ok);
      expect(d.card('system')!.data, {'cpuPercent': 3.5});
      expect(d.card('activity')!.status, SectionState.disabled);
      expect(d.card('media')!.error!.code, 'upstream_unavailable');
      expect(d.card('calendar')!.error!.code, 'upstream_timeout');
      expect(d.card('library'), isNull);
      expect(d.cards.containsKey('containers'), isFalse);
      expect(d.alerts.map((a) => a.id), [
        'vpn.down',
        'dup',
        'seerr.failed',
        'raid.noRedundancy',
      ]);
      expect(d.alerts.firstWhere((a) => a.id == 'dup').title, isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        slowFinished,
        isTrue,
        reason: 'the timed-out load continued in the background',
      );

      final some = DashboardResponse.fromJson(
        (await hub.get('/api/v1/dashboard?cards=system,requests')).map,
      );
      expect(some.cards.keys.toSet(), {'system', 'requests'});
      expect((await hub.get('/api/v1/dashboard?cards=bogus')).status, 400);
    });
  });

  group('audit log', () {
    test(
      'rotates at the size limit and keeps 5 files; queries newest first',
      () async {
        final dir = await Directory.systemTemp.createTemp('yams-hub-audit-');
        addTearDown(() => dir.delete(recursive: true));
        final clock = FakeClock();
        final log = AuditLog(
          dataDir: dir.path,
          clock: clock,
          maxBytes: 2000,
          keepFiles: 5,
        );
        for (var i = 0; i < 200; i++) {
          clock.advance(const Duration(seconds: 1));
          await log.record(
            action: 'test.action',
            target: 't$i',
            params: {'i': i},
          );
        }
        await log.flush();
        final files = dir
            .listSync()
            .map((f) => f.uri.pathSegments.last)
            .toSet();
        expect(
          files,
          containsAll(['audit.jsonl', 'audit.jsonl.1', 'audit.jsonl.5']),
        );
        expect(files, isNot(contains('audit.jsonl.6')));
        final page = await log.query(pageSize: 3);
        expect(page.items.map((e) => e.target), ['t199', 't198', 't197']);
        expect(page.hasMore, isTrue);
        final failing = await log.query(outcome: AuditOutcome.error);
        expect(failing.total, 0);
      },
    );
  });

  group('password hashing', () {
    test('format and verification', () {
      final h = PasswordHasher.hashSync('correct horse', minHashIterations);
      final parts = h.split(r'$');
      expect(parts[0], 'pbkdf2-sha256');
      expect(parts[1], '$minHashIterations');
      expect(parts[2], hasLength(22));
      expect(parts[3], hasLength(43));
      expect(PasswordHasher.verifySync('correct horse', h), isTrue);
      expect(PasswordHasher.verifySync('wrong horse', h), isFalse);
    });

    test('malformed hashes fail closed', () async {
      final good = PasswordHasher.hashSync('pw-pw-pw-pw', minHashIterations);
      final parts = good.split(r'$');
      for (final bad in [
        '',
        'pbkdf2-sha256',
        good.replaceFirst('pbkdf2-sha256', 'pbkdf2-sha1'),
        '${parts[0]}\$99999\$${parts[2]}\$${parts[3]}',
        '${parts[0]}\$6000000\$${parts[2]}\$${parts[3]}',
        '${parts[0]}\$abc\$${parts[2]}\$${parts[3]}',
        '${parts[0]}\$${parts[1]}\$${parts[2]}=\$${parts[3]}',
        '${parts[0]}\$${parts[1]}\$short\$${parts[3]}',
        '${parts[0]}\$${parts[1]}\$${parts[2]}\$${parts[3]}x',
        '\$${parts[1]}\$${parts[2]}\$${parts[3]}', // `$...` eaten by shell interpolation
      ]) {
        expect(PasswordHasher.parse(bad), isNull, reason: bad);
        expect(PasswordHasher.verifySync('pw-pw-pw-pw', bad), isFalse);
      }
      final hasher = PasswordHasher(iterations: minHashIterations);
      expect(
        await hasher.verify('pw-pw-pw-pw', 'garbage', subject: 'u'),
        isFalse,
      );
    });

    test(
      'auto-tune lowers the iteration count when one verify is slow',
      () async {
        final hasher = PasswordHasher(
          iterations: 600000,
          hashFunction: (pw, it) async =>
              PasswordHasher.hashSync(pw, minHashIterations),
          verifyFunction: (pw, stored) async {
            await Future<void>.delayed(const Duration(milliseconds: 1600));
            return false;
          },
        );
        final took = await hasher.autoTune();
        expect(took, greaterThan(slowVerifyThreshold));
        expect(hasher.iterations, fallbackIterations);
      },
    );
  });

  group('json file store', () {
    test('a failed write does not break later writes', () async {
      final dir = await Directory.systemTemp.createTemp('yams-hub-store-');
      addTearDown(() => dir.delete(recursive: true));
      // A regular file where the store's directory should be.
      final blocker = File('${dir.path}/sub')..writeAsStringSync('x');
      final store = JsonFileStore('${dir.path}/sub/doc.json');
      await expectLater(store.writeNow({'n': 1}), throwsA(anything));
      blocker.deleteSync();
      await store.writeNow({'n': 2});
      expect(File('${dir.path}/sub/doc.json').readAsStringSync(), '{"n":2}');
      store.write({'n': 3});
      await store.flush();
      expect(File('${dir.path}/sub/doc.json').readAsStringSync(), '{"n":3}');
    });
  });

  group('login limiter', () {
    test('known IPs are exempt from the per-username lock; bridge IPs skip the per-IP bucket', () async {
      final dir = await Directory.systemTemp.createTemp('yams-hub-lim-');
      addTearDown(() => dir.delete(recursive: true));
      final clock = FakeClock();
      final known = KnownIps(
        StoreFactory(dir.path).open('known_ips.json'),
        clock,
      );
      final limiter = LoginLimiter(clock, known);
      limiter.begin('admin', '192.168.10.20', userId: 'u_1').succeeded('u_1');
      // 50 failures from 50 outsiders lock the user name for everyone else...
      for (var i = 0; i < 50; i++) {
        limiter.begin('admin', '203.0.113.${i + 1}', userId: 'u_1').failed();
      }
      expect(
        () => limiter.begin('admin', '198.51.100.1', userId: 'u_1'),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 429)),
      );
      // ...but not for the admin's own device.
      limiter.begin('admin', '192.168.10.20', userId: 'u_1').succeeded('u_1');

      // 25 failures from the bridge gateway never lock the IP bucket.
      expect(LoginLimiter.isCollapsedIp('172.18.0.1'), isTrue);
      expect(LoginLimiter.isCollapsedIp('127.0.0.1'), isTrue);
      expect(LoginLimiter.isCollapsedIp('172.18.0.5'), isFalse);
      for (var i = 0; i < 25; i++) {
        limiter.begin('user$i', '172.18.0.1').failed();
      }
      limiter.begin('fresh', '172.18.0.1').cancel();

      // 20 failures from one normal IP lock that IP for an hour.
      for (var i = 0; i < 20; i++) {
        limiter.begin('name$i', '192.168.10.99').failed();
      }
      expect(
        () => limiter.begin('another', '192.168.10.99'),
        throwsA(isA<ApiException>()),
      );
      clock.advance(const Duration(minutes: 61));
      limiter.begin('another', '192.168.10.99').cancel();
    });

    test('a known-IP success never refunds another IP\'s failure', () async {
      final dir = await Directory.systemTemp.createTemp('yams-hub-lim-');
      addTearDown(() => dir.delete(recursive: true));
      final clock = FakeClock(); // every attempt has the same time stamp
      final limiter = LoginLimiter(
        clock,
        KnownIps(StoreFactory(dir.path).open('known_ips.json'), clock),
      );
      limiter.begin('admin', '192.168.10.20', userId: 'u_1').succeeded('u_1');
      for (var i = 0; i < 49; i++) {
        limiter.begin('admin', '203.0.113.${i + 1}', userId: 'u_1').failed();
      }
      // The admin's own device logs in between the outsiders' attempts.
      limiter.begin('admin', '192.168.10.20', userId: 'u_1').succeeded('u_1');
      limiter.begin('admin', '203.0.113.200', userId: 'u_1').failed();
      expect(
        () => limiter.begin('admin', '198.51.100.1', userId: 'u_1'),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 429)),
      );
    });

    test('refresh is limited to 30 per minute per IP', () {
      final clock = FakeClock();
      final limiter = LoginLimiter(
        clock,
        KnownIps(JsonFileStore('/nonexistent/known.json'), clock),
      );
      for (var i = 0; i < 30; i++) {
        limiter.checkRefresh('1.2.3.4');
      }
      expect(
        () => limiter.checkRefresh('1.2.3.4'),
        throwsA(isA<ApiException>()),
      );
      limiter.checkRefresh('1.2.3.5');
      clock.advance(const Duration(minutes: 1));
      limiter.checkRefresh('1.2.3.4');
    });
  });
}
