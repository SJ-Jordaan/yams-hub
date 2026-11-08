/// Demand-driven background loops (ARCHITECTURE §5.7).
library;

import 'dart:async';

import 'package:logging/logging.dart';

import '../clock.dart';

final _log = Logger('core.poller');

/// Runs [tick] every [interval] while the last [touch] is younger than
/// [lease], then stops. The first touch after idle runs a tick immediately
/// and waits for it.
final class DemandPoller {
  DemandPoller({
    required this.name,
    required this.interval,
    required this.lease,
    required this._tick,
    required this._clock,
  });

  final String name;
  final Duration interval;
  final Duration lease;
  final Future<void> Function() _tick;
  final Clock _clock;

  DateTime? _lastTouch;
  Timer? _timer;
  Future<void>? _running;
  bool _active = false;
  bool _stopped = false;
  int _ticks = 0;

  /// Whether the loop is running.
  bool get isActive => _active;

  /// Ticks run so far.
  int get ticks => _ticks;

  /// Extends the lease. When idle, starts the loop and completes after the
  /// first tick; otherwise completes immediately.
  Future<void> touch() {
    if (_stopped) return Future.value();
    _lastTouch = _clock.now();
    if (_active) return Future.value();
    _active = true;
    return _runTick();
  }

  /// Runs a tick now (e.g. right after a write) without waiting for the
  /// interval; the schedule continues from there.
  Future<void> runNow() {
    if (_stopped) return Future.value();
    _lastTouch ??= _clock.now();
    _timer?.cancel();
    _timer = null;
    if (!_active) _active = true;
    return _runTick();
  }

  Future<void> _runTick() {
    final running = _running;
    if (running != null) return running;
    final f = () async {
      try {
        _ticks++;
        await _tick();
      } catch (e, st) {
        _log.warning('poller $name tick failed', e, st);
      }
    }();
    _running = f;
    return f.whenComplete(() {
      _running = null;
      _schedule();
    });
  }

  void _schedule() {
    if (_stopped) return;
    final last = _lastTouch;
    if (last == null || _clock.now().difference(last) >= lease) {
      _active = false;
      return;
    }
    _timer?.cancel();
    _timer = Timer(interval, () {
      _timer = null;
      unawaited(_runTick());
    });
  }

  /// Stops the loop for good.
  void stop() {
    _stopped = true;
    _active = false;
    _timer?.cancel();
    _timer = null;
  }
}

/// Creates [DemandPoller]s (`ctx.pollers.create(name, interval, lease, tick)`)
/// and stops them all on shutdown.
final class PollerFactory {
  PollerFactory(this._clock);

  final Clock _clock;
  final _pollers = <DemandPoller>[];

  DemandPoller create(
    String name,
    Duration interval,
    Duration lease,
    Future<void> Function() tick,
  ) {
    final p = DemandPoller(
      name: name,
      interval: interval,
      lease: lease,
      tick: tick,
      clock: _clock,
    );
    _pollers.add(p);
    return p;
  }

  void stopAll() {
    for (final p in _pollers) {
      p.stop();
    }
  }
}
