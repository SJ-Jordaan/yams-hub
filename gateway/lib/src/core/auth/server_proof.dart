/// Per-session server proof for `GET /ping?nonce=&sid=` (ARCHITECTURE §5.4).
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../ids.dart';

/// Nonces: 16..64 base64url characters.
final noncePattern = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

/// A new proof key: 32 random bytes, base64url without padding.
String newProofKey() => randomToken(32);

/// `base64url(HMAC-SHA256(key, nonce))` without padding, where the HMAC key
/// is the 32 decoded bytes of [proofKey] and the message is the UTF-8 nonce
/// string. Clients compute the same value from the `serverProofKey` they got
/// at login.
String computeServerProof(String proofKey, String nonce) {
  final key = decodeBase64UrlNoPad(proofKey) ?? utf8.encode(proofKey);
  final mac = Hmac(sha256, key).convert(utf8.encode(nonce));
  return base64UrlNoPad(mac.bytes);
}
