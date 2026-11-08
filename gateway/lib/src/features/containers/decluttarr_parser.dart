/// Decluttarr v2.2 log parser (integrations/system.md §8). Decluttarr has no
/// API: its container log (all on stderr, timestamps from Docker) is the
/// source.
library;

import 'package:yams_models/yams_models.dart';

import 'docker_logs.dart';

final _level = RegExp(
  r'^(INFO|WARNING|ERROR|DEBUG|VERBOSE|CRITICAL)\s*\| (.*)$',
);
final _runStart = RegExp(r'^\*\*\* Running jobs on (\w+) \((.+)\) \*\*\*$');
final _strike = RegExp(
  r"^>>> Job '(.+?)' flagged download \((\d+)/(\d+) strikes( -> too many)?\): (.+)$",
);
final _removal = RegExp(
  r"^Job '(.+?)' triggered (removal|queue removal \(torrent kept\)): (.+)$",
);
final _obsolete = RegExp(r"^Job '(.+?)' triggered obsolete-tagging: (.+)$");
final _search = RegExp(r"^Job '(.+?)' triggered a search for (\d+) (\w+)s$");
final _errorLine = RegExp(
  r'^(.+): (request|unexpected) error on (\w+) \((.+)\): (.*)$',
);
final _downloadClientError = RegExp(r"^Download-client job '(.+?)' failed on ");

/// How far apart two "Running jobs" lines may be and still belong to one run.
const _sameRun = Duration(seconds: 60);

/// Most warnings/errors returned.
const _maxMessages = 50;

/// Strips the tuple Decluttarr prints for some job names
/// (`('remove_stalled',)` → `remove_stalled`).
String cleanDecluttarrJobName(String job) {
  var j = job.trim();
  if (j.startsWith('(') && j.endsWith(')')) {
    j = j.substring(1, j.length - 1).trim();
    if (j.endsWith(',')) j = j.substring(0, j.length - 1).trim();
  }
  if (j.length >= 2 &&
      ((j.startsWith("'") && j.endsWith("'")) ||
          (j.startsWith('"') && j.endsWith('"')))) {
    j = j.substring(1, j.length - 1);
  }
  return j;
}

/// Parses Decluttarr log lines (oldest first) into a [DecluttarrStatus].
/// [redact] scrubs every text that leaves the gateway; [defaultInterval] is
/// Decluttarr's `timer` when it cannot be inferred from two runs.
DecluttarrStatus parseDecluttarrLog(
  List<DockerLogLine> lines, {
  required MaintenanceContainerState container,
  required String Function(String) redact,
  int defaultInterval = 10,
}) {
  final runStarts = <DateTime>[];
  DateTime? lastRunLine;
  final removed = <DecluttarrRemoval>[];
  final strikes = <DecluttarrStrike>[];
  final warnings = <MaintenanceLogEntry>[];
  final errors = <MaintenanceLogEntry>[];
  var searches = 0;
  var obsolete = 0;
  var testMode = false;

  for (final line in lines) {
    final at = line.at;
    if (at == null) continue;
    final text = line.text.trim();
    if (text.contains('Application Started!')) testMode = false;
    if (text.contains('TEST MODE IS ACTIVE')) testMode = true;
    final lm = _level.firstMatch(text);
    if (lm == null) continue;
    final level = lm[1]!;
    final msg = lm[2]!.trim();

    if (_runStart.hasMatch(msg)) {
      final previous = lastRunLine;
      if (previous == null || at.difference(previous) > _sameRun) {
        runStarts.add(at);
      }
      lastRunLine = at;
      continue;
    }
    if (_removal.firstMatch(msg) case final m?) {
      removed.add(
        DecluttarrRemoval(
          at: at,
          job: cleanDecluttarrJobName(m[1]!),
          title: redact(m[3]!.trim()),
          kind: m[2] == 'removal'
              ? DecluttarrRemovalKind.removal
              : DecluttarrRemovalKind.queueRemoval,
        ),
      );
      continue;
    }
    if (_strike.firstMatch(msg) case final m?) {
      strikes.add(
        DecluttarrStrike(
          at: at,
          job: cleanDecluttarrJobName(m[1]!),
          title: redact(m[5]!.trim()),
          count: int.parse(m[2]!),
          max: int.parse(m[3]!),
        ),
      );
      continue;
    }
    if (_obsolete.hasMatch(msg)) {
      obsolete++;
      continue;
    }
    if (_search.firstMatch(msg) case final m?) {
      searches += int.parse(m[2]!);
      continue;
    }
    final isError =
        level == 'ERROR' ||
        level == 'CRITICAL' ||
        _errorLine.hasMatch(msg) ||
        _downloadClientError.hasMatch(msg);
    if (isError) {
      errors.add(MaintenanceLogEntry(at: at, text: redact(msg)));
    } else if (level == 'WARNING') {
      warnings.add(MaintenanceLogEntry(at: at, text: redact(msg)));
    }
  }

  var interval = defaultInterval;
  if (runStarts.length >= 2) {
    final gaps = <int>[
      for (var i = 1; i < runStarts.length; i++)
        runStarts[i].difference(runStarts[i - 1]).inSeconds,
    ]..sort();
    final median = gaps[gaps.length ~/ 2];
    final minutes = (median / 60).round();
    if (minutes >= 1 && minutes <= 24 * 60) interval = minutes;
  }
  final lastRun = runStarts.isEmpty ? null : runStarts.last;

  List<T> newest<T>(List<T> l) {
    final r = l.reversed.toList();
    return r.length > _maxMessages ? r.sublist(0, _maxMessages) : r;
  }

  return DecluttarrStatus(
    container: container,
    lastRunAt: lastRun,
    intervalMinutes: interval,
    nextRunAt: lastRun?.add(Duration(minutes: interval)),
    testMode: testMode,
    last24h: DecluttarrLast24h(
      runs: runStarts.length,
      removed: newest(removed),
      strikes: newest(strikes),
      searches: searches,
      obsoleteTagged: obsolete,
    ),
    warnings: newest(warnings),
    errors: newest(errors),
  );
}
