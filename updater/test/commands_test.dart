import 'package:test/test.dart';
import 'package:yams_hub_updater/yams_hub_updater.dart';

void main() {
  final commands = ComposeCommands(UpdaterConfig(token: 't' * 48));
  const base = [
    'docker',
    'compose',
    '-p',
    'yams',
    '--project-directory',
    '/opt/yams',
    '-f',
    '/opt/yams/docker-compose.yaml',
    '-f',
    '/opt/yams/docker-compose.custom.yaml',
  ];

  test('every compose call carries project, directory and both files', () {
    expect(commands.base, base);
    expect(commands.configServices(), [...base, 'config', '--services']);
  });

  test('update plan: pull, up --no-deps, prune', () {
    final plan = commands.updatePlan('sonarr');
    expect(
      [for (final s in plan) s.argv],
      [
        [...base, 'pull', '--', 'sonarr'],
        [...base, 'up', '-d', '--no-deps', '--', 'sonarr'],
        ['docker', 'image', 'prune', '-f'],
      ],
    );
    expect([for (final s in plan) s.optional], [false, false, true]);
    expect(plan.first.label, 'Pull sonarr');
  });

  test('gluetun also force-recreates qbittorrent', () {
    final plan = commands.updatePlan('gluetun');
    expect(
      [for (final s in plan) s.argv],
      [
        [...base, 'pull', '--', 'gluetun'],
        [...base, 'up', '-d', '--no-deps', '--', 'gluetun'],
        [
          ...base,
          'up',
          '-d',
          '--no-deps',
          '--force-recreate',
          '--',
          'qbittorrent',
        ],
        ['docker', 'image', 'prune', '-f'],
      ],
    );
  });

  test('the service always follows "--"', () {
    for (final step in commands.updatePlan('radarr').take(2)) {
      final i = step.argv.indexOf('--');
      expect(i, step.argv.length - 2);
      expect(step.argv.last, 'radarr');
    }
  });

  test('invalid service names never reach a command', () {
    expect(() => commands.updatePlan('--help'), throwsArgumentError);
    expect(() => commands.updatePlan('a;b'), throwsArgumentError);
  });

  test('recyclarr sync is a compile-time constant argument array', () {
    // Constant canonicalisation: `identical` holds only for a const list
    // with exactly these elements, so no runtime value can be part of it.
    expect(
      identical(recyclarrSyncCommand, const [
        'docker',
        'exec',
        'recyclarr',
        'recyclarr',
        'sync',
      ]),
      isTrue,
    );
    expect(
      identical(
        ComposeCommands.recyclarrSyncPlan.single.argv,
        recyclarrSyncCommand,
      ),
      isTrue,
    );
    // const lists are unmodifiable.
    expect(() => recyclarrSyncCommand.add('x'), throwsUnsupportedError);
  });

  test('custom project and files', () {
    final c = ComposeCommands(
      UpdaterConfig(
        token: 't' * 48,
        projectName: 'other',
        projectDir: '/srv/stack',
        composeFiles: ['/srv/stack/a.yaml'],
      ),
    );
    expect(c.base, [
      'docker',
      'compose',
      '-p',
      'other',
      '--project-directory',
      '/srv/stack',
      '-f',
      '/srv/stack/a.yaml',
    ]);
  });
}
