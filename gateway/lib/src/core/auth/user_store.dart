/// `$DATA/users.json` (ARCHITECTURE §5.4).
library;

import 'package:collection/collection.dart';
import 'package:logging/logging.dart';
import 'package:yams_models/yams_models.dart';

import '../ids.dart';
import '../store/json_file_store.dart';
import 'records.dart';

final _log = Logger('core.auth.users');

/// User names: lower case, 2..32 of `[a-z0-9._-]`.
final usernamePattern = RegExp(r'^[a-z0-9._-]{2,32}$');

/// Hub user ids: `u_<12 hex>`.
final userIdPattern = RegExp(r'^u_[0-9a-f]{12}$');

/// The user store. Reads are served from an in-memory map that is replaced on
/// every write, so loading the user on every request is free; every write is
/// flushed to disk before it returns.
final class UserStore {
  UserStore(this._file) {
    final doc = _file.read();
    final list = doc is Map ? doc['users'] : null;
    if (list is List) {
      for (final e in list) {
        final m = readMap(e);
        if (m == null) continue;
        try {
          final u = UserRecord.fromJson(m);
          _byId[u.id] = u;
        } on FormatException catch (err) {
          _log.severe('skipping a malformed user record', err);
        }
      }
    }
  }

  final JsonFileStore _file;
  final _byId = <String, UserRecord>{};

  /// Whether `users.json` existed when the gateway started.
  bool get fileExisted => _file.existedOnLoad;

  bool get isEmpty => _byId.isEmpty;

  List<UserRecord> get all =>
      _byId.values.sortedBy((u) => u.username).toList(growable: false);

  UserRecord? byId(String id) => _byId[id];

  UserRecord? byUsername(String username) {
    final n = username.trim().toLowerCase();
    return _byId.values.firstWhereOrNull((u) => u.username == n);
  }

  /// Users linked to [jellyfinUserId].
  UserRecord? byJellyfinUserId(String jellyfinUserId) =>
      _byId.values.firstWhereOrNull((u) => u.jellyfinUserId == jellyfinUserId);

  int get activeAdminCount => _byId.values.where((u) => u.isActiveAdmin).length;

  /// A fresh, unused user id.
  String newId() {
    while (true) {
      final id = 'u_${randomHex(12)}';
      if (!_byId.containsKey(id)) return id;
    }
  }

  Future<void> put(UserRecord user) async {
    _byId[user.id] = user;
    await _persist();
  }

  Future<void> remove(String id) async {
    if (_byId.remove(id) != null) await _persist();
  }

  Future<void> _persist() => _file.writeNow({
    'version': 1,
    'users': [for (final u in all) u.toJson()],
  });
}
