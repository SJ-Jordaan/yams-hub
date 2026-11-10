import 'dart:convert';

import 'package:test/test.dart';

import '../../support/test_hub.dart';
import 'indexers_test_support.dart';

/// Waits for job [id] and returns it through `GET /jobs/{id}`.
Future<Job> _finished(TestHub hub, String id) async {
  await hub.ctx.jobs.get(id)!.done;
  final r = await hub.get('/api/v1/jobs/$id');
  expect(r.status, 200, reason: r.body);
  return Job.fromJson(readMap(r.map['job'])!);
}

void main() {
  late TestHub hub;

  setUp(() {
    hub = TestHub();
    fakeProwlarrReads(hub.fakes);
  });
  tearDown(() => hub.close());

  group('PATCH /indexers', () {
    test('bulk-disables and answers the fresh list', () async {
      var disabled = false;
      hub.fakes
        ..on(ServiceId.prowlarr, 'PUT', '/api/v1/indexer/bulk', (r) {
          disabled = true;
          return FakeResponse.json(<Object?>[], status: 202);
        })
        ..on(ServiceId.prowlarr, 'GET', '/api/v1/indexer', (_) {
          return FakeResponse.json([
            for (final i in indexersWithUindex())
              {
                ...readMap(i)!,
                if (disabled && readMap(i)!['id'] == 15) 'enable': false,
              },
          ]);
        });
      // Warm the cache: the write must invalidate it.
      await hub.get('/api/v1/indexers');

      final r = await hub.patch(
        '/api/v1/indexers',
        body: {
          'ids': [15, 15],
          'enabled': false,
        },
      );
      expect(r.status, 200, reason: r.body);
      final list = IndexerList.fromJson(r.map);
      expect(
        list.items.firstWhere((i) => i.id == 15).status,
        IndexerStatus.disabled,
      );
      final put = hub.fakes
          .callsTo(ServiceId.prowlarr)
          .singleWhere((c) => c.method == 'PUT');
      expect(put.path, '/api/v1/indexer/bulk');
      expect(_json(put.body), {
        'ids': [15],
        'enable': false,
      });
    });

    test('sets priority', () async {
      hub.fakes.on(
        ServiceId.prowlarr,
        'PUT',
        '/api/v1/indexer/bulk',
        (_) => FakeResponse.json(<Object?>[], status: 202),
      );
      final r = await hub.patch(
        '/api/v1/indexers',
        body: {
          'ids': [4, 5],
          'priority': 10,
        },
      );
      expect(r.status, 200, reason: r.body);
      final put = hub.fakes
          .callsTo(ServiceId.prowlarr)
          .singleWhere((c) => c.method == 'PUT');
      expect(_json(put.body), {
        'ids': [4, 5],
        'priority': 10,
      });
    });

    test('validates the body', () async {
      for (final body in <Object>[
        {'enabled': true},
        {'ids': <int>[], 'enabled': true},
        {'ids': List.generate(51, (i) => i + 1), 'enabled': true},
        {
          'ids': [1],
        },
        {
          'ids': [1],
          'priority': 0,
        },
        {
          'ids': [1],
          'priority': 51,
        },
        {
          'ids': ['1'],
          'enabled': true,
        },
        {
          'ids': [1],
          'enabled': 'yes',
        },
      ]) {
        final r = await hub.patch('/api/v1/indexers', body: body);
        expect(r.status, 422, reason: '$body → ${r.body}');
        expect(r.errorCode, 'validation_failed');
      }
      expect(
        hub.fakes.callsTo(ServiceId.prowlarr).where((c) => c.method == 'PUT'),
        isEmpty,
      );
    });

    test('is admin only', () async {
      final r = await hub.patch(
        '/api/v1/indexers',
        body: {
          'ids': [4],
          'enabled': false,
        },
        as: TestAs.member,
      );
      expect(r.status, 403);
    });
  });

  group('POST /indexers/{id}/test', () {
    test(
      'sends the full resource with forceTest and reports failures',
      () async {
        hub.fakes.on(
          ServiceId.prowlarr,
          'POST',
          '/api/v1/indexer/test',
          (_) => FakeResponse.json(
            syntheticFixture('prowlarr_indexer_test_failure.synthetic.json'),
            status: 400,
          ),
        );
        final r = await hub.post('/api/v1/indexers/15/test');
        expect(r.status, 202, reason: r.body);
        final started = Job.fromJson(readMap(r.map['job'])!);
        expect(started.kind, 'indexers.test');
        expect(started.target, '15');

        final job = await _finished(hub, started.id);
        expect(job.status, JobStatus.succeeded);
        final result = IndexerTestResult.fromJson(job.result!);
        expect(result.id, 15);
        expect(result.valid, isFalse);
        expect(result.failures, [
          'Unable to access uindex.org, blocked by CloudFlare Protection.',
        ]);
        expect(job.steps.first.label, 'Test Uindex');

        final call = hub.fakes
            .callsTo(ServiceId.prowlarr)
            .singleWhere((c) => c.path == '/api/v1/indexer/test');
        expect(call.method, 'POST');
        expect(call.query['forceTest'], ['true']);
        final sent = readMap(_json(call.body))!;
        expect(sent['id'], 15);
        expect(sent['fields'], isA<List<Object?>>());
        expect(sent['name'], 'Uindex');
      },
    );

    test('a 2xx answer is valid', () async {
      hub.fakes.on(
        ServiceId.prowlarr,
        'POST',
        '/api/v1/indexer/test',
        (_) => FakeResponse(200),
      );
      final r = await hub.post('/api/v1/indexers/4/test');
      final job = await _finished(hub, readMap(r.map['job'])!['id']! as String);
      final result = IndexerTestResult.fromJson(job.result!);
      expect(result.valid, isTrue);
      expect(result.failures, isEmpty);
    });

    test('an unknown indexer is an immediate 404', () async {
      final r = await hub.post('/api/v1/indexers/999999/test');
      expect(r.status, 404);
      expect(r.errorCode, 'not_found');
    });

    test('a Prowlarr 500 fails the job', () async {
      hub.fakes.on(
        ServiceId.prowlarr,
        'POST',
        '/api/v1/indexer/test',
        (_) => FakeResponse.json({'message': 'kaboom'}, status: 500),
      );
      final r = await hub.post('/api/v1/indexers/4/test');
      final job = await _finished(hub, readMap(r.map['job'])!['id']! as String);
      expect(job.status, JobStatus.failed);
      expect(job.error?.code, 'upstream_error');
    });

    test(
      'a host rejection fails the job with the fix, not a test failure',
      () async {
        hub.fakes.on(
          ServiceId.prowlarr,
          'POST',
          '/api/v1/indexer/test',
          (_) => FakeResponse.bytes(
            fixtureBytes('arr/servarr_error_400_invalid_hostname.html'),
            status: 400,
            contentType: 'text/html',
          ),
        );
        final r = await hub.post('/api/v1/indexers/15/test');
        final job = await _finished(
          hub,
          readMap(r.map['job'])!['id']! as String,
        );
        expect(job.status, JobStatus.failed);
        expect(job.error?.code, ApiErrorCode.upstreamHostRejected);
        expect(
          job.error?.message,
          contains('Allowed Hosts, add prowlarr.test'),
        );
      },
    );

    test('is admin only', () async {
      final r = await hub.post('/api/v1/indexers/4/test', as: TestAs.member);
      expect(r.status, 403);
    });
  });

  group('POST /indexers/test-all', () {
    test('parses the 400 body and redacts messages', () async {
      hub.fakes.on(
        ServiceId.prowlarr,
        'POST',
        '/api/v1/indexer/testall',
        (_) => FakeResponse.json(
          syntheticFixture('prowlarr_testall.synthetic.json'),
          status: 400,
        ),
      );
      final r = await hub.post('/api/v1/indexers/test-all');
      expect(r.status, 202, reason: r.body);
      final started = Job.fromJson(readMap(r.map['job'])!);
      expect(started.kind, 'indexers.testall');

      final job = await _finished(hub, started.id);
      expect(job.status, JobStatus.succeeded, reason: '${job.error?.message}');
      final items = IndexerTestResult.listFromJobResult(job.result);
      expect(items.map((i) => (i.id, i.valid)), [
        (4, true),
        (5, true),
        (15, false),
      ]);
      expect(items.last.failures.single, contains('Unable to connect'));
      expect(items.last.failures.single, isNot(contains('leakedkey123')));
      expect(job.message, '2 of 3 indexers passed');
      expect(job.log.join('\n'), contains('Uindex:'));
      expect(job.log.join('\n'), isNot(contains('leakedkey123')));
      final call = hub.fakes
          .callsTo(ServiceId.prowlarr)
          .singleWhere((c) => c.path == '/api/v1/indexer/testall');
      expect(call.method, 'POST');
    });

    test('a running test-all is reused', () async {
      hub.fakes.on(ServiceId.prowlarr, 'POST', '/api/v1/indexer/testall', (
        _,
      ) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return FakeResponse.json(<Object?>[]);
      });
      final a = await hub.post('/api/v1/indexers/test-all');
      final b = await hub.post('/api/v1/indexers/test-all');
      final idA = readMap(a.map['job'])!['id'];
      expect(readMap(b.map['job'])!['id'], idA);
      await _finished(hub, idA! as String);
    });

    test('a host rejection fails the job with the fix', () async {
      hub.fakes.on(
        ServiceId.prowlarr,
        'POST',
        '/api/v1/indexer/testall',
        (_) => FakeResponse.bytes(
          fixtureBytes('arr/servarr_error_400_invalid_hostname.html'),
          status: 400,
          contentType: 'text/html',
        ),
      );
      final r = await hub.post('/api/v1/indexers/test-all');
      final job = await _finished(hub, readMap(r.map['job'])!['id']! as String);
      expect(job.status, JobStatus.failed);
      expect(job.error?.code, ApiErrorCode.upstreamHostRejected);
      expect(job.error?.message, contains('Allowed Hosts, add prowlarr.test'));
    });

    test('a non-list body fails the job', () async {
      hub.fakes.on(
        ServiceId.prowlarr,
        'POST',
        '/api/v1/indexer/testall',
        (_) => FakeResponse.json({'message': 'odd'}),
      );
      final r = await hub.post('/api/v1/indexers/test-all');
      final job = await _finished(hub, readMap(r.map['job'])!['id']! as String);
      expect(job.status, JobStatus.failed);
      expect(job.error?.code, 'upstream_bad_response');
    });
  });
}

Object? _json(String body) => body.isEmpty ? null : jsonDecode(body);
