/// `yams-hub`: serve | hash-password | healthcheck | check-config |
/// reset-admin (ARCHITECTURE §5.1).
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:yams_hub_gateway/yams_hub_gateway.dart';

Future<void> main(List<String> arguments) async {
  // Every file the gateway creates under $DATA is 0600/0700.
  setUmask(0x3F); // 077

  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.')
    ..addCommand('serve')
    ..addCommand(
      'hash-password',
      ArgParser()..addOption(
        'iterations',
        help: 'PBKDF2 iterations (default: policy value)',
      ),
    )
    ..addCommand('healthcheck')
    ..addCommand('check-config')
    ..addCommand('reset-admin');

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(_usage(parser));
    exit(2);
  }
  if (args['help'] == true) {
    stdout.writeln(_usage(parser));
    exit(0);
  }

  final env = Platform.environment;
  final command = args.command;
  final int code;
  switch (command?.name ?? 'serve') {
    case 'serve':
      code = await runServe(env);
    case 'hash-password':
      final raw = command?['iterations'] as String?;
      final iterations = raw == null ? null : int.tryParse(raw);
      if (raw != null && iterations == null) {
        stderr.writeln('--iterations must be an integer');
        exit(2);
      }
      code = await runHashPassword(env, iterations: iterations);
    case 'healthcheck':
      code = await runHealthcheck(env);
    case 'check-config':
      code = await runCheckConfig(env, stdout);
    case 'reset-admin':
      code = await runResetAdmin(env, stdout);
    default:
      stderr.writeln(_usage(parser));
      code = 2;
  }
  await stdout.flush();
  exit(code);
}

String _usage(ArgParser parser) =>
    'Usage: yams-hub [serve | hash-password [--iterations N] | healthcheck | '
    'check-config | reset-admin]\n${parser.usage}';
