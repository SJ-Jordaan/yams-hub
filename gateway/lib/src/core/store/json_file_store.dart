/// Atomic JSON files under `$DATA` (ARCHITECTURE §5.5 `ctx.stores`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../posix.dart';

final _log = Logger('core.store');
final _random = Random.secure();

/// Writes [contents] to [path] atomically (temp file in the same directory,
/// then rename) with mode 0600.
Future<void> writeFileAtomic(String path, List<int> contents) async {
  final dir = p.dirname(path);
  await Directory(dir).create(recursive: true);
  final tmp = p.join(
    dir,
    '.${p.basename(path)}.${_random.nextInt(1 << 32).toRadixString(16)}.tmp',
  );
  final file = File(tmp);
  try {
    await file.writeAsBytes(contents, flush: true);
    chmod(tmp, 384); // 0600
    await file.rename(path);
  } catch (_) {
    if (await file.exists()) await file.delete();
    rethrow;
  }
}

/// Synchronous variant of [writeFileAtomic] (used while shutting down).
void writeFileAtomicSync(String path, List<int> contents) {
  final dir = p.dirname(path);
  Directory(dir).createSync(recursive: true);
  final tmp = p.join(
    dir,
    '.${p.basename(path)}.${_random.nextInt(1 << 32).toRadixString(16)}.tmp',
  );
  final file = File(tmp);
  try {
    file.writeAsBytesSync(contents, flush: true);
    chmod(tmp, 384);
    file.renameSync(path);
  } catch (_) {
    if (file.existsSync()) file.deleteSync();
    rethrow;
  }
}

/// One JSON document on disk. Reads are served from memory; [write] replaces
/// the document and schedules a debounced flush, [writeNow] flushes at once.
final class JsonFileStore {
  JsonFileStore(this.path, {this.debounce = const Duration(seconds: 2)});

  final String path;
  final Duration debounce;

  Object? _value;
  bool _loaded = false;
  bool _dirty = false;
  Timer? _timer;
  Future<void> _writing = Future.value();

  /// Whether the file existed when it was first read.
  bool existedOnLoad = false;

  /// The current document (`null` when the file does not exist yet).
  Object? read() {
    if (!_loaded) _load();
    return _value;
  }

  void _load() {
    _loaded = true;
    final file = File(path);
    if (!file.existsSync()) return;
    existedOnLoad = true;
    try {
      _value = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      // Keep the broken file for inspection; start empty.
      _log.severe(
        'store ${p.basename(path)} is not valid JSON; ignoring it',
        e,
      );
      try {
        file.copySync('$path.corrupt');
      } on FileSystemException {
        // best effort
      }
    }
  }

  /// Replaces the document and flushes after [debounce].
  void write(Object? value) {
    _loaded = true;
    _value = value;
    _dirty = true;
    _timer ??= Timer(debounce, () {
      _timer = null;
      unawaited(flush().catchError((Object _) {}));
    });
  }

  /// Replaces the document and writes it before returning.
  Future<void> writeNow(Object? value) {
    _loaded = true;
    _value = value;
    _dirty = true;
    return flush();
  }

  /// Writes pending changes.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    // A failed earlier write must not poison the chain: every flush gets its
    // own attempt (the earlier caller already saw that error).
    _writing = _writing.catchError((Object _) {}).then((_) async {
      if (!_dirty) return;
      _dirty = false;
      try {
        await writeFileAtomic(path, utf8.encode(jsonEncode(_value)));
      } catch (e) {
        _dirty = true;
        _log.severe('could not write ${p.basename(path)}', e);
        rethrow;
      }
    });
    return _writing;
  }

  /// Flushes synchronously (process shutdown).
  void flushSync() {
    _timer?.cancel();
    _timer = null;
    if (!_dirty) return;
    _dirty = false;
    writeFileAtomicSync(path, utf8.encode(jsonEncode(_value)));
  }
}

/// Opens [JsonFileStore]s under the data directory. Names are plain file
/// names (`updates.json`); every store is flushed by [closeAll].
final class StoreFactory {
  StoreFactory(this.dataDir);

  final String dataDir;
  final _stores = <String, JsonFileStore>{};
  static final _validName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$');

  /// Returns the store for [name] (one instance per name).
  JsonFileStore open(
    String name, {
    Duration debounce = const Duration(seconds: 2),
  }) {
    if (!_validName.hasMatch(name) || name.contains('..')) {
      throw ArgumentError.value(name, 'name', 'invalid store name');
    }
    return _stores.putIfAbsent(
      name,
      () => JsonFileStore(p.join(dataDir, name), debounce: debounce),
    );
  }

  /// Flushes every open store.
  Future<void> closeAll() async {
    for (final s in _stores.values) {
      try {
        await s.flush();
      } catch (_) {
        // logged by the store
      }
    }
  }
}
