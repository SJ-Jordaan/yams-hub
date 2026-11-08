import 'dart:convert';

import 'package:test/test.dart';

import '../../support/test_hub.dart';
import 'requests_test_support.dart';

void main() {
  late TestHub hub;

  setUp(() {
    hub = TestHub();
    seerrBasics(hub.fakes);
  });
  tearDown(() => hub.close());

  group('POST /requests', () {
    test(
      'member: as their Seerr user, pending → created; quota cache dropped',
      () async {
        hub.fakes
          ..onFixture(
            ServiceId.seerr,
            'GET',
            '/api/v1/user/$memberSeerrId/quota',
            'seerr/seerr_user_quota.json',
          )
          ..on(
            ServiceId.seerr,
            'POST',
            '/api/v1/request',
            (_) => syntheticResponse(
              'seerr_request_created_pending.synthetic.json',
              status: 201,
            ),
          );
        // Warm the quota cache the way /auth/me does.
        expect(
          (await hub.get('/api/v1/auth/me', as: TestAs.member)).status,
          200,
        );
        final quotaCalls = seerrCalls(hub.fakes, '/api/v1/user/2/quota').length;

        final r = await hub.post(
          '/api/v1/requests',
          as: TestAs.member,
          body: {
            'mediaType': 'tv',
            'tmdbId': 10545,
            'seasons': [5, 4, 4],
          },
        );
        expect(r.status, 201, reason: r.body);
        final result = CreateRequestResult.fromJson(r.map);
        expect(result.outcome, CreateRequestOutcome.created);
        expect(result.request!.status, RequestStatus.pending);
        expect(result.request!.title, 'True Blood');
        expect(result.request!.canDelete, isTrue);
        expect(result.request!.canApprove, isFalse);

        final call = seerrCalls(
          hub.fakes,
          '/api/v1/request',
          method: 'POST',
        ).single;
        expect(call.headers['x-api-user'], '2');
        expect(readMap(jsonDecodeBody(call.body)), {
          'mediaType': 'tv',
          'mediaId': 10545,
          'seasons': [4, 5],
        });

        await hub.get('/api/v1/auth/me', as: TestAs.member);
        expect(
          seerrCalls(hub.fakes, '/api/v1/user/2/quota').length,
          quotaCalls + 1,
          reason: 'the quota cache is invalidated on create',
        );
      },
    );

    test(
      'admin: as the Seerr admin, approved → autoApproved; advanced passes',
      () async {
        hub.fakes.on(
          ServiceId.seerr,
          'POST',
          '/api/v1/request',
          (_) => syntheticResponse(
            'seerr_request_created_approved.synthetic.json',
            status: 201,
          ),
        );
        final r = await hub.post(
          '/api/v1/requests',
          body: {
            'mediaType': 'movie',
            'tmdbId': 603,
            'seasons': [1],
            'advanced': {
              'serverId': 0,
              'profileId': 4,
              'rootFolder': '/data/movies',
            },
          },
        );
        expect(r.status, 201, reason: r.body);
        final result = CreateRequestResult.fromJson(r.map);
        expect(result.outcome, CreateRequestOutcome.autoApproved);
        expect(result.request!.libraryId, 300);
        expect(result.request!.title, 'The Matrix');
        final call = seerrCalls(
          hub.fakes,
          '/api/v1/request',
          method: 'POST',
        ).single;
        expect(call.headers.containsKey('x-api-user'), isFalse);
        expect(jsonDecodeBody(call.body), {
          'mediaType': 'movie',
          'mediaId': 603,
          'serverId': 0,
          'profileId': 4,
          'rootFolder': '/data/movies',
        });
      },
    );

    test('202 → 200 nothingToRequest; 409 → already_requested', () async {
      var status = 202;
      hub.fakes.on(
        ServiceId.seerr,
        'POST',
        '/api/v1/request',
        (_) => FakeResponse.json({
          'message': status == 202
              ? 'No seasons available to request'
              : 'Request for this media already exists.',
        }, status: status),
      );
      final body = {'mediaType': 'tv', 'tmdbId': 10545, 'seasons': 'all'};
      final nothing = await hub.post('/api/v1/requests', body: body);
      expect(nothing.status, 200);
      expect(nothing.map, {'outcome': 'nothingToRequest'});
      expect(
        jsonDecodeBody(
          seerrCalls(hub.fakes, '/api/v1/request', method: 'POST').single.body,
        ),
        containsPair('seasons', 'all'),
      );
      status = 409;
      final dup = await hub.post('/api/v1/requests', body: body);
      expect(dup.status, 409);
      expect(dup.errorCode, 'already_requested');
    });

    test('quota_exceeded carries the quota; blocklisted maps too', () async {
      var message = 'Movie Quota exceeded.';
      hub.fakes
        ..on(
          ServiceId.seerr,
          'POST',
          '/api/v1/request',
          (_) => FakeResponse.json({'message': message}, status: 403),
        )
        ..on(
          ServiceId.seerr,
          'GET',
          '/api/v1/user/2/quota',
          (_) =>
              syntheticResponse('seerr_user_quota_restricted.synthetic.json'),
        );
      final r = await hub.post(
        '/api/v1/requests',
        as: TestAs.member,
        body: {'mediaType': 'movie', 'tmdbId': 603},
      );
      expect(r.status, 403);
      expect(r.errorCode, 'quota_exceeded');
      final error = ApiError.fromJson(readMap(r.map['error'])!);
      final quota = SeerrQuota.fromJson(readMap(error.details!['quota'])!);
      expect(quota.movie.limit, 5);
      expect(quota.movie.remaining, 0);
      expect(quota.tv.isUnlimited, isTrue);

      message = 'This media is blocklisted.';
      final b = await hub.post(
        '/api/v1/requests',
        as: TestAs.member,
        body: {'mediaType': 'movie', 'tmdbId': 603},
      );
      expect(b.errorCode, 'blocklisted');

      message = 'You do not have permission to request movies.';
      final p = await hub.post(
        '/api/v1/requests',
        as: TestAs.member,
        body: {'mediaType': 'movie', 'tmdbId': 603},
      );
      expect(p.status, 403);
      expect(p.errorCode, 'forbidden');
    });

    test('validation, advanced for members and unlinked members', () async {
      expect(
        (await hub.post(
          '/api/v1/requests',
          body: {'mediaType': 'tv', 'tmdbId': 1},
        )).status,
        422,
        reason: 'tv needs seasons',
      );
      expect(
        (await hub.post(
          '/api/v1/requests',
          body: {'mediaType': 'music', 'tmdbId': 1},
        )).status,
        422,
      );
      for (final advanced in [
        {'profileId': 'best'},
        {'serverId': -1},
        {'rootFolder': 'data/movies'},
        'radarr',
      ]) {
        final bad = await hub.post(
          '/api/v1/requests',
          body: {'mediaType': 'movie', 'tmdbId': 603, 'advanced': advanced},
        );
        expect(bad.status, 422, reason: '$advanced');
        expect(bad.errorCode, 'validation_failed');
      }
      final adv = await hub.post(
        '/api/v1/requests',
        as: TestAs.member,
        body: {
          'mediaType': 'movie',
          'tmdbId': 603,
          'advanced': {'profileId': 4},
        },
      );
      expect(adv.status, 403);
      expect(adv.errorCode, 'forbidden');
      expect(seerrCalls(hub.fakes, '/api/v1/request', method: 'POST'), isEmpty);

      final h = TestHub();
      seerrBasics(h.fakes, memberLinked: false);
      try {
        final r = await h.post(
          '/api/v1/requests',
          as: TestAs.member,
          body: {'mediaType': 'movie', 'tmdbId': 603},
        );
        expect(r.status, 403);
        expect(r.errorCode, 'seerr_user_not_linked');
      } finally {
        await h.close();
      }
    });

    test('creating is audited as requests.create', () async {
      hub.fakes.on(
        ServiceId.seerr,
        'POST',
        '/api/v1/request',
        (_) => syntheticResponse(
          'seerr_request_created_approved.synthetic.json',
          status: 201,
        ),
      );
      await hub.post(
        '/api/v1/requests',
        body: {'mediaType': 'movie', 'tmdbId': 603},
      );
      final audit = await hub.get('/api/v1/admin/audit');
      expect(audit.body, contains('requests.create'));
    });
  });

  group('GET /requests', () {
    test('admin pending tab: upstream query, title join, PagedList', () async {
      final queries = recordQueries(
        hub.fakes,
        'GET',
        '/api/v1/request',
        (_) => syntheticResponse('seerr_request_list_pending.synthetic.json'),
      );
      final r = await hub.get(
        '/api/v1/requests?filter=pending&page=1&pageSize=20',
      );
      expect(r.status, 200, reason: r.body);
      expect(
        queries.single,
        'take=20&skip=0&filter=pending&sort=added&sortDirection=desc&mediaType=all',
      );
      final page = PagedList.fromJson(r.map, RequestSummary.fromJson);
      expect(page.total, 1);
      expect(page.hasMore, isFalse);
      final item = page.items.single;
      expect(item.title, 'True Blood');
      expect(item.year, 2008);
      expect(item.posterPath, startsWith('/api/v1/img/tmdb/w342/'));
      expect(item.canApprove, isTrue);
      expect(item.requestedBy.id, 2);
      expect(r.body, isNot(contains('redacted@example.com')));
      expect(r.body, isNot(contains('serviceUrl')));
      expect(
        seerrCalls(
          hub.fakes,
          '/api/v1/request',
        ).single.headers.containsKey('x-api-user'),
        isFalse,
      );
    });

    test('members are always mine=true, as their Seerr user', () async {
      final queries = recordQueries(
        hub.fakes,
        'GET',
        '/api/v1/request',
        (_) =>
            FakeResponse.fixture('seerr/seerr_request_list_x_api_user_2.json'),
      );
      hub.fakes.onFixture(
        ServiceId.seerr,
        'GET',
        '/api/v1/tv/33880',
        'seerr/seerr_tv_details_processing.json',
      );
      final r = await hub.get('/api/v1/requests?mine=false', as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      expect(queries.single, contains('requestedBy=2'));
      expect(
        seerrCalls(hub.fakes, '/api/v1/request').single.headers['x-api-user'],
        '2',
      );
      final page = PagedList.fromJson(r.map, RequestSummary.fromJson);
      expect(page.total, 2);
      expect(page.items.map((i) => i.id), [196, 187]);
      expect(page.items.every((i) => !i.canApprove), isTrue);
    });

    test(
      'declined: one take=500 call, gateway paging with exact totals',
      () async {
        final list = fixtureMap('seerr/seerr_request_list.json');
        final results = readList(list['results'], (m) => m);
        for (final r in results.take(3)) {
          r['status'] = 3;
        }
        final queries = recordQueries(
          hub.fakes,
          'GET',
          '/api/v1/request',
          (_) => FakeResponse.json(list),
        );
        final p1 = PagedList.fromJson(
          (await hub.get('/api/v1/requests?filter=declined&pageSize=2')).map,
          RequestSummary.fromJson,
        );
        final p2 = PagedList.fromJson(
          (await hub.get('/api/v1/requests?filter=declined&pageSize=2&page=2'))
              .map,
          RequestSummary.fromJson,
        );
        expect(
          queries.single,
          'take=500&skip=0&filter=all&sort=added&sortDirection=desc&mediaType=all',
        );
        expect(p1.total, 3);
        expect(p1.items, hasLength(2));
        expect(p1.hasMore, isTrue);
        expect(p2.items, hasLength(1));
        expect(p2.hasMore, isFalse);
        expect(
          [
            ...p1.items,
            ...p2.items,
          ].every((i) => i.status == RequestStatus.declined),
          isTrue,
        );
      },
    );

    test(
      'bad filters are 400; unlinked members get seerr_user_not_linked',
      () async {
        expect((await hub.get('/api/v1/requests?filter=bogus')).status, 400);
        expect((await hub.get('/api/v1/requests?pageSize=51')).status, 400);
        final h = TestHub();
        seerrBasics(h.fakes, memberLinked: false);
        try {
          final r = await h.get('/api/v1/requests', as: TestAs.member);
          expect(r.status, 403);
          expect(r.errorCode, 'seerr_user_not_linked');
        } finally {
          await h.close();
        }
      },
    );
  });

  test('GET /requests/counts derives failed', () async {
    hub.fakes.onFixture(
      ServiceId.seerr,
      'GET',
      '/api/v1/request/count',
      'seerr/seerr_request_count.json',
    );
    final r = await hub.get('/api/v1/requests/counts', as: TestAs.member);
    expect(r.status, 200);
    final c = RequestCounts.fromJson(r.map);
    expect(c.total, 127);
    expect(c.failed, 1);
    expect(c.completed, 122);
  });

  group('GET /requests/{id}', () {
    test('summary, as the caller; 404 passes through', () async {
      hub.fakes
        ..onFixture(
          ServiceId.seerr,
          'GET',
          '/api/v1/request/189',
          'seerr/seerr_request_detail_failed.json',
        )
        ..onFixture(
          ServiceId.seerr,
          'GET',
          '/api/v1/request/999999',
          'seerr/seerr_error_404_request.json',
          status: 404,
        );
      final r = await hub.get('/api/v1/requests/189');
      expect(r.status, 200, reason: r.body);
      final s = RequestSummary.fromJson(r.map);
      expect(s.status, RequestStatus.failed);
      expect(s.canRetry, isTrue);
      expect(s.mediaType, MediaType.tv);
      expect(s.tmdbId, 1126);
      final missing = await hub.get('/api/v1/requests/999999');
      expect(missing.status, 404);
      expect(missing.errorCode, 'not_found');
    });

    test("someone else's request: Seerr 403 → 403 forbidden", () async {
      hub.fakes.on(
        ServiceId.seerr,
        'GET',
        '/api/v1/request/195',
        (_) => FakeResponse.json({
          'message': 'You do not have permission to view this request.',
        }, status: 403),
      );
      final r = await hub.get('/api/v1/requests/195', as: TestAs.member);
      expect(r.status, 403);
      expect(r.errorCode, 'forbidden');
      expect(
        seerrCalls(
          hub.fakes,
          '/api/v1/request/195',
        ).single.headers['x-api-user'],
        '2',
      );
    });
  });

  group('manage', () {
    test(
      'approve: admin, as Seerr admin; 409 → invalid_state; members 403',
      () async {
        var conflict = false;
        hub.fakes.on(
          ServiceId.seerr,
          'POST',
          '/api/v1/request/201/approve',
          (_) => conflict
              ? FakeResponse.json({
                  'message':
                      'Only pending requests can be approved or declined.',
                }, status: 409)
              : FakeResponse.json(
                  (synthetic('seerr_request_created_pending.synthetic.json')!
                        as JsonMap)
                    ..['status'] = 2,
                ),
        );
        final ok = await hub.post('/api/v1/requests/201/approve');
        expect(ok.status, 200, reason: ok.body);
        expect(RequestSummary.fromJson(ok.map).status, RequestStatus.approved);
        expect(
          seerrCalls(
            hub.fakes,
            '/api/v1/request/201/approve',
          ).single.headers.containsKey('x-api-user'),
          isFalse,
        );
        conflict = true;
        final again = await hub.post('/api/v1/requests/201/approve');
        expect(again.status, 409);
        expect(again.errorCode, 'invalid_state');
        final member = await hub.post(
          '/api/v1/requests/201/approve',
          as: TestAs.member,
        );
        expect(member.status, 403);
      },
    );

    test('decline and retry hit their Seerr routes', () async {
      final failed = fixtureMap('seerr/seerr_request_detail_failed.json');
      hub.fakes
        ..on(
          ServiceId.seerr,
          'POST',
          '/api/v1/request/189/retry',
          (_) => FakeResponse.json(
            Map<String, Object?>.of(failed)..['status'] = 2,
          ),
        )
        ..on(
          ServiceId.seerr,
          'POST',
          '/api/v1/request/201/decline',
          (_) => FakeResponse.json(
            (synthetic('seerr_request_created_pending.synthetic.json')!
                  as JsonMap)
              ..['status'] = 3,
          ),
        );
      final retry = await hub.post('/api/v1/requests/189/retry');
      expect(retry.status, 200, reason: retry.body);
      expect(RequestSummary.fromJson(retry.map).status, RequestStatus.approved);
      final decline = await hub.post('/api/v1/requests/201/decline');
      expect(
        RequestSummary.fromJson(decline.map).status,
        RequestStatus.declined,
      );
    });

    test(
      'PUT edits seasons of a pending request; 202 → nothingToRequest',
      () async {
        var accepted = false;
        hub.fakes
          ..on(
            ServiceId.seerr,
            'GET',
            '/api/v1/request/201',
            (_) => syntheticResponse(
              'seerr_request_created_pending.synthetic.json',
            ),
          )
          ..on(
            ServiceId.seerr,
            'PUT',
            '/api/v1/request/201',
            (_) => accepted
                ? FakeResponse.json({
                    'message': 'No seasons available to request',
                  }, status: 202)
                : syntheticResponse(
                    'seerr_request_created_pending.synthetic.json',
                  ),
          );
        final r = await hub.put(
          '/api/v1/requests/201',
          as: TestAs.member,
          body: {
            'seasons': [4],
          },
        );
        expect(r.status, 200, reason: r.body);
        final put = seerrCalls(
          hub.fakes,
          '/api/v1/request/201',
          method: 'PUT',
        ).single;
        expect(put.headers['x-api-user'], '2');
        expect(jsonDecodeBody(put.body), {
          'mediaType': 'tv',
          'seasons': [4],
        });
        accepted = true;
        final none = await hub.put(
          '/api/v1/requests/201',
          as: TestAs.member,
          body: {
            'seasons': [4],
          },
        );
        expect(none.map, {'outcome': 'nothingToRequest'});
      },
    );

    test('DELETE needs confirm; Seerr 401 → 403 forbidden', () async {
      var allowed = true;
      hub.fakes.on(
        ServiceId.seerr,
        'DELETE',
        '/api/v1/request/201',
        (_) => allowed
            ? FakeResponse(204, body: const Stream.empty())
            : FakeResponse.json({
                'message': 'You do not have permission to delete this request.',
              }, status: 401),
      );
      final unconfirmed = await hub.delete(
        '/api/v1/requests/201',
        as: TestAs.member,
      );
      expect(unconfirmed.status, 428);
      expect(unconfirmed.errorCode, 'confirmation_required');
      expect(seerrCalls(hub.fakes, '/api/v1/request/201'), isEmpty);

      final ok = await hub.delete(
        '/api/v1/requests/201?confirm=true',
        as: TestAs.member,
      );
      expect(ok.status, 204, reason: ok.body);
      expect(
        seerrCalls(
          hub.fakes,
          '/api/v1/request/201',
        ).single.headers['x-api-user'],
        '2',
      );

      allowed = false;
      final denied = await hub.delete(
        '/api/v1/requests/201',
        as: TestAs.member,
        body: {'confirm': true},
      );
      expect(denied.status, 403);
      expect(denied.errorCode, 'forbidden');
    });
  });

  test('GET /requests/options: admin only, 4K servers left out', () async {
    hub.fakes
      ..on(ServiceId.seerr, 'GET', '/api/v1/service/radarr', (_) {
        final list = readList(
          fixture('seerr/seerr_service_radarr.json'),
          (m) => m,
        );
        return FakeResponse.json([
          ...list,
          {...list.single, 'id': 1, 'name': 'Radarr 4K', 'is4k': true},
        ]);
      })
      ..onFixture(
        ServiceId.seerr,
        'GET',
        '/api/v1/service/sonarr',
        'seerr/seerr_service_sonarr.json',
      )
      ..onFixture(
        ServiceId.seerr,
        'GET',
        '/api/v1/service/radarr/0',
        'seerr/seerr_service_radarr_detail.json',
      )
      ..onFixture(
        ServiceId.seerr,
        'GET',
        '/api/v1/service/sonarr/0',
        'seerr/seerr_service_sonarr_detail.json',
      );
    final r = await hub.get('/api/v1/requests/options');
    expect(r.status, 200, reason: r.body);
    final o = RequestsOptions.fromJson(r.map);
    expect(o.radarr.single.name, 'Radarr');
    expect(o.radarr.single.defaultRootFolder, '/data/movies');
    expect(o.sonarr.single.serverId, 0);
    expect(o.sonarr.single.profiles, isNotEmpty);
    expect(
      (await hub.get('/api/v1/requests/options', as: TestAs.member)).status,
      403,
    );
  });

  group('dashboard card', () {
    void cardFakes() {
      hub.fakes
        ..on(
          ServiceId.seerr,
          'GET',
          '/api/v1/request/count',
          (_) =>
              syntheticResponse('seerr_request_count_pending.synthetic.json'),
        )
        ..on(
          ServiceId.seerr,
          'GET',
          '/api/v1/request',
          (_) => syntheticResponse('seerr_request_list_pending.synthetic.json'),
        )
        ..on(
          ServiceId.seerr,
          'GET',
          '/api/v1/issue/count',
          (_) => syntheticResponse('seerr_issue_count.synthetic.json'),
        );
    }

    test(
      'admin: raw counts.pending, pending list, alerts with routes',
      () async {
        cardFakes();
        final r = await hub.get('/api/v1/dashboard?cards=requests');
        expect(r.status, 200, reason: r.body);
        final section = readMap(readMap(r.map['cards'])!['requests'])!;
        expect(section['status'], 'ok', reason: '$section');
        final data = readMap(section['data'])!;
        expect(readMap(data['counts'])!['pending'], 2);
        final card = RequestsCard.fromJson(data);
        expect(card.pending.single.title, 'True Blood');
        expect(card.recent, isNotEmpty);
        expect(card.openIssues, 2);
        final alerts = readList(r.map['alerts'], Alert.fromJson);
        final pending = alerts.firstWhere((a) => a.id == 'seerr.pending');
        expect(pending.severity, AlertSeverity.info);
        expect(pending.title, '2 requests waiting for approval');
        expect(pending.route, '/requests/list?tab=pending');
        final failed = alerts.firstWhere((a) => a.id == 'seerr.failed');
        expect(failed.severity, AlertSeverity.warning);
        expect(failed.route, '/requests/list?tab=failed');
      },
    );

    test('member: no pending list, own recent, no alerts', () async {
      cardFakes();
      final r = await hub.get(
        '/api/v1/dashboard?cards=requests',
        as: TestAs.member,
      );
      final section = readMap(readMap(r.map['cards'])!['requests'])!;
      final card = RequestsCard.fromJson(readMap(section['data'])!);
      expect(card.pending, isEmpty);
      expect(card.recent, isNotEmpty);
      expect(
        readList(
          r.map['alerts'],
          Alert.fromJson,
        ).where((a) => a.source == ServiceId.seerr),
        isEmpty,
      );
      final recentCall = seerrCalls(hub.fakes, '/api/v1/request').single;
      expect(recentCall.headers['x-api-user'], '2');
      expect(recentCall.query['requestedBy'], ['2']);
    });

    test('a failing Seerr gives an error section', () async {
      hub.fakes.on(
        ServiceId.seerr,
        'GET',
        '/api/v1/request/count',
        (_) => FakeResponse.json({'message': 'boom'}, status: 500),
      );
      final r = await hub.get('/api/v1/dashboard?cards=requests');
      final section = readMap(readMap(r.map['cards'])!['requests'])!;
      expect(section['status'], 'error');
    });
  });
}

/// Decodes a recorded JSON request body.
Object? jsonDecodeBody(String body) => body.isEmpty ? null : jsonDecode(body);
