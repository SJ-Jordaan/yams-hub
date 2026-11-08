/// The Docker event stream kept open by the gateway (integrations/system.md
/// §1.6): the daemon keeps only 256 events, which healthcheck exec events
/// fill in about 80 s, so the gateway stores container events itself.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

/// Server-side filter: container events without the healthcheck exec noise.
const dockerEventFilters = {
  'type': ['container'],
  'event': [
    'start',
    'stop',
    'die',
    'kill',
    'restart',
    'oom',
    'health_status',
    'create',
    'destroy',
  ],
};

/// A parsed event with its nanosecond time (for de-duplication on
/// reconnect) and container id.
final class DockerEventRecord {
  const DockerEventRecord(this.event, this.timeNano, this.containerId);

  final ContainerEvent event;
  final int timeNano;
  final String containerId;
}

/// Parses one NDJSON line of `GET /events`; null for anything that is not a
/// container event of interest.
DockerEventRecord? parseDockerEvent(JsonMap j) {
  if (readString(j['Type']) != 'container') return null;
  final rawAction = readString(j['Action']) ?? readString(j['status']) ?? '';
  final actor = readMap(j['Actor']);
  final attrs = readMap(actor?['Attributes']) ?? const <String, Object?>{};
  final name = readString(attrs['name']);
  if (name == null || name.isEmpty) return null;
  final ContainerEventAction action;
  String? health;
  if (rawAction.startsWith('health_status')) {
    action = ContainerEventAction.health;
    final colon = rawAction.indexOf(':');
    health = colon < 0 ? null : rawAction.substring(colon + 1).trim();
  } else {
    action = ContainerEventAction.fromJson(rawAction.split(':').first.trim());
    if (action == ContainerEventAction.unknown) return null;
  }
  final timeNano =
      readInt(j['timeNano']) ?? ((readInt(j['time']) ?? 0) * 1000000000);
  if (timeNano <= 0) return null;
  final at = DateTime.fromMicrosecondsSinceEpoch(timeNano ~/ 1000, isUtc: true);
  return DockerEventRecord(
    ContainerEvent(
      at: at,
      name: name.startsWith('/') ? name.substring(1) : name,
      action: action,
      health: health == null || health.isEmpty ? null : health,
      exitCode: action == ContainerEventAction.die
          ? readInt(attrs['exitCode'])
          : null,
    ),
    timeNano,
    readString(actor?['ID']) ?? '',
  );
}

/// A ring buffer of the latest container events (newest last).
final class ContainerEventBuffer {
  ContainerEventBuffer({this.capacity = 1000});

  final int capacity;
  final _events = Queue<ContainerEvent>();
  int _lastNano = 0;

  /// Nanosecond time of the newest stored event.
  int get lastTimeNano => _lastNano;

  int get length => _events.length;

  /// Adds [r] unless it is not newer than the last stored event (a
  /// reconnect with `since=` replays the last second).
  bool add(DockerEventRecord r) {
    if (r.timeNano <= _lastNano) return false;
    _lastNano = r.timeNano;
    _events.addLast(r.event);
    while (_events.length > capacity) {
      _events.removeFirst();
    }
    return true;
  }

  /// Newest first, optionally for one container.
  List<ContainerEvent> latest({int limit = 50, String? name}) {
    final out = <ContainerEvent>[];
    for (final e in _events.toList().reversed) {
      if (name != null && e.name != name) continue;
      out.add(e);
      if (out.length >= limit) break;
    }
    return out;
  }

  /// Events of [name] newer than [since].
  Iterable<ContainerEvent> since(DateTime since, {String? name}) => _events
      .where((e) => e.at.isAfter(since) && (name == null || e.name == name));
}

/// Keeps `GET /events` open and reconnects with `since=` after drops
/// (HAProxy closes idle streams after 10 min).
final class ContainerEventStream {
  ContainerEventStream({
    required this.docker,
    required this.buffer,
    required this.onEvent,
    Logger? log,
    this.minBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
  }) : _log = log ?? Logger('feature.containers.events');

  final DockerClient docker;
  final ContainerEventBuffer buffer;

  /// Called for every new event (cache invalidation).
  final void Function(DockerEventRecord record) onEvent;
  final Duration minBackoff;
  final Duration maxBackoff;
  final Logger _log;

  // Cancelled in stop().
  // ignore: cancel_subscriptions
  StreamSubscription<String>? _sub;
  Timer? _retry;
  bool _running = false;
  Duration _backoff = Duration.zero;
  int _connections = 0;

  /// Connections opened so far (tests).
  int get connections => _connections;

  bool get isConnected => _sub != null;

  void start() {
    if (_running || !docker.configured) return;
    _running = true;
    _backoff = minBackoff;
    unawaited(_connect());
  }

  Future<void> stop() async {
    _running = false;
    _retry?.cancel();
    _retry = null;
    final s = _sub;
    _sub = null;
    await s?.cancel();
  }

  Future<void> _connect() async {
    if (!_running) return;
    final last = buffer.lastTimeNano;
    final query = <String, Object?>{'filters': jsonEncode(dockerEventFilters)};
    if (last > 0) query['since'] = '${last ~/ 1000000000}';
    try {
      final stream = await docker.openStream('/events', query: query);
      if (!_running) {
        await stream.body.listen((_) {}).cancel();
        return;
      }
      _connections++;
      _backoff = minBackoff;
      _sub = stream.body
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            _onLine,
            onError: (Object e) {
              _log.fine('docker event stream failed: $e');
              _scheduleReconnect();
            },
            onDone: _scheduleReconnect,
            cancelOnError: true,
          );
    } on UpstreamException catch (e) {
      _log.fine('docker event stream could not open: $e');
      _scheduleReconnect();
    }
  }

  void _onLine(String line) {
    final t = line.trim();
    if (t.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(t);
    } on FormatException {
      return;
    }
    final m = readMap(decoded);
    if (m == null) return;
    final r = parseDockerEvent(m);
    if (r == null) return;
    if (buffer.add(r)) onEvent(r);
  }

  void _scheduleReconnect() {
    _sub = null;
    if (!_running) return;
    _retry?.cancel();
    final wait = _backoff;
    final next = _backoff * 2;
    _backoff = next > maxBackoff ? maxBackoff : next;
    _retry = Timer(wait, () {
      _retry = null;
      unawaited(_connect());
    });
  }
}
