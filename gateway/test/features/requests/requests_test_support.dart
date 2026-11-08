/// Fakes shared by the requests feature tests.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../support/test_hub.dart';

/// Seerr user id of the test member (`seerr_user_by_jellyfin_id.json`).
const memberSeerrId = 2;

/// A synthetic Seerr sample from `test/features/requests/data/`.
Object? synthetic(String name) => jsonDecode(
  File(p.join('test', 'features', 'requests', 'data', name)).readAsStringSync(),
);

/// A JSON map copy of a fixture (for per-test tweaks).
JsonMap fixtureMap(String path) =>
    jsonDecode(jsonEncode(fixture(path))) as JsonMap;

/// A `FakeResponse` for a synthetic sample.
FakeResponse syntheticResponse(String name, {int status = 200}) =>
    FakeResponse.json(synthetic(name), status: status);

/// Details fixtures by `type:tmdbId`.
const detailFixtures = {
  'movie:818': 'seerr/seerr_movie_details_available.json',
  'movie:603': 'seerr/seerr_movie_details_not_in_db.json',
  'tv:10545': 'seerr/seerr_tv_details_partially_available.json',
  'tv:32871': 'seerr/seerr_tv_details_processing.json',
  'tv:1126': 'seerr/seerr_tv_details_failed_request.json',
};

final _details = RegExp(r'^/api/v1/(movie|tv)/(\d+)$');

/// Registers what most requests routes need:
/// - Jellyfin server id, Seerr public settings;
/// - the admin's Seerr user (id 1, no Jellyfin link on the hub admin) and
///   the member's link (Seerr user 2) unless [memberLinked] is false;
/// - movie/tv details for the ids in [detailFixtures] (other ids answer
///   Seerr's 500 "Unable to retrieve ...", like TMDB misses).
void seerrBasics(FakeUpstreams fakes, {bool memberLinked = true}) {
  fakes
    ..onFixture(
      ServiceId.jellyfin,
      'GET',
      '/System/Info/Public',
      'seerr/jellyfin_system_info_public.json',
    )
    ..onFixture(
      ServiceId.seerr,
      'GET',
      '/api/v1/settings/public',
      'seerr/seerr_settings_public.json',
    )
    ..onFixture(
      ServiceId.seerr,
      'GET',
      '/api/v1/user/1',
      'seerr/seerr_user_detail.json',
    )
    ..on(ServiceId.seerr, 'GET', _details, (r) {
      final m = _details.firstMatch(r.uri.path)!;
      final f = detailFixtures['${m[1]}:${m[2]}'];
      if (f == null) {
        return FakeResponse.json({
          'message': 'Unable to retrieve ${m[1]}.',
        }, status: 500);
      }
      return FakeResponse.fixture(f);
    });
  if (memberLinked) {
    fakes.onFixture(
      ServiceId.seerr,
      'GET',
      '/api/v1/user/jellyfin/$testMemberJellyfinId',
      'seerr/seerr_user_by_jellyfin_id.json',
    );
  } else {
    fakes.onFixture(
      ServiceId.seerr,
      'GET',
      '/api/v1/user/jellyfin/$testMemberJellyfinId',
      'seerr/seerr_error_404_user_by_jellyfin_id.json',
      status: 404,
    );
  }
}

/// The raw (still percent-encoded) query of the last [method] [path] call.
String? lastRawQuery(List<String> sink) => sink.isEmpty ? null : sink.last;

/// Registers [path] with [response] and records each raw query in the
/// returned list.
List<String> recordQueries(
  FakeUpstreams fakes,
  String method,
  Object path,
  FakeResponse Function(FakeRequest r) response,
) {
  final queries = <String>[];
  fakes.on(ServiceId.seerr, method, path, (r) {
    queries.add(r.uri.query);
    return response(r);
  });
  return queries;
}

/// Calls to Seerr [path] (exact).
List<RecordedCall> seerrCalls(
  FakeUpstreams fakes,
  String path, {
  String? method,
}) => [
  for (final c in fakes.callsTo(ServiceId.seerr))
    if (c.path == path && (method == null || c.method == method)) c,
];
