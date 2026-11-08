import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/core/http/trusted_proxies.dart';

import '../support/test_hub.dart';

Request _req(String peer, {List<String>? xff}) => Request(
  'GET',
  Uri.parse('http://hub.local/api/v1/ping'),
  headers: {'x-forwarded-for': ?xff},
  context: {'shelf.io.connection_info': FakeConnectionInfo(peer)},
);

void main() {
  group('IpRange / TrustedProxies', () {
    test('parses addresses and CIDR ranges', () {
      final errors = <String>[];
      final p = TrustedProxies.parse(
        '172.18.0.0/16, 10.0.0.5 ,fd00::/8',
        errors,
      );
      expect(errors, isEmpty);
      expect(p.trusts('172.18.4.2'), isTrue);
      expect(p.trusts('172.19.0.1'), isFalse);
      expect(p.trusts('10.0.0.5'), isTrue);
      expect(p.trusts('10.0.0.6'), isFalse);
      expect(p.trusts('fd12::1'), isTrue);
      expect(p.trusts('::ffff:172.18.0.9'), isTrue);
      expect(p.trusts('nonsense'), isFalse);
      TrustedProxies.parse('10.0.0.0/33,bogus', errors);
      expect(errors, hasLength(2));
    });

    test('loopback is the default', () {
      final p = TrustedProxies.loopback();
      expect(p.trusts('127.0.0.1'), isTrue);
      expect(p.trusts('::1'), isTrue);
      expect(p.trusts('192.168.10.2'), isFalse);
    });
  });

  group('resolveClientIp', () {
    final proxies = TrustedProxies.parse('172.18.0.2', []);

    test('ignores X-Forwarded-For without trustProxy', () {
      expect(
        resolveClientIp(
          _req('172.18.0.2', xff: ['1.2.3.4']),
          trustProxy: false,
          proxies: proxies,
        ),
        '172.18.0.2',
      );
    });

    test('ignores X-Forwarded-For from a peer that is not a proxy', () {
      // A LAN client talking to the gateway directly sends its own header.
      expect(
        resolveClientIp(
          _req('192.168.10.23', xff: ['192.168.10.99']),
          trustProxy: true,
          proxies: proxies,
        ),
        '192.168.10.23',
      );
    });

    test('takes the rightmost untrusted hop, not the client-sent left', () {
      // The client sent "192.168.10.99"; the proxy appended the real peer.
      expect(
        resolveClientIp(
          _req('172.18.0.2', xff: ['192.168.10.99, 100.64.0.7']),
          trustProxy: true,
          proxies: proxies,
        ),
        '100.64.0.7',
      );
      // Several headers count as one list.
      expect(
        resolveClientIp(
          _req('172.18.0.2', xff: ['6.6.6.6', '100.64.0.8']),
          trustProxy: true,
          proxies: proxies,
        ),
        '100.64.0.8',
      );
    });

    test('skips chained trusted proxies; a malformed entry stops the walk', () {
      final chain = TrustedProxies.parse('172.18.0.0/16', []);
      expect(
        resolveClientIp(
          _req('172.18.0.2', xff: ['8.8.8.8, 100.64.0.7, 172.18.0.9']),
          trustProxy: true,
          proxies: chain,
        ),
        '100.64.0.7',
      );
      expect(
        resolveClientIp(
          _req('172.18.0.2', xff: ['100.64.0.7, garbage']),
          trustProxy: true,
          proxies: chain,
        ),
        '172.18.0.2',
      );
      expect(
        resolveClientIp(_req('172.18.0.2'), trustProxy: true, proxies: chain),
        '172.18.0.2',
      );
    });
  });

  group('pipeline', () {
    test(
      'X-Forwarded-Proto from an untrusted peer does not add Secure',
      () async {
        final hub = TestHub(env: {'YAMS_HUB_TRUST_PROXY': 'true'});
        addTearDown(hub.close);
        final r = await hub.post(
          '/yh/api/v1/auth/login',
          body: {
            'username': 'member',
            'password': testMemberPassword,
            'deviceName': 'Browser',
            'platform': 'web',
            'transport': 'cookie',
          },
          as: TestAs.anonymous,
          headers: {
            'x-yams-client': 'web',
            'x-forwarded-proto': 'https',
            'x-forwarded-for': '10.9.9.9',
          },
        );
        expect(r.status, 200, reason: r.body);
        expect(r.setCookies, everyElement(isNot(contains('Secure'))));
        final me = LoginResponse.fromJson(r.map);
        expect(me.session.lastIp, '192.168.10.50');
      },
    );

    test('config: the proxy list is parsed and validated', () {
      final ok = ConfigLoader.load({
        'YAMS_HUB_TRUST_PROXY': 'true',
        'YAMS_HUB_TRUSTED_PROXIES': '172.18.0.0/16',
      });
      expect(ok.trustedProxies!.trusts('172.18.1.1'), isTrue);
      final unset = ConfigLoader.load({'YAMS_HUB_TRUST_PROXY': 'true'});
      expect(unset.trustedProxies, isNull);
      expect(unset.warnings.join(), contains('YAMS_HUB_TRUSTED_PROXIES'));
      expect(
        () => ConfigLoader.load({'YAMS_HUB_TRUSTED_PROXIES': 'nope'}),
        throwsA(isA<ConfigException>()),
      );
    });
  });
}
