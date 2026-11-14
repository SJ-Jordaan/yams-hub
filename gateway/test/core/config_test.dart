import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/config/secrets_file.dart';
import 'package:yams_hub_gateway/src/core/auth/password_hasher.dart';
import 'package:yams_hub_gateway/src/core/notify/discord_webhook.dart';
import 'package:yams_hub_gateway/yams_hub_gateway.dart';
import 'package:yams_models/yams_models.dart';

void main() {
  group('secrets file', () {
    test("parses KEY='value' lines, comments and blank lines", () {
      final m = parseSecretsFile("""
# gateway secrets
SONARR_API_KEY='abc123'

YAMS_HUB_ADMIN_PASSWORD_HASH='pbkdf2-sha256\$600000\$salt\$hash'
EMPTY=''
""");
      expect(m['SONARR_API_KEY'], 'abc123');
      expect(
        m['YAMS_HUB_ADMIN_PASSWORD_HASH'],
        r'pbkdf2-sha256$600000$salt$hash',
      );
      expect(m['EMPTY'], '');
    });

    test(
      'a bad line is an error naming the line number, never its content',
      () {
        try {
          parseSecretsFile("A='1'\nSONARR_API_KEY=supersecretvalue\n");
          fail('expected an exception');
        } on SecretsFileException catch (e) {
          expect(e.lineNumber, 2);
          expect(e.message, isNot(contains('supersecretvalue')));
          expect(e.toString(), isNot(contains('supersecretvalue')));
        }
        expect(
          () => parseSecretsFile("A='it's'\n"),
          throwsA(isA<SecretsFileException>()),
        );
      },
    );

    test('the file wins over the environment and sources are tracked', () {
      final c = ConfigLoader.load({
        'SONARR_API_KEY': 'from-env',
        'RADARR_API_KEY': 'env-only',
      }, secretsFileContents: "SONARR_API_KEY='from-file'\n");
      expect(c.service(ServiceId.sonarr).secret, 'from-file');
      expect(c.sources['SONARR_API_KEY'], ConfigSource.file);
      expect(c.sources['RADARR_API_KEY'], ConfigSource.env);
      expect(
        c.warnings.single,
        contains('RADARR_API_KEY is set in the environment'),
      );
      expect(c.secretsFileFound, isTrue);
    });

    test('a broken secrets file is a config error', () {
      expect(
        () => ConfigLoader.load({}, secretsFileContents: 'oops\n'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.errors.single,
            'error',
            contains('line 1'),
          ),
        ),
      );
    });
  });

  group('services', () {
    test('defaults and the configured rule', () {
      final c = ConfigLoader.load({
        'SONARR_API_KEY': 'k',
        'QBIT_USERNAME': 'u',
      });
      final sonarr = c.service(ServiceId.sonarr);
      expect(sonarr.url.toString(), 'http://sonarr:8989');
      expect(sonarr.configured, isTrue);
      expect(c.isConfigured(ServiceId.radarr), isFalse);
      expect(c.service(ServiceId.radarr).missingSecrets, ['RADARR_API_KEY']);
      expect(
        c.isConfigured(ServiceId.qbittorrent),
        isFalse,
        reason: 'password missing',
      );
      expect(
        c.isConfigured(ServiceId.gluetun),
        isTrue,
        reason: 'no secret needed',
      );
      expect(c.isConfigured(ServiceId.shelfmark), isTrue);
      expect(
        c.service(ServiceId.shelfmark).url.toString(),
        'http://shelfmark:8084',
      );
      expect(c.isConfigured(ServiceId.host), isTrue);
      expect(c.hostSys, '/sys');
      expect(c.hostNetDev, '/host/proc/1/net/dev');
      expect(c.jellyfinAdminUserId, isNull, reason: 'auto-detected');
      expect(c.hostVolumeMount, '/volume1');
      expect(c.hostDiskDevice, 'dm-0');
    });

    test('HOST_VOLUME_MOUNT and HOST_DISK_DEVICE describe a generic host', () {
      final c = ConfigLoader.load({
        'HOST_VOLUME_MOUNT': '/srv/media',
        'HOST_DISK_DEVICE': '',
      });
      expect(c.hostVolumeMount, '/srv/media');
      expect(c.hostDiskDevice, '', reason: 'empty: no disk I/O');
      expect(
        ConfigLoader.load({'HOST_DISK_DEVICE': 'sda1'}).hostDiskDevice,
        'sda1',
      );
      expect(
        () => ConfigLoader.load({'HOST_VOLUME_MOUNT': ' '}),
        throwsA(isA<ConfigException>()),
      );
    });

    test('an empty URL disables a service; bad URLs are errors', () {
      final c = ConfigLoader.load({'SHELFMARK_URL': ''});
      expect(c.isConfigured(ServiceId.shelfmark), isFalse);
      expect(
        () => ConfigLoader.load({'SONARR_URL': 'ftp://x'}),
        throwsA(isA<ConfigException>()),
      );
    });

    test('a short updater token is treated as not configured', () {
      final c = ConfigLoader.load({'UPDATER_TOKEN': 'short'});
      expect(c.isConfigured(ServiceId.updater), isFalse);
      expect(c.warnings, contains(contains('UPDATER_TOKEN')));
    });

    test('JELLYFIN_ADMIN_USER_ID is normalised', () {
      final c = ConfigLoader.load(
        {},
        secretsFileContents:
            "JELLYFIN_ADMIN_USER_ID='4C0628AA-CEF2-4BDF-ACD4-0F946EA33EE7'\n",
      );
      expect(c.jellyfinAdminUserId, '4c0628aacef24bdfacd40f946ea33ee7');
    });
  });

  group('CORS origins', () {
    test('exact http(s) origins are accepted and normalised', () {
      final c = ConfigLoader.load({
        'YAMS_HUB_CORS_ORIGINS': 'http://localhost:5173, HTTPS://Dev.Example',
      });
      expect(c.corsOrigins, ['http://localhost:5173', 'https://dev.example']);
    });

    for (final bad in [
      '*',
      'null',
      'http://x/path',
      'file:///etc',
      'localhost:5173',
      'http://*.example',
    ]) {
      test('"$bad" is rejected', () {
        expect(
          () => ConfigLoader.load({'YAMS_HUB_CORS_ORIGINS': bad}),
          throwsA(isA<ConfigException>()),
        );
      });
    }
  });

  group('policy file', () {
    test('defaults match ARCHITECTURE §5.2.1', () {
      final c = ConfigLoader.load({});
      expect(c.policy.allowGlobalSearch, isFalse);
      expect(c.policy.allowArrDeleteFiles, isTrue);
      expect(c.policy.containers.locked, [
        'yams-hub',
        'socket-proxy-hub',
        'yams-hub-updater',
      ]);
      expect(c.auth.adminRefreshTokenTtlDays, 30);
      expect(c.auth.pbkdf2Iterations, 600000);
      expect(c.imageCache.maxBytes, 1073741824);
      expect(c.imageCache.newRemoteEntriesPerUserPerMinute, 300);
      expect(c.externalApps[ExternalApp.shelfmark]!.port, 8084);
      expect(c.remoteImageHosts, contains('www.gravatar.com'));
      expect(c.alerts.indexersFailingPercent, 80);
      expect(c.alerts.indexersFailingForMinutes, 15);
      expect(c.discordAlertWebhookUrl, isNull);
    });

    test('indexer alert keys are read and validated', () {
      final c = ConfigLoader.load(
        {},
        policyFileContents: 'alerts: {indexersFailingPercent: 60, indexersFailingForMinutes: 30}\n',
      );
      expect(c.alerts.indexersFailingPercent, 60);
      expect(c.alerts.indexersFailingForMinutes, 30);
      expect(
        () => ConfigLoader.load(
          {},
          policyFileContents: 'alerts: {indexersFailingPercent: 0, indexersFailingForMinutes: 1.5}\n',
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.errors,
            'errors',
            containsAll([
              contains('alerts.indexersFailingPercent must be between'),
              contains('alerts.indexersFailingForMinutes must be an integer'),
            ]),
          ),
        ),
      );
    });

    test('values are read and validated', () {
      final c = ConfigLoader.load(
        {},
        policyFileContents: '''
publicUrls: ["http://192.168.10.183:8090"]
externalApps:
  jellyfin: {baseUrl: "http://jf.example"}
policy:
  allowGlobalSearch: true
  containers:
    locked: [yams-hub]
auth:
  adminRefreshTokenTtlDays: 7
imageCache:
  maxBytes: 2097152
  newRemoteEntriesPerUserPerMinute: 10
''',
      );
      expect(c.publicUrls.single.host, '192.168.10.183');
      expect(
        c.externalApps[ExternalApp.jellyfin]!.baseUrl,
        'http://jf.example',
      );
      expect(c.externalApps[ExternalApp.jellyfin]!.port, 8096);
      expect(c.policy.allowGlobalSearch, isTrue);
      expect(c.policy.containers.locked, ['yams-hub']);
      expect(c.auth.adminRefreshTokenTtlDays, 7);
      expect(c.imageCache.maxBytes, 2097152);
      expect(c.imageCache.newRemoteEntriesPerUserPerMinute, 10);
    });

    test('bad keys and values are errors', () {
      expect(
        () => ConfigLoader.load(
          {},
          policyFileContents: 'auth: {pbkdf2Iterations: 10}\nnope: 1\n',
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.errors,
            'errors',
            hasLength(2),
          ),
        ),
      );
    });
  });

  group('DISCORD_ALERT_WEBHOOK_URL', () {
    const token = 'tOkEn_value-123';
    const good = 'https://discord.com/api/webhooks/123456789012345678/$token';

    test('is a secret read from the secrets file', () {
      expect(secretVariables, contains('DISCORD_ALERT_WEBHOOK_URL'));
      final c = ConfigLoader.load(
        {},
        secretsFileContents: "DISCORD_ALERT_WEBHOOK_URL='$good'\n",
      );
      expect(c.discordAlertWebhookUrl, Uri.parse(good));
      expect(c.warnings, isEmpty);
    });

    test('only https Discord webhook URLs are accepted', () {
      for (final ok in [
        good,
        'https://discordapp.com/api/webhooks/1/$token',
        'https://discord.com/api/v10/webhooks/1/$token/',
        'https://DISCORD.com:443/api/webhooks/1/$token',
      ]) {
        expect(parseDiscordWebhookUrl(ok), isNotNull, reason: ok);
      }
      for (final bad in [
        'http://discord.com/api/webhooks/1/$token',
        'https://evil.example/api/webhooks/1/$token',
        'https://discord.com.evil.example/api/webhooks/1/$token',
        'https://discord.com/api/webhooks/1',
        'https://discord.com/api/webhooks/abc/$token',
        'https://discord.com/api/webhooks/1/$token?wait=true',
        'https://user:pw@discord.com/api/webhooks/1/$token',
        'https://discord.com:8443/api/webhooks/1/$token',
        'https://discord.com/api/webhooks/1/$token/github',
        'not a url',
      ]) {
        expect(parseDiscordWebhookUrl(bad), isNull, reason: bad);
      }
    });

    test(
      'an invalid value turns the alerts off with a warning, never the value',
      () {
        final c = ConfigLoader.load(
          {},
          secretsFileContents:
              "DISCORD_ALERT_WEBHOOK_URL='https://example.com/hook/$token'\n",
        );
        expect(c.discordAlertWebhookUrl, isNull);
        expect(c.warnings.single, contains('Discord alerts are off'));
        expect(c.warnings.single, isNot(contains(token)));
      },
    );

    test('in the environment it warns like the other secrets', () {
      final c = ConfigLoader.load({'DISCORD_ALERT_WEBHOOK_URL': good});
      expect(c.discordAlertWebhookUrl, isNotNull);
      expect(
        c.warnings.single,
        contains('DISCORD_ALERT_WEBHOOK_URL is set in the environment'),
      );
      expect(c.warnings.single, isNot(contains(token)));
    });

    test('check-config reports it without printing it', () async {
      final dir = await Directory.systemTemp.createTemp('yams-hub-cfg-');
      addTearDown(() => dir.delete(recursive: true));
      Future<String> run(String? secrets) async {
        final out = StringBuffer();
        await runCheckConfig(
          {'YAMS_HUB_DATA_DIR': p.join(dir.path, 'data')},
          out,
          readFiles: false,
          secretsFileContents: secrets,
          hasher: PasswordHasher(iterations: minHashIterations),
        );
        return out.toString();
      }

      final on = await run("DISCORD_ALERT_WEBHOOK_URL='$good'\n");
      expect(on, contains('Discord alerts: on (file)'));
      expect(on, isNot(contains(token)));
      final off = await run(null);
      expect(
        off,
        contains('Discord alerts: off (DISCORD_ALERT_WEBHOOK_URL not set)'),
      );
      final bad = await run(
        "DISCORD_ALERT_WEBHOOK_URL='https://x.example/$token'\n",
      );
      expect(
        bad,
        contains(
          'Discord alerts: off (DISCORD_ALERT_WEBHOOK_URL invalid or empty)',
        ),
      );
      expect(bad, isNot(contains(token)));
    });
  });

  group('check-config', () {
    late Directory dir;
    setUp(
      () async => dir = await Directory.systemTemp.createTemp('yams-hub-cfg-'),
    );
    tearDown(() => dir.delete(recursive: true));

    test('reports services configured from the secrets file without printing values', () async {
      final hash = PasswordHasher.hashSync(
        'bootstrap-password',
        minHashIterations,
      );
      final secrets = File(p.join(dir.path, 'yams-hub.env'))
        ..writeAsStringSync(
          "SONARR_API_KEY='sonarr-secret-value'\n"
          "SEERR_API_KEY='seerr-secret-value'\n"
          "YAMS_HUB_ADMIN_PASSWORD_HASH='$hash'\n"
          "JELLYFIN_ADMIN_USER_ID='4c0628aacef24bdfacd40f946ea33ee7'\n",
        );
      final out = StringBuffer();
      final code = await runCheckConfig(
        {
          'YAMS_HUB_SECRETS_FILE': secrets.path,
          'YAMS_HUB_DATA_DIR': p.join(dir.path, 'data'),
        },
        out,
        hasher: PasswordHasher(iterations: minHashIterations),
      );
      final text = out.toString();
      expect(code, 0, reason: text);
      expect(text, contains('found'));
      expect(
        text,
        matches(RegExp(r'sonarr\s+configured\s+\[url: default, key: file\]')),
      );
      expect(text, matches(RegExp(r'seerr\s+configured')));
      expect(
        text,
        matches(RegExp(r'radarr\s+not configured \(missing RADARR_API_KEY\)')),
      );
      expect(text, contains('JELLYFIN_ADMIN_USER_ID: set (file)'));
      expect(text, contains('hash set (file)'));
      expect(text, contains('PBKDF2: one verification at 100000 iterations'));
      for (final secret in [
        'sonarr-secret-value',
        'seerr-secret-value',
        hash,
        '4c0628aacef24bdfacd40f946ea33ee7',
      ]) {
        expect(text, isNot(contains(secret)));
      }
    });

    test(
      'auto-detected admin id and a missing secrets file are reported',
      () async {
        final out = StringBuffer();
        final code = await runCheckConfig(
          {
            'YAMS_HUB_SECRETS_FILE': p.join(dir.path, 'missing.env'),
            'YAMS_HUB_DATA_DIR': dir.path,
          },
          out,
          hasher: PasswordHasher(iterations: minHashIterations),
        );
        expect(code, 0);
        expect(out.toString(), contains('not found; environment only'));
        expect(out.toString(), contains('auto-detected'));
      },
    );

    test('invalid CORS and policy fail with exit code 1', () async {
      File(p.join(dir.path, 'yams-hub.yaml'))
          .writeAsStringSync('policy: {allowGlobalSearch: maybe}\n');
      final out = StringBuffer();
      final code = await runCheckConfig({
        'YAMS_HUB_DATA_DIR': dir.path,
        'YAMS_HUB_SECRETS_FILE': p.join(dir.path, 'none.env'),
        'YAMS_HUB_CORS_ORIGINS': '*',
      }, out);
      expect(code, 1);
      expect(out.toString(), contains('INVALID'));
      expect(out.toString(), contains('YAMS_HUB_CORS_ORIGINS'));
      expect(out.toString(), contains('policy.allowGlobalSearch'));
    });
  });
}
