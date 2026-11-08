import 'dart:async';

import 'package:yams_hub_updater/yams_hub_updater.dart';

/// A scripted reply of [FakeProcessRunner].
final class FakeReply {
  FakeReply({
    this.exitCode = 0,
    this.stdout = const [],
    this.stderr = const [],
    this.timedOut = false,
    this.startError,
    this.gate,
  });

  final int exitCode;
  final List<String> stdout;
  final List<String> stderr;
  final bool timedOut;
  final String? startError;

  /// When set, the command "runs" until this completes.
  final Completer<void>? gate;
}

/// One recorded invocation.
final class FakeCall {
  FakeCall(this.argv, this.timeout);

  /// The exact list object handed to the runner (tests use `identical`).
  final List<String> argv;
  final Duration timeout;

  String get line => argv.join(' ');
}

/// [ProcessRunner] that records every call and answers from a script.
///
/// [on] registers a reply for commands whose joined argv contains a
/// fragment; the first matching rule wins. Unmatched commands succeed with
/// no output.
final class FakeProcessRunner implements ProcessRunner {
  final calls = <FakeCall>[];
  final _rules = <(String, FakeReply Function())>[];

  void on(String fragment, FakeReply Function() reply) =>
      _rules.add((fragment, reply));

  /// Answers `compose config --services` with [services].
  void composeServices(List<String> services, {int exitCode = 0}) => on(
    'config --services',
    () => FakeReply(stdout: services, exitCode: exitCode),
  );

  List<String> get lines => [for (final c in calls) c.line];

  @override
  Future<CommandResult> run(
    List<String> argv, {
    required Duration timeout,
    LineSink? onLine,
  }) async {
    calls.add(FakeCall(argv, timeout));
    final line = argv.join(' ');
    FakeReply reply = FakeReply();
    for (final (fragment, make) in _rules) {
      if (line.contains(fragment)) {
        reply = make();
        break;
      }
    }
    if (reply.startError != null) {
      return CommandResult(startError: reply.startError);
    }
    for (final l in reply.stdout) {
      onLine?.call(OutputStream.stdout, l);
    }
    for (final l in reply.stderr) {
      onLine?.call(OutputStream.stderr, l);
    }
    if (reply.gate != null) await reply.gate!.future;
    return CommandResult(exitCode: reply.exitCode, timedOut: reply.timedOut);
  }
}
