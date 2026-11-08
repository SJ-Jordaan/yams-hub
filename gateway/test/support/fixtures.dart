/// Loads captured upstream responses from the repository's `fixtures/`
/// directory (read-only).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

String? _root;

/// The absolute path of `fixtures/` (found by walking up from the current
/// directory, so tests work from `gateway/` and from the repo root).
String fixturesDir() {
  final cached = _root;
  if (cached != null) return cached;
  var dir = Directory.current.absolute;
  while (true) {
    final candidate = Directory(p.join(dir.path, 'fixtures'));
    if (candidate.existsSync() &&
        Directory(p.join(candidate.path, 'arr')).existsSync()) {
      return _root = candidate.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('fixtures/ not found above ${Directory.current.path}');
    }
    dir = parent;
  }
}

/// The decoded JSON of `fixtures/<relativePath>` (e.g. `arr/sonarr_series.json`).
Object? fixture(String relativePath) => jsonDecode(fixtureText(relativePath));

/// The raw text of a fixture (Prometheus metrics, log files).
String fixtureText(String relativePath) =>
    File(p.join(fixturesDir(), relativePath)).readAsStringSync();

/// The raw bytes of a fixture.
List<int> fixtureBytes(String relativePath) =>
    File(p.join(fixturesDir(), relativePath)).readAsBytesSync();
