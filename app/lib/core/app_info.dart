/// Compile-time facts about this app build.
library;

import 'platform/platform.dart';

/// The app version (kept in step with `pubspec.yaml`). Compared with the
/// gateway's `minAppVersion` and sent in `X-YAMS-Client`.
const String hubAppVersion = '1.0.0';

/// The gateway API version this app speaks (`/api/v1`).
const int supportedApiVersion = 1;

/// Product name shown in the UI.
const String appTitle = 'YAMS Hub';

/// Value of the `X-YAMS-Client` header sent on every request
/// (`yams-hub/<version> (<platform>)`, API.md §1.3).
String get hubClientHeader => 'yams-hub/$hubAppVersion ($platformLabel)';

/// Compares two `major.minor.patch` versions (missing parts count as 0,
/// pre-release/build suffixes are ignored). Negative when [a] < [b].
int compareVersions(String a, String b) {
  List<int> parts(String v) => [
    for (final p in v.split(RegExp(r'[-+]')).first.split('.'))
      int.tryParse(p.trim()) ?? 0,
  ];
  final pa = parts(a), pb = parts(b);
  for (var i = 0; i < 3; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// Why this app cannot talk to a gateway, or null when it can.
String? incompatibilityReason({required int apiVersion, required String minAppVersion}) {
  if (apiVersion > supportedApiVersion) return 'This hub needs a newer app.';
  if (apiVersion < supportedApiVersion) return 'This hub needs an older app.';
  if (compareVersions(hubAppVersion, minAppVersion) < 0) {
    return 'This hub needs app version $minAppVersion or newer.';
  }
  return null;
}
