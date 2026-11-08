/// The `yams-hub-updater` sidecar (ARCHITECTURE §5.17): compose-aware image
/// updates and the fixed `recyclarr sync` command.
library;

import 'dart:async';

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

/// Service names the updater accepts (re-validated by the updater).
final updaterServicePattern = RegExp(r'^[a-z0-9][a-z0-9_.-]*$');

/// Mirrors an updater job (`GET /jobs/{id}`) into a gateway job.
final class UpdaterJobMirror {
  UpdaterJobMirror({
    required this.updater,
    required this.handle,
    required this.pollInterval,
    required this.timeout,
  });

  final UpstreamClient updater;
  final JobHandle handle;
  final Duration pollInterval;
  final Duration timeout;

  int _stepsSeen = 0;
  final List<String> _lastLog = [];

  /// Polls until the updater job finished; throws when it failed.
  Future<JsonMap> follow(String updaterJobId, {required String what}) async {
    final sw = Stopwatch()..start();
    while (true) {
      JsonMap job;
      try {
        job =
            readMap(
              await updater.getJson(
                '/jobs/$updaterJobId',
                timeout: const Duration(seconds: 10),
              ),
            ) ??
            const {};
      } on UpstreamUnavailable {
        // The updater may restart the stack's network briefly: keep trying.
        job = const {};
      } on UpstreamTimeout {
        job = const {};
      }
      if (job.isNotEmpty) {
        _mirrorSteps(job);
        _mirrorLog(readStringList(job['log']));
        final state = readString(job['state']);
        if (state == 'succeeded') return job;
        if (state == 'failed') {
          throw ApiException(
            502,
            ApiErrorCode.upstreamError,
            '$what failed (see the job log).',
            service: ServiceId.updater,
          );
        }
      }
      if (sw.elapsed > timeout) {
        throw ApiException(
          504,
          ApiErrorCode.upstreamTimeout,
          '$what did not finish in time.',
          service: ServiceId.updater,
        );
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  void _mirrorSteps(JsonMap job) {
    final steps = readList(job['steps'], (m) => m);
    while (_stepsSeen < steps.length) {
      final s = steps[_stepsSeen];
      final cmd = readString(s['cmd']) ?? 'Step ${_stepsSeen + 1}';
      handle.step(_label(cmd));
      _stepsSeen++;
    }
  }

  /// `docker compose -p yams ... pull -- sonarr` → `compose pull sonarr`.
  static String _label(String cmd) {
    final parts = cmd.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    final compose = parts.indexOf('compose');
    if (compose < 0) return cmd;
    final rest = <String>[];
    for (var i = compose + 1; i < parts.length; i++) {
      final p = parts[i];
      if (p == '-p' || p == '-f' || p == '--project-directory') {
        i++;
        continue;
      }
      if (p == '--') continue;
      rest.add(p);
    }
    return 'compose ${rest.join(' ')}';
  }

  void _mirrorLog(List<String> log) {
    if (log.isEmpty) return;
    var start = 0;
    if (_lastLog.isNotEmpty) {
      // The updater keeps a sliding window: continue after the last line
      // already mirrored.
      final anchor = _findOverlap(log);
      start = anchor ?? 0;
    }
    for (var i = start; i < log.length; i++) {
      handle.log(log[i]);
    }
    _lastLog
      ..clear()
      ..addAll(log);
  }

  int? _findOverlap(List<String> log) {
    if (log.length >= _lastLog.length) {
      var same = true;
      for (var i = 0; i < _lastLog.length; i++) {
        if (log[i] != _lastLog[i]) {
          same = false;
          break;
        }
      }
      if (same) return _lastLog.length;
    }
    // Window slid: find the last mirrored line in the new log.
    final last = _lastLog.last;
    final idx = log.lastIndexOf(last);
    return idx < 0 ? 0 : idx + 1;
  }
}
