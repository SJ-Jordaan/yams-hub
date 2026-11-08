/// In-memory TTL cache with single-flight loads and stale-on-error
/// (ARCHITECTURE §5.7).
library;

import 'dart:async';

import '../clock.dart';

/// A cached value. [stale] is true when the value was served after a failed
/// refresh; [error] is that failure.
final class CacheResult<V> {
  const CacheResult(
    this.value, {
    required this.fetchedAt,
    this.stale = false,
    this.error,
  });

  final V value;
  final DateTime fetchedAt;
  final bool stale;
  final Object? error;
}

final class _Entry<V> {
  _Entry(this.value, this.fetchedAt);

  final V value;
  final DateTime fetchedAt;
}

/// A TTL cache.
///
/// - Concurrent misses for one key share one load (single-flight).
/// - When a load fails and a value younger than [maxStale] exists, that value
///   is returned with `stale: true`; otherwise the error propagates.
/// - At most [maxEntries] keys are kept (least recently used evicted).
final class TtlCache<K, V> {
  TtlCache(
    this.name,
    this.ttl, {
    required this._clock,
    Duration? maxStale,
    this.maxEntries = 1000,
  }) : maxStale = maxStale ?? ttl * 10;

  final String name;
  final Duration ttl;

  /// How old a value may be to be served after a failed refresh.
  final Duration maxStale;
  final int maxEntries;
  final Clock _clock;
  final _entries = <K, _Entry<V>>{};
  final _inflight = <K, Future<_Entry<V>>>{};
  int _generation = 0;

  int get length => _entries.length;

  /// Returns the cached value for [key] or loads it with [load].
  Future<CacheResult<V>> get(K key, Future<V> Function() load) async {
    final now = _clock.now();
    final e = _entries[key];
    if (e != null && now.difference(e.fetchedAt) < ttl) {
      _touch(key, e);
      return CacheResult(e.value, fetchedAt: e.fetchedAt);
    }
    try {
      final fresh = await _load(key, load);
      return CacheResult(fresh.value, fetchedAt: fresh.fetchedAt);
    } catch (error) {
      final old = _entries[key] ?? e;
      if (old != null && _clock.now().difference(old.fetchedAt) < maxStale) {
        return CacheResult(
          old.value,
          fetchedAt: old.fetchedAt,
          stale: true,
          error: error,
        );
      }
      rethrow;
    }
  }

  /// Like [get] but returns only the value.
  Future<V> value(K key, Future<V> Function() load) async =>
      (await get(key, load)).value;

  Future<_Entry<V>> _load(K key, Future<V> Function() load) {
    final running = _inflight[key];
    if (running != null) return running;
    final generation = _generation;
    final future = () async {
      final v = await load();
      final entry = _Entry(v, _clock.now());
      // An invalidation during the load means the value may be outdated.
      if (generation == _generation) {
        _entries.remove(key);
        _entries[key] = entry;
        _evict();
      }
      return entry;
    }();
    _inflight[key] = future;
    future.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_inflight[key], future)) _inflight.remove(key);
    });
    return future;
  }

  void _touch(K key, _Entry<V> e) {
    _entries.remove(key);
    _entries[key] = e;
  }

  void _evict() {
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// The cached value (fresh or not) without loading.
  V? peek(K key) => _entries[key]?.value;

  /// Stores [value] as freshly loaded.
  void put(K key, V value) {
    _entries.remove(key);
    _entries[key] = _Entry(value, _clock.now());
    _evict();
  }

  void invalidate(K key) {
    _generation++;
    _entries.remove(key);
    _inflight.remove(key);
  }

  void invalidateWhere(bool Function(K key) test) {
    _generation++;
    _entries.removeWhere((k, _) => test(k));
    _inflight.removeWhere((k, _) => test(k));
  }

  void clear() {
    _generation++;
    _entries.clear();
    _inflight.clear();
  }
}

/// Creates caches (`ctx.caches.ttl<K, V>(name, ttl, ...)`).
final class CacheFactory {
  CacheFactory(this._clock);

  final Clock _clock;
  final _caches = <String, Object>{};

  /// A new cache; [name] is for diagnostics and must be unique.
  TtlCache<K, V> ttl<K, V>(
    String name,
    Duration ttl, {
    Duration? maxStale,
    int maxEntries = 1000,
  }) {
    final cache = TtlCache<K, V>(
      name,
      ttl,
      clock: _clock,
      maxStale: maxStale,
      maxEntries: maxEntries,
    );
    _caches[name] = cache;
    return cache;
  }

  /// Names of the caches created so far.
  Iterable<String> get names => _caches.keys;
}
