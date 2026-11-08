/// Watchtower metrics and `/v1/check` results (integrations/system.md §3,
/// ARCHITECTURE §5.17).
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

final _metricLine = RegExp(
  r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{[^}]*\})?\s+([-+0-9.eEInfa]+)',
);

/// Parses Prometheus text into `name → value` (labelled series keep the last
/// value; comments are skipped).
Map<String, double> parsePrometheusText(String text) {
  final out = <String, double>{};
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final m = _metricLine.firstMatch(line);
    if (m == null) continue;
    final v = double.tryParse(m[2]!);
    if (v != null && v.isFinite) out[m[1]!] = v;
  }
  return out;
}

/// The last scan from `/v1/metrics` text; [at] from `/v1/status`.
WatchtowerScan parseWatchtowerMetrics(String text, {DateTime? at}) {
  final m = parsePrometheusText(text);
  int v(String name) => (m[name] ?? 0).round();
  return WatchtowerScan(
    scanned: v('watchtower_containers_scanned'),
    updated: v('watchtower_containers_updated'),
    failed: v('watchtower_containers_failed'),
    skipped: v('watchtower_containers_skipped'),
    restarted: v('watchtower_containers_restarted'),
    scansTotal: v('watchtower_scans_total'),
    at: at,
  );
}

/// One container of a `/v1/check` answer, as stored in `updates.json`.
final class UpdateCheckResult {
  const UpdateCheckResult({
    required this.name,
    required this.checkedAt,
    this.image,
    this.updateAvailable,
    this.currentDigest,
    this.latestDigest,
    this.currentVersion,
    this.error,
  });

  /// From Watchtower's JSON (`name`, `update_available`, `digest`,
  /// `latest_digest`, `current_image_version`, `error`, `timestamp`).
  static UpdateCheckResult? fromWatchtower(
    JsonMap j,
    DateTime fallbackAt,
    String Function(String) redact,
  ) {
    var name = readString(j['name']);
    if (name == null || name.isEmpty) return null;
    if (name.startsWith('/')) name = name.substring(1);
    final error = _nonEmpty(readString(j['error']));
    return UpdateCheckResult(
      name: name,
      image: _nonEmpty(readString(j['image'])),
      updateAvailable: error != null && readBool(j['update_available']) != true
          ? null
          : readBool(j['update_available']),
      currentDigest: _nonEmpty(readString(j['digest'])),
      latestDigest: _nonEmpty(readString(j['latest_digest'])),
      currentVersion: _nonEmpty(readString(j['current_image_version'])),
      error: error == null ? null : _cap(redact(error), 300),
      checkedAt: readInstant(j['timestamp']) ?? fallbackAt,
    );
  }

  static UpdateCheckResult? fromStore(JsonMap j) {
    final name = readString(j['name']);
    final at = readInstant(j['checkedAt']);
    if (name == null || at == null) return null;
    return UpdateCheckResult(
      name: name,
      image: readString(j['image']),
      updateAvailable: readBool(j['updateAvailable']),
      currentDigest: readString(j['currentDigest']),
      latestDigest: readString(j['latestDigest']),
      currentVersion: readString(j['currentVersion']),
      error: readString(j['error']),
      checkedAt: at,
    );
  }

  final String name;
  final String? image;
  final bool? updateAvailable;
  final String? currentDigest;
  final String? latestDigest;
  final String? currentVersion;
  final String? error;
  final DateTime checkedAt;

  JsonMap toJson() => compactJson({
    'name': name,
    'image': image,
    'updateAvailable': updateAvailable,
    'currentDigest': currentDigest,
    'latestDigest': latestDigest,
    'currentVersion': currentVersion,
    'error': error,
    'checkedAt': instantToJson(checkedAt),
  });
}

String? _nonEmpty(String? s) => s == null || s.trim().isEmpty ? null : s.trim();

String _cap(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

/// The cached check results (`$DATA/updates.json`), surviving restarts.
final class UpdateResultsStore {
  UpdateResultsStore(this._store) {
    _load();
  }

  final JsonFileStore _store;
  final _results = <String, UpdateCheckResult>{};
  DateTime? _checkedAt;
  DateTime? _lastFullCheckAt;

  /// When the last check (full or targeted) finished.
  DateTime? get checkedAt => _checkedAt;

  /// When the last full check finished (rate limit and the 6 h schedule).
  DateTime? get lastFullCheckAt => _lastFullCheckAt;

  UpdateCheckResult? of(String name) => _results[name];

  Iterable<UpdateCheckResult> get all => _results.values;

  void _load() {
    final doc = readMap(_store.read());
    if (doc == null) return;
    _checkedAt = readInstant(doc['checkedAt']);
    _lastFullCheckAt = readInstant(doc['lastFullCheckAt']);
    for (final r in readList(doc['results'], UpdateCheckResult.fromStore)) {
      if (r != null) _results[r.name] = r;
    }
  }

  /// Stores the results of a check. A [full] check replaces every result;
  /// a targeted one replaces only the containers it covered.
  Future<void> record(
    List<UpdateCheckResult> results, {
    required bool full,
    required DateTime at,
  }) async {
    if (full) _results.clear();
    for (final r in results) {
      _results[r.name] = r;
    }
    _checkedAt = at;
    if (full) _lastFullCheckAt = at;
    await _store.writeNow({
      'v': 1,
      'checkedAt': instantToJson(at),
      'lastFullCheckAt': optionalInstantToJson(_lastFullCheckAt),
      'results': [for (final r in _results.values) r.toJson()],
    });
  }
}
