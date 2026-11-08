/// `yams-hub-updater`: serve | healthcheck (ARCHITECTURE §5.17).
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:yams_hub_updater/yams_hub_updater.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.')
    ..addFlag('version', negatable: false, help: 'Print the version.')
    ..addCommand('serve')
    ..addCommand('healthcheck');

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr
      ..writeln(e.message)
      ..writeln(_usage(parser));
    exit(2);
  }
  if (args.flag('help')) {
    stdout.writeln(_usage(parser));
    exit(0);
  }
  if (args.flag('version')) {
    stdout.writeln(updaterVersion);
    exit(0);
  }

  final env = Platform.environment;
  final code = switch (args.command?.name ?? 'serve') {
    'serve' => await runServe(env),
    'healthcheck' => await runHealthcheck(env),
    _ => 2,
  };
  await stdout.flush();
  exit(code);
}

String _usage(ArgParser parser) =>
    'Usage: yams-hub-updater [serve | healthcheck]\n'
    'Environment: UPDATER_TOKEN_FILE (default ${UpdaterConfig.defaultTokenFile}), '
    'UPDATER_PORT (8080), UPDATER_DENY (${defaultDenyList.join(',')}), '
    'UPDATER_LOG_LEVEL (info)\n${parser.usage}';
