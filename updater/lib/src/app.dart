/// `serve` and `healthcheck` commands.
library;

import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'allow_list.dart';
import 'auth.dart';
import 'commands.dart';
import 'config.dart';
import 'jobs.dart';
import 'process_runner.dart';
import 'server.dart';
import 'version.dart';

/// Exit code for an invalid configuration (sysexits `EX_CONFIG`).
const exitConfig = 78;

final _log = Logger('updater');

/// Loads the configuration, or prints why it cannot (never a secret) and
/// returns null.
UpdaterConfig? loadConfig(Map<String, String> env, IOSink err) {
  if ((env['UPDATER_TOKEN'] ?? '').isNotEmpty) {
    err.writeln(
      'warning: UPDATER_TOKEN in the environment is ignored; '
      'the token is read only from UPDATER_TOKEN_FILE',
    );
  }
  try {
    return UpdaterConfig.fromEnvironment(
      env,
      readFile: (p) => File(p).readAsStringSync(),
    );
  } on UpdaterConfigException catch (e) {
    err.writeln('yams-hub-updater: ${e.message}; refusing to start');
    return null;
  }
}

/// Routes `package:logging` records to stdout (the container log).
void configureLogging(Map<String, String> env) {
  final level = switch ((env['UPDATER_LOG_LEVEL'] ?? 'info').toLowerCase()) {
    'fine' || 'debug' => Level.FINE,
    'warning' => Level.WARNING,
    'severe' => Level.SEVERE,
    _ => Level.INFO,
  };
  Logger.root.level = level;
  Logger.root.onRecord.listen((r) {
    final b = StringBuffer()
      ..write(r.time.toUtc().toIso8601String())
      ..write(' ')
      ..write(r.level.name)
      ..write(' ')
      ..write(r.loggerName)
      ..write(': ')
      ..write(r.message);
    if (r.stackTrace != null) b.write('\n${r.stackTrace}');
    stdout.writeln(b);
  });
}

/// Runs the server until SIGTERM/SIGINT. Returns the process exit code.
Future<int> runServe(Map<String, String> env, {ProcessRunner? runner}) async {
  configureLogging(env);
  final config = loadConfig(env, stderr);
  if (config == null) return exitConfig;

  final processes = runner ?? const IoProcessRunner();
  final commands = ComposeCommands(config);
  final allowList = ServiceAllowList(
    runner: processes,
    configCommand: commands.configServices(),
    deny: config.deny,
    refreshInterval: config.allowListRefresh,
  );
  final jobs = JobManager(runner: processes, stepTimeout: config.stepTimeout);
  final handler = buildUpdaterHandler(
    auth: BearerAuth(config.token),
    allowList: allowList,
    jobs: jobs,
    commands: commands,
  );

  _log.info('yams-hub-updater $updaterVersion starting: $config');
  await allowList.start();

  final server =
      await shelf_io.serve(handler, InternetAddress.anyIPv4, config.port)
        ..autoCompress = false
        ..idleTimeout = const Duration(seconds: 30);
  _log.info('listening on 0.0.0.0:${server.port}');

  final stopped = Completer<void>();
  final subs = <StreamSubscription<ProcessSignal>>[];
  void shutdown(ProcessSignal signal) {
    if (stopped.isCompleted) return;
    _log.info('${signal.name} received; shutting down');
    allowList.stop();
    final running = jobs.active;
    if (running != null) {
      _log.warning(
        'job ${running.id} (${running.service}) is still running; it is abandoned',
      );
    }
    stopped.complete();
  }

  subs.add(ProcessSignal.sigint.watch().listen(shutdown));
  if (!Platform.isWindows) {
    subs.add(ProcessSignal.sigterm.watch().listen(shutdown));
  }
  await stopped.future;
  await server.close();
  for (final s in subs) {
    await s.cancel();
  }
  return 0;
}

/// `healthcheck`: `GET http://127.0.0.1:$UPDATER_PORT/healthz` with the
/// token; 0 on 200 (Docker `HEALTHCHECK`; the image has no shell or curl).
Future<int> runHealthcheck(Map<String, String> env) async {
  final config = loadConfig(env, stderr);
  if (config == null) return exitConfig;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client
        .getUrl(Uri.parse('http://127.0.0.1:${config.port}/healthz'))
        .timeout(const Duration(seconds: 5));
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${config.token}',
    );
    final response = await request.close().timeout(const Duration(seconds: 5));
    await response.drain<void>();
    return response.statusCode == 200 ? 0 : 1;
  } on Object catch (e) {
    stderr.writeln('healthcheck failed (${e.runtimeType})');
    return 1;
  } finally {
    client.close(force: true);
  }
}
