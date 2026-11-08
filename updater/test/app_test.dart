import 'dart:io';

import 'package:test/test.dart';
import 'package:yams_hub_updater/yams_hub_updater.dart';

import 'support/fake_process_runner.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('updater_app_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  String tokenFile(String token) {
    final f = File('${dir.path}/updater.env')
      ..writeAsStringSync("UPDATER_TOKEN='$token'\n");
    return f.path;
  }

  test(
    'refuses to start with a token under 32 bytes, without running anything',
    () async {
      final runner = FakeProcessRunner();
      final code = await runServe({
        'UPDATER_TOKEN_FILE': tokenFile('short-token'),
      }, runner: runner);
      expect(code, exitConfig);
      expect(runner.calls, isEmpty);
    },
  );

  test('refuses to start without a token file', () async {
    final runner = FakeProcessRunner();
    final code = await runServe({
      'UPDATER_TOKEN_FILE': '${dir.path}/missing.env',
      // An environment token is never a substitute.
      'UPDATER_TOKEN': 'x' * 48,
    }, runner: runner);
    expect(code, exitConfig);
    expect(runner.calls, isEmpty);
  });

  test('healthcheck fails when nothing listens', () async {
    final code = await runHealthcheck({
      'UPDATER_TOKEN_FILE': tokenFile('y' * 48),
      'UPDATER_PORT': '1',
    });
    expect(code, 1);
  });
}
