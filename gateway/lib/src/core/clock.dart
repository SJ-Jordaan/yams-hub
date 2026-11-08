/// Time source for the gateway (ARCHITECTURE §5.5 `ctx.clock`).
library;

/// Returns the current instant in UTC. Production uses [SystemClock]; tests
/// inject a [FakeClock] they can advance.
abstract interface class Clock {
  DateTime now();
}

/// The wall clock, in UTC.
final class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now().toUtc();
}

/// A manually advanced clock for tests.
final class FakeClock implements Clock {
  FakeClock([DateTime? start])
    : _now = (start ?? DateTime.utc(2026, 11, 8, 9)).toUtc();

  DateTime _now;

  @override
  DateTime now() => _now;

  /// Moves the clock forward by [d].
  void advance(Duration d) => _now = _now.add(d);

  /// Sets the clock to [instant].
  void set(DateTime instant) => _now = instant.toUtc();
}
