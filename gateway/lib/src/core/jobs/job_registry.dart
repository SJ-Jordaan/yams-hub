/// Long-running actions (ARCHITECTURE §5.9).
library;

import 'dart:async';
import 'dart:collection';

import 'package:logging/logging.dart';
import 'package:yams_models/yams_models.dart';

import '../audit/audit_log.dart';
import '../clock.dart';
import '../http/api_exception.dart';
import '../ids.dart';
import '../log/redact.dart';
import '../upstream/upstream_exception.dart';

final _log = Logger('core.jobs');

const _maxLogLines = 200;

/// A running or finished job.
final class JobRecord {
  JobRecord._({
    required this.id,
    required this.kind,
    required this.target,
    required this.userId,
    required this.createdAt,
  });

  final String id;
  final String kind;
  final String? target;
  final String? userId;
  final DateTime createdAt;
  JobStatus status = JobStatus.queued;
  double? progress;
  String? message;
  final List<JobStep> steps = [];
  final Queue<String> _log = Queue();
  JsonMap? result;
  ApiError? error;
  DateTime? startedAt;
  DateTime? finishedAt;
  final _done = Completer<void>();

  /// Completes when the job finished (successfully or not).
  Future<void> get done => _done.future;

  bool get isActive => status.isActive;

  Job toDto() => Job(
    id: id,
    kind: kind,
    target: target,
    status: status,
    progress: progress,
    message: message,
    steps: List.unmodifiable(steps),
    log: List.unmodifiable(_log),
    result: result,
    error: error,
    createdAt: createdAt,
    startedAt: startedAt,
    finishedAt: finishedAt,
    userId: userId,
  );
}

/// What a job's `run` function can report. Texts pass through
/// `redactSecrets` before they are stored.
final class JobHandle {
  JobHandle._(this._job, this._clock);

  final JobRecord _job;
  final Clock _clock;

  String get id => _job.id;

  /// Starts a new step (finishing the previous running one).
  void step(String label) {
    final now = _clock.now();
    _finishRunningStep(JobStatus.succeeded, now);
    final clean = redactSecrets(label);
    _job.steps.add(
      JobStep(label: clean, status: JobStatus.running, startedAt: now),
    );
    _job.message = clean;
  }

  void _finishRunningStep(JobStatus status, DateTime now) {
    final i = _job.steps.lastIndexWhere((s) => s.status == JobStatus.running);
    if (i < 0) return;
    final s = _job.steps[i];
    _job.steps[i] = JobStep(
      label: s.label,
      status: status,
      startedAt: s.startedAt,
      finishedAt: now,
    );
  }

  /// Appends a log line (the last 200 are kept).
  void log(String line) {
    _job._log.add(redactSecrets(line));
    while (_job._log.length > _maxLogLines) {
      _job._log.removeFirst();
    }
  }

  /// Sets the 0..1 progress.
  void progress(double value) => _job.progress = value.clamp(0, 1).toDouble();

  /// Sets the status message.
  set message(String text) => _job.message = redactSecrets(text);
}

/// In-memory job registry: keeps the last 200 jobs for 24 h, at most one
/// running job per `(kind, target)`; every finished job is audited.
final class JobRegistry {
  JobRegistry({
    required this._clock,
    required this._audit,
    this.maxJobs = 200,
    this.retention = const Duration(hours: 24),
  });

  final Clock _clock;
  final AuditLog _audit;
  final int maxJobs;
  final Duration retention;
  final _jobs = <String, JobRecord>{};

  /// Starts [run] as a job. When a job of the same [kind] and [target] is
  /// still active, that job is returned instead (the caller answers 202 with
  /// it). [run]'s return value becomes `result`; an exception marks the job
  /// failed with the mapped error.
  JobRecord start({
    required String kind,
    String? target,
    String? userId,
    required Future<JsonMap?> Function(JobHandle h) run,
  }) {
    _prune();
    for (final j in _jobs.values) {
      if (j.isActive && j.kind == kind && j.target == target) return j;
    }
    final job = JobRecord._(
      id: _newId(),
      kind: kind,
      target: target,
      userId: userId,
      createdAt: _clock.now(),
    );
    _jobs[job.id] = job;
    final handle = JobHandle._(job, _clock);
    final sw = Stopwatch();
    scheduleMicrotask(() async {
      job
        ..status = JobStatus.running
        ..startedAt = _clock.now();
      sw.start();
      try {
        final result = await run(handle);
        job.result = result == null ? null : _redactMap(result);
        handle._finishRunningStep(JobStatus.succeeded, _clock.now());
        job.status = JobStatus.succeeded;
        job.progress = 1;
      } catch (e, st) {
        final api = _toApiException(e);
        if (api.status >= 500 &&
            e is! UpstreamException &&
            e is! ApiException) {
          _log.severe('job $kind failed', e, st);
        }
        job.error = api.toApiError(job.id);
        job.message = redactSecrets(api.message);
        handle._finishRunningStep(JobStatus.failed, _clock.now());
        job.status = JobStatus.failed;
      } finally {
        job.finishedAt = _clock.now();
        job._done.complete();
        await _audit.record(
          actor: AuditActor(userId: userId),
          action: kind,
          target: target,
          outcome: job.status == JobStatus.succeeded
              ? AuditOutcome.ok
              : AuditOutcome.error,
          errorCode: job.error?.code,
          duration: sw.elapsed,
          params: {'jobId': job.id},
        );
      }
    });
    return job;
  }

  /// The job [id], or null when unknown or expired.
  JobRecord? get(String id) {
    _prune();
    return _jobs[id];
  }

  /// Jobs newest first, optionally only active ones, of a kind prefix, or of
  /// one user.
  List<JobRecord> list({
    bool activeOnly = false,
    String? kindPrefix,
    String? userId,
  }) {
    _prune();
    return [
      for (final j in _jobs.values.toList().reversed)
        if ((!activeOnly || j.isActive) &&
            (kindPrefix == null || j.kind.startsWith(kindPrefix)) &&
            (userId == null || j.userId == userId))
          j,
    ];
  }

  String _newId() {
    while (true) {
      final id = 'j_${randomHex(12)}';
      if (!_jobs.containsKey(id)) return id;
    }
  }

  void _prune() {
    final now = _clock.now();
    _jobs.removeWhere(
      (_, j) =>
          !j.isActive &&
          j.finishedAt != null &&
          now.difference(j.finishedAt!) > retention,
    );
    while (_jobs.length > maxJobs) {
      final oldestFinished = _jobs.values.where((j) => !j.isActive).firstOrNull;
      if (oldestFinished == null) break;
      _jobs.remove(oldestFinished.id);
    }
  }
}

ApiException _toApiException(Object e) => switch (e) {
  ApiException() => e,
  UpstreamException() => e.toApiException(),
  FormatException() || TypeError() => const ApiException(
    502,
    ApiErrorCode.upstreamBadResponse,
    'An upstream response could not be read.',
  ),
  _ => ApiException.internal(),
};

JsonMap _redactMap(JsonMap m) => {
  for (final e in m.entries) e.key: _redactValue(e.value),
};

Object? _redactValue(Object? v) => switch (v) {
  String() => redactSecrets(v),
  Map<String, Object?>() => _redactMap(v),
  List() => [for (final x in v) _redactValue(x)],
  _ => v,
};
