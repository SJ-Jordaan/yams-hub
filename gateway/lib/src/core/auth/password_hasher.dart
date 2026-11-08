/// PBKDF2-HMAC-SHA256 password hashing with a global verification semaphore
/// (ARCHITECTURE §5.4).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';

import '../http/api_exception.dart';
import '../ids.dart';

final _log = Logger('core.auth.password');

/// Iteration bounds accepted when parsing a stored hash.
const minHashIterations = 100000;
const maxHashIterations = 5000000;

/// Iterations used for new hashes when one verification at the configured
/// count takes longer than [slowVerifyThreshold].
const fallbackIterations = 310000;
const slowVerifyThreshold = Duration(milliseconds: 1500);

const _prefix = 'pbkdf2-sha256';
const _saltBytes = 16;
const _hashBytes = 32;

/// A stored hash that parsed.
final class ParsedHash {
  const ParsedHash(this.iterations, this.salt, this.hash);

  final int iterations;
  final Uint8List salt;
  final Uint8List hash;
}

/// PBKDF2-HMAC-SHA256 with a 32-byte output (one block).
Uint8List pbkdf2Sha256(List<int> password, List<int> salt, int iterations) {
  final hmac = Hmac(sha256, password);
  final first = Uint8List(salt.length + 4)
    ..setAll(0, salt)
    ..[salt.length + 3] = 1;
  var u = hmac.convert(first).bytes;
  final t = Uint8List.fromList(u);
  for (var i = 1; i < iterations; i++) {
    u = hmac.convert(u).bytes;
    for (var j = 0; j < _hashBytes; j++) {
      t[j] ^= u[j];
    }
  }
  return t;
}

/// The two jobs a hasher runs; replaceable in tests.
typedef VerifyFunction = Future<bool> Function(String password, String stored);
typedef HashFunction = Future<String> Function(String password, int iterations);

Future<bool> _isolateVerify(String password, String stored) =>
    Isolate.run(() => PasswordHasher.verifySync(password, stored));

Future<String> _isolateHash(String password, int iterations) =>
    Isolate.run(() => PasswordHasher.hashSync(password, iterations));

/// Bounds concurrent password work: at most [maxRunning] jobs run and at most
/// [maxQueued] wait; any further caller gets `429 rate_limited` with
/// `Retry-After: 2` without hashing.
final class VerificationGate {
  VerificationGate({this.maxRunning = 2, this.maxQueued = 8});

  final int maxRunning;
  final int maxQueued;
  int _running = 0;
  final _queue = Queue<Completer<void>>();

  int get running => _running;
  int get queued => _queue.length;

  Future<T> run<T>(Future<T> Function() job) async {
    if (_running >= maxRunning) {
      if (_queue.length >= maxQueued) {
        throw ApiException.rateLimited(
          2,
          'The server is busy verifying passwords; try again in a moment.',
        );
      }
      final c = Completer<void>();
      _queue.add(c);
      await c.future;
    } else {
      _running++;
    }
    try {
      return await job();
    } finally {
      if (_queue.isNotEmpty) {
        // Hand the slot to the next waiter; the running count is unchanged.
        _queue.removeFirst().complete();
      } else {
        _running--;
      }
    }
  }
}

/// Hashes and verifies passwords. Every verification and every new hash goes
/// through one [VerificationGate].
final class PasswordHasher {
  PasswordHasher({
    required int iterations,
    VerificationGate? gate,
    VerifyFunction? verifyFunction,
    HashFunction? hashFunction,
  }) : _configuredIterations = iterations,
       _iterations = iterations,
       gate = gate ?? VerificationGate(),
       _verify = verifyFunction ?? _isolateVerify,
       _hash = hashFunction ?? _isolateHash;

  final int _configuredIterations;
  int _iterations;
  final VerificationGate gate;
  final VerifyFunction _verify;
  final HashFunction _hash;
  Future<String>? _dummyHash;
  Duration? _lastMeasurement;
  final _reportedBad = <String>{};

  /// The configured iteration count (what [autoTune] measures).
  int get configuredIterations => _configuredIterations;

  /// Iterations used for new hashes (may be lowered by [autoTune]).
  int get iterations => _iterations;

  /// The verification time measured by [autoTune].
  Duration? get lastMeasurement => _lastMeasurement;

  /// Parses `pbkdf2-sha256$<iterations>$<salt>$<hash>`; null for anything
  /// malformed (fail closed).
  static ParsedHash? parse(String stored) {
    final parts = stored.split(r'$');
    if (parts.length != 4 || parts[0] != _prefix) return null;
    if (!RegExp(r'^[1-9][0-9]{0,7}$').hasMatch(parts[1])) return null;
    final iterations = int.parse(parts[1]);
    if (iterations < minHashIterations || iterations > maxHashIterations) {
      return null;
    }
    if (parts[2].contains('=') || parts[3].contains('=')) return null;
    final salt = decodeBase64UrlNoPad(parts[2]);
    final hash = decodeBase64UrlNoPad(parts[3]);
    if (salt == null || salt.length != _saltBytes) return null;
    if (hash == null || hash.length != _hashBytes) return null;
    return ParsedHash(iterations, salt, hash);
  }

  /// Computes a new hash on the calling isolate.
  static String hashSync(String password, int iterations, {List<int>? salt}) {
    final s = salt ?? randomBytes(_saltBytes);
    final h = pbkdf2Sha256(utf8.encode(password), s, iterations);
    return [
      _prefix,
      '$iterations',
      base64UrlNoPad(s),
      base64UrlNoPad(h),
    ].join(r'$');
  }

  /// Verifies on the calling isolate; false for a malformed [stored] value.
  static bool verifySync(String password, String stored) {
    final parsed = parse(stored);
    if (parsed == null) return false;
    final h = pbkdf2Sha256(
      utf8.encode(password),
      parsed.salt,
      parsed.iterations,
    );
    return constantTimeBytesEqual(h, parsed.hash);
  }

  /// Verifies [password] against [stored] through the gate. A malformed hash
  /// never verifies (logged at `severe` once per [subject]); the dummy hash is
  /// verified instead so the timing stays the same.
  Future<bool> verify(String password, String stored, {String? subject}) async {
    if (parse(stored) == null) {
      final key = subject ?? '<unknown>';
      if (_reportedBad.add(key)) {
        _log.severe(
          'stored password hash for $key is malformed; it never verifies',
        );
      }
      await verifyDummy(password);
      return false;
    }
    return gate.run(() => _verify(password, stored));
  }

  /// Verifies against a fixed dummy hash (unknown user names), so the
  /// response time does not reveal whether the user exists.
  Future<void> verifyDummy(String password) async {
    final dummy = await (_dummyHash ??= _hash(
      'dummy-${randomHex(16)}',
      _iterations,
    ));
    await gate.run(() => _verify(password, dummy));
  }

  /// Hashes [password] with [iterations] through the gate.
  Future<String> hash(String password) =>
      gate.run(() => _hash(password, _iterations));

  /// Times one verification at the configured iteration count. When it takes
  /// longer than 1.5 s, new hashes use 310 000 iterations (existing hashes keep
  /// their stored count).
  Future<Duration> autoTune() async {
    final sample = await _hash(
      'auto-tune-${randomHex(8)}',
      _configuredIterations,
    );
    final sw = Stopwatch()..start();
    await _verify('auto-tune-mismatch', sample);
    sw.stop();
    _lastMeasurement = sw.elapsed;
    if (sw.elapsed > slowVerifyThreshold &&
        _configuredIterations > fallbackIterations) {
      _iterations = fallbackIterations;
      _log.warning(
        'one PBKDF2 verification took ${sw.elapsedMilliseconds} ms at '
        '$_configuredIterations iterations; new hashes use $fallbackIterations',
      );
    }
    _dummyHash = _hash('dummy-${randomHex(16)}', _iterations);
    return sw.elapsed;
  }
}
