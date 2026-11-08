import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:yams_hub_updater/yams_hub_updater.dart';

import 'support/fake_process_runner.dart';

const _token = 'test-updater-token-0123456789abcdef0123';

final class _Harness {
  _Harness({List<String>? services}) {
    runner.composeServices(
      services ??
          [
            'sonarr',
            'radarr',
            'gluetun',
            'qbittorrent',
            'recyclarr',
            'yams-hub',
            'socket-proxy-hub',
            'yams-hub-updater',
          ],
    );
    allowList = ServiceAllowList(
      runner: runner,
      configCommand: commands.configServices(),
      deny: config.deny,
    );
    jobs = JobManager(runner: runner, stepTimeout: config.stepTimeout);
    handler = buildUpdaterHandler(
      auth: BearerAuth(config.token),
      allowList: allowList,
      jobs: jobs,
      commands: commands,
    );
  }

  final runner = FakeProcessRunner();
  final config = UpdaterConfig(token: _token);
  late final commands = ComposeCommands(config);
  late final ServiceAllowList allowList;
  late final JobManager jobs;
  late final Handler handler;

  Future<Response> send(
    String method,
    String path, {
    String? token = _token,
    String? body,
  }) async => handler(
    Request(
      method,
      Uri.parse('http://yams-hub-updater:8080$path'),
      headers: {if (token != null) 'authorization': 'Bearer $token'},
      body: body,
    ),
  );

  /// Sends and decodes the JSON body.
  Future<(int, Map<String, Object?>)> json(
    String method,
    String path, {
    String? token = _token,
    String? body,
  }) async {
    final r = await send(method, path, token: token, body: body);
    expect(r.headers['content-type'], startsWith('application/json'));
    return (
      r.statusCode,
      jsonDecode(await r.readAsString()) as Map<String, Object?>,
    );
  }

  Future<Map<String, Object?>> waitForJob(String id) async {
    await jobs[id]!.done;
    final (status, body) = await json('GET', '/jobs/$id');
    expect(status, 200);
    return body;
  }
}

void main() {
  late _Harness h;
  setUp(() async {
    h = _Harness();
    await h.allowList.refresh();
    h.runner.calls.clear();
  });

  group('auth', () {
    for (final (method, path) in [
      ('GET', '/healthz'),
      ('GET', '/services'),
      ('POST', '/update/sonarr'),
      ('POST', '/exec/recyclarr-sync'),
      ('GET', '/jobs/j_0123456789abcdef'),
      ('GET', '/does-not-exist'),
      ('DELETE', '/update/sonarr'),
      ('GET', '/'),
    ]) {
      test('$method $path without the token is 401', () async {
        for (final token in [null, 'wrong-token', '${_token}x', '']) {
          final r = await h.send(method, path, token: token);
          expect(r.statusCode, 401, reason: 'token=$token');
          expect(r.headers['www-authenticate'], 'Bearer');
        }
        final r = await h.handler(
          Request(
            method,
            Uri.parse('http://u$path'),
            headers: const {'authorization': 'Basic $_token'},
          ),
        );
        expect(r.statusCode, 401);
        expect(h.runner.calls, isEmpty);
      });
    }

    test('unknown paths with the token are a JSON 404', () async {
      final (status, body) = await h.json('GET', '/does-not-exist');
      expect(status, 404);
      expect(body['error'], 'not_found');
    });
  });

  test('GET /healthz', () async {
    final (status, body) = await h.json('GET', '/healthz');
    expect(status, 200);
    expect(body, {'status': 'ok', 'version': updaterVersion});
  });

  test('GET /services is the allow-list minus the deny-list', () async {
    final (status, body) = await h.json('GET', '/services');
    expect(status, 200);
    expect(body, {
      'services': ['gluetun', 'qbittorrent', 'radarr', 'recyclarr', 'sonarr'],
    });
  });

  test('GET /services loads the allow-list when start-up failed', () async {
    final fresh = _Harness(services: ['sonarr', 'yams-hub']);
    final (status, body) = await fresh.json('GET', '/services');
    expect(status, 200);
    expect(body, {
      'services': ['sonarr'],
    });
    expect(fresh.runner.lines.single, endsWith('config --services'));
    // Loaded once: later calls use the cached list.
    await fresh.json('GET', '/services');
    expect(fresh.runner.calls, hasLength(1));
  });

  group('POST /update/{service}', () {
    test('202 with a job id, then the job runs pull, up and prune', () async {
      final (status, body) = await h.json('POST', '/update/sonarr');
      expect(status, 202);
      final id = body['jobId']! as String;
      expect(id, matches(RegExp(r'^j_[0-9a-f]{16}$')));

      final job = await h.waitForJob(id);
      expect(job['state'], 'succeeded');
      expect(job['service'], 'sonarr');
      expect(h.runner.lines, [
        'docker compose -p yams --project-directory /opt/yams '
            '-f /opt/yams/docker-compose.yaml -f /opt/yams/docker-compose.custom.yaml '
            'pull -- sonarr',
        'docker compose -p yams --project-directory /opt/yams '
            '-f /opt/yams/docker-compose.yaml -f /opt/yams/docker-compose.custom.yaml '
            'up -d --no-deps -- sonarr',
        'docker image prune -f',
      ]);
      final steps = job['steps']! as List<Object?>;
      expect(steps, hasLength(3));
      for (final s in steps.cast<Map<String, Object?>>()) {
        expect(
          s.keys,
          containsAll(['cmd', 'exitCode', 'startedAt', 'finishedAt']),
        );
        expect(s['exitCode'], 0);
      }
      expect(
        job.keys,
        containsAll([
          'id',
          'service',
          'state',
          'steps',
          'log',
          'startedAt',
          'finishedAt',
        ]),
      );
    });

    test('gluetun also force-recreates qbittorrent', () async {
      final (_, body) = await h.json('POST', '/update/gluetun');
      await h.waitForJob(body['jobId']! as String);
      expect(
        h.runner.lines.map(
          (l) => l.split(' -f /opt/yams/docker-compose.custom.yaml ').last,
        ),
        [
          'pull -- gluetun',
          'up -d --no-deps -- gluetun',
          'up -d --no-deps --force-recreate -- qbittorrent',
          'docker image prune -f',
        ],
      );
    });

    test('denied services are 404 and run nothing', () async {
      for (final s in ['yams-hub', 'yams-hub-updater', 'socket-proxy-hub']) {
        final (status, body) = await h.json('POST', '/update/$s');
        expect(status, 404, reason: s);
        expect(body['error'], 'not_found');
      }
      expect(h.runner.calls, isEmpty);
    });

    test('unknown or invalid services are 404 and run nothing', () async {
      for (final s in [
        'lidarr',
        'Sonarr',
        '-p',
        '--help',
        '..',
        '.',
        'sonarr%20radarr',
        'sonarr;reboot',
        'sonarr%2Fx',
        'x' * 65,
      ]) {
        final r = await h.send('POST', '/update/$s');
        expect(r.statusCode, 404, reason: s);
      }
      expect(h.runner.calls, isEmpty);
    });

    test('the request body is ignored', () async {
      final (status, body) = await h.json(
        'POST',
        '/update/sonarr',
        body: jsonEncode({
          'service': 'yams-hub',
          'args': ['--force-recreate'],
        }),
      );
      expect(status, 202);
      final job = await h.waitForJob(body['jobId']! as String);
      expect(job['service'], 'sonarr');
      expect(h.runner.lines.join('\n'), isNot(contains('yams-hub ')));
      expect(h.runner.lines.join('\n'), isNot(contains('--force-recreate')));
    });

    test('409 while another job runs', () async {
      final gate = Completer<void>();
      h.runner.on(' pull ', () => FakeReply(gate: gate));
      final (_, first) = await h.json('POST', '/update/sonarr');
      final (status, body) = await h.json('POST', '/update/radarr');
      expect(status, 409);
      expect(body['error'], 'busy');
      expect(body['jobId'], first['jobId']);
      final (syncStatus, _) = await h.json('POST', '/exec/recyclarr-sync');
      expect(syncStatus, 409);

      await Future<void>.delayed(Duration.zero);
      final (_, running) = await h.json('GET', '/jobs/${first['jobId']}');
      expect(running['state'], 'running');
      // Only the step that is running so far (the gateway mirrors each entry as it appears).
      final runningSteps = running['steps']! as List<Object?>;
      expect(runningSteps, hasLength(1));
      expect((runningSteps.single! as Map)['exitCode'], isNull);
      expect(running['stepCount'], 3);
      gate.complete();
      await h.waitForJob(first['jobId']! as String);
      final (again, _) = await h.json('POST', '/update/radarr');
      expect(again, 202);
    });

    test(
      '503 once the updater is shutting down; job status still answers',
      () async {
        final gate = Completer<void>();
        h.runner.on(' pull ', () => FakeReply(gate: gate));
        final (_, first) = await h.json('POST', '/update/sonarr');
        await Future<void>.delayed(Duration.zero);
        final closing = h.jobs.close(timeout: const Duration(seconds: 5));
        final (status, body) = await h.json('POST', '/update/radarr');
        expect(status, 503);
        expect(body['error'], 'shutting_down');
        final (syncStatus, _) = await h.json('POST', '/exec/recyclarr-sync');
        expect(syncStatus, 503);
        final (jobStatus, running) = await h.json(
          'GET',
          '/jobs/${first['jobId']}',
        );
        expect(jobStatus, 200);
        expect(running['state'], 'running');
        gate.complete();
        expect(await closing, isTrue);
        final (_, ended) = await h.json('GET', '/jobs/${first['jobId']}');
        expect(ended['state'], 'failed');
        expect(ended['error'], 'updater shut down before Recreate sonarr');
      },
    );

    test('a failed pull reports the failure and stops', () async {
      h.runner.on(
        ' pull ',
        () => FakeReply(exitCode: 1, stderr: ['pull access denied']),
      );
      final (_, body) = await h.json('POST', '/update/sonarr');
      final job = await h.waitForJob(body['jobId']! as String);
      expect(job['state'], 'failed');
      expect(job['log'], contains('pull access denied'));
      expect(h.runner.calls, hasLength(1));
    });

    test('loads the allow-list on demand when start-up failed', () async {
      final fresh = _Harness();
      final (status, _) = await fresh.json('POST', '/update/sonarr');
      expect(status, 202);
      expect(fresh.runner.lines.first, endsWith('config --services'));
    });
  });

  group('POST /exec/recyclarr-sync', () {
    test('runs exactly the constant argument array', () async {
      final (status, body) = await h.json(
        'POST',
        '/exec/recyclarr-sync?cmd=rm&args=-rf',
        body: '{"command":["sh","-c","id"],"container":"sonarr"}',
      );
      expect(status, 202);
      final job = await h.waitForJob(body['jobId']! as String);
      expect(job['state'], 'succeeded');
      expect(job['service'], 'recyclarr');
      expect(job['kind'], 'recyclarr-sync');
      expect(h.runner.calls, hasLength(1));
      expect(
        identical(h.runner.calls.single.argv, recyclarrSyncCommand),
        isTrue,
      );
      expect(h.runner.calls.single.argv, [
        'docker',
        'exec',
        'recyclarr',
        'recyclarr',
        'sync',
      ]);
    });

    test('GET is not routed', () async {
      final r = await h.send('GET', '/exec/recyclarr-sync');
      expect(r.statusCode, 404);
      expect(h.runner.calls, isEmpty);
    });
  });

  group('GET /jobs/{id}', () {
    test('unknown and malformed ids are 404', () async {
      for (final id in ['j_doesnotexist', 'nope', '..', 'j_%2E%2E']) {
        final r = await h.send('GET', '/jobs/$id');
        expect(r.statusCode, 404, reason: id);
      }
    });
  });

  test('request bodies, queries and tokens are never logged', () async {
    final records = <String>[];
    final previous = Logger.root.level;
    Logger.root.level = Level.ALL;
    final sub = Logger.root.onRecord.listen((r) => records.add(r.message));
    addTearDown(() async {
      await sub.cancel();
      Logger.root.level = previous;
    });

    const secretBody = '{"password":"s3cret-body-value"}';
    final (_, body) = await h.json(
      'POST',
      '/update/sonarr?q=s3cret-query-value',
      body: secretBody,
    );
    await h.waitForJob(body['jobId']! as String);
    await h.send('GET', '/healthz', token: 'wrong-s3cret-token');

    final all = records.join('\n');
    expect(all, contains('POST /update/sonarr 202'));
    expect(all, contains('GET /healthz 401'));
    expect(all, isNot(contains('s3cret')));
    expect(all, isNot(contains(_token)));
  });

  test('unexpected handler errors are a JSON 500 without details', () async {
    final failing = buildUpdaterHandler(
      auth: BearerAuth(_token),
      allowList: _ThrowingAllowList(h.runner, h.commands),
      jobs: h.jobs,
      commands: h.commands,
    );
    final r = await failing(
      Request(
        'POST',
        Uri.parse('http://u/update/sonarr'),
        headers: const {'authorization': 'Bearer $_token'},
      ),
    );
    expect(r.statusCode, 500);
    expect(jsonDecode(await r.readAsString()), {
      'error': 'internal',
      'message': 'Internal error',
    });
  });
}

final class _ThrowingAllowList extends ServiceAllowList {
  _ThrowingAllowList(FakeProcessRunner runner, ComposeCommands commands)
    : super(
        runner: runner,
        configCommand: commands.configServices(),
        deny: const {},
      );

  @override
  Future<bool> allowsFresh(String service) =>
      Future.error(StateError('boom with private detail'));
}
