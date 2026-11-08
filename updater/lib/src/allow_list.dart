/// The services the updater may touch: `docker compose config --services`
/// minus the deny-list, refreshed every 10 minutes (ARCHITECTURE §5.17).
library;

import 'dart:async';

import 'package:logging/logging.dart';

import 'config.dart';
import 'process_runner.dart';

final _log = Logger('updater.allow_list');

/// Caches the compose service list.
base class ServiceAllowList {
  ServiceAllowList({
    required this._runner,
    required List<String> configCommand,
    required Set<String> deny,
    this.refreshInterval = const Duration(minutes: 10),
    this.commandTimeout = const Duration(minutes: 2),
    DateTime Function()? clock,
  }) : _configCommand = List.unmodifiable(configCommand),
       _deny = Set.unmodifiable(deny),
       _clock = clock ?? DateTime.now;

  final ProcessRunner _runner;
  final List<String> _configCommand;
  final Set<String> _deny;
  final DateTime Function() _clock;
  final Duration refreshInterval;
  final Duration commandTimeout;

  Set<String> _services = const {};
  DateTime? _loadedAt;
  Timer? _timer;
  Future<bool>? _inFlight;

  /// When the list was last loaded successfully (null: never).
  DateTime? get loadedAt => _loadedAt;

  /// Allow-listed services (compose services minus the deny-list), sorted.
  List<String> get services =>
      (_services.where((s) => !_deny.contains(s)).toList()..sort());

  /// Whether [service] may be updated.
  bool allows(String service) =>
      isValidServiceName(service) &&
      !_deny.contains(service) &&
      _services.contains(service);

  /// Like [allows], but loads the list first if it was never loaded (the
  /// start-up refresh failed, e.g. while the daemon was restarting).
  Future<bool> allowsFresh(String service) async {
    if (!isValidServiceName(service) || _deny.contains(service)) return false;
    if (_loadedAt == null) await refresh();
    return allows(service);
  }

  /// Like [services], but loads the list first if it was never loaded, so
  /// a failed start-up refresh does not make the gateway cache an empty list
  /// for 10 minutes.
  Future<List<String>> servicesFresh() async {
    if (_loadedAt == null) await refresh();
    return services;
  }

  /// Loads the list now and every [refreshInterval] after.
  Future<void> start() async {
    _timer?.cancel();
    _timer = Timer.periodic(refreshInterval, (_) => unawaited(refresh()));
    await refresh();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Runs `compose config --services`. On failure the previous list stays.
  /// Concurrent callers share one run. Returns whether the run succeeded.
  Future<bool> refresh() => _inFlight ??= _refresh().whenComplete(() {
    _inFlight = null;
  });

  Future<bool> _refresh() async {
    final found = <String>{};
    final stderr = <String>[];
    var ignored = 0;
    final CommandResult result;
    try {
      result = await _runner.run(
        _configCommand,
        timeout: commandTimeout,
        onLine: (stream, line) {
          if (stream == OutputStream.stderr) {
            if (stderr.length < 3) stderr.add(_clip(line));
            return;
          }
          final name = line.trim();
          if (name.isEmpty) return;
          if (isValidServiceName(name)) {
            found.add(name);
          } else {
            ignored++;
          }
        },
      );
    } on Object catch (e) {
      _log.warning('compose config failed to run (${e.runtimeType})');
      return false;
    }
    if (!result.succeeded) {
      final why =
          result.startError ??
          (result.timedOut ? 'timed out' : 'exit code ${result.exitCode}');
      _log.warning(
        'compose config --services failed ($why); keeping '
        '${_services.length} known services'
        '${stderr.isEmpty ? '' : ': ${stderr.join(' | ')}'}',
      );
      return false;
    }
    if (found.isEmpty) {
      _log.warning(
        'compose config --services listed no services; keeping the old list',
      );
      return false;
    }
    if (ignored > 0) _log.warning('ignored $ignored invalid service names');
    final changed =
        found.length != _services.length || !found.containsAll(_services);
    _services = Set.unmodifiable(found);
    _loadedAt = _clock().toUtc();
    if (changed) {
      _log.info(
        'allow-list: ${services.length} services '
        '(${found.length} in compose, ${_deny.length} denied)',
      );
    }
    return true;
  }
}

String _clip(String s) => s.length <= 200 ? s : '${s.substring(0, 200)}…';
