import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/core/audit/sanitize.dart';
import 'package:yams_hub_gateway/yams_hub_gateway.dart';

void main() {
  group('redactSecrets', () {
    test('a Prowlarr download URL loses its apikey', () {
      const url =
          'http://prowlarr:9696/12/download?apikey=0123456789abcdef0123456789abcdef&link=aHR0cHM6&file=Show';
      final r = redactSecrets(url);
      expect(r, isNot(contains('0123456789abcdef')));
      expect(r, contains('apikey=***'));
      expect(r, contains('link=aHR0cHM6'));
    });

    test('private tracker announce URLs lose their passkeys', () {
      expect(
        redactSecrets(
          'udp://tracker.example.org:1337/announce/abcdefABCDEF1234567890',
        ),
        'udp://tracker.example.org:1337/announce/***',
      );
      expect(
        redactSecrets(
          'https://t.example.org/0123456789abcdefABCDEF0123/announce',
        ),
        'https://t.example.org/***/announce',
      );
      expect(
        redactSecrets('https://t.example.org/announce?passkey=deadbeefcafe'),
        contains('passkey=***'),
      );
    });

    test('an Authorization: MediaBrowser Token="..." line is scrubbed', () {
      const line =
          'Authorization: MediaBrowser Client="YAMS Hub", Device="yams-hub", Token="0123456789abcdef"';
      final r = redactSecrets(line);
      expect(r, startsWith('Authorization: ***'));
      expect(
        redactSecrets('authorization: MediaBrowser Token="0123456789abcdef"'),
        'authorization: ***',
      );
      expect(redactSecrets('X-Api-Key: abc123'), 'X-Api-Key: ***');
      expect(redactSecrets('Cookie: QBT_SID_8081=xyz'), 'Cookie: ***');
    });

    test('hub tokens, passwords and sids', () {
      expect(
        redactSecrets('token yha_abcDEF-123_x leaked'),
        'token *** leaked',
      );
      expect(
        redactSecrets('refresh yhr_s_0123456789ab.abc-DEF_1 x'),
        'refresh *** x',
      );
      expect(
        redactSecrets('password=hunter2&user=bob'),
        'password=***&user=bob',
      );
      expect(redactSecrets('SID=abc; token=x'), 'SID=*** token=***');
      expect(redactSecrets('nothing to see'), 'nothing to see');
    });

    test('Discord webhook ids and tokens', () {
      const token = 'AbC-def_123.xyz';
      expect(
        redactSecrets(
          'POST https://discord.com/api/webhooks/1234/$token failed',
        ),
        'POST https://discord.com/api/webhooks/*** failed',
      );
      expect(
        redactSecrets('uri=https://DiscordApp.com/api/v10/webhooks/99/$token'),
        'uri=https://DiscordApp.com/api/v10/webhooks/***',
      );
      expect(
        redactSecrets('"https://discord.com/api/webhooks/1/$token"'),
        isNot(contains(token)),
      );
    });
  });

  group('audit params sanitisation', () {
    test('secret keys are masked at any depth', () {
      final s = sanitizeAuditParams({
        'username': 'bob',
        'password': 'hunter2',
        'nested': {
          'apiKey': 'k',
          'Authorization': 'Bearer x',
          'list': [
            {'refreshToken': 't'},
          ],
        },
        'torrentFilesBase64': ['ZDg6...'],
        'serverProofKey': 'p',
        'cookieJar': 'c',
      })!;
      expect(s['username'], 'bob');
      expect(s['password'], '***');
      final nested = s['nested']! as Map;
      expect(nested['apiKey'], '***');
      expect(nested['Authorization'], '***');
      expect(((nested['list']! as List).single as Map)['refreshToken'], '***');
      expect(s['torrentFilesBase64'], '***');
      expect(s['serverProofKey'], '***');
      expect(s['cookieJar'], '***');
    });

    test('URLs keep scheme and host; magnets keep the info hash', () {
      final s = sanitizeAuditParams({
        'url': 'https://tracker.example.org/download.php?id=1&passkey=abc',
        'urls': [
          'magnet:?xt=urn:btih:E66AAC4C7D8A4F813A4E5B3A63C1BB52BEEE342E&dn=Show&tr=udp://x/announce/key',
          'http://indexer.example/get/123',
        ],
        'title': 'Show S01',
      })!;
      expect(s['url'], 'https://tracker.example.org');
      expect(s['urls'], [
        'magnet:e66aac4c7d8a4f813a4e5b3a63c1bb52beee342e',
        'http://indexer.example',
      ]);
      expect(s['title'], 'Show S01');
    });

    test('long strings are truncated and big params capped at 4 KB', () {
      final long = sanitizeAuditParams({'note': 'x' * 500})!;
      expect((long['note']! as String).length, lessThan(210));
      final big = sanitizeAuditParams({
        for (var i = 0; i < 100; i++) 'k$i': 'y' * 150,
      });
      expect(big, {'truncated': true});
    });

    test('login_failed targets only keep plausible user names', () {
      expect(loginFailedTarget('admin'), 'admin');
      expect(loginFailedTarget('My Password 123!'), '<invalid>');
      expect(loginFailedTarget('x'), '<invalid>');
    });
  });
}
