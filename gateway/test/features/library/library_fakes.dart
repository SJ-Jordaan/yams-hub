/// Fake Sonarr/Radarr/Seerr answers for the library tests: the captured
/// fixtures plus the synthetic samples in `data/` (queue records and release
/// searches were never captured live; built from integrations/arr.md §9).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../support/test_hub.dart';

/// The decoded JSON of `test/features/library/data/<name>`.
Object? syntheticJson(String name) {
  var dir = Directory.current.absolute;
  // Tests run from gateway/; also work from the repo root.
  for (final candidate in [
    p.join(dir.path, 'test', 'features', 'library', 'data', name),
    p.join(dir.path, 'gateway', 'test', 'features', 'library', 'data', name),
  ]) {
    final f = File(candidate);
    if (f.existsSync()) return jsonDecode(f.readAsStringSync());
  }
  throw StateError('synthetic sample $name not found');
}

/// A deep copy of a fixture so a test can modify it.
Object? fixtureCopy(String path) => jsonDecode(jsonEncode(fixture(path)));

/// Registers the standard upstream answers used by most library tests.
void stubLibraryUpstreams(FakeUpstreams fakes) {
  const s = ServiceId.sonarr;
  const r = ServiceId.radarr;
  fakes
    ..onFixture(s, 'GET', '/api/v3/series', 'arr/sonarr_series.json')
    ..onFixture(
      s,
      'GET',
      RegExp(r'^/api/v3/series/\d+$'),
      'arr/sonarr_error_404.json',
      status: 404,
    )
    ..onFixture(s, 'GET', '/api/v3/series/54', 'arr/sonarr_series_id.json')
    ..onFixture(s, 'GET', '/api/v3/episode', 'arr/sonarr_episode_anime.json')
    ..on(
      s,
      'GET',
      '/api/v3/queue/details',
      (_) => FakeResponse.json(
        syntheticJson('sonarr_queue_details.synthetic.json'),
      ),
    )
    ..on(
      s,
      'GET',
      '/api/v3/tag',
      (_) => FakeResponse.json(syntheticJson('sonarr_tag.synthetic.json')),
    )
    ..onFixture(
      s,
      'GET',
      '/api/v3/qualityprofile',
      'arr/sonarr_qualityprofile.json',
    )
    ..onFixture(s, 'GET', '/api/v3/rootfolder', 'arr/sonarr_rootfolder.json')
    ..onFixture(
      s,
      'GET',
      '/api/v3/system/status',
      'arr/sonarr_system_status.json',
    )
    ..onFixture(s, 'GET', '/api/v3/health', 'arr/sonarr_health.json')
    ..onFixture(
      s,
      'GET',
      '/api/v3/queue/status',
      'arr/sonarr_queue_status.json',
    )
    ..onFixture(
      s,
      'GET',
      '/api/v3/wanted/missing',
      'arr/sonarr_wanted_missing.json',
    )
    ..onFixture(
      s,
      'GET',
      '/api/v3/wanted/cutoff',
      'arr/sonarr_wanted_cutoff.json',
    )
    ..onFixture(s, 'GET', '/api/v3/history', 'arr/sonarr_history.json')
    ..onFixture(
      s,
      'GET',
      '/api/v3/series/lookup',
      'arr/sonarr_series_lookup.json',
    )
    ..onFixture(r, 'GET', '/api/v3/movie', 'arr/radarr_movie.json')
    ..onFixture(
      r,
      'GET',
      RegExp(r'^/api/v3/movie/\d+$'),
      'arr/radarr_error_404.json',
      status: 404,
    )
    ..onFixture(r, 'GET', '/api/v3/movie/1', 'arr/radarr_movie_id.json')
    ..onFixture(r, 'GET', '/api/v3/moviefile', 'arr/radarr_moviefile.json')
    ..on(
      r,
      'GET',
      RegExp(r'^/api/v3/moviefile/\d+$'),
      (_) => FakeResponse.json(
        (fixture('arr/radarr_moviefile.json')! as List).first,
      ),
    )
    ..onFixture(
      r,
      'GET',
      '/api/v3/queue/details',
      'arr/radarr_queue_details.json',
    )
    ..on(
      r,
      'GET',
      '/api/v3/tag',
      (_) => FakeResponse.json(syntheticJson('radarr_tag.synthetic.json')),
    )
    ..onFixture(
      r,
      'GET',
      '/api/v3/qualityprofile',
      'arr/radarr_qualityprofile.json',
    )
    ..onFixture(r, 'GET', '/api/v3/rootfolder', 'arr/radarr_rootfolder.json')
    ..onFixture(
      r,
      'GET',
      '/api/v3/system/status',
      'arr/radarr_system_status.json',
    )
    ..onFixture(r, 'GET', '/api/v3/health', 'arr/radarr_health.json')
    ..onFixture(
      r,
      'GET',
      '/api/v3/queue/status',
      'arr/radarr_queue_status.json',
    )
    ..onFixture(
      r,
      'GET',
      '/api/v3/wanted/missing',
      'arr/radarr_wanted_missing.json',
    )
    ..onFixture(
      r,
      'GET',
      '/api/v3/wanted/cutoff',
      'arr/radarr_wanted_cutoff.json',
    )
    ..onFixture(r, 'GET', '/api/v3/history', 'arr/radarr_history.json')
    ..onFixture(
      r,
      'GET',
      '/api/v3/movie/lookup',
      'arr/radarr_movie_lookup.json',
    )
    ..onFixture(
      ServiceId.seerr,
      'GET',
      '/api/v1/service/sonarr',
      'seerr/seerr_service_sonarr.json',
    )
    ..onFixture(
      ServiceId.seerr,
      'GET',
      '/api/v1/service/radarr',
      'seerr/seerr_service_radarr.json',
    );
}

/// A created Servarr command resource (`POST /api/v3/command` → 201).
JsonMap commandResource(int id, JsonMap body) => {
  'name': body['name'],
  'commandName': body['name'],
  'body': {...body, 'trigger': 'manual'},
  'priority': 'normal',
  'status': 'queued',
  'result': 'unknown',
  'queued': '2026-11-08T09:00:00Z',
  'trigger': 'manual',
  'id': id,
};

/// Answers `POST /api/v3/command` on [service] with increasing ids.
void stubCommands(
  FakeUpstreams fakes,
  ServiceId service, {
  int firstId = 5000,
}) {
  var next = firstId;
  fakes.on(
    service,
    'POST',
    '/api/v3/command',
    (req) => FakeResponse.json(
      commandResource(next++, req.json()! as JsonMap),
      status: 201,
    ),
  );
}

/// The calls to [service] whose path equals [path] (and [method]).
List<RecordedCall> callsOf(
  FakeUpstreams fakes,
  ServiceId service,
  String path, {
  String? method,
}) => [
  for (final c in fakes.callsTo(service))
    if (c.path == path && (method == null || c.method == method)) c,
];
