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

  test('the updater only accepts the gateway\'s control-network address', () {
    final text = File('../deploy/docker-compose.hub.yaml').readAsStringSync();
    String block(String service) {
      final start = text.indexOf('\n  $service:\n');
      expect(start, isNonNegative, reason: service);
      final next = RegExp(r'\n  [a-z]').firstMatch(text.substring(start + 1));
      return text.substring(
        start,
        next == null ? text.length : start + 1 + next.start,
      );
    }

    final ctlAddress = RegExp(
      r'^      yams_hub_ctl:\n        ipv4_address:\s*(\S+)',
      multiLine: true,
    );
    final gateway = ctlAddress.firstMatch(block('yams-hub'))?[1];
    final updater = ctlAddress.firstMatch(block('yams-hub-updater'))?[1];
    expect(gateway, '172.30.250.2');
    expect(updater, isNotNull);

    final m = RegExp(
      r'^\s+- UPDATER_ALLOWED_SOURCES=(\S+)',
      multiLine: true,
    ).firstMatch(block('yams-hub-updater'));
    expect(
      m,
      isNotNull,
      reason: 'yams-hub-updater needs UPDATER_ALLOWED_SOURCES',
    );
    final sources = SourceAllowList.parse(m![1]!);
    expect(sources.allows(InternetAddress(gateway!)), isTrue);
    for (final other in [
      '172.30.250.1',
      '172.30.250.3',
      updater!,
      '172.28.0.49',
    ]) {
      expect(sources.allows(InternetAddress(other)), isFalse, reason: other);
    }
  });
}
