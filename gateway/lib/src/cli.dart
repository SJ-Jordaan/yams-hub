/// The `yams-hub` commands (ARCHITECTURE §5.1).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:yams_models/yams_models.dart';

import 'app.dart';
import 'config/config.dart';
import 'core/audit/audit_log.dart';
import 'core/auth/access_tokens.dart';
import 'core/auth/auth_service.dart';
import 'core/auth/login_limiter.dart';
import 'core/auth/password_hasher.dart';
import 'core/auth/session_store.dart';
import 'core/auth/user_store.dart';
import 'core/clock.dart';
import 'core/log/log.dart';
import 'core/store/json_file_store.dart';
import 'version.dart';

final _log = Logger('hub.cli');

/// `serve`: runs until SIGTERM/SIGINT, then stops accepting, waits up to
/// 10 s for in-flight requests, stops the modules and flushes the stores.
Future<int> runServe(Map<String, String> env) async {
  final HubConfig config;
  try {
    config = ConfigLoader.loadFromSystem(env);
  } on ConfigException catch (e) {
    stderr.writeln('yams-hub: invalid configuration:');
    for (final err in e.errors) {
      stderr.writeln('  - $err');
    }
    return 1;
  }
  configureLogging(config.logLevel);
  for (final w in config.warnings) {
    _log.warning(w);
  }
  if (!config.secretsFileFound) {
    _log.warning(
      'secrets file ${config.secretsFile} not found; only the environment is used',
    );
  }
  final hub = await Hub.create(config, autoTune: true);
  await hub.start();
  final server = await shelf_io.serve(
    hub.handler,
    InternetAddress.anyIPv4,
    config.port,
  );
  server.autoCompress = false;
  _log.info('yams-hub $hubVersion listening on 0.0.0.0:${config.port}');

  final done = Completer<void>();
  final subs = <StreamSubscription<ProcessSignal>>[];
  Future<void> shutdown(ProcessSignal signal) async {
    if (done.isCompleted) return;
    _log.info('received ${signal.name}; shutting down');
    try {
      await server.close().timeout(const Duration(seconds: 10));
    } on TimeoutException {
      await server.close(force: true);
    }
    await hub.stop();
    done.complete();
  }

  subs.add(ProcessSignal.sigint.watch().listen(shutdown));
  if (!Platform.isWindows) {
    subs.add(ProcessSignal.sigterm.watch().listen(shutdown));
  }
  await done.future;
  for (final s in subs) {
    await s.cancel();
  }
  return 0;
}

/// `healthcheck`: `GET http://127.0.0.1:$PORT/api/v1/ping`, 0 on 200.
Future<int> runHealthcheck(Map<String, String> env) async {
  final port = int.tryParse(env['YAMS_HUB_PORT'] ?? '') ?? 8080;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client
        .getUrl(Uri.parse('http://127.0.0.1:$port/api/v1/ping'))
        .timeout(const Duration(seconds: 4));
    final res = await req.close().timeout(const Duration(seconds: 4));
    await res.drain<void>();
    return res.statusCode == 200 ? 0 : 1;
  } on Object {
    return 1;
  } finally {
    client.close(force: true);
  }
}

/// `hash-password`: reads a password from stdin (no echo on a TTY, entered
/// twice) and prints its hash.
Future<int> runHashPassword(Map<String, String> env, {int? iterations}) async {
  var iter = iterations;
  if (iter == null) {
    try {
      iter = ConfigLoader.loadFromSystem(env).auth.pbkdf2Iterations;
    } on ConfigException {
      iter = const AuthSettings().pbkdf2Iterations;
    }
  }
  if (iter < minHashIterations || iter > maxHashIterations) {
    stderr.writeln(
      'iterations must be between $minHashIterations and $maxHashIterations',
    );
    return 2;
  }
  final String password;
  if (stdin.hasTerminal) {
    stdin.echoMode = false;
    try {
      stderr.write('Password: ');
      final a = stdin.readLineSync() ?? '';
      stderr.write('\nRepeat:   ');
      final b = stdin.readLineSync() ?? '';
      stderr.writeln();
      if (a != b) {
        stderr.writeln('The passwords do not match.');
        return 1;
      }
      password = a;
    } finally {
      stdin.echoMode = true;
    }
  } else {
    password = stdin.readLineSync(encoding: utf8) ?? '';
  }
  if (password.length < 10) {
    stderr.writeln('The password must have at least 10 characters.');
    return 1;
  }
  stdout.writeln(PasswordHasher.hashSync(password, iter));
  return 0;
}

/// `check-config`: loads the environment and the secrets file, prints which
/// services are configured and from which source (never values), the
/// Jellyfin admin user id mode, the PBKDF2 timing and every error. Returns 1
/// for an invalid configuration.
Future<int> runCheckConfig(
  Map<String, String> env,
  StringSink out, {
  PasswordHasher? hasher,
  String? secretsFileContents,
  bool readFiles = true,
}) async {
  final HubConfig config;
  try {
    config = readFiles
        ? ConfigLoader.loadFromSystem(env)
        : ConfigLoader.load(env, secretsFileContents: secretsFileContents);
  } on ConfigException catch (e) {
    out.writeln('Configuration: INVALID');
    for (final err in e.errors) {
      out.writeln('  error: $err');
    }
    return 1;
  }
  out.writeln('yams-hub $hubVersion: configuration OK');
  out.writeln(
    'Secrets file: ${config.secretsFile} '
    '(${config.secretsFileFound ? 'found' : 'not found; environment only'})',
  );
  out.writeln(
    'Policy file:  ${config.configFile} '
    '(${config.policyFileFound ? 'found' : 'not found; defaults'})',
  );
  out.writeln('Data dir:     ${config.dataDir}');
  out.writeln('Port:         ${config.port}');
  out.writeln('Services:');
  for (final id in ServiceId.values) {
    if (id == ServiceId.unknown || id == ServiceId.host) continue;
    final s = config.service(id);
    final parts = <String>[
      'url: ${s.url == null ? 'unset' : s.urlSource.label}',
      for (final name in s.requiredSecrets)
        '${_short(name)}: ${_sourceOf(config, name)}',
    ];
    final state = s.configured
        ? 'configured'
        : s.url == null
        ? 'not configured (no URL)'
        : 'not configured (missing ${s.missingSecrets.join(', ')})';
    out.writeln('  ${id.name.padRight(15)} $state  [${parts.join(', ')}]');
  }
  out.writeln(
    'JELLYFIN_ADMIN_USER_ID: ${config.jellyfinAdminUserId == null ? 'auto-detected (first enabled Jellyfin administrator)' : 'set (${_sourceOf(config, 'JELLYFIN_ADMIN_USER_ID')})'}',
  );
  final bootstrap = config.adminPasswordHash;
  out.writeln(
    'Bootstrap admin: ${config.adminUsername}, hash '
    '${bootstrap == null ? 'not set' : (PasswordHasher.parse(bootstrap) == null ? 'MALFORMED (never verifies)' : 'set (${_sourceOf(config, 'YAMS_HUB_ADMIN_PASSWORD_HASH')})')}',
  );
  out.writeln(
    'CORS origins: ${config.corsOrigins.isEmpty ? 'none' : config.corsOrigins.join(', ')}',
  );
  out.writeln(
    'Discord alerts: ${config.discordAlertWebhookUrl == null ? 'off (DISCORD_ALERT_WEBHOOK_URL ${config.sources.containsKey('DISCORD_ALERT_WEBHOOK_URL') ? 'invalid or empty' : 'not set'})' : 'on (${_sourceOf(config, 'DISCORD_ALERT_WEBHOOK_URL')})'}',
  );
  final h = hasher ?? PasswordHasher(iterations: config.auth.pbkdf2Iterations);
  final took = await h.autoTune();
  out.writeln(
    'PBKDF2: one verification at ${h.configuredIterations} iterations took '
    '${took.inMilliseconds} ms; new hashes use ${h.iterations} iterations',
  );
  for (final w in config.warnings) {
    out.writeln('  warning: $w');
  }
  return 0;
}

String _short(String variable) {
  if (variable.endsWith('_API_KEY')) return 'key';
  if (variable.endsWith('_TOKEN')) return 'token';
  if (variable.endsWith('_USERNAME')) return 'username';
  if (variable.endsWith('_PASSWORD')) return 'password';
  return variable.toLowerCase();
}

String _sourceOf(HubConfig config, String variable) {
  final src = config.sources[variable];
  return src == null ? 'missing' : src.label;
}

/// `reset-admin`: replaces the admin's password with
/// `YAMS_HUB_ADMIN_PASSWORD_HASH` and revokes all sessions. Refuses while the
/// gateway answers on its port (its in-memory stores would overwrite the
/// change).
Future<int> runResetAdmin(Map<String, String> env, StringSink out) async {
  final HubConfig config;
  try {
    config = ConfigLoader.loadFromSystem(env);
  } on ConfigException catch (e) {
    out.writeln('invalid configuration: ${e.errors.join('; ')}');
    return 1;
  }
  if (await runHealthcheck({'YAMS_HUB_PORT': '${config.port}'}) == 0) {
    out.writeln(
      'The gateway is running on port ${config.port}; stop it first, then run reset-admin.',
    );
    return 1;
  }
  const clock = SystemClock();
  final stores = StoreFactory(config.dataDir);
  final users = UserStore(stores.open('users.json'));
  final audit = AuditLog(dataDir: config.dataDir, clock: clock);
  final auth = AuthService(
    config: config,
    users: users,
    sessions: SessionStore(stores.open('sessions.json'), clock),
    tokens: AccessTokenIndex(clock),
    hasher: PasswordHasher(iterations: config.auth.pbkdf2Iterations),
    limiter: LoginLimiter(
      clock,
      KnownIps(stores.open('known_ips.json'), clock),
    ),
    audit: audit,
    clock: clock,
  );
  try {
    final admin = await auth.resetAdmin();
    await stores.closeAll();
    out.writeln('Password of "${admin.username}" reset; all sessions revoked.');
    return 0;
  } on ConfigException catch (e) {
    out.writeln(e.errors.join('; '));
    return 1;
  }
}
