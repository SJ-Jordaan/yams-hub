import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:yams_hub_gateway/yams_hub_gateway.dart';
import 'package:yams_models/yams_models.dart';

/// A clock driven by fake_async's elapsed time.
final class _AsyncClock implements Clock {
  _AsyncClock(this._async);

  final FakeAsync _async;
  final _start = DateTime.utc(2026, 11, 8, 9);

  @override
  DateTime now() => _start.add(_async.elapsed);
}

void main() {
  group('TtlCache', () {
    test('caches for ttl, single-flights concurrent misses', () {
      fakeAsync((async) {
        final cache = TtlCache<String, int>(
          't',
          const Duration(seconds: 30),
          clock: _AsyncClock(async),
        );
        var loads = 0;
        Future<int> load() async {
          loads++;
          await Future<void>.delayed(const Duration(seconds: 1));
          return loads;
        }

        final results = <int>[];
        for (var i = 0; i < 5; i++) {
          cache.value('k', load).then(results.add);
        }
        async.elapse(const Duration(seconds: 2));
        expect(results, [1, 1, 1, 1, 1]);
        expect(loads, 1);

        cache.value('k', load).then(results.add);
        async.flushMicrotasks();
        expect(results.last, 1, reason: 'fresh value');
        async.elapse(const Duration(seconds: 30));
        cache.value('k', load).then(results.add);
        async.elapse(const Duration(seconds: 2));
        expect(results.last, 2);
      });
    });

    test('stale on error within maxStale, error after', () {
      fakeAsync((async) {
        final cache = TtlCache<String, String>(
          't',
          const Duration(seconds: 10),
          clock: _AsyncClock(async),
          maxStale: const Duration(minutes: 1),
        );
        CacheResult<String>? result;
        cache.get('k', () async => 'v1').then((r) => result = r);
        async.flushMicrotasks();
        expect(result!.stale, isFalse);

        async.elapse(const Duration(seconds: 20));
        cache
            .get('k', () async => throw StateError('down'))
            .then((r) => result = r);
        async.flushMicrotasks();
        expect(result!.value, 'v1');
        expect(result!.stale, isTrue);
        expect(result!.error, isA<StateError>());

        async.elapse(const Duration(minutes: 2));
        Object? error;
        cache.get('k', () async => throw StateError('still down')).catchError((
          Object e,
        ) {
          error = e;
          return result!;
        });
        async.flushMicrotasks();
        expect(error, isA<StateError>());
      });
    });

    test('invalidate, invalidateWhere, LRU eviction', () async {
      final clock = FakeClock();
      final cache = TtlCache<int, int>(
        't',
        const Duration(minutes: 1),
        clock: clock,
        maxEntries: 3,
      );
      for (var i = 0; i < 3; i++) {
        await cache.value(i, () async => i);
      }
      await cache.value(0, () async => -1); // touch 0
      await cache.value(3, () async => 3); // evicts 1 (least recently used)
      expect(cache.peek(1), isNull);
      expect(cache.peek(0), 0);
      cache.invalidate(0);
      expect(cache.peek(0), isNull);
      cache.invalidateWhere((k) => k >= 3);
      expect(cache.peek(3), isNull);
      expect(cache.peek(2), 2);
      cache.clear();
      expect(cache.length, 0);
    });

    test(
      'an invalidation during a load does not store the outdated value',
      () async {
        final cache = TtlCache<int, int>(
          't',
          const Duration(minutes: 1),
          clock: FakeClock(),
        );
        final gate = Completer<void>();
        final pending = cache.value(1, () async {
          await gate.future;
          return 1;
        });
        cache.invalidate(1);
        gate.complete();
        expect(await pending, 1);
        expect(cache.peek(1), isNull);
      },
    );
  });

  group('DemandPoller', () {
    test('the first touch runs a tick and awaits it; runs while leased, then stops', () {
      fakeAsync((async) {
        final clock = _AsyncClock(async);
        var ticks = 0;
        final poller = DemandPoller(
          name: 'p',
          interval: const Duration(milliseconds: 1500),
          lease: const Duration(seconds: 20),
          tick: () async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            ticks++;
          },
          clock: clock,
        );
        var firstDone = false;
        poller.touch().then((_) => firstDone = true);
        async.elapse(const Duration(milliseconds: 50));
        expect(firstDone, isFalse);
        async.elapse(const Duration(milliseconds: 60));
        expect(firstDone, isTrue);
        expect(ticks, 1);
        expect(poller.isActive, isTrue);

        // A touch while active returns immediately.
        var second = false;
        poller.touch().then((_) => second = true);
        async.flushMicrotasks();
        expect(second, isTrue);

        async.elapse(const Duration(seconds: 10));
        expect(ticks, greaterThan(5));
        async.elapse(const Duration(seconds: 30));
        expect(poller.isActive, isFalse);
        final stoppedAt = ticks;
        async.elapse(const Duration(minutes: 1));
        expect(ticks, stoppedAt);

        poller.touch();
        async.elapse(const Duration(milliseconds: 200));
        expect(ticks, stoppedAt + 1);
        poller.stop();
        async.elapse(const Duration(minutes: 1));
        expect(ticks, stoppedAt + 1);
      });
    });

    test('a failing tick keeps the loop alive', () {
      fakeAsync((async) {
        var ticks = 0;
        final poller = PollerFactory(_AsyncClock(async)).create(
          'p',
          const Duration(seconds: 1),
          const Duration(seconds: 5),
          () async {
            ticks++;
            throw StateError('boom');
          },
        );
        poller.touch();
        async.elapse(const Duration(seconds: 3));
        expect(ticks, greaterThanOrEqualTo(3));
        poller.stop();
      });
    });
  });

  group('merged cursor', () {
    final clock = FakeClock();
    List<DateTime> feed(int start, int count, int stepMinutes) => [
      for (var i = 0; i < count; i++)
        DateTime.utc(
          2026,
          11,
          8,
          12,
        ).subtract(Duration(minutes: start + i * stepMinutes)),
    ];

    test('merges newest first across sources and pages to the end', () async {
      final a = feed(0, 120, 2); // even minutes
      final b = feed(1, 30, 2); // odd minutes
      final loads = <String>[];
      Map<String, FeedPageLoader<DateTime>> sources() => {
        'sonarr': (page) async {
          loads.add('sonarr:$page');
          return a.skip((page - 1) * 50).take(50).toList();
        },
        'radarr': (page) async {
          loads.add('radarr:$page');
          return b.skip((page - 1) * 50).take(50).toList();
        },
      };
      final all = <DateTime>[];
      String? cursor;
      var pages = 0;
      do {
        final page = await mergeFeeds<DateTime>(
          sources: sources(),
          dateOf: (d) => d,
          limit: 25,
          clock: clock,
          cursor: cursor,
        );
        all.addAll(page.items);
        cursor = page.nextCursor;
        pages++;
      } while (cursor != null && pages < 20);
      expect(all, hasLength(150));
      final sorted = [...all]..sort((x, y) => y.compareTo(x));
      expect(all, sorted);
      expect(all.toSet(), hasLength(150));
      expect(loads, contains('sonarr:3'));
    });

    test('expired and garbage cursors are 400 with reason cursor', () async {
      final page = await mergeFeeds<DateTime>(
        sources: {
          's': (p) async => feed(0, 60, 1).skip((p - 1) * 50).take(50).toList(),
        },
        dateOf: (d) => d,
        limit: 10,
        clock: clock,
      );
      expect(page.nextCursor, isNotNull);
      final later = FakeClock(clock.now().add(const Duration(minutes: 11)));
      for (final c in [page.nextCursor!, 'garbage', 'eyJ2IjoyfQ']) {
        try {
          MergedCursor.decode(c, later);
          fail('expected 400');
        } on ApiException catch (e) {
          expect(e.status, 400);
          expect(e.details, {'reason': 'cursor'});
        }
      }
      expect(
        MergedCursor.decode(page.nextCursor!, clock).positions['s']!.idx,
        10,
      );
    });

    test('empty sources give an empty page without a cursor', () async {
      final page = await mergeFeeds<DateTime>(
        sources: {'a': (_) async => [], 'b': (_) async => []},
        dateOf: (d) => d,
        limit: 25,
        clock: clock,
      );
      expect(page.items, isEmpty);
      expect(page.nextCursor, isNull);
      expect(page.toJson((d) => {'t': d.toIso8601String()}), {
        'items': <Object?>[],
      });
    });
  });

  test('CursorPage is the yams_models envelope', () {
    const p = CursorPage<int>(items: [1], nextCursor: 'x');
    expect(p.hasMore, isTrue);
  });
}
