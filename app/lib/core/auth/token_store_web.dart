/// Dev web token storage: memory plus `sessionStorage` (ARCHITECTURE §7.6).
///
/// Only used when the page is not served by the gateway (cookie transport
/// uses `NoopTokenStore`). flutter_secure_storage needs WebCrypto, which plain
/// HTTP pages do not get, so tokens live for the browser tab only.
library;

import 'package:web/web.dart' as web;

import 'token_store.dart';

class SessionStorageTokenBackend implements TokenBackend {
  final _memory = MemoryTokenBackend();

  @override
  Future<String?> read(String key) async {
    final cached = await _memory.read(key);
    if (cached != null) return cached;
    try {
      return web.window.sessionStorage.getItem(key);
    } catch (_) {
      return null; // storage disabled
    }
  }

  @override
  Future<void> write(String key, String value) async {
    await _memory.write(key, value);
    try {
      web.window.sessionStorage.setItem(key, value);
    } catch (_) {
      // Memory only.
    }
  }

  @override
  Future<void> delete(String key) async {
    await _memory.delete(key);
    try {
      web.window.sessionStorage.removeItem(key);
    } catch (_) {
      // Nothing stored.
    }
  }
}

TokenStore createPlatformTokenStore() => BackendTokenStore(SessionStorageTokenBackend());
