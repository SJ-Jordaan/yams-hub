/// The single secret scrubber (ARCHITECTURE §5.14).
library;

final _queryValue = RegExp(
  r'''(api[_-]?key|apikey|passkey|token|password|pass|auth|sid|secret)=([^&\s"']+)''',
  caseSensitive: false,
);
final _headerValue = RegExp(
  r'(authorization|x-api-key|x-emby-token|cookie):\s*\S+(\s+\S+)?',
  caseSensitive: false,
);
final _announceKeyAfter = RegExp(r'/announce/[A-Za-z0-9]{16,}');
final _announceKeyBefore = RegExp(r'/[A-Za-z0-9]{24,}/announce');
final _hubTokens = RegExp(r'yha_[A-Za-z0-9_-]+|yhr_[A-Za-z0-9_.-]+');

/// Replaces secrets in [input] with `***`:
/// - values of `apikey=`, `token=`, `password=`, ... query/form parameters;
/// - `Authorization:`, `X-Api-Key:`, `X-Emby-Token:` and `Cookie:` header values
///   (including a second word, as in `MediaBrowser Token="..."`);
/// - private-tracker passkeys in announce paths;
/// - hub access and refresh tokens.
String redactSecrets(String input) {
  if (input.isEmpty) return input;
  var s = input.replaceAllMapped(_queryValue, (m) => '${m[1]}=***');
  s = s.replaceAllMapped(_headerValue, (m) => '${m[1]}: ***');
  s = s.replaceAll(_announceKeyAfter, '/announce/***');
  s = s.replaceAll(_announceKeyBefore, '/***/announce');
  s = s.replaceAll(_hubTokens, '***');
  return s;
}
