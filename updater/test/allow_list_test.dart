import 'package:test/test.dart';
import 'package:yams_hub_updater/yams_hub_updater.dart';

import 'support/fake_process_runner.dart';

void main() {
  final commands = ComposeCommands(UpdaterConfig(token: 't' * 48));

  ServiceAllowList make(FakeProcessRunner runner) => ServiceAllowList(
    runner: runner,
    configCommand: commands.configServices(),
    deny: parseDenyList(null),
  );

  test('loads compose services minus the deny-list, sorted', () async {
    final runner = FakeProcessRunner()
      ..composeServices([
        'sonarr',
        'yams-hub',
        'radarr',
        'socket-proxy-hub',
        'yams-hub-updater',
        'gluetun',
        '',
      ]);
    final list = make(runner);
    expect(await list.refresh(), isTrue);
    expect(list.services, ['gluetun', 'radarr', 'sonarr']);
    expect(list.allows('sonarr'), isTrue);
    expect(list.allows('yams-hub'), isFalse);
    expect(list.allows('yams-hub-updater'), isFalse);
    expect(list.allows('lidarr'), isFalse);
    expect(list.loadedAt, isNotNull);
    expect(runner.calls.single.argv, commands.configServices());
  });

  test('stderr lines and invalid names are not services', () async {
    final runner = FakeProcessRunner()
      ..on(
        'config --services',
        () => FakeReply(
          stdout: ['sonarr', 'WARN something', 'Bad Name'],
          stderr: ['WARN[0000] The "X" variable is not set'],
        ),
      );
    final list = make(runner);
    await list.refresh();
    expect(list.services, ['sonarr']);
  });

  test('a failed refresh keeps the previous list', () async {
    var fail = false;
    final runner = FakeProcessRunner()
      ..on(
        'config --services',
        () => fail
            ? FakeReply(exitCode: 1, stderr: ['no such file'])
            : FakeReply(stdout: ['sonarr', 'radarr']),
      );
    final list = make(runner);
    await list.refresh();
    fail = true;
    expect(await list.refresh(), isFalse);
    expect(list.services, ['radarr', 'sonarr']);
  });

  test('an empty listing does not wipe the list', () async {
    var empty = false;
    final runner = FakeProcessRunner()
      ..on(
        'config --services',
        () => FakeReply(stdout: empty ? const [] : ['sonarr']),
      );
    final list = make(runner);
    await list.refresh();
    empty = true;
    expect(await list.refresh(), isFalse);
    expect(list.services, ['sonarr']);
  });

  test('allowsFresh loads the list when it was never loaded', () async {
    var down = true;
    final runner = FakeProcessRunner()
      ..on(
        'config --services',
        () => down
            ? FakeReply(startError: 'cannot start docker')
            : FakeReply(stdout: ['sonarr']),
      );
    final list = make(runner);
    await list.refresh();
    expect(list.loadedAt, isNull);
    down = false;
    expect(await list.allowsFresh('sonarr'), isTrue);
    // Loaded now: a miss does not re-run compose.
    final calls = runner.calls.length;
    expect(await list.allowsFresh('lidarr'), isFalse);
    expect(runner.calls.length, calls);
  });

  test('allowsFresh never runs compose for denied or invalid names', () async {
    final runner = FakeProcessRunner()..composeServices(['sonarr']);
    final list = make(runner);
    expect(await list.allowsFresh('yams-hub'), isFalse);
    expect(await list.allowsFresh('../etc'), isFalse);
    expect(runner.calls, isEmpty);
  });

  test('concurrent refreshes share one compose run', () async {
    final runner = FakeProcessRunner()..composeServices(['sonarr']);
    final list = make(runner);
    await Future.wait([list.refresh(), list.refresh(), list.refresh()]);
    expect(runner.calls, hasLength(1));
  });

  test('start() refreshes immediately and stop() cancels the timer', () async {
    final runner = FakeProcessRunner()..composeServices(['sonarr']);
    final list = ServiceAllowList(
      runner: runner,
      configCommand: commands.configServices(),
      deny: const {},
      refreshInterval: const Duration(milliseconds: 20),
    );
    await list.start();
    expect(list.services, ['sonarr']);
    await Future<void>.delayed(const Duration(milliseconds: 70));
    list.stop();
    final n = runner.calls.length;
    expect(n, greaterThan(1));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(runner.calls.length, n);
  });
}
