import 'package:test/test.dart';
import 'package:yams_hub_updater/yams_hub_updater.dart';

const _token = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ'; // 46 bytes

void main() {
  group('parseTokenFile', () {
    test('reads UPDATER_TOKEN and ignores comments and other keys', () {
      final token = parseTokenFile(
        "# written by make_hub_env.sh\n\nOTHER='x'\r\nUPDATER_TOKEN='$_token'\n",
      );
      expect(token, _token);
    });

    test('refuses a token shorter than 32 bytes', () {
      expect(
        () => parseTokenFile("UPDATER_TOKEN='${'a' * 31}'"),
        throwsA(
          isA<UpdaterConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('31 bytes'), isNot(contains('aaaa'))),
          ),
        ),
      );
      expect(parseTokenFile("UPDATER_TOKEN='${'a' * 32}'"), 'a' * 32);
    });

    test('counts bytes, not characters', () {
      // 16 two-byte characters = 32 bytes.
      expect(parseTokenFile("UPDATER_TOKEN='${'é' * 16}'"), 'é' * 16);
    });

    test('missing or empty token is an error', () {
      expect(
        () => parseTokenFile('# nothing\n'),
        throwsA(isA<UpdaterConfigException>()),
      );
      expect(
        () => parseTokenFile("UPDATER_TOKEN=''"),
        throwsA(isA<UpdaterConfigException>()),
      );
    });

    test('a malformed line is reported by number, never by content', () {
      expect(
        () => parseTokenFile('UPDATER_TOKEN=$_token\n'),
        throwsA(
          isA<UpdaterConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('line 1'), isNot(contains(_token))),
          ),
        ),
      );
    });
  });

  group('parseDenyList', () {
    test('default denies the hub, the proxy and the updater', () {
      expect(parseDenyList(null), {
        'yams-hub',
        'yams-hub-updater',
        'socket-proxy-hub',
      });
    });

    test('the updater itself is always denied', () {
      expect(parseDenyList(''), {'yams-hub-updater'});
      expect(parseDenyList('jellyfin, portainer'), {
        'yams-hub-updater',
        'jellyfin',
        'portainer',
      });
    });

    test('invalid names are a config error', () {
      expect(
        () => parseDenyList('Sonarr'),
        throwsA(isA<UpdaterConfigException>()),
      );
      expect(
        () => parseDenyList('../x'),
        throwsA(isA<UpdaterConfigException>()),
      );
    });
  });

  group('UpdaterConfig.fromEnvironment', () {
    String Function(String) files(Map<String, String> m) =>
        (p) => m[p] ?? (throw StateError('no file $p'));

    test('defaults', () {
      final c = UpdaterConfig.fromEnvironment(
        const {},
        readFile: files({
          '/run/secrets/updater.env': "UPDATER_TOKEN='$_token'\n",
        }),
      );
      expect(c.token, _token);
      expect(c.port, 8080);
      expect(c.projectName, 'yams');
      expect(c.projectDir, '/opt/yams');
      expect(c.composeFiles, [
        '/opt/yams/docker-compose.yaml',
        '/opt/yams/docker-compose.custom.yaml',
      ]);
      expect(c.deny, containsAll(defaultDenyList));
      expect(c.stepTimeout, const Duration(minutes: 15));
      expect(c.allowListRefresh, const Duration(minutes: 10));
      expect(c.toString(), isNot(contains(_token)));
    });

    test('never takes the token from the environment', () {
      expect(
        () => UpdaterConfig.fromEnvironment(const {
          'UPDATER_TOKEN': _token,
        }, readFile: files(const {})),
        throwsA(
          isA<UpdaterConfigException>().having(
            (e) => e.message,
            'message',
            contains('not readable'),
          ),
        ),
      );
    });

    test('honours UPDATER_TOKEN_FILE, UPDATER_PORT and UPDATER_DENY', () {
      final c = UpdaterConfig.fromEnvironment(const {
        'UPDATER_TOKEN_FILE': '/tmp/t.env',
        'UPDATER_PORT': '9090',
        'UPDATER_DENY': 'yams-hub,jellyfin',
      }, readFile: files({'/tmp/t.env': "UPDATER_TOKEN='$_token'"}));
      expect(c.port, 9090);
      expect(c.tokenFile, '/tmp/t.env');
      expect(c.deny, {'yams-hub', 'jellyfin', 'yams-hub-updater'});
    });

    test('UPDATER_COMPOSE_FILES replaces the default compose files', () {
      final c = UpdaterConfig.fromEnvironment(const {
        'UPDATER_PROJECT_DIR': '/srv/yams',
        'UPDATER_COMPOSE_FILES': ' /srv/yams/docker-compose.yaml , ',
      }, readFile: (_) => "UPDATER_TOKEN='$_token'");
      expect(c.composeFiles, ['/srv/yams/docker-compose.yaml']);
      expect(
        ComposeCommands(c).configServices(),
        containsAllInOrder([
          '--project-directory',
          '/srv/yams',
          '-f',
          '/srv/yams/docker-compose.yaml',
          'config',
        ]),
      );
      expect(
        ComposeCommands(c).configServices(),
        isNot(contains('/srv/yams/docker-compose.custom.yaml')),
      );
      final blank = UpdaterConfig.fromEnvironment(const {
        'UPDATER_COMPOSE_FILES': ' ',
      }, readFile: (_) => "UPDATER_TOKEN='$_token'");
      expect(blank.composeFiles, hasLength(2), reason: 'blank: the default');
      expect(
        () => UpdaterConfig.fromEnvironment(const {
          'UPDATER_COMPOSE_FILES': 'docker-compose.yaml',
        }, readFile: (_) => "UPDATER_TOKEN='$_token'"),
        throwsA(isA<UpdaterConfigException>()),
      );
    });

    test('invalid port is an error', () {
      expect(
        () => UpdaterConfig.fromEnvironment(const {
          'UPDATER_PORT': '0',
        }, readFile: (_) => "UPDATER_TOKEN='$_token'"),
        throwsA(isA<UpdaterConfigException>()),
      );
    });
  });

  test('isValidServiceName', () {
    for (final ok in ['sonarr', 'jellystat-db', 'a', 'x_1.2']) {
      expect(isValidServiceName(ok), isTrue, reason: ok);
    }
    for (final bad in [
      '',
      '-x',
      '.',
      '..',
      'Sonarr',
      'a/b',
      'a b',
      '--force',
      'x' * 65,
    ]) {
      expect(isValidServiceName(bad), isFalse, reason: bad);
    }
  });
}
