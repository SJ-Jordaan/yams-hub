/// Audit `params` sanitisation (ARCHITECTURE §5.13).
library;

import 'dart:convert';

const _secretKeyParts = [
  'password',
  'token',
  'secret',
  'key',
  'passkey',
  'cookie',
  'authorization',
  'proof',
  'torrentfilesbase64',
];

const _maxString = 200;
const _maxParamsBytes = 4096;

bool _isSecretKey(String key) {
  final k = key.toLowerCase();
  return _secretKeyParts.any(k.contains);
}

/// Reduces a URL to `scheme://host` (and `magnet:` links to their info hash).
/// Returns null when [s] is not an absolute URL.
String? reduceUrl(String s) {
  final t = s.trim();
  if (t.toLowerCase().startsWith('magnet:')) {
    final m = RegExp(
      r'xt=urn:btih:([A-Za-z0-9]+)',
      caseSensitive: false,
    ).firstMatch(t);
    return m == null ? 'magnet:' : 'magnet:${m[1]!.toLowerCase()}';
  }
  final u = Uri.tryParse(t);
  if (u == null || !u.hasScheme || u.host.isEmpty || t.contains(' ')) {
    return null;
  }
  return '${u.scheme}://${u.host}';
}

Object? _sanitizeValue(Object? v, {bool urlList = false}) {
  switch (v) {
    case null:
    case bool():
    case num():
      return v;
    case String():
      final reduced = reduceUrl(v);
      if (reduced != null) return reduced;
      if (urlList) return v.length > 8 ? '${v.substring(0, 8)}...' : v;
      return v.length > _maxString ? '${v.substring(0, _maxString)}...' : v;
    case Map():
      return {
        for (final e in v.entries)
          '${e.key}': _isSecretKey('${e.key}')
              ? '***'
              : _sanitizeValue(e.value, urlList: '${e.key}' == 'urls'),
      };
    case Iterable():
      return [for (final e in v) _sanitizeValue(e, urlList: urlList)];
    default:
      return _sanitizeValue(v.toString());
  }
}

/// Sanitises audit [params]: secret-looking keys are replaced by `***` at any
/// depth, URLs are reduced to `scheme://host` (magnets to `magnet:<hash>`),
/// strings are truncated to 200 characters and the whole map is capped at
/// 4 KB (then `{"truncated": true}`).
Map<String, Object?>? sanitizeAuditParams(Map<String, Object?>? params) {
  if (params == null) return null;
  final out = _sanitizeValue(params) as Map<String, Object?>;
  if (utf8.encode(jsonEncode(out)).length > _maxParamsBytes) {
    return {'truncated': true};
  }
  return out;
}

final _username = RegExp(r'^[a-z0-9._-]{2,32}$');

/// The `target` of an `auth.login_failed` entry: the username only when it
/// looks like one (a password typed into the username field is never stored).
String loginFailedTarget(String username) =>
    _username.hasMatch(username) ? username : '<invalid>';
