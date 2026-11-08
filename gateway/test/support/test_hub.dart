/// The full gateway against fake upstreams, for core and feature tests
/// (ARCHITECTURE §5.19).
///
/// ```dart
/// final hub = TestHub();
/// hub.fakes.onFixture(ServiceId.sonarr, 'GET', '/api/v3/series', 'arr/sonarr_series.json');
/// final r = await hub.get('/api/v1/library/tv');           // as admin
/// final m = await hub.get('/api/v1/library/tv', as: TestAs.member);
/// await hub.close();
/// ```
///
/// Modules' `start()` is not called unless [TestHub.startModules] is true or
/// [TestHub.startOnly] names them, so no sampler, event stream or 6 h timer
/// leaks into other tests.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:yams_hub_gateway/src/core/auth/password_hasher.dart';
import 'package:yams_hub_gateway/src/core/auth/records.dart';
import 'package:yams_hub_gateway/yams_hub_gateway.dart';
import 'package:yams_models/yams_models.dart';

import 'fake_upstreams.dart';

export 'package:yams_hub_gateway/yams_hub_gateway.dart';
export 'package:yams_models/yams_models.dart';

export 'fake_upstreams.dart';
export 'fixtures.dart';

/// Who a test request is sent as.
enum TestAs { admin, member, anonymous }

/// Passwords of the two seeded users.
const testAdminPassword = 'admin-password-1';
const testMemberPassword = 'member-password-1';

/// The member's Jellyfin user id (Seerr user 2 in the fixtures).
const testMemberJellyfinId = '8bed8d8cccf249548eb6a39fd6a7e54b';

/// Hashes are computed once per test isolate (PBKDF2 at the minimum cost).
final _adminHash = PasswordHasher.hashSync(
  testAdminPassword,
  minHashIterations,
);
final _memberHash = PasswordHasher.hashSync(
  testMemberPassword,
  minHashIterations,
);

/// A fake `HttpConnectionInfo` so the gateway sees a client IP.
final class FakeConnectionInfo implements HttpConnectionInfo {
  FakeConnectionInfo(String ip) : remoteAddress = InternetAddress(ip);

  @override
  final InternetAddress remoteAddress;

  @override
  int get remotePort => 50000;

  @override
  int get localPort => 8080;
}

/// A response with helpers.
final class TestResponse {
  TestResponse(this.status, this.headers, this.bodyBytes);

  final int status;

  /// Lower-case names; multi-value headers joined with `, ` except
  /// `set-cookie` (see [setCookies]).
  final Map<String, String> headers;
  final List<int> bodyBytes;
  List<String> setCookies = const [];

  String get body => utf8.decode(bodyBytes, allowMalformed: true);

  /// The decoded JSON body.
  Object? get json => bodyBytes.isEmpty ? null : jsonDecode(body);

  /// The JSON body as a map.
  JsonMap get map =>
      readMap(json) ?? (throw StateError('body is not a JSON object: $body'));

  /// `error.code` of an error body.
  String? get errorCode => readString(readMap(map['error'])?['code']);

  @override
  String toString() => 'TestResponse($status, $body)';
}

/// The gateway with fake upstreams, a temp data dir, a [FakeClock] and
/// logged-in admin and member sessions.
final class TestHub {
  TestHub({
    this.startModules = false,
    this.startOnly,
    FakeClock? clock,
    FakeUpstreams? fakes,
    Map<String, String> env = const {},
    Set<ServiceId> unconfigured = const {},
    String? policyYaml,
    ModuleBuilder modules = buildFeatureModules,
    PasswordHasher? hasher,
    this.clientIp = '192.168.10.50',
    bool login = true,
  }) : clock = clock ?? FakeClock(),
       fakes = fakes ?? FakeUpstreams() {
    ready = _init(env, unconfigured, policyYaml, modules, hasher, login);
  }

  final bool startModules;
  final Set<String>? startOnly;
  final FakeClock clock;
  final FakeUpstreams fakes;

  /// Default client IP of requests.
  final String clientIp;

  /// Completes once the hub is built and the users are logged in.
  late final Future<void> ready;

  late final Directory dataDir;
  late final HubConfig config;
  late final Hub hub;
  late final UserRecord admin;
  late final UserRecord member;
  late final String adminToken;
  late final String memberToken;
  late final String adminSessionId;
  late final String memberSessionId;

  FeatureContext get ctx => hub.context;

  Future<void> _init(
    Map<String, String> extraEnv,
    Set<ServiceId> unconfigured,
    String? policyYaml,
    ModuleBuilder modules,
    PasswordHasher? hasher,
    bool login,
  ) async {
    dataDir = await Directory.systemTemp.createTemp('yams-hub-test-');
    final hostDir = Directory(p.join(dataDir.path, '_host'))..createSync();
    final netDev = File(p.join(hostDir.path, 'net_dev'))
      ..writeAsStringSync('Inter-|   Receive\n');
    File(p.join(hostDir.path, 'stat'))
        .writeAsStringSync('cpu  1 0 1 1 0 0 0 0 0 0\n');
    final env = {
      ...fakes.env(unconfigured: unconfigured),
      'YAMS_HUB_DATA_DIR': p.join(dataDir.path, 'data'),
      'YAMS_HUB_WEB_DIR': p.join(dataDir.path, 'web'),
      'HOST_NET_DEV': netDev.path,
      'HOST_SYS': p.join(hostDir.path, 'sys'),
      'RECYCLARR_LOG_DIR': p.join(hostDir.path, 'recyclarr'),
      ...extraEnv,
    };
    config = ConfigLoader.load(
      env,
      policyFileContents: policyYaml,
    ).copyWith(procDir: hostDir.path);
    hub = await Hub.create(
      config,
      upstreamClient: fakes.client,
      remoteFetcher: fakes.remoteFetcher(),
      clock: clock,
      hasher: hasher ?? PasswordHasher(iterations: minHashIterations),
      modules: modules,
    );
    final now = clock.now();
    admin = UserRecord(
      id: 'u_00000000000a',
      username: 'admin',
      displayName: 'Admin',
      role: Role.admin,
      passwordHash: _adminHash,
      createdAt: now,
      updatedAt: now,
    );
    member = UserRecord(
      id: 'u_00000000000b',
      username: 'member',
      displayName: 'Member',
      role: Role.member,
      passwordHash: _memberHash,
      jellyfinUserId: testMemberJellyfinId,
      createdAt: now,
      updatedAt: now,
    );
    await hub.auth.users.put(admin);
    await hub.auth.users.put(member);
    if (login) {
      final a = await hub.auth.login(
        username: 'admin',
        password: testAdminPassword,
        deviceName: 'test',
        platform: ClientPlatform.other,
        ip: '192.168.10.2',
      );
      adminToken = a.tokens.accessToken;
      adminSessionId = a.session.id;
      final m = await hub.auth.login(
        username: 'member',
        password: testMemberPassword,
        deviceName: 'test',
        platform: ClientPlatform.other,
        ip: '192.168.10.3',
      );
      memberToken = m.tokens.accessToken;
      memberSessionId = m.session.id;
    }
    if (startModules || startOnly != null) {
      await hub.start(only: startModules ? null : startOnly, core: false);
    }
  }

  /// Sends a request through the full pipeline. [path] includes the mount
  /// (`/api/v1/...` or `/yh/api/v1/...`). [body] is JSON-encoded unless it is
  /// a `String` or bytes.
  Future<TestResponse> request(
    String method,
    String path, {
    Object? body,
    TestAs as = TestAs.admin,
    String? token,
    Map<String, String> headers = const {},
    String? ip,
    String host = '192.168.10.183:8090',
  }) async {
    await ready;
    final h = <String, String>{'host': host, ...headers};
    final bearer =
        token ??
        switch (as) {
          TestAs.admin => adminToken,
          TestAs.member => memberToken,
          TestAs.anonymous => null,
        };
    if (bearer != null && !h.containsKey('authorization')) {
      h['authorization'] = 'Bearer $bearer';
    }
    Object? encoded;
    if (body != null) {
      if (body is String || body is List<int>) {
        encoded = body;
      } else {
        encoded = jsonEncode(body);
        h.putIfAbsent('content-type', () => 'application/json');
      }
    }
    final request = Request(
      method,
      Uri.parse('http://$host$path'),
      headers: h,
      body: encoded,
      context: {'shelf.io.connection_info': FakeConnectionInfo(ip ?? clientIp)},
    );
    final response = await hub.handler(request);
    final bytes = await response.read().fold<List<int>>(
      <int>[],
      (a, b) => a..addAll(b),
    );
    final r = TestResponse(response.statusCode, {
      for (final e in response.headersAll.entries)
        e.key.toLowerCase(): e.value.join(', '),
    }, bytes);
    r.setCookies = response.headersAll['set-cookie'] ?? const [];
    return r;
  }

  Future<TestResponse> get(
    String path, {
    TestAs as = TestAs.admin,
    String? token,
    Map<String, String> headers = const {},
    String? ip,
  }) => request('GET', path, as: as, token: token, headers: headers, ip: ip);

  Future<TestResponse> post(
    String path, {
    Object? body,
    TestAs as = TestAs.admin,
    String? token,
    Map<String, String> headers = const {},
    String? ip,
  }) => request(
    'POST',
    path,
    body: body,
    as: as,
    token: token,
    headers: headers,
    ip: ip,
  );

  Future<TestResponse> put(
    String path, {
    Object? body,
    TestAs as = TestAs.admin,
    String? token,
    Map<String, String> headers = const {},
  }) =>
      request('PUT', path, body: body, as: as, token: token, headers: headers);

  Future<TestResponse> patch(
    String path, {
    Object? body,
    TestAs as = TestAs.admin,
    String? token,
    Map<String, String> headers = const {},
  }) => request(
    'PATCH',
    path,
    body: body,
    as: as,
    token: token,
    headers: headers,
  );

  Future<TestResponse> delete(
    String path, {
    Object? body,
    TestAs as = TestAs.admin,
    String? token,
    Map<String, String> headers = const {},
  }) => request(
    'DELETE',
    path,
    body: body,
    as: as,
    token: token,
    headers: headers,
  );

  /// Stops the hub and deletes the temp directory.
  Future<void> close() async {
    await ready;
    await hub.stop();
    if (await dataDir.exists()) await dataDir.delete(recursive: true);
  }
}
