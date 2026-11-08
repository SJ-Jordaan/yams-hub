/// JSON read helpers shared by every model file (ARCHITECTURE §4).
///
/// All readers are lenient: they accept the representations upstreams and
/// older gateways are known to send and return `null` (or an empty list, or the
/// enum fallback) instead of throwing when a value has the wrong shape. Required
/// fields are enforced with [req], which throws a [FormatException].
library;

/// A decoded JSON object.
typedef JsonMap = Map<String, Object?>;

/// Returns [v] or throws a [FormatException] naming [field] when it is null.
///
/// Use it for required fields: `req(readString(j['id']), 'id')`.
T req<T>(T? v, String field) =>
    v ?? (throw FormatException('Missing or invalid required field "$field"'));

/// Reads an integer.
///
/// Accepts an `int`, a finite `double` without a fractional part, and a numeric
/// string (`"42"`, `" 42 "`, `"42.0"`).
int? readInt(Object? v) {
  switch (v) {
    case int():
      return v;
    case double() when v.isFinite && v == v.truncateToDouble():
      return v.toInt();
    case String():
      final s = v.trim();
      // radix 10: `int.tryParse` would otherwise accept `0x1F`.
      return int.tryParse(s, radix: 10) ?? readInt(double.tryParse(s));
    default:
      return null;
  }
}

/// Reads a finite floating point number from a `num` or a numeric string.
///
/// `NaN` and infinities yield `null`: they cannot be written back as JSON.
double? readDouble(Object? v) {
  final d = switch (v) {
    num() => v.toDouble(),
    String() => double.tryParse(v.trim()),
    _ => null,
  };
  return d != null && d.isFinite ? d : null;
}

/// Reads a string. Numbers and booleans are converted with `toString()`.
String? readString(Object? v) {
  switch (v) {
    case String():
      return v;
    case num() || bool():
      return v.toString();
    default:
      return null;
  }
}

/// Reads a boolean from a `bool` or the strings `"true"`/`"false"`
/// (case-insensitive).
bool? readBool(Object? v) {
  switch (v) {
    case bool():
      return v;
    case String():
      switch (v.trim().toLowerCase()) {
        case 'true':
          return true;
        case 'false':
          return false;
      }
      return null;
    default:
      return null;
  }
}

/// Reads an instant and returns it in UTC.
///
/// Strings without a zone designator are interpreted as UTC (several .NET
/// upstreams omit the `Z`). The .NET "no value" sentinel `0001-01-01T00:00:00Z`
/// (any instant in year 1) yields `null`.
DateTime? readInstant(Object? v) {
  final DateTime? utc = switch (v) {
    DateTime() => v.toUtc(),
    String() => _parseInstant(v.trim()),
    _ => null,
  };
  if (utc == null || utc.year <= 1) return null;
  return utc;
}

DateTime? _parseInstant(String s) {
  final parsed = DateTime.tryParse(s);
  if (parsed == null || parsed.isUtc) return parsed;
  // No zone designator: re-parse as UTC rather than copying the local-time
  // fields, which the local time zone may have shifted (DST gaps).
  return DateTime.tryParse('${s}Z') ??
      DateTime.utc(
        parsed.year,
        parsed.month,
        parsed.day,
        parsed.hour,
        parsed.minute,
        parsed.second,
        parsed.millisecond,
        parsed.microsecond,
      );
}

/// Serialises an instant as an ISO-8601 UTC string with `Z`.
///
/// Fractional seconds are only written when they are non-zero
/// (`2026-11-08T07:41:48Z`, `2026-11-08T07:41:48.250Z`).
String instantToJson(DateTime d) {
  final s = d.toUtc().toIso8601String();
  if (s.endsWith('.000000Z')) return '${s.substring(0, s.length - 8)}Z';
  if (s.endsWith('.000Z')) return '${s.substring(0, s.length - 5)}Z';
  return s;
}

/// [instantToJson] for optional fields: `null` stays `null` (and is then
/// dropped by [compactJson]).
String? optionalInstantToJson(DateTime? d) =>
    d == null ? null : instantToJson(d);

/// Reads a JSON object. Maps with non-string keys are converted when every key
/// is a string; anything else yields `null`.
JsonMap? readMap(Object? v) {
  if (v is Map<String, Object?>) return v;
  if (v is Map && v.keys.every((k) => k is String)) {
    return v.cast<String, Object?>();
  }
  return null;
}

/// Reads a list of objects, decoding each element with [f].
///
/// A missing or non-list value yields an empty list. Elements that are not
/// JSON objects are skipped; a [FormatException] thrown by [f] propagates.
List<T> readList<T>(Object? v, T Function(JsonMap) f) {
  if (v is! List) return <T>[];
  return [
    for (final e in v)
      if (readMap(e) case final m?) f(m),
  ];
}

/// Reads a list of strings. Non-string elements are converted where
/// [readString] can, otherwise skipped.
List<String> readStringList(Object? v) {
  if (v is! List) return const <String>[];
  return [for (final e in v) ?readString(e)];
}

/// Reads a list of integers. Elements [readInt] cannot read are skipped.
List<int> readIntList(Object? v) {
  if (v is! List) return const <int>[];
  return [for (final e in v) ?readInt(e)];
}

/// Reads an enum serialised by its `name`. Unknown or missing values yield
/// [fallback] (by convention the enum's `unknown` member); it never throws.
T readEnum<T extends Enum>(Object? v, List<T> values, T fallback) =>
    readOptionalEnum(v, values) ?? fallback;

/// Like [readEnum] but returns `null` when the value is missing or unknown.
T? readOptionalEnum<T extends Enum>(Object? v, List<T> values) {
  if (v is! String) return null;
  for (final e in values) {
    if (e.name == v) return e;
  }
  return null;
}

/// Returns a copy of [m] without its `null` values (top level only).
///
/// `toJson` implementations wrap their map with this so optional fields are
/// omitted rather than written as `null` (ARCHITECTURE §3).
JsonMap compactJson(JsonMap m) => {
  for (final e in m.entries)
    if (e.value != null) e.key: e.value,
};
