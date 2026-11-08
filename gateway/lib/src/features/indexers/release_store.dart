/// Server-side memory of manual-search results (API.md §10.4): the client
/// only ever sees an opaque `releaseId`; the download links stay here.
library;

import 'package:yams_hub_gateway/src/core/clock.dart';
import 'package:yams_hub_gateway/src/core/ids.dart';

import 'prowlarr_mapping.dart';

/// `releaseId → {indexerId, downloadUrl, magnetUrl}` for [ttl] (Prowlarr's
/// own release cache lives about as long).
final class ReleaseStore {
  ReleaseStore({
    required this._clock,
    this.ttl = const Duration(minutes: 30),
    this.maxEntries = 5000,
  });

  final Clock _clock;
  final Duration ttl;
  final int maxEntries;

  // Map literals keep insertion order = age order (entries never refresh).
  final _entries = <String, _Stored>{};

  int get length {
    _prune();
    return _entries.length;
  }

  /// Stores [links] and returns its new token.
  String put(ProwlarrReleaseLinks links) {
    _prune();
    String id;
    do {
      id = 'rel_${randomHex(24)}';
    } while (_entries.containsKey(id));
    _entries[id] = _Stored(links, _clock.now().add(ttl));
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return id;
  }

  /// The links of [releaseId], or null when unknown or expired.
  ProwlarrReleaseLinks? get(String releaseId) {
    _prune();
    return _entries[releaseId]?.links;
  }

  void _prune() {
    final now = _clock.now();
    while (_entries.isNotEmpty) {
      final first = _entries.entries.first;
      if (first.value.expires.isAfter(now)) break;
      _entries.remove(first.key);
    }
  }
}

final class _Stored {
  const _Stored(this.links, this.expires);

  final ProwlarrReleaseLinks links;
  final DateTime expires;
}
