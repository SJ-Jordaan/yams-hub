/// Every command the updater can run (ARCHITECTURE §5.17).
///
/// Commands are argument arrays handed to `Process.start` (never a shell).
/// Request data reaches them only as the validated, allow-listed `{service}`,
/// always after `--` so it can never be read as an option.
library;

import 'config.dart';

/// `POST /exec/recyclarr-sync` runs exactly this. It is a compile-time
/// constant: no request data can reach it.
const recyclarrSyncCommand = <String>[
  'docker',
  'exec',
  'recyclarr',
  'recyclarr',
  'sync',
];

/// Removes dangling images only (mirrors `WATCHTOWER_CLEANUP`).
const imagePruneCommand = <String>['docker', 'image', 'prune', '-f'];

/// Services whose network namespace is gluetun's: recreated after gluetun.
const gluetunDependants = <String>['qbittorrent'];

/// One step of a job.
final class StepSpec {
  const StepSpec(
    this.label,
    this.argv, {
    this.optional = false,
    this.changesStack = true,
  });

  /// Short human label ("Pull sonarr").
  final String label;
  final List<String> argv;

  /// A failing optional step is logged but does not fail the job (used for
  /// the final image prune: the update itself already succeeded).
  final bool optional;

  /// Whether the step changes running containers. A pull does not: when the
  /// updater shuts down after a pull, the job stops there and the stack is
  /// untouched. Once a step that changes the stack has started, the job's
  /// remaining required steps still run during shutdown (gluetun's
  /// dependants must follow it).
  final bool changesStack;
}

/// Builds the compose command lines for the configured project.
final class ComposeCommands {
  ComposeCommands(UpdaterConfig config)
    : base = List.unmodifiable([
        'docker',
        'compose',
        '-p',
        config.projectName,
        '--project-directory',
        config.projectDir,
        for (final f in config.composeFiles) ...['-f', f],
      ]);

  /// `docker compose -p yams --project-directory /opt/yams -f ... -f ...`.
  final List<String> base;

  /// Lists the services of the merged compose files (active profiles only).
  List<String> configServices() => [...base, 'config', '--services'];

  List<String> pull(String service) => [...base, 'pull', '--', service];

  List<String> up(String service) => [
    ...base,
    'up',
    '-d',
    '--no-deps',
    '--',
    service,
  ];

  List<String> forceRecreate(String service) => [
    ...base,
    'up',
    '-d',
    '--no-deps',
    '--force-recreate',
    '--',
    service,
  ];

  /// The steps of `POST /update/{service}`. [service] must already be
  /// validated and allow-listed.
  List<StepSpec> updatePlan(String service) {
    if (!isValidServiceName(service)) {
      throw ArgumentError.value(service, 'service', 'invalid service name');
    }
    return [
      StepSpec('Pull $service', pull(service), changesStack: false),
      StepSpec('Recreate $service', up(service)),
      if (service == 'gluetun')
        for (final dependant in gluetunDependants)
          StepSpec('Recreate $dependant', forceRecreate(dependant)),
      const StepSpec(
        'Prune dangling images',
        imagePruneCommand,
        optional: true,
        changesStack: false,
      ),
    ];
  }

  /// The single step of `POST /exec/recyclarr-sync`.
  static const recyclarrSyncPlan = [
    StepSpec('Recyclarr sync', recyclarrSyncCommand),
  ];
}
