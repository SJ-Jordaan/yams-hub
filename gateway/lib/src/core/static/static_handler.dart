/// The Flutter web build at `/` (ARCHITECTURE §5.15).
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_static/shelf_static.dart';

final _log = Logger('core.static');

const _compressible = {
  'js',
  'mjs',
  'wasm',
  'json',
  'html',
  'css',
  'txt',
  'otf',
  'ttf',
};

/// Files at or below this size are served uncompressed.
const gzipMinBytes = 1024;

/// Upper bound of the in-memory gzip cache (LRU).
const _gzipCacheLimit = 64 * 1024 * 1024;

/// `Cache-Control` of `canvaskit-<engineRevision>/…`.
const immutableCacheControl = 'public, max-age=31536000, immutable';

/// Files compressed first during warm-up (the ones every start loads).
const _warmFirst = [
  'index.html',
  'flutter_bootstrap.js',
  'main.dart.js',
  'canvaskit/canvaskit.js',
  'canvaskit/canvaskit.wasm',
  'canvaskit/chromium/canvaskit.js',
  'canvaskit/chromium/canvaskit.wasm',
];

final _engineRevisionPattern = RegExp(
  r'"engineRevision"\s*:\s*"([0-9a-fA-F]{6,64})"',
);
final _revisionedCanvasKit = RegExp(r'^canvaskit-([^/]*)/(.+)$');

/// Whether the raw request path tries to leave the web root (`..`, raw or
/// percent-encoded, encoded slashes or backslashes).
bool isTraversalPath(String rawPath) {
  final lower = rawPath.toLowerCase();
  if (lower.contains('..') ||
      lower.contains('%2e%2e') ||
      lower.contains('%2e.') ||
      lower.contains('.%2e') ||
      lower.contains('%2f') ||
      lower.contains('%5c') ||
      lower.contains('\\') ||
      lower.contains('%00')) {
    return true;
  }
  final decoded = Uri.decodeFull(rawPath);
  return decoded.split('/').any((s) => s == '..' || s == '.');
}

/// Serves [webDir]; see [StaticWebHandler]. Pre-compression starts only
/// when [StaticWebHandler.warmUp] is called (`Hub.start`).
Handler createWebHandler(String webDir) => StaticWebHandler(webDir).call;

/// Identity of one version of a file: absolute path, size and mtime.
typedef _FileKey = ({String path, int size, int mtime});

/// Serves the Flutter web build:
///
/// - SPA fallback to `index.html` for extension-less paths;
/// - `Cache-Control: no-cache` with a content-hash ETag (sha256 of the bytes,
///   computed in a background isolate and remembered per path, size and
///   mtime), so a redeploy that rewrites identical files still answers
///   `304`. Until a file's hash is known the ETag is size + mtime; that tag
///   stays accepted while the file is unchanged;
/// - gzip for compressible types over [gzipMinBytes], compressed ahead of
///   time by [warmUp] (level 9, in background isolates). A file that is not
///   compressed yet is served uncompressed and queued: compression never
///   runs on the request path;
/// - `canvaskit-<engineRevision>/…` (the revision from the build's
///   `flutter_bootstrap.js`) mapped onto `canvaskit/…` with
///   [immutableCacheControl]; any other revision is `404`.
final class StaticWebHandler {
  StaticWebHandler(String webDir) {
    final dir = Directory(webDir);
    final index = File(p.join(webDir, 'index.html'));
    installed = dir.existsSync() && index.existsSync();
    if (!installed) return;
    _root = dir.resolveSymbolicLinksSync();
    _index = File(p.join(_root, 'index.html'));
    _files = createStaticHandler(
      _root,
      serveFilesOutsidePath: false,
      listDirectories: false,
      useHeaderBytesForContentType: false,
      defaultDocument: 'index.html',
    );
    _engineRevision = _readEngineRevision(_root);
  }

  /// Whether [webDir] holds a web build (`index.html`).
  late final bool installed;

  /// The Flutter engine revision of the build, if `flutter_bootstrap.js`
  /// names one.
  String? get engineRevision => _engineRevision;
  String? _engineRevision;

  late final String _root;
  late final File _index;
  late final Handler _files;

  /// Content hashes (ETags) per absolute path, valid for one size + mtime.
  final _hashes = <String, ({_FileKey key, String etag})>{};
  final _hashing = <_FileKey, Future<String?>>{};

  /// gzip bodies by file key, least recently used first.
  final _gzip = <_FileKey, Uint8List>{};
  var _gzipBytes = 0;
  final _compressing = <_FileKey, Future<void>>{};

  Future<void>? _warm;

  /// Bytes currently held by the gzip cache (tests).
  int get gzipCacheBytes => _gzipBytes;

  /// Hashes, then gzips, every servable file in the background (each file
  /// in its own short-lived isolate). Idempotent; the future completes when
  /// both passes are done and never fails.
  Future<void> warmUp() => _warm ??= _warmUp();

  Future<void> _warmUp() async {
    if (!installed) return;
    final sw = Stopwatch()..start();
    try {
      final files = await _listFiles();
      for (final f in files) {
        final key = _keyOf(f);
        if (key != null) await _hashFor(key);
      }
      for (final f in files) {
        final key = _keyOf(f);
        if (key != null && _wantsGzip(key)) await _compress(key);
      }
      _log.info(
        'web build warmed up: ${files.length} files, '
        '${(_gzipBytes / 1024).round()} KiB gzip, '
        '${sw.elapsedMilliseconds} ms',
      );
    } catch (e, st) {
      _log.warning('web build warm-up failed', e, st);
    }
  }

  Future<List<File>> _listFiles() async {
    final all = <File>[];
    await for (final e in Directory(
      _root,
    ).list(recursive: true, followLinks: false)) {
      if (e is File) all.add(e);
    }
    int rank(File f) {
      final i = _warmFirst.indexOf(
        p.split(p.relative(f.path, from: _root)).join('/'),
      );
      return i < 0 ? _warmFirst.length : i;
    }

    all.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.path.compareTo(b.path);
    });
    return all;
  }

  static _FileKey? _keyOf(File f) {
    try {
      final stat = f.statSync();
      if (stat.type != FileSystemEntityType.file) return null;
      return (
        path: f.path,
        size: stat.size,
        mtime: stat.modified.millisecondsSinceEpoch,
      );
    } on FileSystemException {
      return null;
    }
  }

  static String _statEtag(_FileKey k) =>
      '"${k.size.toRadixString(16)}-${k.mtime.toRadixString(16)}"';

  static bool _wantsGzip(_FileKey k) =>
      k.size > gzipMinBytes &&
      _compressible.contains(
        p.extension(k.path).replaceFirst('.', '').toLowerCase(),
      );

  String? _knownHash(_FileKey k) {
    final h = _hashes[k.path];
    return h != null && h.key == k ? h.etag : null;
  }

  /// The content-hash ETag of [k] (single-flight, in an isolate); null when
  /// the file changed while it was read.
  Future<String?> _hashFor(_FileKey k) {
    final known = _knownHash(k);
    if (known != null) return Future.value(known);
    return _hashing[k] ??= () async {
      try {
        final hex = await _sha256InIsolate(k.path);
        if (_keyOf(File(k.path)) != k) return null;
        final etag = '"${hex.substring(0, 32)}"';
        _hashes[k.path] = (key: k, etag: etag);
        return etag;
      } on Object catch (e) {
        _log.fine('could not hash ${k.path}: $e');
        return null;
      } finally {
        unawaited(_hashing.remove(k));
      }
    }();
  }

  /// gzips [k] into the cache (single-flight, in an isolate).
  Future<void> _compress(_FileKey k) {
    if (_gzip.containsKey(k)) return Future.value();
    return _compressing[k] ??= () async {
      try {
        final gz = await _gzipInIsolate(k.path);
        if (_keyOf(File(k.path)) != k) return;
        // Drop older versions of the same file.
        for (final old in [
          for (final o in _gzip.keys)
            if (o.path == k.path) o,
        ]) {
          _gzipBytes -= _gzip.remove(old)!.length;
        }
        _gzip[k] = gz;
        _gzipBytes += gz.length;
        while (_gzipBytes > _gzipCacheLimit && _gzip.length > 1) {
          _gzipBytes -= _gzip.remove(_gzip.keys.first)!.length;
        }
      } on Object catch (e) {
        _log.fine('could not gzip ${k.path}: $e');
      } finally {
        unawaited(_compressing.remove(k));
      }
    }();
  }

  Uint8List? _gzipFor(_FileKey k) {
    final gz = _gzip.remove(k);
    if (gz != null) _gzip[k] = gz; // most recently used
    return gz;
  }

  static Response _notFound() => Response.notFound(
    'Not found',
    headers: {'content-type': 'text/plain; charset=utf-8'},
  );

  /// The shelf handler.
  Future<Response> call(Request request) async {
    if (!installed) {
      return Response.ok(
        '<!doctype html><meta charset="utf-8"><title>YAMS Hub</title>'
        '<p>YAMS Hub: web build not installed.</p>',
        headers: {
          'content-type': 'text/html; charset=utf-8',
          'cache-control': 'no-cache',
        },
      );
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      return Response(405, headers: {'allow': 'GET, HEAD'});
    }
    final raw = request.requestedUri.path;
    if (isTraversalPath(raw) || isTraversalPath(request.url.path)) {
      return _notFound();
    }
    var rel = request.url.path;
    var cacheControl = 'no-cache';
    final revisioned = _revisionedCanvasKit.firstMatch(rel);
    if (revisioned != null) {
      final rev = engineRevision;
      if (rev == null || revisioned[1] != rev) return _notFound();
      rel = 'canvaskit/${revisioned[2]}';
      cacheControl = immutableCacheControl;
    }
    final filePath = p.normalize(
      p.join(_root, rel.isEmpty ? 'index.html' : rel),
    );
    if (!p.isWithin(_root, filePath) && filePath != _root) {
      return Response.notFound('Not found');
    }
    var file = File(filePath);
    if (FileSystemEntity.isDirectorySync(filePath)) {
      file = File(p.join(filePath, 'index.html'));
      rel = p.join(rel, 'index.html');
    }
    if (!file.existsSync()) {
      final last = rel.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '';
      if (last.contains('.') || revisioned != null) return _notFound();
      // SPA route: serve index.html.
      file = _index;
      rel = 'index.html';
    }
    final key = _keyOf(file);
    if (key == null) return _notFound();
    final statEtag = _statEtag(key);
    var etag = _knownHash(key);
    final inm = request.headers['if-none-match'];
    final tags = inm == null
        ? const <String>{}
        : {for (final t in inm.split(',')) t.trim()};
    if (etag == null && tags.isNotEmpty && !tags.contains(statEtag)) {
      // A conditional request after a redeploy: the content hash decides,
      // which is much cheaper for a phone than the full download.
      etag = await _hashFor(key);
    } else if (etag == null) {
      unawaited(_hashFor(key));
    }
    etag ??= statEtag;
    final gzipType = _wantsGzip(key);
    if (tags.contains(etag) || tags.contains(statEtag)) {
      // A 304 carries the Vary the 200 would (RFC 9110 §15.4.5).
      return Response.notModified(
        headers: {
          'etag': etag,
          'cache-control': cacheControl,
          if (gzipType) 'vary': 'Accept-Encoding',
        },
      );
    }
    final served = await _files(
      Request(
        request.method,
        request.requestedUri.replace(path: '/$rel', query: ''),
        headers: {
          for (final e in request.headers.entries)
            if (e.key != 'if-modified-since' &&
                e.key != 'if-none-match' &&
                e.key != 'range' &&
                e.key != 'if-range')
              e.key: e.value,
        },
      ),
    );
    if (served.statusCode != 200) return served;
    var response = served.change(
      headers: {
        'etag': etag,
        'cache-control': cacheControl,
        if (gzipType) 'vary': 'Accept-Encoding',
      },
    );
    final accepts = (request.headers['accept-encoding'] ?? '')
        .toLowerCase()
        .contains('gzip');
    if (accepts && gzipType && request.method == 'GET') {
      final gz = _gzipFor(key);
      if (gz == null) {
        // Not compressed yet: serve the file as is and compress it in the
        // background for the next request.
        unawaited(_compress(key));
      } else {
        final headers = Map<String, Object>.of(response.headersAll)
          ..remove('content-length')
          ..remove('accept-ranges')
          ..['content-encoding'] = 'gzip';
        await served.read().drain<void>();
        response = Response.ok(gz, headers: headers);
      }
    }
    return response;
  }

  // Static, so the isolate closures capture nothing but the path.
  static Future<String> _sha256InIsolate(String path) => Isolate.run(
    () => sha256.convert(File(path).readAsBytesSync()).toString(),
  );

  static Future<Uint8List> _gzipInIsolate(String path) => Isolate.run(() {
    final out = GZipCodec(level: 9).encode(File(path).readAsBytesSync());
    return out is Uint8List ? out : Uint8List.fromList(out);
  });

  static String? _readEngineRevision(String root) {
    try {
      final f = File(p.join(root, 'flutter_bootstrap.js'));
      if (!f.existsSync()) return null;
      return _engineRevisionPattern.firstMatch(f.readAsStringSync())?[1];
    } on FileSystemException {
      return null;
    }
  }
}
