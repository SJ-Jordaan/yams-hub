/// Display formatting (APP.md §2.2): binary byte units, decimal speeds,
/// relative times, device-local dates, calendar dates as-is.
library;

import 'package:intl/intl.dart';

const _binaryUnits = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
const _decimalUnits = ['B/s', 'kB/s', 'MB/s', 'GB/s', 'TB/s'];

String _trim(double v, int decimals) {
  final s = v.toStringAsFixed(decimals);
  return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
}

/// `1.4 GiB` (binary units; [decimals] below 100 of a unit, none above).
String formatBytes(int? bytes, {int decimals = 1}) {
  if (bytes == null) return '–';
  if (bytes < 0) return '-${formatBytes(-bytes, decimals: decimals)}';
  if (bytes < 1024) return '$bytes B';
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < _binaryUnits.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${_trim(value, value >= 100 ? 0 : decimals)} ${_binaryUnits[unit]}';
}

/// `12.3 MB/s` (decimal units, like qBittorrent).
String formatBps(int? bytesPerSecond) {
  if (bytesPerSecond == null) return '–';
  if (bytesPerSecond <= 0) return '0 B/s';
  var value = bytesPerSecond.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < _decimalUnits.length - 1) {
    value /= 1000;
    unit++;
  }
  return '${_trim(value, unit == 0 || value >= 100 ? 0 : 1)} ${_decimalUnits[unit]}';
}

/// `2d 4h`, `1h 23m`, `5m 03s`, `42s`.
String formatDuration(Duration? d) {
  if (d == null) return '–';
  final negative = d.isNegative;
  final abs = d.abs();
  final days = abs.inDays;
  final hours = abs.inHours % 24;
  final minutes = abs.inMinutes % 60;
  final seconds = abs.inSeconds % 60;
  final String s;
  if (days > 0) {
    s = hours > 0 ? '${days}d ${hours}h' : '${days}d';
  } else if (hours > 0) {
    s = minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
  } else if (minutes > 0) {
    s = '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  } else {
    s = '${seconds}s';
  }
  return negative ? '-$s' : s;
}

/// [formatDuration] for a number of seconds.
String formatSeconds(int? seconds) => seconds == null ? '–' : formatDuration(Duration(seconds: seconds));

/// Remaining time of a download; `∞` for unknown/infinite (qBittorrent sends
/// 8640000 for "never").
String formatEta(int? seconds) {
  if (seconds == null || seconds < 0 || seconds >= 8640000) return '∞';
  if (seconds == 0) return 'done';
  return formatDuration(Duration(seconds: seconds));
}

/// "just now", "5 min ago", "3 h ago", "2 days ago", "in 10 min".
/// Older than a week: the date.
String formatRelative(DateTime? instant, {DateTime? now}) {
  if (instant == null) return '–';
  final ref = now ?? DateTime.now();
  final diff = ref.difference(instant);
  final future = diff.isNegative;
  final abs = diff.abs();
  String ago(String s) => future ? 'in $s' : '$s ago';
  if (abs.inSeconds < 45) return future ? 'in a moment' : 'just now';
  if (abs.inMinutes < 60) return ago('${abs.inMinutes.clamp(1, 59)} min');
  if (abs.inHours < 24) return ago('${abs.inHours} h');
  if (abs.inDays < 7) return ago(abs.inDays == 1 ? '1 day' : '${abs.inDays} days');
  return formatDate(instant);
}

/// Device-local date ("Nov 8, 2026").
String formatDate(DateTime? instant) {
  if (instant == null) return '–';
  return DateFormat.yMMMd().format(instant.toLocal());
}

/// Device-local date and time ("Nov 8, 2026 09:41").
String formatDateTime(DateTime? instant) {
  if (instant == null) return '–';
  final local = instant.toLocal();
  return '${DateFormat.yMMMd().format(local)} ${DateFormat.Hm().format(local)}';
}

/// Device-local time of day ("09:41").
String formatTime(DateTime? instant) {
  if (instant == null) return '–';
  return DateFormat.Hm().format(instant.toLocal());
}

/// A `Date` field (`"2026-11-08"`, never time-zone converted) in the device
/// locale; unparsable input is shown as-is.
String formatCalendarDate(String? date) {
  if (date == null || date.isEmpty) return '–';
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(date);
  if (m == null) return date;
  final d = DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  return DateFormat.yMMMd().format(d);
}

/// `42 %` from a 0..100 value; `–` for null.
String formatPercent(double? percent, {int decimals = 0}) {
  if (percent == null) return '–';
  return '${percent.toStringAsFixed(decimals)} %';
}

/// Thousands separators in the device locale ("1,694").
String formatCount(int? n) => n == null ? '–' : NumberFormat.decimalPattern().format(n);
