/// Automatic provider retry policy (ARCHITECTURE §7.2), passed to
/// `ProviderScope(retry: hubRetry)`.
library;

import 'api_exception.dart';

/// No retry for gateway answers below 500 or for non-API errors; network
/// failures and 5xx answers are retried at most twice (after 1 s, then 3 s).
Duration? hubRetry(int retryCount, Object error) {
  final e = ApiException.tryFrom(error);
  if (e == null) return null;
  if (e.status > 0 && e.status < 500) return null;
  if (e.code == ClientErrorCode.resultUnknown || e.code == ClientErrorCode.noServer) return null;
  return switch (retryCount) {
    0 => const Duration(seconds: 1),
    1 => const Duration(seconds: 3),
    _ => null,
  };
}
