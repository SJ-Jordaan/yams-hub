/// Shared fakes for the activity tests: captured qBittorrent/gluetun
/// fixtures plus the synthetic *arr queue and manual-import samples in
/// `data/` (the queues were empty while probing; shapes from arr.md §9).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../support/test_hub.dart';

/// A fixture torrent that the synthetic Sonarr queue tracks (season pack,
/// `importPending`).
const sonarrHash = '0985d9efdf7508db837e629ae8f40ee8b56f4d71';

/// A fixture torrent that the synthetic Radarr queue tracks.
const radarrHash = '2b96b8269b32cb9c44bf8808eca92aaad3e2b015';

/// A fixture torrent nobody tracks (`stoppedUP`).
const plainHash = '4f1acde36a17c2f9faedc9f425758ca8525e2e57';

String _dataPath(String name) {
  for (final base in const [
    'test/features/activity/data',
    'gateway/test/features/activity/data',
  ]) {
    final f = File(p.join(base, name));
    if (f.existsSync()) return f.path;
  }
  throw StateError('synthetic sample $name not found');
}

/// A synthetic sample from `data/`.
Object? synthetic(String name) =>
    jsonDecode(File(_dataPath(name)).readAsStringSync());

FakeResponse syntheticResponse(String name) =>
    FakeResponse.json(synthetic(name));

/// Text/plain JSON, like gluetun answers.
FakeResponse gluetunResponse(Object? json) => FakeResponse.text(
  '${jsonEncode(json)}\n',
  contentType: 'text/plain; charset=utf-8',
);

/// Registers the default activity fakes on [f].
void installActivityFakes(FakeUpstreams f, {bool queues = true}) {
  const q = ServiceId.qbittorrent;
  f
    ..onFixture(
      q,
      'GET',
      '/api/v2/sync/maindata',
      'downloads/qbittorrent_sync_maindata_full.json',
    )
    ..onFixture(
      q,
      'GET',
      '/api/v2/transfer/getSpeedLimits',
      'downloads/qbittorrent_transfer_getSpeedLimits.json',
    )
    ..onFixture(
      q,
      'GET',
      '/api/v2/app/preferences',
      'downloads/qbittorrent_app_preferences.json',
    )
    ..onFixture(
      q,
      'GET',
      '/api/v2/torrents/categories',
      'downloads/qbittorrent_torrents_categories.json',
    )
    ..onFixture(
      q,
      'GET',
      '/api/v2/torrents/tags',
      'downloads/qbittorrent_torrents_tags.json',
    )
    ..on(
      q,
      'POST',
      RegExp(r'^/api/v2/(torrents|transfer)/'),
      (_) => FakeResponse(200),
    )
    ..on(
      ServiceId.gluetun,
      'GET',
      '/v1/publicip/ip',
      (_) => gluetunResponse(fixture('downloads/gluetun_publicip_ip.json')),
    )
    ..on(
      ServiceId.gluetun,
      'GET',
      '/v1/openvpn/portforwarded',
      (_) => gluetunResponse(
        fixture('downloads/gluetun_openvpn_portforwarded.json'),
      ),
    )
    ..on(
      ServiceId.docker,
      'GET',
      '/v1.54/containers/json',
      (_) => syntheticResponse('docker_containers_gluetun.synthetic.json'),
    );
  if (queues) {
    f
      ..on(
        ServiceId.sonarr,
        'GET',
        '/api/v3/queue',
        (_) => syntheticResponse('sonarr_queue.synthetic.json'),
      )
      ..on(
        ServiceId.radarr,
        'GET',
        '/api/v3/queue',
        (_) => syntheticResponse('radarr_queue.synthetic.json'),
      );
  } else {
    for (final s in [ServiceId.sonarr, ServiceId.radarr]) {
      f.onFixture(s, 'GET', '/api/v3/queue', 'arr/${s.name}_queue.json');
    }
  }
}

/// A hub with the default activity fakes.
TestHub activityHub({
  bool queues = true,
  Set<ServiceId> unconfigured = const {},
}) {
  final fakes = FakeUpstreams();
  installActivityFakes(fakes, queues: queues);
  return TestHub(fakes: fakes, unconfigured: unconfigured);
}

/// The form fields of the last [method] call to [path] on [service].
Map<String, String> lastForm(
  FakeUpstreams f,
  ServiceId service,
  String path, {
  String method = 'POST',
}) {
  final call = f
      .callsTo(service)
      .lastWhere((c) => c.method == method && c.path == path);
  return Uri.splitQueryString(call.body);
}

/// Whether [service] received a [method] call to [path].
bool called(
  FakeUpstreams f,
  ServiceId service,
  String path, {
  String method = 'POST',
}) => f.callsTo(service).any((c) => c.method == method && c.path == path);
