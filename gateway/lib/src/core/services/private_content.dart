/// Which Jellyfin items and users are private (`ctx.privacy`, ARCHITECTURE
/// §5.2 "Private content"). With every `PRIVATE_*` setting unset nothing
/// here calls an upstream and every check answers "public".
library;

import 'package:logging/logging.dart';
import 'package:yams_models/yams_models.dart';

import '../../config/config.dart';
import '../cache/ttl_cache.dart';
import '../clock.dart';
import '../upstream/upstream_client.dart';

/// The private Jellyfin libraries: their ids and folders.
final class PrivateLibraries {
  const PrivateLibraries({this.ids = const {}, this.locations = const []});

  static const none = PrivateLibraries();

  /// 32-hex library (`CollectionFolder`) ids.
  final Set<String> ids;

  /// Normalised folders ([normalisePath]).
  final List<String> locations;

  bool get isEmpty => ids.isEmpty && locations.isEmpty;

  /// [path] is one of [locations] or below one.
  bool containsPath(String? path) {
    if (path == null || path.trim().isEmpty) return false;
    final p = normalisePath(path);
    for (final l in locations) {
      if (p == l || p.startsWith('$l/')) return true;
    }
    return false;
  }

  /// Lower case, forward slashes, no trailing slash. Lower case hides more
  /// rather than less when two folders differ only in case.
  static String normalisePath(String path) {
    var p = path.trim().replaceAll('\\', '/').toLowerCase();
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }
}

final _log = Logger('core.privacy');

/// The library ids an item may be filed under (`ParentId` of a movie in
/// the library root, `SeriesId`/`SeasonId` of an episode, ...).
const _parentKeys = ['ParentId', 'SeriesId', 'SeasonId', 'AlbumId'];

/// Answers whether Jellyfin items and users are private.
final class PrivateContent {
  PrivateContent({
    required this.settings,
    required UpstreamClient jellyfin,
    required CacheFactory caches,
    required this._clock,
  }) : _jf = jellyfin,
       _libraries = caches.ttl<int, PrivateLibraries>(
         'privacy.jellyfin.libraries',
         const Duration(seconds: 60),
       ),
       _users = caches.ttl<int, Set<String>>(
         'privacy.jellyfin.users',
         const Duration(minutes: 5),
       );

  final PrivateContentSettings settings;
  final UpstreamClient _jf;
  final Clock _clock;
  final TtlCache<int, PrivateLibraries> _libraries;
  final TtlCache<int, Set<String>> _users;

  /// Item id → private, with when it was decided.
  final _items = <String, ({bool private, DateTime at})>{};
  static const _itemTtl = Duration(minutes: 10);
  static const _maxItems = 5000;

  /// Ids per `/Items?ids=` call.
  static const _batch = 100;

  bool get hidesLibraries => settings.hasLibraries;
  bool get hidesUsers => settings.hasUsers;

  /// The private libraries from `/Library/VirtualFolders` (cache 60 s); no
  /// call when `PRIVATE_JELLYFIN_LIBRARIES` is unset.
  Future<PrivateLibraries> libraries() async {
    if (!hidesLibraries) return PrivateLibraries.none;
    return _libraries.value(0, () async {
      final body = await _jf.getJson('/Library/VirtualFolders');
      return librariesOf([
        if (body is List)
          for (final f in body) ?readMap(f),
      ]);
    });
  }

  /// The private libraries of a `/Library/VirtualFolders` answer the caller
  /// already has, kept as the cached [libraries].
  PrivateLibraries rememberLibraries(List<JsonMap> folders) {
    final libs = librariesOf(folders);
    if (hidesLibraries) _libraries.put(0, libs);
    return libs;
  }

  /// `PRIVATE_JELLYFIN_LIBRARIES` names that matched no Jellyfin library in
  /// the last `/Library/VirtualFolders` answer (sorted; nothing of them is
  /// hidden, so the dashboard warns admins).
  List<String> get unmatchedLibraries => _unmatched;
  List<String> _unmatched = const [];

  /// The private libraries of a `/Library/VirtualFolders` answer.
  PrivateLibraries librariesOf(List<JsonMap> folders) {
    final ids = <String>{};
    final locations = <String>[];
    if (hidesLibraries) {
      final names = {
        for (final f in folders) ?readString(f['Name'])?.trim().toLowerCase(),
      };
      final unmatched = [
        for (final n in settings.jellyfinLibraries)
          if (!names.contains(n)) n,
      ]..sort();
      if (unmatched.join(',') != _unmatched.join(',') && unmatched.isNotEmpty) {
        _log.warning(
          'PRIVATE_JELLYFIN_LIBRARIES: no Jellyfin library is named '
          '${unmatched.map((n) => '"$n"').join(', ')}; nothing of it is hidden',
        );
      }
      _unmatched = List.unmodifiable(unmatched);
    }
    for (final f in folders) {
      if (!settings.isPrivateLibrary(readString(f['Name']))) continue;
      if (normaliseJellyfinId(readString(f['ItemId'])) case final id?) {
        ids.add(id);
      }
      for (final l in readStringList(f['Locations'])) {
        if (l.trim().isNotEmpty) {
          locations.add(PrivateLibraries.normalisePath(l));
        }
      }
    }
    return PrivateLibraries(ids: ids, locations: locations);
  }

  /// Ids of the private Jellyfin users (`/Users`, cache 5 min); no call when
  /// `PRIVATE_JELLYFIN_USERS` is unset.
  Future<Set<String>> userIds() async {
    if (!hidesUsers) return const {};
    return _users.value(0, () async {
      final body = await _jf.getJson('/Users');
      return {
        if (body is List)
          for (final u in body)
            if (readMap(u) case final m?
                when settings.isPrivateUser(readString(m['Name'])))
              ?normaliseJellyfinId(readString(m['Id'])),
      };
    });
  }

  /// Whether the user named [name] is private.
  bool isPrivateUserName(String? name) => settings.isPrivateUser(name);

  /// Whether a `BaseItemDto` is private from its own fields: true when it
  /// (or its parent) is a private library or its `Path` is in one, false
  /// when its `Path` is elsewhere, null when it cannot tell.
  bool? classify(JsonMap item, PrivateLibraries libs) {
    if (libs.isEmpty) return false;
    final id = normaliseJellyfinId(readString(item['Id']));
    if (id != null && (libs.ids.contains(id) || _known(id) == true)) {
      return true;
    }
    for (final k in _parentKeys) {
      final parent = normaliseJellyfinId(readString(item[k]));
      if (parent != null &&
          (libs.ids.contains(parent) || _known(parent) == true)) {
        return true;
      }
    }
    final path = readString(item['Path']);
    if (path != null && path.trim().isNotEmpty) {
      return libs.containsPath(path);
    }
    return id == null ? null : _known(id);
  }

  /// [items] without the private ones. Items that do not say where they
  /// are filed are looked up (`/Items?ids=`, cached 10 min).
  Future<List<JsonMap>> withoutPrivateItems(List<JsonMap> items) async {
    if (!hidesLibraries || items.isEmpty) return items;
    final libs = await libraries();
    if (libs.isEmpty) return items;
    final verdicts = [for (final i in items) classify(i, libs)];
    // Kept for the image proxy, which asks about the same ids next.
    for (final (n, i) in items.indexed) {
      final id = normaliseJellyfinId(readString(i['Id']));
      if (id != null && verdicts[n] != null) _remember(id, verdicts[n]!);
    }
    final unknown = <String>{
      for (final (n, i) in items.indexed)
        if (verdicts[n] == null) ?normaliseJellyfinId(readString(i['Id'])),
    };
    final private = unknown.isEmpty
        ? const <String>{}
        : await _lookup(unknown, libs);
    return [
      for (final (n, i) in items.indexed)
        if (verdicts[n] != true &&
            !private.contains(normaliseJellyfinId(readString(i['Id']))))
          i,
    ];
  }

  /// The private ones among [ids] (any case or dashes; nulls ignored).
  Future<Set<String>> privateItemIds(Iterable<String?> ids) async {
    if (!hidesLibraries) return const {};
    final wanted = {for (final i in ids) ?normaliseJellyfinId(i)};
    if (wanted.isEmpty) return const {};
    // Without Jellyfin nothing can be checked: hide everything.
    if (!_jf.configured) return wanted;
    final libs = await libraries();
    if (libs.isEmpty) return const {};
    final out = <String>{};
    final unknown = <String>{};
    for (final id in wanted) {
      if (libs.ids.contains(id)) {
        out.add(id);
        continue;
      }
      switch (_known(id)) {
        case true:
          out.add(id);
        case false:
          break;
        case null:
          unknown.add(id);
      }
    }
    if (unknown.isNotEmpty) out.addAll(await _lookup(unknown, libs));
    return out;
  }

  /// Whether item [id] is private.
  Future<bool> isPrivateItem(String id) async =>
      (await privateItemIds([id])).isNotEmpty;

  bool? _known(String id) {
    final e = _items[id];
    if (e == null) return null;
    if (_clock.now().difference(e.at) >= _itemTtl) {
      _items.remove(id);
      return null;
    }
    return e.private;
  }

  void _remember(String id, bool private) {
    _items.remove(id);
    _items[id] = (private: private, at: _clock.now());
    while (_items.length > _maxItems) {
      _items.remove(_items.keys.first);
    }
  }

  /// Looks [ids] up in Jellyfin; returns the private ones. Items without a
  /// `Path` are decided by their series/season (one more lookup). Items
  /// Jellyfin does not know are public (nothing of them can be shown).
  Future<Set<String>> _lookup(Set<String> ids, PrivateLibraries libs) async {
    final found = await _fetch(ids);
    final out = <String>{};
    final pending = <String, List<String>>{}; // parent → children
    for (final id in ids) {
      final item = found[id];
      if (item == null) {
        _remember(id, false);
        continue;
      }
      final v = classify(item, libs);
      if (v != null) {
        _remember(id, v);
        if (v) out.add(id);
        continue;
      }
      final parents = [
        for (final k in _parentKeys) ?normaliseJellyfinId(readString(item[k])),
      ];
      if (parents.isEmpty) {
        _remember(id, false);
      } else {
        for (final p in parents) {
          (pending[p] ??= []).add(id);
        }
      }
    }
    if (pending.isNotEmpty) {
      final parents = await _fetch(pending.keys.toSet());
      final privateChildren = <String>{};
      for (final e in pending.entries) {
        final parent = parents[e.key];
        if (parent != null && classify(parent, libs) == true) {
          _remember(e.key, true);
          privateChildren.addAll(e.value);
        }
      }
      for (final children in pending.values) {
        for (final c in children) {
          final p = privateChildren.contains(c);
          _remember(c, p);
          if (p) out.add(c);
        }
      }
    }
    return out;
  }

  Future<Map<String, JsonMap>> _fetch(Set<String> ids) async {
    final list = ids.toList();
    final out = <String, JsonMap>{};
    for (var i = 0; i < list.length; i += _batch) {
      final chunk = list.sublist(
        i,
        i + _batch > list.length ? list.length : i + _batch,
      );
      final body = readMap(
        await _jf.getJson(
          '/Items',
          query: {
            'ids': chunk.join(','),
            'fields': 'Path,ParentId',
            'enableImages': false,
            'enableUserData': false,
          },
        ),
      );
      for (final item in readList(body?['Items'], (m) => m)) {
        if (normaliseJellyfinId(readString(item['Id'])) case final id?) {
          out[id] = item;
        }
      }
    }
    return out;
  }
}
