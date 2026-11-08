/// The image disk cache with growth control (ARCHITECTURE §5.8).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:yams_models/yams_models.dart';

import '../clock.dart';
import '../store/json_file_store.dart';

final _log = Logger('core.images.cache');

/// A cached image.
final class CachedImage {
  const CachedImage({
    required this.hash,
    required this.bytes,
    required this.contentType,
    required this.fetchedAt,
    this.version,
  });

  /// sha256 of the cache key (hex); also the ETag.
  final String hash;
  final Uint8List bytes;

  /// The sniffed content type.
  final String contentType;
  final DateTime fetchedAt;
  final String? version;
}

final class _IndexEntry {
  _IndexEntry(this.bytes);

  int bytes;
}

/// Files at `<dir>/<hash[0:2]>/<hash>` with a JSON sidecar `<hash>.json`
/// (`contentType`, `fetchedAt`, `bytes`, `version`).
///
/// The total size is tracked in memory (initialised by [scan]). Every write
/// evicts least recently used entries while the total exceeds [maxBytes];
/// a write that would push the total above 110 % is refused (the caller
/// serves the image pass-through).
final class ImageDiskCache {
  ImageDiskCache({
    required this.dir,
    required this.maxBytes,
    required this._clock,
  });

  final String dir;
  final int maxBytes;
  final Clock _clock;

  /// Hash → size, in LRU order (first = least recently used).
  final _index = <String, _IndexEntry>{};
  int _total = 0;
  bool _scanned = false;

  int get totalBytes => _total;
  int get entryCount => _index.length;

  /// The cache hash of [key].
  static String hashOf(String key) =>
      sha256.convert(utf8.encode(key)).toString();

  String _file(String hash) => p.join(dir, hash.substring(0, 2), hash);
  String _sidecar(String hash) => '${_file(hash)}.json';

  /// Rebuilds the in-memory index from disk (start-up and periodic prune).
  Future<void> scan() async {
    final root = Directory(dir);
    final found = <(String, int, DateTime)>[];
    if (await root.exists()) {
      await for (final e in root.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        if (name.endsWith('.json') || name.startsWith('.')) continue;
        if (!File('${e.path}.json').existsSync()) {
          // Orphan without sidecar (interrupted write).
          await _delete(e.path);
          continue;
        }
        try {
          final st = await e.stat();
          found.add((
            name,
            st.size,
            st.accessed.isAfter(st.modified) ? st.accessed : st.modified,
          ));
        } on FileSystemException {
          continue;
        }
      }
    }
    found.sort((a, b) => a.$3.compareTo(b.$3));
    _index.clear();
    _total = 0;
    for (final (hash, size, _) in found) {
      _index[hash] = _IndexEntry(size);
      _total += size;
    }
    _scanned = true;
    _evictTo(maxBytes);
  }

  /// Reads the entry for [key] (and marks it recently used).
  Future<CachedImage?> read(String key) async {
    final hash = hashOf(key);
    final entry = _index[hash];
    if (entry == null && _scanned) return null;
    try {
      final side = File(_sidecar(hash));
      final file = File(_file(hash));
      if (!await side.exists() || !await file.exists()) {
        _forget(hash);
        return null;
      }
      final meta = readMap(jsonDecode(await side.readAsString()));
      final bytes = await file.readAsBytes();
      final type = readString(meta?['contentType']);
      if (meta == null || type == null) return null;
      if (entry != null) {
        _index.remove(hash);
        _index[hash] = entry;
      }
      return CachedImage(
        hash: hash,
        bytes: bytes,
        contentType: type,
        fetchedAt: readInstant(meta['fetchedAt']) ?? _clock.now(),
        version: readString(meta['version']),
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Whether a write of [size] bytes is currently possible.
  bool canWrite(int size) =>
      size <= maxBytes && _total + size <= maxBytes * 1.1;

  /// Stores [bytes] for [key] (replacing an existing entry). Returns false
  /// when the cache refused the write (over the hard limit).
  Future<bool> write(
    String key,
    Uint8List bytes, {
    required String contentType,
    String? version,
  }) async {
    final hash = hashOf(key);
    final previous = _index[hash]?.bytes ?? 0;
    if (_total - previous + bytes.length > maxBytes) {
      _evictTo(maxBytes - bytes.length, keep: hash);
    }
    if (bytes.length > maxBytes ||
        _total - previous + bytes.length > maxBytes * 1.1) {
      return false;
    }
    try {
      await writeFileAtomic(_file(hash), bytes);
      await writeFileAtomic(
        _sidecar(hash),
        utf8.encode(
          jsonEncode(
            compactJson({
              'contentType': contentType,
              'fetchedAt': instantToJson(_clock.now()),
              'bytes': bytes.length,
              'version': version,
            }),
          ),
        ),
      );
    } on FileSystemException catch (e) {
      _log.warning('image cache write failed', e);
      return false;
    }
    _forget(hash);
    _index[hash] = _IndexEntry(bytes.length);
    _total += bytes.length;
    _evictTo(maxBytes, keep: hash);
    return true;
  }

  void _forget(String hash) {
    final e = _index.remove(hash);
    if (e != null) _total -= e.bytes;
  }

  void _evictTo(int target, {String? keep}) {
    while (_total > target && _index.isNotEmpty) {
      final victim = _index.keys.firstWhere((h) => h != keep, orElse: () => '');
      if (victim.isEmpty) break;
      _forget(victim);
      unawaited(_delete(_file(victim)));
      unawaited(_delete(_sidecar(victim)));
    }
  }

  Future<void> _delete(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // already gone
    }
  }
}

/// Per-user limit for new remote cache entries per minute.
final class RemoteEntryLimiter {
  RemoteEntryLimiter(this.perMinute, this._clock);

  final int perMinute;
  final Clock _clock;
  final _byUser = <String, List<DateTime>>{};

  /// Counts a new entry for [userId]; false when over the limit.
  bool tryAcquire(String userId) {
    final now = _clock.now();
    final list = _byUser.putIfAbsent(userId, () => []);
    list.removeWhere((t) => now.difference(t) >= const Duration(minutes: 1));
    if (list.length >= perMinute) return false;
    list.add(now);
    return true;
  }
}

/// Magic-byte sniffing for the allowed raster types; null for anything else
/// (SVG, HTML, unknown).
String? sniffImageType(List<int> b) {
  bool at(int offset, List<int> sig) {
    if (b.length < offset + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (b[offset + i] != sig[i]) return false;
    }
    return true;
  }

  if (at(0, const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (at(0, const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (at(0, const [0x52, 0x49, 0x46, 0x46]) &&
      at(8, const [0x57, 0x45, 0x42, 0x50])) {
    return 'image/webp';
  }
  if (at(0, const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (at(4, const [0x66, 0x74, 0x79, 0x70]) &&
      (at(8, const [0x61, 0x76, 0x69, 0x66]) ||
          at(8, const [0x61, 0x76, 0x69, 0x73]))) {
    return 'image/avif';
  }
  return null;
}

/// The raster types the image proxy serves.
const allowedImageTypes = {
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/gif',
  'image/avif',
};

/// Whether an upstream `Content-Type` is acceptable: absent, generic binary,
/// or one of [allowedImageTypes]. SVG, HTML, XML, scripts and text never are.
bool acceptableUpstreamImageType(String? contentType) {
  if (contentType == null || contentType.trim().isEmpty) return true;
  final main = contentType.split(';').first.trim().toLowerCase();
  if (main == 'application/octet-stream' || main == 'binary/octet-stream') {
    return true;
  }
  if (main == 'image/jpg' || main == 'image/pjpeg') return true;
  return allowedImageTypes.contains(main);
}
