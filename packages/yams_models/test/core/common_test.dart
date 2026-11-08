import 'package:test/test.dart';
import 'package:yams_models/yams_models.dart';

import 'round_trip.dart';

final _apiErrorJson = <String, Object?>{
  'code': 'validation_failed',
  'message': 'Sonarr rejected the request.',
  'status': 422,
  'service': 'sonarr',
  'requestId': 'a1b2c3d4e5f60718',
  'fields': [
    {'field': 'qualityProfileId', 'message': 'Quality profile does not exist'},
  ],
  'details': {'upstreamStatus': 400},
};

JsonMap _itemJson(_Item i) => {'n': i.n};

final class _Item {
  const _Item(this.n);
  factory _Item.fromJson(JsonMap j) => _Item(req(readInt(j['n']), 'n'));
  final int n;
}

void main() {
  group('ServiceId', () {
    test('serialises every member by name and parses unknown values', () {
      for (final v in ServiceId.values) {
        expect(ServiceId.fromJson(v.toJson()), v);
      }
      expect(ServiceId.fromJson('uptimeKuma'), ServiceId.uptimeKuma);
      expect(ServiceId.fromJson('shelfmark'), ServiceId.shelfmark);
      expect(ServiceId.fromJson('plex'), ServiceId.unknown);
      expect(ServiceId.fromJson(null), ServiceId.unknown);
      expect(ServiceId.fromJsonOrNull(null), isNull);
      expect(ServiceId.fromJsonOrNull('plex'), ServiceId.unknown);
    });
  });

  group('ExternalApp', () {
    test('includes shelfmark and parses unknown values', () {
      expect(ExternalApp.fromJson('shelfmark'), ExternalApp.shelfmark);
      expect(ExternalApp.fromJson('homepage'), ExternalApp.unknown);
      for (final v in ExternalApp.values) {
        expect(ExternalApp.fromJson(v.toJson()), v);
      }
    });
    test('maps 1:1 to ServiceId except portainer', () {
      for (final app in ExternalApp.values) {
        if (app == ExternalApp.portainer || app == ExternalApp.unknown) {
          expect(app.serviceId, isNull);
        } else {
          expect(app.serviceId?.name, app.name);
        }
      }
    });
  });

  group('ApiError', () {
    test('round trips', () {
      final e = expectRoundTrip(
        _apiErrorJson,
        ApiError.fromJson,
        (e) => e.toJson(),
      );
      expect(e.service, ServiceId.sonarr);
      expect(e.fields.single.field, 'qualityProfileId');
      expect(
        e.messageFor('qualityProfileId'),
        'Quality profile does not exist',
      );
      expect(e.messageFor('other'), isNull);
      expect(e.details, {'upstreamStatus': 400});
    });

    test('round trips with retryAfterSeconds and no optional fields', () {
      expectRoundTrip(
        {
          'code': 'rate_limited',
          'message': 'Too many attempts.',
          'status': 429,
          'requestId': 'r1',
          'fields': <Object?>[],
          'retryAfterSeconds': 30,
        },
        ApiError.fromJson,
        (e) => e.toJson(),
      );
    });

    test('parses the response envelope', () {
      final e = ApiError.tryParseResponseBody({'error': _apiErrorJson});
      expect(e?.code, ApiErrorCode.validationFailed);
      expect(e?.toResponseBody(), {'error': _apiErrorJson});
      expect(ApiError.tryParseResponseBody({'message': 'x'}), isNull);
      expect(ApiError.tryParseResponseBody('Route not found'), isNull);
      expect(ApiError.tryParseResponseBody(null), isNull);
    });

    test('is lenient: unknown service, missing optional parts', () {
      final e = ApiError.fromJson({'code': 'internal', 'service': 'plex'});
      expect(e.service, ServiceId.unknown);
      expect(e.message, '');
      expect(e.status, 0);
      expect(e.fields, isEmpty);
      expect(e, isA<Exception>());
      expect(e.toString(), contains('internal'));
    });

    test('requires a code', () {
      expect(() => ApiError.fromJson({'message': 'x'}), throwsFormatException);
    });
  });

  group('envelopes', () {
    test('ItemList round trips', () {
      final list = expectRoundTrip(
        {
          'items': [
            {'n': 1},
            {'n': 2},
          ],
        },
        (j) => ItemList.fromJson(j, _Item.fromJson),
        (l) => l.toJson(_itemJson),
      );
      expect(list.items.map((i) => i.n), [1, 2]);
      expect(ItemList.fromJson({}, _Item.fromJson).items, isEmpty);
    });

    test('PagedList round trips', () {
      final page = expectRoundTrip(
        {
          'items': [
            {'n': 26},
          ],
          'page': 2,
          'pageSize': 25,
          'total': 51,
          'hasMore': true,
        },
        (j) => PagedList.fromJson(j, _Item.fromJson),
        (p) => p.toJson(_itemJson),
      );
      expect(page.page, 2);
      expect(page.hasMore, isTrue);
    });

    test('PagedList.of derives hasMore', () {
      expect(
        PagedList.of(items: const [], page: 2, pageSize: 25, total: 50).hasMore,
        isFalse,
      );
      expect(
        PagedList.of(items: const [], page: 1, pageSize: 25, total: 26).hasMore,
        isTrue,
      );
      expect(
        PagedList.of(items: const [], page: 9, pageSize: 25, total: 26).hasMore,
        isFalse,
      );
    });

    test('CursorPage round trips with and without a cursor', () {
      final withCursor = expectRoundTrip(
        {
          'items': [
            {'n': 1},
          ],
          'nextCursor': 'abc',
        },
        (j) => CursorPage.fromJson(j, _Item.fromJson),
        (p) => p.toJson(_itemJson),
      );
      expect(withCursor.hasMore, isTrue);
      final last = expectRoundTrip(
        {'items': <Object?>[]},
        (j) => CursorPage.fromJson(j, _Item.fromJson),
        (p) => p.toJson(_itemJson),
      );
      expect(last.hasMore, isFalse);
    });
  });

  group('Section', () {
    test('ok section round trips and decodes its data', () {
      final s = expectRoundTrip(
        {
          'status': 'ok',
          'data': {'n': 7},
          'fetchedAt': '2026-11-08T09:00:00Z',
          'stale': false,
        },
        Section.fromJson,
        (s) => s.toJson(),
      );
      expect(s.isOk, isTrue);
      expect(s.decode(_Item.fromJson)?.n, 7);
    });

    test('stale section keeps data and the refresh error', () {
      final s = expectRoundTrip(
        {
          'status': 'ok',
          'data': {'n': 7},
          'error': _apiErrorJson,
          'fetchedAt': '2026-11-08T09:00:00Z',
          'stale': true,
        },
        Section.fromJson,
        (s) => s.toJson(),
      );
      expect(s.stale, isTrue);
      expect(s.error?.code, 'validation_failed');
    });

    test('error and disabled sections round trip; decode yields null', () {
      final err = expectRoundTrip(
        {
          'status': 'error',
          'error': {
            'code': 'not_implemented',
            'message': 'Not implemented',
            'status': 501,
            'requestId': 'r',
            'fields': <Object?>[],
          },
          'fetchedAt': '2026-11-08T09:00:00Z',
          'stale': false,
        },
        Section.fromJson,
        (s) => s.toJson(),
      );
      expect(err.status, SectionState.error);
      expect(err.decode(_Item.fromJson), isNull);

      final disabled = Section.fromJson({
        'status': 'disabled',
        'error': {'code': 'service_not_configured'},
      });
      expect(disabled.status, SectionState.disabled);
      expect(disabled.fetchedAt, isNull);
      expect(disabled.error?.code, ApiErrorCode.serviceNotConfigured);
    });

    test('named constructors produce the documented shapes', () {
      final at = DateTime.utc(2026, 11, 8, 9);
      const error = ApiError(
        code: 'upstream_unavailable',
        message: 'x',
        status: 503,
      );
      expect(Section.ok(const {'n': 1}, fetchedAt: at).toJson(), {
        'status': 'ok',
        'data': {'n': 1},
        'fetchedAt': '2026-11-08T09:00:00Z',
        'stale': false,
      });
      expect(Section.failure(error, fetchedAt: at).toJson()['status'], 'error');
      expect(const Section.disabled(error).toJson().keys, [
        'status',
        'error',
        'stale',
      ]);
    });

    test('unknown status parses to unknown', () {
      expect(
        Section.fromJson({'status': 'partial'}).status,
        SectionState.unknown,
      );
      expect(SectionState.fromJson(null), SectionState.unknown);
    });
  });

  group('SectionStatus', () {
    test('round trips', () {
      expectRoundTrip(
        {'status': 'ok'},
        SectionStatus.fromJson,
        (s) => s.toJson(),
      );
      final failed = expectRoundTrip(
        {'status': 'error', 'error': _apiErrorJson},
        SectionStatus.fromJson,
        (s) => s.toJson(),
      );
      expect(failed.isOk, isFalse);
      expect(const SectionStatus.ok().toJson(), {'status': 'ok'});
      expect(
        SectionStatus.fromJson({'status': 'weird'}).status,
        SectionState.unknown,
      );
    });
  });

  test('ExternalLink round trips; unknown app parses', () {
    final link = expectRoundTrip(
      {
        'app': 'jellyfin',
        'path': '/web/#/details?id=4f5731b2c357273bf4002dd8d042a856&serverId=79315eab3c4c401f8391d5c26210b6d7',
      },
      ExternalLink.fromJson,
      (l) => l.toJson(),
    );
    expect(link.app, ExternalApp.jellyfin);
    expect(
      ExternalLink.fromJson({'app': 'plex', 'path': '/'}).app,
      ExternalApp.unknown,
    );
  });

  group('Alert', () {
    test('round trips', () {
      final a = expectRoundTrip(
        {
          'id': 'sonarr.health.IndexerLongTermStatusCheck',
          'severity': 'warning',
          'source': 'sonarr',
          'feature': 'indexers',
          'title': 'Indexers unavailable',
          'message': 'All indexers are unavailable due to failures',
          'route': '/indexers',
          'since': '2026-11-08T07:41:48Z',
          'dismissible': true,
        },
        Alert.fromJson,
        (a) => a.toJson(),
      );
      expect(a.severity, AlertSeverity.warning);
      expect(a.since, DateTime.utc(2026, 11, 8, 7, 41, 48));
    });

    test('unknown severity and source parse to unknown', () {
      final a = Alert.fromJson({
        'id': 'x',
        'severity': 'catastrophic',
        'source': 'plex',
        'feature': 'system',
        'title': 't',
      });
      expect(a.severity, AlertSeverity.unknown);
      expect(a.source, ServiceId.unknown);
      expect(a.dismissible, isFalse);
    });

    test('severity rank orders info < warning < error < critical', () {
      final ranks = [
        AlertSeverity.unknown,
        AlertSeverity.info,
        AlertSeverity.warning,
        AlertSeverity.error,
        AlertSeverity.critical,
      ].map((s) => s.rank).toList();
      expect(ranks, orderedEquals([...ranks]..sort()));
      expect(ranks.toSet(), hasLength(5));
    });
  });

  group('Job', () {
    final jobJson = <String, Object?>{
      'id': 'j_7f3a9c21b0d4',
      'kind': 'containers.restart',
      'target': 'sonarr',
      'status': 'running',
      'progress': 0.5,
      'message': 'Restarting sonarr',
      'steps': [
        {
          'label': 'Restart sonarr',
          'status': 'running',
          'startedAt': '2026-11-08T09:00:01Z',
        },
        {'label': 'Wait for health', 'status': 'queued'},
      ],
      'log': ['restart requested'],
      'result': <String, Object?>{},
      'createdAt': '2026-11-08T09:00:00Z',
      'startedAt': '2026-11-08T09:00:01Z',
      'userId': 'u_1a2b3c4d5e6f',
    };

    test('round trips', () {
      final job = expectRoundTrip(jobJson, Job.fromJson, (j) => j.toJson());
      expect(job.status.isActive, isTrue);
      expect(job.steps, hasLength(2));
      expect(job.steps.last.status, JobStatus.queued);
    });

    test('failed job round trips with its error', () {
      final job = expectRoundTrip(
        {
          'id': 'j_1',
          'kind': 'library.search',
          'status': 'failed',
          'steps': <Object?>[],
          'log': <Object?>[],
          'error': _apiErrorJson,
          'createdAt': '2026-11-08T09:00:00Z',
          'finishedAt': '2026-11-08T09:00:05.500Z',
        },
        Job.fromJson,
        (j) => j.toJson(),
      );
      expect(job.status.isFinished, isTrue);
      expect(job.error?.code, 'validation_failed');
    });

    test('unknown status parses to unknown', () {
      final job = Job.fromJson({
        ...jobJson,
        'status': 'paused',
        'steps': [
          {'label': 's', 'status': 'skipped'},
        ],
      });
      expect(job.status, JobStatus.unknown);
      expect(job.steps.single.status, JobStatus.unknown);
      expect(job.status.isActive, isFalse);
    });
  });

  group('CommandRef', () {
    test('round trips', () {
      final c = expectRoundTrip(
        {
          'service': 'sonarr',
          'id': 12345,
          'name': 'SeriesSearch',
          'status': 'completed',
          'result': 'successful',
          'message': 'Completed',
          'queuedAt': '2026-11-08T09:00:00Z',
          'startedAt': '2026-11-08T09:00:01Z',
          'endedAt': '2026-11-08T09:00:09Z',
        },
        CommandRef.fromJson,
        (c) => c.toJson(),
      );
      expect(c.status, CommandStatus.completed);
      expect(c.result, CommandResult.successful);
    });

    test('unknown status and result parse to unknown', () {
      final c = CommandRef.fromJson({
        'service': 'radarr',
        'id': '9',
        'name': 'MoviesSearch',
        'status': 'restarting',
        'result': 'meh',
      });
      expect(c.id, 9);
      expect(c.status, CommandStatus.unknown);
      expect(c.result, CommandResult.unknown);
      for (final v in CommandStatus.values) {
        expect(CommandStatus.fromJson(v.toJson()), v);
      }
    });
  });
}
