/// A small progress chip for a running job (ARCHITECTURE §7.2, APP.md §2.3).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_models/yams_models.dart';

import '../api/api_exception.dart';
import '../theme/theme.dart';
import 'job_provider.dart';

/// Consecutive failed job polls before a [JobChip] gives up on its job.
const jobMaxPollFailures = 3;

/// SnackBar text when a [JobChip] gives up on its job.
const jobLostMessage = 'Lost track of the job. Refresh to check the result.';

/// Shows the current step label with a spinner while [jobId] runs, then a
/// result SnackBar ("Restart sonarr: done" or the error message) and calls
/// [onDone] once.
///
/// [jobProvider] stops polling after a failed fetch, so a network blip
/// (LAN/Tailscale switch) or an expired job (404 after a gateway restart)
/// would otherwise leave the chip, and whatever the caller disabled while
/// the job runs, stuck forever. Failed polls are retried every
/// [jobPollInterval]; a 404 or [jobMaxPollFailures] failures in a row give
/// up: [jobLostMessage] is shown (with [showSnackBar]) and [onLost] runs
/// once. Exactly one of [onDone] and [onLost] is called.
class JobChip extends ConsumerStatefulWidget {
  const JobChip(this.jobId, {super.key, this.onDone, this.onLost, this.showSnackBar = true});

  final String jobId;
  final ValueChanged<Job>? onDone;

  /// Called once when the chip stops following the job without a result.
  final ValueChanged<ApiException>? onLost;
  final bool showSnackBar;

  /// Text describing a job's current activity.
  static String labelFor(Job job) {
    for (final step in job.steps.reversed) {
      if (step.status == JobStatus.running) return step.label;
    }
    final message = job.message;
    if (message != null && message.isNotEmpty) return message;
    if (job.steps.isNotEmpty) return job.steps.last.label;
    return job.target == null ? job.kind : '${job.kind} ${job.target}';
  }

  /// SnackBar text when [job] finished.
  static String resultFor(Job job) {
    final label = job.steps.isNotEmpty ? job.steps.first.label : (job.message ?? job.kind);
    if (job.status == JobStatus.succeeded) return '$label: done';
    final error = job.error;
    return error == null || error.message.isEmpty ? '$label: failed' : '$label: ${error.message}';
  }

  @override
  ConsumerState<JobChip> createState() => _JobChipState();
}

class _JobChipState extends ConsumerState<JobChip> {
  bool _reported = false;
  int _failures = 0;
  Timer? _retry;

  @override
  void didUpdateWidget(JobChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.jobId != widget.jobId) {
      _retry?.cancel();
      _reported = false;
      _failures = 0;
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  void _onPoll(AsyncValue<Job> next) {
    if (next.isLoading || _reported) return;
    final job = next.value;
    if (!next.hasError) {
      _failures = 0;
      if (job != null) _report(job);
      return;
    }
    final e = ApiException.from(next.error!);
    if (e.status == 404 || e.code == ApiErrorCode.notFound || ++_failures >= jobMaxPollFailures) {
      _lose(e);
      return;
    }
    final id = widget.jobId;
    _retry?.cancel();
    _retry = Timer(jobPollInterval, () {
      if (mounted && !_reported && widget.jobId == id) ref.invalidate(jobProvider(id));
    });
  }

  void _lose(ApiException e) {
    _retry?.cancel();
    _reported = true;
    if (widget.showSnackBar) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text(jobLostMessage)));
    }
    widget.onLost?.call(e);
  }

  void _report(Job job) {
    if (_reported || !job.status.isFinished) return;
    _reported = true;
    _retry?.cancel();
    if (widget.showSnackBar) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(JobChip.resultFor(job))));
    }
    widget.onDone?.call(job);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<Job>>(jobProvider(widget.jobId), (_, next) => _onPoll(next));
    final value = ref.watch(jobProvider(widget.jobId));
    final job = value.value;
    final colors = StatusColors.of(context);

    if (job == null) {
      if (value.hasError) {
        return Chip(
          avatar: Icon(Icons.error_outline, size: 18, color: colors.error),
          label: Text(ApiException.from(value.error!).message),
        );
      }
      return const Chip(
        avatar: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        label: Text('Starting…'),
      );
    }

    final Widget avatar = switch (job.status) {
      JobStatus.succeeded => Icon(Icons.check_circle, size: 18, color: colors.ok),
      JobStatus.failed => Icon(Icons.error, size: 18, color: colors.error),
      _ => SizedBox.square(
        dimension: 16,
        child: CircularProgressIndicator(strokeWidth: 2, value: job.progress),
      ),
    };
    return Chip(
      avatar: avatar,
      label: Text(job.status.isFinished ? JobChip.resultFor(job) : JobChip.labelFor(job)),
    );
  }
}
