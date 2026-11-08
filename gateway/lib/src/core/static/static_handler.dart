/// The Flutter web build at `/` (ARCHITECTURE §5.15).
library;

import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_static/shelf_static.dart';

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

/// Serves [webDir] with SPA fallback to `index.html` for extension-less
/// paths, `Cache-Control: no-cache` plus an ETag (size + mtime) on every
/// file, and a gzip cache for compressible types.
Handler createWebHandler(String webDir) {
  final dir = Directory(webDir);
  final index = File(p.join(webDir, 'index.html'));
  if (!dir.existsSync() || !index.existsSync()) {
    return (request) => Response.ok(
      '<!doctype html><meta charset="utf-8"><title>YAMS Hub</title>'
      '<p>YAMS Hub: web build not installed.</p>',
      headers: {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-cache',
      },
    );
  }
  final root = dir.resolveSymbolicLinksSync();
  final files = createStaticHandler(
    root,
    serveFilesOutsidePath: false,
    listDirectories: false,
    useHeaderBytesForContentType: false,
    defaultDocument: 'index.html',
  );
  final gzipCache = <String, List<int>>{};
  var gzipBytes = 0;
  const gzipCacheLimit = 64 * 1024 * 1024;

  return (request) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      return Response(405, headers: {'allow': 'GET, HEAD'});
    }
    final raw = request.requestedUri.path;
    if (isTraversalPath(raw) || isTraversalPath(request.url.path)) {
      return Response.notFound(
        'Not found',
        headers: {'content-type': 'text/plain; charset=utf-8'},
      );
    }
    var rel = request.url.path;
    var filePath = p.normalize(p.join(root, rel.isEmpty ? 'index.html' : rel));
    if (!p.isWithin(root, filePath) && filePath != root) {
      return Response.notFound('Not found');
    }
    var file = File(filePath);
    if (FileSystemEntity.isDirectorySync(filePath)) {
      file = File(p.join(filePath, 'index.html'));
      rel = p.join(rel, 'index.html');
    }
    if (!file.existsSync()) {
      final last = rel.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '';
      if (last.contains('.')) {
        return Response.notFound(
          'Not found',
          headers: {'content-type': 'text/plain; charset=utf-8'},
        );
      }
      // SPA route: serve index.html.
      file = index;
      rel = 'index.html';
    }
    final stat = file.statSync();
    final etag =
        '"${stat.size.toRadixString(16)}-${stat.modified.millisecondsSinceEpoch.toRadixString(16)}"';
    final inm = request.headers['if-none-match'];
    if (inm != null && inm.split(',').map((s) => s.trim()).contains(etag)) {
      return Response.notModified(
        headers: {'etag': etag, 'cache-control': 'no-cache'},
      );
    }
    final served = await files(
      Request(
        request.method,
        request.requestedUri.replace(path: '/$rel', query: ''),
        headers: {
          for (final e in request.headers.entries)
            if (e.key != 'if-modified-since' &&
                e.key != 'range' &&
                e.key != 'if-range')
              e.key: e.value,
        },
      ),
    );
    if (served.statusCode != 200) return served;
    var response = served.change(
      headers: {'etag': etag, 'cache-control': 'no-cache'},
    );
    final ext = p.extension(file.path).replaceFirst('.', '').toLowerCase();
    final accepts = (request.headers['accept-encoding'] ?? '')
        .toLowerCase()
        .contains('gzip');
    if (accepts && _compressible.contains(ext) && request.method == 'GET') {
      final key = '${file.path}|$etag';
      var gz = gzipCache.remove(key);
      if (gz == null) {
        gz = gzip.encode(await file.readAsBytes());
        gzipBytes += gz.length;
        while (gzipBytes > gzipCacheLimit && gzipCache.isNotEmpty) {
          final first = gzipCache.keys.first;
          gzipBytes -= gzipCache.remove(first)!.length;
        }
      }
      gzipCache[key] = gz;
      final headers = Map<String, Object>.of(response.headersAll)
        ..remove('content-length')
        ..remove('accept-ranges')
        ..['content-encoding'] = 'gzip'
        ..['vary'] = 'Accept-Encoding';
      await served.read().drain<void>();
      response = Response.ok(gz, headers: headers);
    }
    return response;
  };
}
