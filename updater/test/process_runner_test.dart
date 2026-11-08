@TestOn('linux || mac-os')
library;

import 'package:test/test.dart';
import 'package:yams_hub_updater/yams_hub_updater.dart';

void main() {
  const runner = IoProcessRunner(killGrace: Duration(milliseconds: 200));

  test('streams stdout and stderr lines and reports the exit code', () async {
    final lines = <(OutputStream, String)>[];
    final r = await runner.run(
      ['sh', '-c', 'echo one; echo two >&2; printf "three\\r\\nfour"; exit 3'],
      timeout: const Duration(seconds: 10),
      onLine: (s, l) => lines.add((s, l)),
    );
    expect(r.exitCode, 3);
    expect(r.timedOut, isFalse);
    expect(r.succeeded, isFalse);
    expect(
      lines,
      containsAll([
        (OutputStream.stdout, 'one'),
        (OutputStream.stderr, 'two'),
        (OutputStream.stdout, 'three'),
        (OutputStream.stdout, 'four'),
      ]),
    );
  });

  test('arguments are passed verbatim, never through a shell', () async {
    final lines = <String>[];
    final r = await runner.run(
      ['printf', '%s\\n', r'$(id)', 'a;b', '`x`'],
      timeout: const Duration(seconds: 10),
      onLine: (_, l) => lines.add(l),
    );
    expect(r.succeeded, isTrue);
    expect(lines, [r'$(id)', 'a;b', '`x`']);
  });

  test('kills a command that runs past its timeout', () async {
    final sw = Stopwatch()..start();
    final r = await runner.run([
      'sleep',
      '30',
    ], timeout: const Duration(milliseconds: 200));
    expect(r.timedOut, isTrue);
    expect(r.succeeded, isFalse);
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
  });

  test('a missing executable is a start error, not an exception', () async {
    final r = await runner.run([
      '/nonexistent/docker',
      'ps',
    ], timeout: const Duration(seconds: 5));
    expect(r.exitCode, isNull);
    expect(r.startError, contains('/nonexistent/docker'));
    expect(r.succeeded, isFalse);
  });

  test('compose output is requested plain and uncoloured', () async {
    final lines = <String>[];
    await runner.run(
      ['sh', '-c', r'echo "$COMPOSE_ANSI $COMPOSE_PROGRESS $NO_COLOR"'],
      timeout: const Duration(seconds: 5),
      onLine: (_, l) => lines.add(l),
    );
    expect(lines, ['never plain 1']);
  });
}
