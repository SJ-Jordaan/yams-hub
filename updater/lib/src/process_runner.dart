/// Runs commands as argument arrays (never through a shell).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Which pipe a line of output came from.
enum OutputStream { stdout, stderr }

/// Receives each line of a command's output as it arrives.
typedef LineSink = void Function(OutputStream stream, String line);

/// How a command ended.
final class CommandResult {
  const CommandResult({this.exitCode, this.timedOut = false, this.startError});

  /// The process exit code; null when the process could not be started.
  final int? exitCode;

  /// The command ran past its timeout and was killed.
  final bool timedOut;

  /// Why the process could not be started (no secret: the argv is fixed).
  final String? startError;

  bool get succeeded => exitCode == 0 && !timedOut && startError == null;
}

/// Starts processes. Tests replace it with a fake.
abstract interface class ProcessRunner {
  /// Runs [argv] (`argv.first` is the executable), streaming every output
  /// line to [onLine]. Kills the process when it runs longer than [timeout].
  Future<CommandResult> run(
    List<String> argv, {
    required Duration timeout,
    LineSink? onLine,
  });
}

/// [ProcessRunner] backed by `Process.start`.
final class IoProcessRunner implements ProcessRunner {
  const IoProcessRunner({
    this.killGrace = const Duration(seconds: 10),
    this.environment = defaultEnvironment,
  });

  /// After SIGTERM on timeout, SIGKILL follows after this long.
  final Duration killGrace;

  /// Added to the inherited environment (plain, uncoloured compose output).
  final Map<String, String> environment;

  static const defaultEnvironment = {
    'COMPOSE_ANSI': 'never',
    'COMPOSE_PROGRESS': 'plain',
    'NO_COLOR': '1',
  };

  @override
  Future<CommandResult> run(
    List<String> argv, {
    required Duration timeout,
    LineSink? onLine,
  }) async {
    if (argv.isEmpty) throw ArgumentError.value(argv, 'argv', 'empty');
    final Process process;
    try {
      process = await Process.start(
        argv.first,
        argv.sublist(1),
        environment: environment,
        runInShell: false,
      );
    } on ProcessException catch (e) {
      return CommandResult(
        startError: 'cannot start ${argv.first}: ${e.message}',
      );
    }
    // No stdin: commands never read request data.
    unawaited(process.stdin.close().catchError((Object _) {}));

    Future<void> pump(Stream<List<int>> s, OutputStream which) => s
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) => onLine?.call(which, line))
        .asFuture<void>()
        .catchError((Object _) {});

    final out = pump(process.stdout, OutputStream.stdout);
    final err = pump(process.stderr, OutputStream.stderr);

    var timedOut = false;
    Timer? killTimer;
    final timeoutTimer = Timer(timeout, () {
      timedOut = true;
      process.kill(ProcessSignal.sigterm);
      killTimer = Timer(killGrace, () => process.kill(ProcessSignal.sigkill));
    });
    final code = await process.exitCode;
    timeoutTimer.cancel();
    killTimer?.cancel();
    // A grandchild could keep a pipe open; do not wait for it forever.
    await Future.wait([out, err])
        .timeout(const Duration(seconds: 5), onTimeout: () => const []);
    return CommandResult(exitCode: code, timedOut: timedOut);
  }
}
