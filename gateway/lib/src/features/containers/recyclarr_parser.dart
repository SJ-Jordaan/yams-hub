/// Recyclarr v8 run-log parser and cron schedule (integrations/system.md
/// §9). Recyclarr has no API: the newest `logs/cli/*.debug.log` is the last
/// run.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yams_models/yams_models.dart';

final _fileName = RegExp(
  r'^recyclarr_(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})\.debug\.log$',
);
final _line = RegExp(r'^\[(\d\d):(\d\d):(\d\d) (INF|WRN|ERR|FTL)\] (.*)$');
final _prefixed = RegExp(r'^([\w-]+): (.*)$');
final _processing = RegExp(r'^Processing (Radarr|Sonarr) server (.+)$');
final _created = RegExp(r'^Created (\d+) New Custom Formats$');
final _updated = RegExp(r'^Updated (\d+) Existing Custom Formats$');
final _skipped = RegExp(r'^Skipped (\d+) Custom Formats that did not change$');
final _sizesSynced = RegExp(
  r'^Total of (\d+) sizes were synced for quality definition (\w+)$',
);
final _sizesUpToDate = RegExp(
  r'^All sizes for quality definition (\w+) are already up to date!$',
);
final _profilesSynced = RegExp(
  r'^A total of (\d+) profiles were synced\. (\d+) contain quality changes and (\d+) contain updated scores$',
);
final _completed = RegExp(
  r'^Completed at (\d{2})/(\d{2})/(\d{4}) (\d{2}):(\d{2}):(\d{2})$',
);

/// Largest log file read (debug logs of big syncs stay well below this).
const recyclarrMaxLogBytes = 20 * 1024 * 1024;

/// The start time encoded in a run-log file name (UTC), or null.
DateTime? recyclarrRunStart(String fileName) {
  final m = _fileName.firstMatch(fileName);
  if (m == null) return null;
  int g(int i) => int.parse(m[i]!);
  return DateTime.utc(g(1), g(2), g(3), g(4), g(5), g(6));
}

/// The newest `recyclarr_*.debug.log` in `<logDir>/cli`, or null.
Future<File?> newestRecyclarrLog(String logDir) async {
  final dir = Directory(p.join(logDir, 'cli'));
  if (!await dir.exists()) return null;
  File? best;
  DateTime? bestAt;
  await for (final e in dir.list(followLinks: false)) {
    if (e is! File) continue;
    final at = recyclarrRunStart(p.basename(e.path));
    if (at == null) continue;
    if (bestAt == null || at.isAfter(bestAt)) {
      best = e;
      bestAt = at;
    }
  }
  return best;
}

final class _Instance {
  _Instance(this.name, this.type);

  final String name;
  final RecyclarrInstanceType type;
  int created = 0;
  int updated = 0;
  int skipped = 0;
  int? profiles;
  bool sizes = false;
  DateTime? completedAt;

  RecyclarrInstance toDto() => RecyclarrInstance(
    name: name,
    type: type,
    customFormatsCreated: created,
    customFormatsUpdated: updated,
    customFormatsSkipped: skipped,
    profilesSynced: profiles,
    qualitySizesSynced: sizes,
    completedAt: completedAt,
  );
}

/// Parses the lines of one run log. Only `INF|WRN|ERR|FTL` lines count. A run
/// with any `ERR|FTL` line, without instances, or with an instance lacking
/// `Completed at` failed.
RecyclarrRun parseRecyclarrLog(
  Iterable<String> lines, {
  required DateTime startedAt,
  required String Function(String) redact,
}) {
  final instances = <String, _Instance>{};
  final warnings = <String>[];
  final errors = <String>[];
  for (final raw in lines) {
    final m = _line.firstMatch(raw.trimRight());
    if (m == null) continue;
    final level = m[4]!;
    var text = m[5]!.trim();
    _Instance? instance;
    if (_prefixed.firstMatch(text) case final pm?) {
      final name = pm[1]!;
      final rest = pm[2]!;
      final processing = _processing.firstMatch(rest);
      if (processing != null) {
        instance = instances.putIfAbsent(
          name,
          () => _Instance(
            name,
            processing[1] == 'Radarr'
                ? RecyclarrInstanceType.radarr
                : RecyclarrInstanceType.sonarr,
          ),
        );
        text = rest;
      } else if (instances[name] case final known?) {
        instance = known;
        text = rest;
      }
    }
    switch (level) {
      case 'WRN':
        warnings.add(redact(m[5]!.trim()));
      case 'ERR' || 'FTL':
        errors.add(redact(m[5]!.trim()));
    }
    if (instance == null) continue;
    if (_created.firstMatch(text) case final c?) {
      instance.created = int.parse(c[1]!);
    } else if (_updated.firstMatch(text) case final c?) {
      instance.updated = int.parse(c[1]!);
    } else if (_skipped.firstMatch(text) case final c?) {
      instance.skipped = int.parse(c[1]!);
    } else if (_sizesSynced.hasMatch(text) || _sizesUpToDate.hasMatch(text)) {
      instance.sizes = true;
    } else if (_profilesSynced.firstMatch(text) case final c?) {
      instance.profiles = int.parse(c[1]!);
    } else if (_completed.firstMatch(text) case final c?) {
      int g(int i) => int.parse(c[i]!);
      // US format, UTC: MM/dd/yyyy HH:mm:ss.
      instance.completedAt = DateTime.utc(g(3), g(1), g(2), g(4), g(5), g(6));
    }
  }
  final list = [for (final i in instances.values) i.toDto()];
  final ok =
      errors.isEmpty && list.isNotEmpty && list.every((i) => i.completed);
  return RecyclarrRun(
    startedAt: startedAt,
    ok: ok,
    instances: list,
    warnings: warnings,
    errors: errors,
  );
}

/// Reads and parses [file] (at most [recyclarrMaxLogBytes]).
Future<RecyclarrRun?> readRecyclarrRun(
  File file, {
  required String Function(String) redact,
}) async {
  final startedAt = recyclarrRunStart(p.basename(file.path));
  if (startedAt == null) return null;
  final lines = file
      .openRead(0, recyclarrMaxLogBytes)
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());
  final kept = <String>[];
  await for (final l in lines) {
    // Debug logs are mostly DBG lines: keep only what the parser reads.
    if (_line.hasMatch(l)) kept.add(l);
  }
  return parseRecyclarrLog(kept, startedAt: startedAt, redact: redact);
}

// ---------------------------------------------------------------------------
// Cron
// ---------------------------------------------------------------------------

/// A five-field cron expression (`minute hour day-of-month month
/// day-of-week`) with `*`, lists, ranges and steps, as supercronic accepts
/// for the usual schedules.
final class CronSchedule {
  CronSchedule._(
    this.expression,
    this._minutes,
    this._hours,
    this._days,
    this._months,
    this._weekdays,
    this._dayRestricted,
    this._weekdayRestricted,
  );

  /// Parses [expression]; null when it is not a supported five-field cron.
  static CronSchedule? tryParse(String expression) {
    final fields = expression.trim().split(RegExp(r'\s+'));
    if (fields.length != 5) return null;
    final minutes = _field(fields[0], 0, 59);
    final hours = _field(fields[1], 0, 23);
    final days = _field(fields[2], 1, 31);
    final months = _field(fields[3], 1, 12);
    final weekdays = _field(fields[4], 0, 7)?.map((d) => d % 7).toSet();
    if (minutes == null ||
        hours == null ||
        days == null ||
        months == null ||
        weekdays == null) {
      return null;
    }
    return CronSchedule._(
      expression.trim(),
      minutes,
      hours,
      days,
      months,
      weekdays,
      fields[2] != '*',
      fields[4] != '*',
    );
  }

  static Set<int>? _field(String f, int min, int max) {
    final out = <int>{};
    for (final part in f.split(',')) {
      var range = part;
      var step = 1;
      final slash = part.indexOf('/');
      if (slash >= 0) {
        step = int.tryParse(part.substring(slash + 1)) ?? 0;
        range = part.substring(0, slash);
        if (step <= 0) return null;
      }
      int lo;
      int hi;
      if (range == '*') {
        lo = min;
        hi = max;
      } else if (range.contains('-')) {
        final bits = range.split('-');
        if (bits.length != 2) return null;
        final a = int.tryParse(bits[0]);
        final b = int.tryParse(bits[1]);
        if (a == null || b == null) return null;
        lo = a;
        hi = b;
      } else {
        final v = int.tryParse(range);
        if (v == null) return null;
        lo = v;
        hi = slash >= 0 ? max : v;
      }
      if (lo < min || hi > max || lo > hi) return null;
      for (var v = lo; v <= hi; v += step) {
        out.add(v);
      }
    }
    return out.isEmpty ? null : out;
  }

  final String expression;
  final Set<int> _minutes;
  final Set<int> _hours;
  final Set<int> _days;
  final Set<int> _months;
  final Set<int> _weekdays;
  final bool _dayRestricted;
  final bool _weekdayRestricted;

  bool _dayMatches(DateTime local) {
    final dom = _days.contains(local.day);
    final dow = _weekdays.contains(local.weekday % 7);
    // Vixie cron: when both fields are restricted, either may match.
    if (_dayRestricted && _weekdayRestricted) return dom || dow;
    if (_dayRestricted) return dom;
    if (_weekdayRestricted) return dow;
    return true;
  }

  /// The first run strictly after [after], in a fixed local time zone
  /// [offset] (SAST has no DST). Returns UTC.
  DateTime? nextAfter(DateTime after, Duration offset) {
    // Wall-clock fields of the local zone, computed on a UTC DateTime.
    var t = after.toUtc().add(offset);
    t = DateTime.utc(
      t.year,
      t.month,
      t.day,
      t.hour,
      t.minute,
    ).add(const Duration(minutes: 1));
    final limit = t.add(const Duration(days: 366 * 5));
    while (t.isBefore(limit)) {
      if (!_months.contains(t.month)) {
        t = DateTime.utc(t.year, t.month + 1);
        continue;
      }
      if (!_dayMatches(t)) {
        t = DateTime.utc(t.year, t.month, t.day + 1);
        continue;
      }
      if (!_hours.contains(t.hour)) {
        t = DateTime.utc(t.year, t.month, t.day, t.hour + 1);
        continue;
      }
      if (!_minutes.contains(t.minute)) {
        t = t.add(const Duration(minutes: 1));
        continue;
      }
      return t.subtract(offset);
    }
    return null;
  }
}
