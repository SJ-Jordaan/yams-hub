import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';
import 'package:yams_hub_updater/yams_hub_updater.dart';

import 'support/fake_process_runner.dart';

const _token = 'test-updater-token-0123456789abcdef0123';
const _hub = '172.30.250.2';

InternetAddress _ip(String s) => InternetAddress(s);

final class _Conn implements HttpConnectionInfo {
  _Conn(String ip) : remoteAddress = InternetAddress(ip);

  @override
  final InternetAddress remoteAddress;
  @override
  int get remotePort => 40000;
  @override
  int get localPort => 8080;
}

Handler _handler(FakeProcessRunner runner, {SourceAllowList? sources}) {
  final config = UpdaterConfig(token: _token);
  final commands = ComposeCommands(config);
  return buildUpdaterHandler(
    auth: BearerAuth(_token),
    allowList: ServiceAllowList(
      runner: runner,
      configCommand: commands.configServices(),
      deny: config.deny,
    ),
    jobs: JobManager(runner: runner, stepTimeout: config.stepTimeout),
    commands: commands,
    allowedSources: sources,
  );
}

Request _req(
  String method,
  String path, {
  String? from,
  bool withToken = true,
}) => Request(
  method,
  Uri.parse('http://yams-hub-updater:8080$path'),
  headers: {if (withToken) 'authorization': 'Bearer $_token'},
  context: {if (from != null) connectionInfoKey: _Conn(from)},
);

void main() {
  group('IpRange', () {
    test('single addresses and CIDR ranges', () {
      final one = IpRange.parse(_hub);
      expect(one.contains(_ip(_hub)), isTrue);
      expect(one.contains(_ip('172.30.250.3')), isFalse);
      expect(one.toString(), _hub);

      final net = IpRange.parse(' 172.30.250.0/29 ');
      expect(net.contains(_ip('172.30.250.0')), isTrue);
      expect(net.contains(_ip('172.30.250.7')), isTrue);
      expect(net.contains(_ip('172.30.250.8')), isFalse);
      expect(net.contains(_ip('172.28.0.12')), isFalse);
      expect(net.toString(), '172.30.250.0/29');

      final v6 = IpRange.parse('fd00::/8');
      expect(v6.contains(_ip('fd12::1')), isTrue);
      expect(v6.contains(_ip('fe80::1')), isFalse);
      expect(v6.contains(_ip('10.0.0.1')), isFalse);
      expect(IpRange.parse('0.0.0.0/0').contains(_ip('8.8.8.8')), isTrue);
    });

    test('IPv4-mapped IPv6 peers count as IPv4', () {
      expect(IpRange.parse(_hub).contains(_ip('::ffff:$_hub')), isTrue);
      expect(IpRange.parse('::ffff:$_hub').contains(_ip(_hub)), isTrue);
      expect(IpRange.parse(_hub).contains(_ip('::ffff:172.30.250.3')), isFalse);
    });

    test('malformed entries are refused', () {
      for (final bad in [
        '',
        'yams-hub',
        '172.30.250',
        '172.30.250.256',
        '172.30.250.0/33',
        '172.30.250.0/-1',
        '172.30.250.0/x',
        '::1/129',
      ]) {
        expect(() => IpRange.parse(bad), throwsFormatException, reason: bad);
      }
    });

    test('host bits below the prefix are refused, naming the network', () {
      expect(
        () => IpRange.parse('172.30.250.2/29'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('172.30.250.0/29'),
          ),
        ),
      );
    });
  });

  group('SourceAllowList', () {
    test('parses comma or whitespace separated lists', () {
      final l = SourceAllowList.parse('172.30.250.2, 10.0.0.0/8  fd00::/8');
      expect(l.ranges, hasLength(3));
      expect(l.toString(), '172.30.250.2,10.0.0.0/8,fd00::/8');
      expect(l.allows(_ip('10.1.2.3')), isTrue);
      expect(l.allows(_ip('172.28.0.12')), isFalse);
    });

    test('an empty list is an error, not "allow nobody"', () {
      expect(() => SourceAllowList.parse(' , '), throwsFormatException);
    });

    test('loopback is always allowed (the Docker healthcheck)', () {
      final l = SourceAllowList.parse(_hub);
      expect(l.allows(_ip('127.0.0.1')), isTrue);
      expect(l.allows(_ip('127.0.0.11')), isTrue);
      expect(l.allows(_ip('::1')), isTrue);
      expect(l.allows(_ip('::ffff:127.0.0.1')), isTrue);
    });

    test('the bridge gateway and other containers are not', () {
      final l = SourceAllowList.parse(_hub);
      for (final ip in [
        '172.30.250.1', // host / masqueraded traffic
        '172.30.250.3', // socket-proxy-hub
        '172.30.250.4', // the updater itself
        '172.28.0.49', // the hub's yams_network address
        '172.28.0.12', // prowlarr
      ]) {
        expect(l.allows(_ip(ip)), isFalse, reason: ip);
      }
    });
  });

  group('UPDATER_ALLOWED_SOURCES in the config', () {
    String read(String _) => "UPDATER_TOKEN='$_token'";

    test('unset or blank means no source check', () {
      expect(
        UpdaterConfig.fromEnvironment(const {}, readFile: read).allowedSources,
        isNull,
      );
      final blank = UpdaterConfig.fromEnvironment(const {
        'UPDATER_ALLOWED_SOURCES': '  ',
      }, readFile: read);
      expect(blank.allowedSources, isNull);
      expect(blank.toString(), contains('allowedSources: any (unset)'));
    });

    test('parsed and shown in the start-up line', () {
      final c = UpdaterConfig.fromEnvironment(const {
        'UPDATER_ALLOWED_SOURCES': _hub,
      }, readFile: read);
      expect(c.allowedSources!.allows(_ip(_hub)), isTrue);
      expect(c.toString(), contains('allowedSources: $_hub'));
      expect(c.toString(), isNot(contains(_token)));
    });

    test('a malformed entry stops the updater from starting', () {
      expect(
        () => UpdaterConfig.fromEnvironment(const {
          'UPDATER_ALLOWED_SOURCES': '172.30.250.2,yams-hub',
        }, readFile: read),
        throwsA(
          isA<UpdaterConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('UPDATER_ALLOWED_SOURCES'), contains('yams-hub')),
          ),
        ),
      );
    });
  });

  group('the source check in the handler', () {
    late FakeProcessRunner runner;
    late Handler handler;
    setUp(() {
      runner = FakeProcessRunner()..composeServices(['sonarr']);
      handler = _handler(runner, sources: SourceAllowList.parse(_hub));
    });

    test(
      'the gateway gets through to the token check and the routes',
      () async {
        final ok = await handler(_req('GET', '/healthz', from: _hub));
        expect(ok.statusCode, 200);
        final noToken = await handler(
          _req('GET', '/healthz', from: _hub, withToken: false),
        );
        expect(noToken.statusCode, 401);
      },
    );

    for (final (method, path) in [
      ('GET', '/healthz'),
      ('GET', '/services'),
      ('POST', '/update/sonarr'),
      ('POST', '/exec/recyclarr-sync'),
      ('GET', '/does-not-exist'),
    ]) {
      test('$method $path from another container is a bare 403, even with the '
          'token, and runs nothing', () async {
        for (final withToken in [true, false]) {
          final r = await handler(
            _req(method, path, from: '172.28.0.12', withToken: withToken),
          );
          expect(r.statusCode, 403);
          expect(r.headers['www-authenticate'], isNull);
          expect(jsonDecode(await r.readAsString()), {
            'error': 'forbidden',
            'message': 'Forbidden',
          });
        }
        expect(runner.calls, isEmpty);
      });
    }

    test('no connection info fails closed', () async {
      final r = await handler(_req('GET', '/healthz'));
      expect(r.statusCode, 403);
    });

    test('loopback is allowed (the in-container healthcheck)', () async {
      final r = await handler(_req('GET', '/healthz', from: '127.0.0.1'));
      expect(r.statusCode, 200);
    });

    test('refusals are logged at WARNING, throttled per address', () async {
      final records = <LogRecord>[];
      final previous = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(() async {
        await sub.cancel();
        Logger.root.level = previous;
      });
      for (var i = 0; i < 5; i++) {
        await handler(_req('GET', '/healthz?q=s3cret', from: '172.28.0.12'));
      }
      await handler(_req('GET', '/healthz', from: '172.28.0.13'));
      final refused = records
          .where((r) => r.message.startsWith('refused'))
          .toList();
      expect(refused.map((r) => r.message), [
        'refused GET from 172.28.0.12: not in UPDATER_ALLOWED_SOURCES',
        'refused GET from 172.28.0.13: not in UPDATER_ALLOWED_SOURCES',
      ]);
      expect(refused.every((r) => r.level == Level.WARNING), isTrue);
      expect(records.join('\n'), isNot(contains('s3cret')));
    });

    test('without UPDATER_ALLOWED_SOURCES any peer reaches the token check '
        '(back-compat)', () async {
      final open = _handler(runner);
      final r = await open(_req('GET', '/healthz', from: '172.28.0.12'));
      expect(r.statusCode, 200);
      final anon = await open(_req('GET', '/healthz', withToken: false));
      expect(anon.statusCode, 401);
    });
  });

  group('over a real socket (shelf_io)', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('updater_src_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<HttpServer> serve(InternetAddress on) async => shelf_io.serve(
      _handler(
        FakeProcessRunner()..composeServices(['sonarr']),
        sources: SourceAllowList.parse(_hub),
      ),
      on,
      0,
    );

    test(
      '`updater healthcheck` (127.0.0.1) passes with the allow-list set',
      () async {
        final server = await serve(InternetAddress.loopbackIPv4);
        addTearDown(() => server.close(force: true));
        final tokenFile = File('${dir.path}/updater.env')
          ..writeAsStringSync("UPDATER_TOKEN='$_token'\n");
        final code = await runHealthcheck({
          'UPDATER_TOKEN_FILE': tokenFile.path,
          'UPDATER_PORT': '${server.port}',
          'UPDATER_ALLOWED_SOURCES': _hub,
        });
        expect(code, 0);
      },
    );

    test('a non-loopback peer that is not listed gets 403', () async {
      InternetAddress? own;
      for (final nic in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      )) {
        for (final a in nic.addresses) {
          if (!a.isLoopback && !a.isLinkLocal) own ??= a;
        }
      }
      if (own == null) {
        markTestSkipped('no non-loopback IPv4 address on this machine');
        return;
      }
      final server = await serve(own);
      addTearDown(() => server.close(force: true));
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.get(own.address, server.port, '/healthz');
      request.headers.set('authorization', 'Bearer $_token');
      final response = await request.close();
      expect(response.statusCode, 403);
      await response.drain<void>();
    });
  });
}
