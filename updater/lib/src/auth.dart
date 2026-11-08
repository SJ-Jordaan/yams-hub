/// Bearer token check (ARCHITECTURE §5.17).
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Compares presented bearer tokens with the configured one in constant time.
///
/// Both sides are hashed with SHA-256 first, so the comparison always runs
/// over 32 bytes and neither the length nor a common prefix of the real token
/// leaks through timing.
final class BearerAuth {
  BearerAuth(String token)
    : _expected = sha256.convert(utf8.encode(token)).bytes;

  final List<int> _expected;

  static final _bearer = RegExp(r'^Bearer[ ]+(\S+)[ ]*$', caseSensitive: false);

  /// Whether the `Authorization` header value [header] carries the token.
  bool accepts(String? header) {
    if (header == null) return false;
    final m = _bearer.firstMatch(header);
    if (m == null) return false;
    return constantTimeEquals(
      sha256.convert(utf8.encode(m[1]!)).bytes,
      _expected,
    );
  }
}

/// Constant-time equality of two byte lists of the same length. Lists of
/// different lengths compare unequal (their length is not secret here: both
/// are SHA-256 digests).
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
