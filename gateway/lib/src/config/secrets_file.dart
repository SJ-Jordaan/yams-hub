/// Parser for the bind-mounted secrets file (ARCHITECTURE §5.2).
library;

/// A line of the secrets file that is not `KEY='value'`. Only the line number
/// is reported, never the content (it may hold a secret).
final class SecretsFileException implements Exception {
  const SecretsFileException(this.lineNumber);

  final int lineNumber;

  String get message =>
      "secrets file line $lineNumber is not of the form KEY='value'";

  @override
  String toString() => 'SecretsFileException: $message';
}

final _line = RegExp(r"^([A-Za-z_][A-Za-z0-9_]*)='([^']*)'$");

/// Parses `KEY='value'` lines. Blank lines and lines starting with `#` are
/// ignored; values are single-quoted and may not contain a single quote. A
/// later line overrides an earlier one with the same key.
///
/// Throws [SecretsFileException] for the first line that does not parse.
Map<String, String> parseSecretsFile(String contents) {
  final out = <String, String>{};
  final lines = contents.split('\n');
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final m = _line.firstMatch(trimmed);
    if (m == null) throw SecretsFileException(i + 1);
    out[m[1]!] = m[2]!;
  }
  return out;
}
