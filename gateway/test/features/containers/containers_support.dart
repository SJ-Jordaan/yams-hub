/// Shared fakes for the containers feature tests.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:yams_hub_gateway/src/features/containers/containers_module.dart';

import '../../support/test_hub.dart';

export '../../support/test_hub.dart';

/// `test/features/containers/data/<name>`.
String dataPath(String name) {
  for (final base in [
    p.join('test', 'features', 'containers', 'data'),
    p.join('gateway', 'test', 'features', 'containers', 'data'),
  ]) {
    final f = File(p.join(base, name));
    if (f.existsSync()) return f.path;
  }
  throw StateError('test data $name not found');
}

Object? dataJson(String name) =>
    jsonDecode(File(dataPath(name)).readAsStringSync());

String dataText(String name) => File(dataPath(name)).readAsStringSync();

/// The five captured containers plus the synthetic extras.
List<JsonMap> dockerList() => [
  for (final e in fixture('system/docker_containers_json.json')! as List)
    readMap(e)!,
  for (final e
      in readMap(dataJson('docker_containers_extra.synthetic.json'))!['items']!
          as List)
    readMap(e)!,
];

/// The id of [name] in [dockerList].
String idOf(String name) => readString(
  dockerList().firstWhere(
    (e) => readStringList(e['Names']).first == '/$name',
  )['Id'],
)!;

/// A Docker multiplexed log body (`[stream][0,0,0][size][payload]`).
List<int> multiplexed(List<(int, String)> frames) {
  final out = BytesBuilder();
  for (final (stream, text) in frames) {
    final payload = utf8.encode(text);
    final header = ByteData(8)
      ..setUint8(0, stream)
      ..setUint32(4, payload.length);
    out
      ..add(header.buffer.asUint8List())
      ..add(payload);
  }
  return out.takeBytes();
}

/// Builds a hub with only the containers module and fast timings.
TestHub containersHub({
  bool start = false,
  Set<ServiceId> unconfigured = const {},
  String? policyYaml,
  FakeClock? clock,
}) => TestHub(
  modules: (ctx) => [
    ContainersModule(
      ctx.forFeature('containers'),
      timings: const ContainersTimings.fast(),
    ),
  ],
  startOnly: start ? {'containers'} : null,
  unconfigured: unconfigured,
  policyYaml: policyYaml,
  clock: clock,
);

extension ContainersHubX on TestHub {
  ContainersModule get containers =>
      hub.modules.whereType<ContainersModule>().single;

  /// Answers the Docker list and inspect calls from the fixtures.
  void fakeDocker({List<JsonMap>? list}) {
    final entries = list ?? dockerList();
    fakes.on(
      ServiceId.docker,
      'GET',
      '/v1.54/containers/json',
      (_) => FakeResponse.json(entries),
    );
    fakes.onFixture(
      ServiceId.docker,
      'GET',
      '/v1.54/info',
      'system/docker_info.json',
    );
    fakes.onFixture(
      ServiceId.docker,
      'GET',
      '/v1.54/containers/sonarr/json',
      'system/docker_container_inspect.json',
    );
    fakes.onFixture(
      ServiceId.docker,
      'GET',
      '/v1.54/containers/${idOf('sonarr')}/json',
      'system/docker_container_inspect.json',
    );
    final decl = readMap(dataJson('docker_inspect_decluttarr.synthetic.json'))!;
    decl['Id'] = idOf('decluttarr');
    for (final ref in ['decluttarr', idOf('decluttarr')]) {
      fakes.on(
        ServiceId.docker,
        'GET',
        '/v1.54/containers/$ref/json',
        (_) => FakeResponse.json(decl),
      );
    }
  }

  /// Makes the proxy self-test pass (every write probe answers 403).
  Future<void> passSelfTest() async {
    await ready;
    for (final (method, path) in [
      ('POST', '/v1.54/containers/create'),
      ('POST', '/v1.54/images/create'),
      ('DELETE', '/v1.54/containers/yams-hub-selftest-nonexistent'),
    ]) {
      fakes.on(
        ServiceId.docker,
        method,
        path,
        (_) => FakeResponse.text(
          '<html><body><h1>403 Forbidden</h1></body></html>',
          status: 403,
          contentType: 'text/html',
        ),
      );
    }
    final state = await hub.health.dockerProxy.run();
    if (state != ProxySelfTestState.passed) {
      throw StateError('self-test did not pass: $state');
    }
  }

  /// Waits until job [id] finished.
  Future<Job> waitJob(String id) async {
    final record = ctx.jobs.get(id)!;
    await record.done.timeout(const Duration(seconds: 10));
    return record.toDto();
  }

  /// Docker calls whose path is [path] (ignores the stats poller).
  List<RecordedCall> dockerCalls(String path, {String? method}) => [
    for (final c in fakes.callsTo(ServiceId.docker))
      if (c.path == path && (method == null || c.method == method)) c,
  ];
}
