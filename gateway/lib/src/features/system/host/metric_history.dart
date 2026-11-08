/// The sampler's ring buffers (API.md §13): 5 s resolution for 1 h and 1 min
/// averages for 24 h.
library;

import 'package:yams_models/yams_models.dart';

/// A fixed-capacity FIFO that overwrites its oldest element.
final class RingBuffer<T> {
  RingBuffer(this.capacity) : assert(capacity > 0);

  final int capacity;
  final _items = <T?>[];
  var _start = 0;

  int get length => _items.length;
  bool get isEmpty => _items.isEmpty;

  void add(T item) {
    if (_items.length < capacity) {
      _items.add(item);
    } else {
      _items[_start] = item;
      _start = (_start + 1) % capacity;
    }
  }

  /// Oldest first.
  List<T> toList() => [
    for (var i = 0; i < _items.length; i++)
      _items[(_start + i) % _items.length] as T,
  ];

  /// The newest [n] elements, oldest first.
  List<T> last(int n) {
    final all = toList();
    return n >= all.length ? all : all.sublist(all.length - n);
  }

  T? get newest => _items.isEmpty
      ? null
      : _items[(_start + _items.length - 1) % _items.length];

  void clear() {
    _items.clear();
    _start = 0;
  }
}

/// The values of one sample; a metric the sampler could not read is absent.
typedef MetricValues = Map<HostMetricKind, double>;

/// One point in time with its metric values.
final class HistoryEntry {
  const HistoryEntry(this.t, this.values);

  final DateTime t;
  final MetricValues values;
}

/// Raw 5 s samples for the last hour plus per-minute averages for the last
/// 24 hours.
final class MetricHistory {
  MetricHistory({
    this.sampleInterval = const Duration(seconds: 5),
    this.fineWindow = const Duration(hours: 1),
    this.coarseWindow = const Duration(hours: 24),
    this.bucket = const Duration(minutes: 1),
  }) : _fine = RingBuffer(
         fineWindow.inMilliseconds ~/ sampleInterval.inMilliseconds,
       ),
       _coarse = RingBuffer(
         coarseWindow.inMilliseconds ~/ bucket.inMilliseconds,
       );

  final Duration sampleInterval;
  final Duration fineWindow;
  final Duration coarseWindow;
  final Duration bucket;

  final RingBuffer<HistoryEntry> _fine;
  final RingBuffer<HistoryEntry> _coarse;

  DateTime? _bucketStart;
  final _sums = <HostMetricKind, double>{};
  final _counts = <HostMetricKind, int>{};

  /// Records one sample taken at [t] (UTC).
  void add(DateTime t, MetricValues values) {
    _fine.add(HistoryEntry(t, Map.unmodifiable(values)));
    final start = _bucketOf(t);
    final current = _bucketStart;
    if (current != null && start != current) _closeBucket();
    _bucketStart = start;
    for (final e in values.entries) {
      _sums[e.key] = (_sums[e.key] ?? 0) + e.value;
      _counts[e.key] = (_counts[e.key] ?? 0) + 1;
    }
  }

  /// The newest [n] raw values of [metric], oldest first.
  List<double> recent(HostMetricKind metric, int n) => [
    for (final e in _fine.last(n)) ?e.values[metric],
  ];

  /// The series of [metric] over [range], ending at [now]: raw samples for
  /// `1h`, minute averages (the running minute included) for `24h`.
  List<MetricSeriesPoint> series(
    HostMetricKind metric,
    HostHistoryRange range,
    DateTime now,
  ) {
    final since = now.subtract(range.duration);
    final entries = switch (range) {
      HostHistoryRange.hour => _fine.toList(),
      HostHistoryRange.day => [..._coarse.toList(), ?_runningBucket()],
    };
    return [
      for (final e in entries)
        if (!e.t.isBefore(since))
          if (e.values[metric] case final v?)
            MetricSeriesPoint(t: e.t, v: _round(v)),
    ];
  }

  void clear() {
    _fine.clear();
    _coarse.clear();
    _bucketStart = null;
    _sums.clear();
    _counts.clear();
  }

  DateTime _bucketOf(DateTime t) {
    final ms = bucket.inMilliseconds;
    final utc = t.toUtc().millisecondsSinceEpoch;
    return DateTime.fromMillisecondsSinceEpoch(utc - utc % ms, isUtc: true);
  }

  HistoryEntry? _runningBucket() {
    final start = _bucketStart;
    if (start == null || _counts.isEmpty) return null;
    return HistoryEntry(start, {
      for (final k in _counts.keys) k: _sums[k]! / _counts[k]!,
    });
  }

  void _closeBucket() {
    final entry = _runningBucket();
    if (entry != null) _coarse.add(entry);
    _sums.clear();
    _counts.clear();
  }

  static double _round(double v) => (v * 100).roundToDouble() / 100;
}
