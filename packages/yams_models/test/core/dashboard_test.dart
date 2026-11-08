import 'package:test/test.dart';
import 'package:yams_models/yams_models.dart';

import 'round_trip.dart';

void main() {
  final sample = <String, Object?>{
    'generatedAt': '2026-11-08T09:00:00Z',
    'alerts': [
      {
        'id': 'prowlarr.indexer.5',
        'severity': 'error',
        'source': 'prowlarr',
        'feature': 'indexers',
        'title': 'Nyaa.si is failing',
        'route': '/indexers',
        'dismissible': false,
      },
    ],
    'cards': {
      'requests': {
        'status': 'ok',
        'data': {
          'counts': {'pending': 3},
        },
        'fetchedAt': '2026-11-08T09:00:00Z',
        'stale': false,
      },
      'activity': {
        'status': 'ok',
        'data': {
          'counts': {'attention': 1},
        },
        'fetchedAt': '2026-11-08T08:59:58Z',
        'stale': true,
      },
      'indexers': {
        'status': 'error',
        'error': {
          'code': 'not_implemented',
          'message': 'Not implemented yet.',
          'status': 501,
          'requestId': 'r1',
          'fields': <Object?>[],
        },
        'fetchedAt': '2026-11-08T09:00:00Z',
        'stale': false,
      },
      'subtitles': {
        'status': 'disabled',
        'error': {
          'code': 'service_not_configured',
          'message': 'Bazarr is not configured.',
          'status': 503,
          'service': 'bazarr',
          'requestId': 'r2',
          'fields': <Object?>[],
        },
        'stale': false,
      },
    },
  };

  test('DashboardResponse round trips', () {
    final d = expectRoundTrip(
      sample,
      DashboardResponse.fromJson,
      (d) => d.toJson(),
    );
    expect(d.alerts.single.severity, AlertSeverity.error);
    expect(d.cards.keys, ['requests', 'activity', 'indexers', 'subtitles']);
    expect(
      d.card(DashboardCardKeys.indexers)?.error?.code,
      ApiErrorCode.notImplemented,
    );
    expect(d.card(DashboardCardKeys.subtitles)?.status, SectionState.disabled);
    expect(d.card(DashboardCardKeys.system), isNull);
  });

  test('raw badge keys stay readable from Section.data', () {
    final d = DashboardResponse.fromJson(wire(sample));
    final counts = readMap(d.card(DashboardCardKeys.requests)?.data?['counts']);
    expect(readInt(counts?['pending']), 3);
    expect(d.card(DashboardCardKeys.activity)?.stale, isTrue);
  });

  test('unknown card statuses and malformed cards are tolerated', () {
    final d = DashboardResponse.fromJson({
      'generatedAt': '2026-11-08T09:00:00Z',
      'cards': {
        'system': {'status': 'warming'},
        'media': 'broken',
      },
    });
    expect(d.alerts, isEmpty);
    expect(d.cards.keys, ['system']);
    expect(d.card('system')?.status, SectionState.unknown);
  });

  test('card keys cover every feature card', () {
    expect(DashboardCardKeys.all, hasLength(9));
    expect(DashboardCardKeys.all.toSet(), hasLength(9));
  });
}
