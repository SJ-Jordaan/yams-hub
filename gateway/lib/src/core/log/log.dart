/// Structured JSON logging (ARCHITECTURE §5.14).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import 'redact.dart';

/// Zone key holding the current request id (set by the requestId middleware).
const requestIdZoneKey = #yamsHubRequestId;

/// A log message with structured fields. Pass it as the message object:
/// `log.info(LogEvent('upstream call', {'service': 'sonarr', 'ms': 12}))`.
final class LogEvent {
  const LogEvent(this.message, [this.fields = const {}]);

  final String message;

  /// Extra JSON fields (`method`, `path`, `status`, `ms`, `user`, `service`).
  /// Values must be JSON encodable.
  final Map<String, Object?> fields;

  @override
  String toString() => message;
}

/// Parses `fine`/`info`/`warning`/`severe` (case-insensitive).
Level? parseLogLevel(String value) => switch (value.trim().toLowerCase()) {
  'all' => Level.ALL,
  'finest' => Level.FINEST,
  'finer' => Level.FINER,
  'fine' => Level.FINE,
  'config' => Level.CONFIG,
  'info' => Level.INFO,
  'warning' => Level.WARNING,
  'severe' => Level.SEVERE,
  'off' => Level.OFF,
  _ => null,
};

/// Formats [record] as one JSON line. Messages and errors pass through
/// [redactSecrets]; stack traces are kept for `severe` records only.
String formatLogRecord(LogRecord record) {
  final out = <String, Object?>{
    'ts': record.time.toUtc().toIso8601String(),
    'level': record.level.name.toLowerCase(),
    'logger': record.loggerName,
    'msg': redactSecrets(record.message),
  };
  final requestId = record.zone?[requestIdZoneKey];
  if (requestId is String) out['requestId'] = requestId;
  final object = record.object;
  if (object is LogEvent) {
    for (final e in object.fields.entries) {
      if (e.value == null) continue;
      final v = e.value;
      out[e.key] = v is String ? redactSecrets(v) : v;
    }
  }
  final error = record.error;
  if (error != null) {
    out['error'] = redactSecrets(error.toString());
  }
  final stack = record.stackTrace;
  if (stack != null && record.level >= Level.SEVERE) {
    out['stack'] = redactSecrets(stack.toString());
  }
  try {
    return jsonEncode(out);
  } on JsonUnsupportedObjectError {
    return jsonEncode({
      for (final e in out.entries) e.key: e.value?.toString(),
    });
  }
}

StreamSubscription<LogRecord>? _rootSubscription;

/// Installs the root listener that prints one JSON object per line to
/// [sink] (stdout by default).
void configureLogging(Level level, {IOSink? sink}) {
  hierarchicalLoggingEnabled = false;
  Logger.root.level = level;
  final out = sink ?? stdout;
  unawaited(_rootSubscription?.cancel());
  _rootSubscription = Logger.root.onRecord.listen(
    (r) => out.writeln(formatLogRecord(r)),
  );
}
