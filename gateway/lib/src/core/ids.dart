/// Random identifiers and token helpers.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

final _random = Random.secure();

/// [n] cryptographically random bytes.
Uint8List randomBytes(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = _random.nextInt(256);
  }
  return out;
}

/// [chars] random lower-case hex characters.
String randomHex(int chars) {
  final sb = StringBuffer();
  for (var i = 0; i < chars; i++) {
    sb.write(_random.nextInt(16).toRadixString(16));
  }
  return sb.toString();
}

/// base64url without padding.
String base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Decodes base64url with or without padding; null when invalid.
Uint8List? decodeBase64UrlNoPad(String s) {
  if (!RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(s)) return null;
  final padded = s.padRight((s.length + 3) ~/ 4 * 4, '=');
  try {
    return base64Url.decode(padded);
  } on FormatException {
    return null;
  }
}

/// [n] random bytes as base64url without padding.
String randomToken(int n) => base64UrlNoPad(randomBytes(n));

/// sha256 of the UTF-8 bytes of [s], hex.
String sha256Hex(String s) => sha256.convert(utf8.encode(s)).toString();

/// Compares two strings in time independent of where they differ.
bool constantTimeEquals(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  var diff = x.length ^ y.length;
  final n = x.length < y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    diff |= x[i] ^ y[i];
  }
  return diff == 0;
}

/// Compares two byte lists in constant time.
bool constantTimeBytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
