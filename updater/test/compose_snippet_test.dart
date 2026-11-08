import 'dart:io';

import 'package:test/test.dart';
import 'package:yams_hub_updater/yams_hub_updater.dart';

/// Parses compose durations such as `17m`, `90s` or `1h5m`.
Duration _composeDuration(String raw) {
  var total = Duration.zero;
  for (final m in RegExp(r'(\d+)(h|m|s)').allMatches(raw)) {
    final n = int.parse(m[1]!);
    total += switch (m[2]) {
      'h' => Duration(hours: n),
      'm' => Duration(minutes: n),
      _ => Duration(seconds: n),
    };
  }
  return total;
}

void main() {
  test('the compose snippet gives the updater time to drain its job', () {
    final snippet = File('../deploy/docker-compose.hub.yaml');
    expect(snippet.existsSync(), isTrue, reason: 'run from updater/');
    final text = snippet.readAsStringSync();
    final start = text.indexOf('\n  yams-hub-updater:\n');
    expect(start, isNonNegative);
    final block = text.substring(start);
    final m = RegExp(
      r'^    stop_grace_period:\s*(\S+)',
      multiLine: true,
    ).firstMatch(block);
    expect(m, isNotNull, reason: 'yams-hub-updater needs stop_grace_period');
    expect(
      _composeDuration(m![1]!),
      greaterThan(shutdownDrainTimeout(UpdaterConfig(token: 't' * 48))),
    );
  });
}
