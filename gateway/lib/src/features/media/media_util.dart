/// Small helpers shared by the media services.
library;

import 'dart:async';

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

/// Jellyfin ticks (100 ns) per second.
const ticksPerSecond = 10000000;

/// Seconds from Jellyfin ticks.
int? ticksToSeconds(Object? ticks) {
  final t = readInt(ticks);
  return t == null ? null : t ~/ ticksPerSecond;
}

/// Rounds a 0..1 ratio to 4 decimals (stable ETags between polls).
double ratio(num value) => (value.clamp(0, 1) * 10000).round() / 10000;

/// Runs [load] and maps an [UpstreamException] to the API error of a route
/// that did not address the upstream resource itself (an upstream 404 is a
/// 502, not a 404).
Future<T> upstreamGuard<T>(Future<T> Function() load) async {
  try {
    return await load();
  } on UpstreamException catch (e) {
    throw e.toApiException(resourceNotFound: false);
  }
}

/// [future]'s value, or null when it fails or takes longer than [timeout]
/// (the load keeps running and warms its cache). [onError] sees failures.
Future<T?> optional<T>(
  Future<T> future, {
  Duration timeout = const Duration(seconds: 3),
  void Function(Object error)? onError,
}) async {
  try {
    return await future.timeout(timeout);
  } on TimeoutException {
    // `timeout` keeps listening to [future], so a late failure is handled.
    return null;
  } on Exception catch (e) {
    onError?.call(e);
    return null;
  }
}

/// `1,694` (thousands separators, like the app's `formatCount`).
String groupThousands(int n) {
  final s = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

/// `1 movie` / `179 movies`.
String plural(int n, String one, [String? many]) =>
    '${groupThousands(n)} ${n == 1 ? one : (many ?? '${one}s')}';

/// The API error for an arbitrary failure (dashboard part errors).
ApiError apiErrorOf(Object error, String requestId) => switch (error) {
  ApiException() => error.toApiError(requestId),
  UpstreamException() =>
    error.toApiException(resourceNotFound: false).toApiError(requestId),
  _ => ApiException.internal().toApiError(requestId),
};
