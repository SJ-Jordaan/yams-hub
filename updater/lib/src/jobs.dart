/// One-at-a-time job runner (ARCHITECTURE §5.17).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:logging/logging.dart';

import 'commands.dart';
import 'process_runner.dart';

final _log = Logger('updater.jobs');

enum JobState { queued, running, succeeded, failed }

/// Kind of job, reported as `kind` (additive to the documented shape).
enum JobKind {
  update('update'),
  recyclarrSync('recyclarr-sync');

  const JobKind(this.wire);
  final String wire;
}

/// One executed (or pending) step.
final class JobStep {
  JobStep._(this.spec);

  final StepSpec spec;
  int? exitCode;
  bool timedOut = false;
  DateTime? startedAt;
  DateTime? finishedAt;

  /// The command line as one string (arguments never contain secrets).
  String get cmd => spec.argv.join(' ');

  Map<String, Object?> toJson() => {
    'label': spec.label,
    'cmd': cmd,
    'exitCode': exitCode,
    if (timedOut) 'timedOut': true,
    if (spec.optional) 'optional': true,
    'startedAt': startedAt == null ? null : _instant(startedAt!),
    'finishedAt': finishedAt == null ? null : _instant(finishedAt!),
  };
}

/// A job and its live state.
final class UpdaterJob {
  UpdaterJob._({
    required this.id,
    required this.kind,
    required this.service,
    required List<StepSpec> plan,
    required this.createdAt,
    required this._maxLogLines,
  }) : steps = List.unmodifiable([for (final s in plan) JobStep._(s)]);

  final String id;
  final JobKind kind;

  /// The compose service (`recyclarr` for the sync job).
  final String service;
  final List<JobStep> steps;
  final DateTime createdAt;
  JobState state = JobState.queued;
  DateTime? startedAt;
  DateTime? finishedAt;

  /// Short reason when [state] is failed.
  String? error;

  final int _maxLogLines;
  final _log = ListQueue<String>();
  final _done = Completer<void>();

  /// The last [_maxLogLines] lines of combined output and step markers.
  List<String> get log => List.unmodifiable(_log);

  bool get active => state == JobState.queued || state == JobState.running;

  /// Completes when the job has finished (either way).
  Future<void> get done => _done.future;

  void _append(String line) {
    _log.addLast(
      line.length <= _maxLineLength
          ? line
          : '${line.substring(0, _maxLineLength)}…',
    );
    while (_log.length > _maxLogLines) {
      _log.removeFirst();
    }
  }

  static const _maxLineLength = 2000;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.wire,
    'service': service,
    'state': state.name,
    // Only steps that have started: consumers mirror each new entry as
    // "now running" (the gateway's job view does).
    'steps': [
      for (final s in steps)
        if (s.startedAt != null) s.toJson(),
    ],
    'stepCount': steps.length,
    'log': log,
    if (error != null) 'error': error,
    'createdAt': _instant(createdAt),
    'startedAt': startedAt == null ? null : _instant(startedAt!),
    'finishedAt': finishedAt == null ? null : _instant(finishedAt!),
  };
}

/// Thrown by [JobManager.start] while another job is queued or running.
final class JobBusyException implements Exception {
  const JobBusyException(this.activeJobId);

  final String activeJobId;

  @override
  String toString() => 'JobBusyException: job $activeJobId is running';
}

/// Thrown by [JobManager.start] after [JobManager.close] (shutting down).
final class JobManagerClosedException implements Exception {
  const JobManagerClosedException();

  @override
  String toString() =>
      'JobManagerClosedException: the updater is shutting down';
}

/// Runs at most one job at a time and remembers recent ones.
final class JobManager {
  JobManager({
    required this._runner,
    this.stepTimeout = const Duration(minutes: 15),
    this.maxLogLines = 500,
    this.keepFinished = 50,
    this.retention = const Duration(hours: 24),
    DateTime Function()? clock,
    String Function()? newId,
  }) : _clock = clock ?? DateTime.now,
       _newId = newId ?? _randomJobId;

  final ProcessRunner _runner;
  final DateTime Function() _clock;
  final String Function() _newId;
  final Duration stepTimeout;
  final int maxLogLines;
  final int keepFinished;
  final Duration retention;

  /// Insertion-ordered: oldest first.
  final _jobs = <String, UpdaterJob>{};
  UpdaterJob? _active;
  bool _closed = false;

  /// The queued or running job, if any.
  UpdaterJob? get active => _active;

  /// Whether [close] was called: no new job starts.
  bool get closed => _closed;

  /// Stops accepting jobs ([start] throws [JobManagerClosedException]) and
  /// lets the active job reach a safe point: the step it is running always
  /// finishes; a job that has not yet started a step that changes the stack
  /// (only pulled) stops there and fails; a job that has, still runs its
  /// remaining required steps (gluetun's dependants) and skips optional ones.
  ///
  /// Completes with true once no job is active, or with false after
  /// [timeout] (the job is then abandoned by the caller's exit).
  Future<bool> close({required Duration timeout}) async {
    _closed = true;
    final job = _active;
    if (job == null || !job.active) return true;
    try {
      await job.done.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  UpdaterJob? operator [](String id) => _jobs[id];

  /// Starts [plan] as a new job and returns it immediately (state `queued`,
  /// switching to `running` right away). Throws [JobBusyException] when a
  /// job is already active.
  UpdaterJob start({
    required JobKind kind,
    required String service,
    required List<StepSpec> plan,
  }) {
    if (_closed) throw const JobManagerClosedException();
    final current = _active;
    if (current != null && current.active) throw JobBusyException(current.id);
    _prune();
    var id = _newId();
    while (_jobs.containsKey(id)) {
      id = _newId();
    }
    final job = UpdaterJob._(
      id: id,
      kind: kind,
      service: service,
      plan: plan,
      createdAt: _now(),
      maxLogLines: maxLogLines,
    );
    _jobs[id] = job;
    _active = job;
    unawaited(_run(job));
    return job;
  }

  Future<void> _run(UpdaterJob job) async {
    // Let the caller answer 202 before the first process starts.
    await Future<void>.delayed(Duration.zero);
    job
      ..state = JobState.running
      ..startedAt = _now();
    _log.info('job ${job.id} (${job.kind.wire} ${job.service}) started');
    try {
      var changedStack = false;
      for (final step in job.steps) {
        if (_closed) {
          if (step.spec.optional) {
            job._append(
              '${step.spec.label} skipped: the updater is shutting down',
            );
            continue;
          }
          if (!changedStack) {
            job
              .._append(
                'the updater is shutting down: stopped before '
                '${step.spec.label} (nothing was changed)',
              )
              ..state = JobState.failed
              ..error = 'updater shut down before ${step.spec.label}';
            return;
          }
        }
        changedStack = changedStack || step.spec.changesStack;
        step.startedAt = _now();
        job._append('\$ ${step.cmd}');
        _log.info('job ${job.id}: ${step.spec.label}');
        CommandResult result;
        try {
          result = await _runner.run(
            step.spec.argv,
            timeout: stepTimeout,
            onLine: (_, line) => job._append(line),
          );
        } on Object catch (e) {
          result = CommandResult(startError: 'runner error (${e.runtimeType})');
        }
        step
          ..finishedAt = _now()
          ..exitCode = result.exitCode
          ..timedOut = result.timedOut;
        if (result.startError != null) job._append(result.startError!);
        if (result.timedOut) {
          job._append('timed out after ${stepTimeout.inMinutes} min; killed');
        }
        final seconds =
            step.finishedAt!.difference(step.startedAt!).inMilliseconds / 1000;
        job._append(
          '${step.spec.label}: ${result.succeeded ? 'ok' : 'failed'} '
          '(exit ${result.exitCode ?? '-'}, ${seconds.toStringAsFixed(1)} s)',
        );
        _log.info(
          'job ${job.id}: ${step.spec.label} exit ${result.exitCode ?? '-'}'
          '${result.timedOut ? ' (timed out)' : ''}',
        );
        if (!result.succeeded) {
          if (step.spec.optional) {
            job._append('${step.spec.label} is optional; continuing');
            continue;
          }
          job
            ..state = JobState.failed
            ..error = result.timedOut
                ? '${step.spec.label} timed out'
                : '${step.spec.label} failed';
          return;
        }
      }
      job.state = JobState.succeeded;
    } finally {
      job.finishedAt = _now();
      if (identical(_active, job)) _active = null;
      _log.info('job ${job.id} ${job.state.name}');
      job._done.complete();
    }
  }

  /// Drops finished jobs older than [retention] and keeps at most
  /// [keepFinished] finished jobs.
  void _prune() {
    final cutoff = _now().subtract(retention);
    _jobs.removeWhere(
      (_, j) =>
          !j.active && j.finishedAt != null && j.finishedAt!.isBefore(cutoff),
    );
    final finished = [
      for (final j in _jobs.values)
        if (!j.active) j,
    ];
    for (var i = 0; i < finished.length - keepFinished + 1; i++) {
      _jobs.remove(finished[i].id);
    }
  }

  DateTime _now() => _clock().toUtc();
}

final _random = Random.secure();

/// `j_` + 16 hex chars from a CSPRNG.
String _randomJobId() {
  final b = StringBuffer('j_');
  for (var i = 0; i < 8; i++) {
    b.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

/// Job ids accepted by `GET /jobs/{id}`.
final jobIdPattern = RegExp(r'^j_[A-Za-z0-9_-]{1,64}$');

String _instant(DateTime d) => d.toUtc().toIso8601String();
