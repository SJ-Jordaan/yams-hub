import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/servers/server_proof.dart';

String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('sha256 (FIPS 180-4 vectors)', () {
    test('empty, abc, two-block and one-million-a messages', () {
      expect(hex(sha256([])), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(hex(sha256(utf8.encode('abc'))), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(
        hex(sha256(utf8.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
      expect(
        hex(sha256(List.filled(1000000, 0x61))),
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
      );
    });

    test('padding boundaries (55, 56, 64 bytes)', () {
      expect(
        hex(sha256(List.filled(55, 0x61))),
        '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318',
      );
      expect(
        hex(sha256(List.filled(56, 0x61))),
        'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a',
      );
      expect(
        hex(sha256(List.filled(64, 0x61))),
        'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb',
      );
    });
  });

  group('hmacSha256 (RFC 4231 vectors)', () {
    test('test case 1', () {
      expect(
        hex(hmacSha256(List.filled(20, 0x0b), utf8.encode('Hi There'))),
        'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7',
      );
    });
    test('test case 2', () {
      expect(
        hex(hmacSha256(utf8.encode('Jefe'), utf8.encode('what do ya want for nothing?'))),
        '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
      );
    });
    test('test case 6 (key longer than a block)', () {
      expect(
        hex(hmacSha256(List.filled(131, 0xaa), utf8.encode('Test Using Larger Than Block-Size Key - Hash Key First'))),
        '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54',
      );
    });
  });

  group('server proof', () {
    const key = 'q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA';
    const nonce = 'abcdefghijklmnopqrstuvwx';

    test('proof = base64url(HMAC-SHA256(decoded key, nonce)) without padding', () {
      final expected = base64Url
          .encode(hmacSha256(base64Url.decode(base64Url.normalize(key)), utf8.encode(nonce)))
          .replaceAll('=', '');
      expect(computeServerProof(key, nonce), expected);
      expect(verifyServerProof(serverProofKey: key, nonce: nonce, proof: expected), isTrue);
    });

    test('padded proofs verify too', () {
      final padded = base64Url.encode(hmacSha256(base64Url.decode(base64Url.normalize(key)), utf8.encode(nonce)));
      expect(padded, endsWith('='));
      expect(verifyServerProof(serverProofKey: key, nonce: nonce, proof: padded), isTrue);
    });

    test('a gateway keyed with the UTF-8 key string verifies as well', () {
      final utf8Proof = base64Url.encode(hmacSha256(utf8.encode(key), utf8.encode(nonce))).replaceAll('=', '');
      expect(verifyServerProof(serverProofKey: key, nonce: nonce, proof: utf8Proof), isTrue);
    });

    test('wrong key, wrong nonce, tampered or empty proofs fail', () {
      final proof = computeServerProof(key, nonce);
      expect(verifyServerProof(serverProofKey: 'AAAA$key', nonce: nonce, proof: proof), isFalse);
      expect(verifyServerProof(serverProofKey: key, nonce: '${nonce}y', proof: proof), isFalse);
      final tampered = '${proof.substring(0, proof.length - 1)}${proof.endsWith('A') ? 'B' : 'A'}';
      expect(verifyServerProof(serverProofKey: key, nonce: nonce, proof: tampered), isFalse);
      expect(verifyServerProof(serverProofKey: key, nonce: nonce, proof: ''), isFalse);
    });

    test('nonces are 24 base64url characters', () {
      final n = generateProofNonce(Random(1));
      expect(n, hasLength(24));
      expect(RegExp(r'^[A-Za-z0-9_-]{24}$').hasMatch(n), isTrue);
      expect(generateProofNonce(), isNot(generateProofNonce()));
    });
  });
}
