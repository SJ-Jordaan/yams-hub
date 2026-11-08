/// Server proof verification (ARCHITECTURE §5.4, §7.5).
///
/// `GET /ping?nonce=<n>&sid=<sessionId>` answers with
/// `proof = base64url(HMAC-SHA256(serverProofKey, nonce))`. The app sends
/// tokens to a non-Tailscale URL only after the proof verifies.
///
/// The app's dependency list (ARCHITECTURE §2.1) has no crypto package, so
/// SHA-256 and HMAC (FIPS 180-4, RFC 2104) are implemented here; both are
/// covered by the published test vectors in `test/core/server_proof_test.dart`.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Generates a random nonce of 24 base64url characters (18 random bytes).
String generateProofNonce([Random? random]) {
  final r = random ?? Random.secure();
  final bytes = Uint8List.fromList([for (var i = 0; i < 18; i++) r.nextInt(256)]);
  return base64Url.encode(bytes);
}

/// `base64url(HMAC-SHA256(key, nonce))` without padding, where the key is the
/// 32 bytes that [serverProofKey] encodes (base64url).
String computeServerProof(String serverProofKey, String nonce) =>
    _b64(hmacSha256(_decodeKey(serverProofKey) ?? utf8.encode(serverProofKey), utf8.encode(nonce)));

/// Verifies [proof] for [nonce] in constant time.
///
/// The key is the decoded base64url bytes of [serverProofKey]; the UTF-8
/// bytes of the key string are accepted as well, so a gateway that keyed its
/// HMAC with the transport string still verifies (both derive from the same
/// per-session secret). Padding in [proof] is ignored.
bool verifyServerProof({
  required String serverProofKey,
  required String nonce,
  required String proof,
}) {
  final presented = _stripPadding(proof.trim());
  if (presented.isEmpty) return false;
  final message = utf8.encode(nonce);
  final keys = <List<int>>[
    ?_decodeKey(serverProofKey),
    utf8.encode(serverProofKey),
  ];
  var ok = false;
  for (final key in keys) {
    // Evaluate every candidate so timing does not depend on which matched.
    ok = _constantTimeEquals(_b64(hmacSha256(key, message)), presented) | ok;
  }
  return ok;
}

List<int>? _decodeKey(String key) {
  try {
    final bytes = base64Url.decode(base64Url.normalize(key.trim()));
    return bytes.isEmpty ? null : bytes;
  } on FormatException {
    return null;
  }
}

String _b64(List<int> bytes) => _stripPadding(base64Url.encode(bytes));

String _stripPadding(String s) {
  var end = s.length;
  while (end > 0 && s.codeUnitAt(end - 1) == 0x3d) {
    end--;
  }
  return s.substring(0, end);
}

bool _constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// HMAC-SHA256 (RFC 2104).
Uint8List hmacSha256(List<int> key, List<int> message) {
  const blockSize = 64;
  var k = key.length > blockSize ? sha256(key) : Uint8List.fromList(key);
  if (k.length < blockSize) {
    k = Uint8List(blockSize)..setRange(0, k.length, k);
  }
  final inner = Uint8List(blockSize + message.length);
  final outerPad = Uint8List(blockSize + 32);
  for (var i = 0; i < blockSize; i++) {
    inner[i] = k[i] ^ 0x36;
    outerPad[i] = k[i] ^ 0x5c;
  }
  inner.setRange(blockSize, inner.length, message);
  outerPad.setRange(blockSize, outerPad.length, sha256(inner));
  return sha256(outerPad);
}

const List<int> _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, //
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// SHA-256 (FIPS 180-4) of [data].
Uint8List sha256(List<int> data) {
  const mask = 0xffffffff;
  int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & mask;

  final bitLength = data.length * 8;
  final paddedLength = ((data.length + 9 + 63) ~/ 64) * 64;
  final msg = Uint8List(paddedLength)
    ..setRange(0, data.length, data)
    ..[data.length] = 0x80;
  final view = ByteData.sublistView(msg);
  // Bit length as a 64-bit big-endian integer (split for web, where ints are
  // doubles and setUint64 is unsupported).
  view.setUint32(paddedLength - 8, (bitLength ~/ 0x100000000) & mask);
  view.setUint32(paddedLength - 4, bitLength & mask);

  final h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  final w = List<int>.filled(64, 0);
  for (var offset = 0; offset < paddedLength; offset += 64) {
    for (var t = 0; t < 16; t++) {
      w[t] = view.getUint32(offset + t * 4);
    }
    for (var t = 16; t < 64; t++) {
      final s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3);
      final s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & mask;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var t = 0; t < 64; t++) {
      final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ ((~e & mask) & g);
      final t1 = (hh + s1 + ch + _k[t] + w[t]) & mask;
      final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & mask;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & mask;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & mask;
    }
    h[0] = (h[0] + a) & mask;
    h[1] = (h[1] + b) & mask;
    h[2] = (h[2] + c) & mask;
    h[3] = (h[3] + d) & mask;
    h[4] = (h[4] + e) & mask;
    h[5] = (h[5] + f) & mask;
    h[6] = (h[6] + g) & mask;
    h[7] = (h[7] + hh) & mask;
  }
  final out = ByteData(32);
  for (var i = 0; i < 8; i++) {
    out.setUint32(i * 4, h[i]);
  }
  return out.buffer.asUint8List();
}
