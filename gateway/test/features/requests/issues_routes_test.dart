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

  test(
    'GET /issues: explicit filter, as the user, commentCount only',
    () async {
      final queries = recordQueries(
        hub.fakes,
        'GET',
        '/api/v1/issue',
        (_) => syntheticResponse('seerr_issue_list.synthetic.json'),
      );
      final r = await hub.get('/api/v1/issues', as: TestAs.member);
      expect(r.status, 200, reason: r.body);
      expect(queries.single, 'take=25&skip=0&filter=open&sort=added');
      expect(
        seerrCalls(hub.fakes, '/api/v1/issue').single.headers['x-api-user'],
        '2',
      );
      final page = PagedList.fromJson(r.map, Issue.fromJson);
      expect(page.total, 2);
      final first = page.items.first;
      expect(first.title, 'True Blood');
      expect(first.commentCount, 2);
      expect(first.comments, isEmpty);
      expect(first.season, 2);
      expect(page.items.last.title, 'Austin Powers in Goldmember');
      expect(r.body, isNot(contains('redacted@example.com')));

      await hub.get('/api/v1/issues?filter=all&page=2&pageSize=10');
      expect(queries.last, 'take=10&skip=10&filter=all&sort=added');
      expect((await hub.get('/api/v1/issues?filter=closed')).status, 400);
    },
  );

  test('GET /issues: a member without Seerr issue permissions gets an '
      'empty list', () async {
    // Seerr's default member permissions (32, REQUEST) fail GET /issue.
    hub.fakes.on(
      ServiceId.seerr,
      'GET',
      '/api/v1/issue',
      (_) => FakeResponse.json({
        'status': 403,
        'error': 'You do not have permission to access this endpoint',
      }, status: 403),
    );
    final r = await hub.get('/api/v1/issues', as: TestAs.member);
    expect(r.status, 200, reason: r.body);
    final page = PagedList.fromJson(r.map, Issue.fromJson);
    expect(page.items, isEmpty);
    expect(page.total, 0);
    // An admin call failing the same way is still an error.
    final admin = await hub.get('/api/v1/issues');
    expect(admin.status, isNot(200));
  });

  test(
    'POST /issues without CREATE_ISSUES names the missing permission',
    () async {
      hub.fakes.on(
        ServiceId.seerr,
        'POST',
        '/api/v1/issue',
        (_) => FakeResponse.json({
          'status': 403,
          'error': 'You do not have permission to access this endpoint',
        }, status: 403),
      );
      final r = await hub.post(
        '/api/v1/issues',
        as: TestAs.member,
        body: {
          'mediaType': 'tv',
          'tmdbId': 10545,
          'type': 'audio',
          'message': 'Audio out of sync',
          'season': 2,
          'episode': 5,
        },
      );
      expect(r.status, 403, reason: r.body);
      expect(r.errorCode, 'forbidden');
      expect(readMap(r.map['error'])?['message'], contains('Create Issues'));
    },
  );

  test('GET /issues/counts maps others and closed', () async {
    hub.fakes.on(
      ServiceId.seerr,
      'GET',
      '/api/v1/issue/count',
      (_) => syntheticResponse('seerr_issue_count.synthetic.json'),
    );
    final r = await hub.get('/api/v1/issues/counts', as: TestAs.member);
    expect(r.status, 200);
    expect(r.map, {
      'total': 3,
      'video': 1,
      'audio': 1,
      'subtitles': 0,
      'other': 1,
      'open': 2,
      'resolved': 1,
    });
  });

  test('GET /issues/{id} has the comment thread', () async {
    hub.fakes.on(
      ServiceId.seerr,
      'GET',
      '/api/v1/issue/11',
      (_) => syntheticResponse('seerr_issue_detail.synthetic.json'),
    );
    final r = await hub.get('/api/v1/issues/11', as: TestAs.member);
    expect(r.status, 200);
    final i = Issue.fromJson(r.map);
    expect(i.comments, hasLength(2));
    expect(i.comments.last.author.displayName, 'Paul Greyrat');
    expect(
      i.comments.last.author.avatarPath,
      startsWith('/api/v1/img/seerr-avatar/1'),
    );
    expect((await hub.get('/api/v1/issues/99')).status, 404);
  });

  group('POST /issues', () {
    test('resolves the Seerr media id from the title', () async {
      hub.fakes.on(
        ServiceId.seerr,
        'POST',
        '/api/v1/issue',
        (_) =>
            syntheticResponse('seerr_issue_detail.synthetic.json', status: 201),
      );
      final r = await hub.post(
        '/api/v1/issues',
        as: TestAs.member,
        body: {
          'mediaType': 'tv',
          'tmdbId': 10545,
          'type': 'audio',
          'message': '  Audio out of sync from 12:30  ',
          'season': 2,
          'episode': 5,
        },
      );
      expect(r.status, 201, reason: r.body);
      expect(Issue.fromJson(r.map).id, 11);
      final call = seerrCalls(
        hub.fakes,
        '/api/v1/issue',
        method: 'POST',
      ).single;
      expect(call.headers['x-api-user'], '2');
      final mediaId = readInt(
        readMap(
          fixtureMap(
            'seerr/seerr_tv_details_partially_available.json',
          )['mediaInfo'],
        )!['id'],
      );
      expect(jsonDecode(call.body), {
        'issueType': 2,
        'message': 'Audio out of sync from 12:30',
        'mediaId': mediaId,
        'problemSeason': 2,
        'problemEpisode': 5,
      });
    });

    test('a title Seerr does not track is 404', () async {
      final r = await hub.post(
        '/api/v1/issues',
        body: {
          'mediaType': 'movie',
          'tmdbId': 603,
          'type': 'video',
          'message': 'x',
        },
      );
      expect(r.status, 404);
      expect(r.errorCode, 'not_found');
      expect(r.map.toString(), contains('Seerr does not track this title yet'));
      expect(seerrCalls(hub.fakes, '/api/v1/issue', method: 'POST'), isEmpty);
    });

    test('validation', () async {
      Future<int> post(Map<String, Object?> body) async =>
          (await hub.post('/api/v1/issues', body: body)).status;
      expect(
        await post({
          'mediaType': 'movie',
          'tmdbId': 818,
          'type': 'smell',
          'message': 'x',
        }),
        422,
      );
      expect(
        await post({
          'mediaType': 'movie',
          'tmdbId': 818,
          'type': 'video',
          'message': ' ',
        }),
        422,
      );
      expect(
        await post({
          'mediaType': 'movie',
          'tmdbId': 818,
          'type': 'video',
          'message': 'x' * 2001,
        }),
        422,
      );
    });
  });

  test(
    'comment and resolve run as the user; Seerr 403 → 403 forbidden',
    () async {
      var allowed = true;
      hub.fakes
        ..on(
          ServiceId.seerr,
          'POST',
          '/api/v1/issue/11/comment',
          (_) => syntheticResponse('seerr_issue_detail.synthetic.json'),
        )
        ..on(
          ServiceId.seerr,
          'POST',
          '/api/v1/issue/11/resolved',
          (_) => allowed
              ? syntheticResponse('seerr_issue_resolved.synthetic.json')
              : FakeResponse.json({
                  'message': 'You do not have permission',
                }, status: 403),
        )
        ..on(
          ServiceId.seerr,
          'POST',
          '/api/v1/issue/11/open',
          (_) => syntheticResponse('seerr_issue_detail.synthetic.json'),
        );
      final c = await hub.post(
        '/api/v1/issues/11/comments',
        as: TestAs.member,
        body: {'message': 'Still happening'},
      );
      expect(c.status, 200, reason: c.body);
      final commentCall = seerrCalls(
        hub.fakes,
        '/api/v1/issue/11/comment',
      ).single;
      expect(commentCall.headers['x-api-user'], '2');
      expect(jsonDecode(commentCall.body), {'message': 'Still happening'});

      final resolved = await hub.post(
        '/api/v1/issues/11/resolve',
        as: TestAs.member,
      );
      expect(Issue.fromJson(resolved.map).status, IssueStatus.resolved);
      expect(
        seerrCalls(
          hub.fakes,
          '/api/v1/issue/11/resolved',
        ).single.headers['x-api-user'],
        '2',
      );

      allowed = false;
      final denied = await hub.post(
        '/api/v1/issues/11/resolve',
        as: TestAs.member,
      );
      expect(denied.status, 403);
      expect(denied.errorCode, 'forbidden');
      expect(denied.map.toString(), contains('Only the reporter or an admin'));

      final reopened = await hub.post('/api/v1/issues/11/reopen');
      expect(Issue.fromJson(reopened.map).status, IssueStatus.open);
      expect(
        seerrCalls(
          hub.fakes,
          '/api/v1/issue/11/open',
        ).single.headers.containsKey('x-api-user'),
        isFalse,
      );
    },
  );

  test(
    'unlinked members get an empty read-only list and cannot write',
    () async {
      final h = TestHub();
      seerrBasics(h.fakes, memberLinked: false);
      h.fakes.on(
        ServiceId.seerr,
        'GET',
        '/api/v1/issue',
        (_) => syntheticResponse('seerr_issue_list.synthetic.json'),
      );
      try {
        final list = await h.get('/api/v1/issues', as: TestAs.member);
        expect(list.status, 200);
        // Never the Seerr admin's view of everyone's issues.
        final page = PagedList.fromJson(list.map, Issue.fromJson);
        expect(page.items, isEmpty);
        expect(page.total, 0);
        expect(seerrCalls(h.fakes, '/api/v1/issue'), isEmpty);
        final detail = await h.get('/api/v1/issues/11', as: TestAs.member);
        expect(detail.status, 403);
        expect(detail.errorCode, 'seerr_user_not_linked');
        for (final (path, body) in [
          ('/api/v1/issues/11/comments', {'message': 'hi'}),
          ('/api/v1/issues/11/resolve', null),
          ('/api/v1/issues/11/reopen', null),
          (
            '/api/v1/issues',
            {
              'mediaType': 'movie',
              'tmdbId': 818,
              'type': 'video',
              'message': 'x',
            },
          ),
        ]) {
          final r = await h.post(path, as: TestAs.member, body: body);
          expect(r.status, 403, reason: path);
          expect(r.errorCode, 'seerr_user_not_linked', reason: path);
        }
      } finally {
        await h.close();
      }
    },
  );

  test(
    "Seerr's permission middleware refusing the user is 403, not a key error",
    () async {
      // Seerr answers a failed permission check with the same body as a bad
      // API key; with X-API-User it is the user's permissions.
      final body = {
        'status': 403,
        'error': 'You do not have permission to access this endpoint',
      };
      hub.fakes
        ..on(
          ServiceId.seerr,
          'GET',
          '/api/v1/issue',
          (_) => FakeResponse.json(body, status: 403),
        )
        ..on(
          ServiceId.seerr,
          'POST',
          '/api/v1/issue/11/resolved',
          (_) => FakeResponse.json({
            'message': 'You do not have permission to modify this issue.',
          }, status: 401),
        );
      // A member Seerr refuses the list to has no issues to see.
      final member = await hub.get('/api/v1/issues', as: TestAs.member);
      expect(member.status, 200, reason: member.body);
      expect(PagedList.fromJson(member.map, Issue.fromJson).items, isEmpty);

      final admin = await hub.get('/api/v1/issues');
      expect(admin.status, 502);
      expect(admin.errorCode, 'upstream_auth_failed');

      final resolve = await hub.post(
        '/api/v1/issues/11/resolve',
        as: TestAs.member,
      );
      expect(resolve.status, 403);
      expect(resolve.errorCode, 'forbidden');
      expect(resolve.map.toString(), contains('Only the reporter or an admin'));
    },
  );
}
