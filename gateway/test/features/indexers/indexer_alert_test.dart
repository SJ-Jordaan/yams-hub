import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/core/log/log.dart';
import 'package:yams_hub_gateway/src/core/notify/discord_webhook.dart';
import 'package:yams_hub_gateway/src/features/indexers/indexer_alert.dart';
import 'package:yams_hub_gateway/src/features/indexers/indexers_module.dart';
import 'package:yams_hub_gateway/src/features/indexers/prowlarr_repository.dart';

import '../../support/test_hub.dart';
import 'indexers_test_support.dart';

const _token = 'SeCrEt-webhook_token.0123456789';
final _webhookUrl = Uri.parse(
  'https://discord.com/api/webhooks/123456789012345678/$_token',
);

IndexerFailureSample _sample(int failing, int enabled) => IndexerFailureSample(
  enabled: enabled,
  failing: [for (var i = 1; i <= failing; i++) 'Indexer $i'],
);

/// A fake Discord: records posts and answers from [replies] (then 204).
final class _FakeDiscord {
  final posts = <Map<String, Object?>>[];
  final urls = <Uri>[];
  final replies = <http.Response Function()>[];
  final sleeps = <Duration>[];

  late final client = MockClient((r) async {
    urls.add(r.url);
    posts.add(jsonDecode(r.body) as Map<String, Object?>);
    if (replies.isNotEmpty) return replies.removeAt(0)();
    return http.Response('', 204);
  });

  DiscordWebhook webhook() => DiscordWebhook(
    url: _webhookUrl,
    client: client,
    sleep: (d) async => sleeps.add(d),
  );

  List<String> get titles => [
    for (final post in posts)
      ((post['embeds']! as List).single as Map)['title'] as String,
  ];
}

/// Every log line (formatted like production, and raw).
final class _Logs {
  _Logs() {
    Logger.root.level = Level.ALL;
    _sub = Logger.root.onRecord.listen((r) {
      lines.add(formatLogRecord(r));
      raw.add('${r.message} ${r.error ?? ''}');
    });
  }

  final lines = <String>[];
  final raw = <String>[];
  late final StreamSubscription<LogRecord> _sub;

  Future<void> close() => _sub.cancel();
}

void main() {
  late Directory dir;
  late FakeClock clock;
  late _FakeDiscord discord;
  late DateTime t0;
  late _Logs logs;
  IndexerFailureSample? next;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('yams-hub-alert-');
    clock = FakeClock();
    t0 = clock.now();
    discord = _FakeDiscord();
    logs = _Logs();
    next = null;
  });
  tearDown(() async {
    await logs.close();
    await dir.delete(recursive: true);
  });

  JsonFileStore store() => JsonFileStore(
    p.join(dir.path, alertStateStoreName),
    debounce: Duration.zero,
  );

  IndexerAlertMonitor monitor({
    AlertThresholds thresholds = const AlertThresholds(),
    Uri? page,
  }) => IndexerAlertMonitor.create(
    thresholds: thresholds,
    store: store(),
    sample: () async => next,
    webhook: discord.webhook(),
    clock: clock,
    indexersPage: page,
  );

  /// Samples [s] at t0 + [minute].
  Future<void> at(IndexerAlertMonitor m, int minute, IndexerFailureSample? s) {
    clock.set(t0.add(Duration(minutes: minute)));
    next = s;
    return m.tick();
  }

  /// Samples [s] every 3 min (like production) from [from] to [to] inclusive.
  Future<void> every(
    IndexerAlertMonitor m,
    int from,
    int to,
    IndexerFailureSample? s,
  ) async {
    for (var minute = from; minute <= to; minute += 3) {
      await at(m, minute, s);
    }
    if ((to - from) % 3 != 0) await at(m, to, s);
  }

  group('trigger', () {
    test('no alert after 14 min at the threshold, one at 15', () async {
      final m = monitor();
      for (final minute in [0, 3, 6, 9, 12, 14]) {
        await at(m, minute, _sample(8, 10));
      }
      expect(discord.posts, isEmpty);
      await at(m, 15, _sample(9, 10));
      expect(discord.titles, ['⚠️ Indexers down: 9 of 10 failing for 15 min']);
    });

    test('below the threshold never alerts', () async {
      final m = monitor();
      for (var minute = 0; minute <= 60; minute += 3) {
        await at(m, minute, _sample(7, 10));
      }
      expect(discord.posts, isEmpty);
    });

    test('no duplicates while the condition holds', () async {
      final m = monitor();
      for (var minute = 0; minute <= 180; minute += 3) {
        await at(m, minute, _sample(10, 10));
      }
      expect(discord.titles, hasLength(1));
      expect(m.rule.state.firing, isTrue);
    });

    test('flapping within 15 min sends nothing', () async {
      final m = monitor();
      for (var cycle = 0; cycle < 10; cycle++) {
        final base = cycle * 15;
        await at(m, base, _sample(9, 10));
        await at(m, base + 6, _sample(10, 10));
        await at(m, base + 12, _sample(9, 10));
        await at(m, base + 14, _sample(1, 10)); // one good sample resets
      }
      expect(discord.posts, isEmpty);
    });

    test('policy threshold and duration are honoured', () async {
      final m = monitor(
        thresholds: const AlertThresholds(
          indexersFailingPercent: 50,
          indexersFailingForMinutes: 30,
        ),
      );
      await every(m, 0, 29, _sample(5, 10));
      expect(discord.posts, isEmpty);
      await at(m, 30, _sample(5, 10));
      expect(discord.titles.single, contains('5 of 10 failing for 30 min'));
    });

    test('fewer than 2 enabled indexers are ignored', () async {
      final m = monitor();
      for (var minute = 0; minute <= 60; minute += 3) {
        await at(m, minute, _sample(1, 1));
      }
      await at(m, 63, _sample(0, 0));
      expect(discord.posts, isEmpty);
      expect(m.rule.state.breachSince, isNull);
    });
  });

  group('recovery', () {
    Future<IndexerAlertMonitor> firing() async {
      final m = monitor();
      await every(m, 0, 15, _sample(10, 10));
      expect(discord.posts, hasLength(1));
      return m;
    }

    test('one "recovered" after 5 min below the threshold', () async {
      final m = await firing();
      await at(m, 18, _sample(1, 10));
      await at(m, 21, _sample(1, 10));
      await at(m, 22, _sample(1, 10));
      expect(discord.posts, hasLength(1));
      await at(m, 23, _sample(1, 10));
      expect(discord.titles.last, '✅ Indexers recovered: 1 of 10 failing');
      for (var minute = 26; minute <= 60; minute += 3) {
        await at(m, minute, _sample(0, 10));
      }
      expect(discord.posts, hasLength(2));
      expect(m.rule.state.firing, isFalse);
    });

    test('a dip back over the threshold restarts the recovery wait', () async {
      final m = await firing();
      await at(m, 18, _sample(1, 10));
      await at(m, 21, _sample(9, 10));
      await at(m, 24, _sample(1, 10));
      await at(m, 27, _sample(1, 10));
      expect(discord.posts, hasLength(1));
      await at(m, 29, _sample(1, 10));
      expect(discord.posts, hasLength(2));
    });
  });

  group('unknown Prowlarr state', () {
    test('holds a pending breach and sends nothing', () async {
      final m = monitor();
      await at(m, 0, _sample(9, 10));
      for (var minute = 3; minute <= 60; minute += 3) {
        await at(m, minute, null);
      }
      expect(discord.posts, isEmpty);
      expect(m.rule.state.breachSince, t0);
    });

    test('never counts as recovered', () async {
      final m = monitor();
      await every(m, 0, 15, _sample(10, 10));
      for (var minute = 18; minute <= 120; minute += 3) {
        await at(m, minute, null);
      }
      expect(discord.posts, hasLength(1));
      expect(m.rule.state.firing, isTrue);
    });

    test('a stale or failed Prowlarr snapshot is unknown', () async {
      final hub = TestHub();
      addTearDown(hub.close);
      fakeProwlarrReads(hub.fakes);
      await hub.ready;
      final repo = ProwlarrRepository(hub.ctx);

      final ok = await sampleProwlarr(repo, hub.clock);
      expect(ok!.enabled, 6);
      expect(ok.failing, ['Uindex']);

      hub.fakes.on(
        ServiceId.prowlarr,
        'GET',
        '/api/v1/indexer',
        (_) => FakeResponse.text('down', status: 503),
      );
      hub.clock.advance(const Duration(minutes: 2)); // past the 60 s TTL
      expect(await sampleProwlarr(repo, hub.clock), isNull); // stale copy
      hub.clock.advance(const Duration(hours: 1)); // past maxStale
      expect(await sampleProwlarr(repo, hub.clock), isNull); // error
    });

    test('a gap in the samples restarts a pending breach', () async {
      // One breach before a Prowlarr outage and one after it are not 15
      // continuous minutes of failures.
      final m = monitor();
      await at(m, 0, _sample(9, 10));
      for (var minute = 3; minute <= 18; minute += 3) {
        await at(m, minute, null);
      }
      await at(m, 21, _sample(9, 10));
      expect(discord.posts, isEmpty);
      expect(m.rule.state.breachSince, t0.add(const Duration(minutes: 21)));
      await every(m, 24, 35, _sample(9, 10));
      expect(discord.posts, isEmpty);
      await at(m, 36, _sample(9, 10));
      expect(discord.titles, ['⚠️ Indexers down: 9 of 10 failing for 15 min']);
    });

    test('a gap in the samples restarts a pending recovery', () async {
      final m = monitor();
      await every(m, 0, 15, _sample(10, 10));
      await at(m, 18, _sample(1, 10));
      for (var minute = 21; minute <= 27; minute += 3) {
        await at(m, minute, null);
      }
      await at(m, 30, _sample(1, 10));
      expect(discord.posts, hasLength(1));
      await at(m, 33, _sample(1, 10));
      expect(discord.posts, hasLength(1));
      await at(m, 35, _sample(1, 10));
      expect(discord.titles.last, '✅ Indexers recovered: 1 of 10 failing');
    });

    test('a clock jump backwards restarts a pending breach', () async {
      final m = monitor();
      await every(m, 0, 9, _sample(9, 10));
      // NTP moves the clock back an hour: the breach must still be seen for
      // 15 min, measured from the new time.
      await every(m, -60, -48, _sample(9, 10));
      expect(discord.posts, isEmpty);
      await at(m, -45, _sample(9, 10));
      expect(discord.titles, ['⚠️ Indexers down: 9 of 10 failing for 15 min']);
    });
  });

  group('persistence', () {
    test('a restart while firing does not resend', () async {
      final first = monitor();
      await every(first, 0, 15, _sample(10, 10));
      expect(discord.posts, hasLength(1));

      final saved = jsonDecode(
        File(p.join(dir.path, alertStateStoreName)).readAsStringSync(),
      ) as Map;
      expect((saved['indexersFailing'] as Map)['firing'], isTrue);

      final second = monitor(); // a fresh store reads the file
      for (var minute = 18; minute <= 60; minute += 3) {
        await at(second, minute, _sample(10, 10));
      }
      expect(discord.posts, hasLength(1));
      await every(second, 63, 68, _sample(0, 10));
      expect(discord.titles.last, startsWith('✅ Indexers recovered'));
    });

    test('a pending breach survives a restart', () async {
      final first = monitor();
      await every(first, 0, 12, _sample(9, 10));
      final second = monitor();
      await at(second, 14, _sample(9, 10));
      expect(discord.posts, isEmpty);
      await at(second, 15, _sample(9, 10));
      expect(discord.titles, ['⚠️ Indexers down: 9 of 10 failing for 15 min']);
    });

    test('a restart days later does not count the downtime', () async {
      final first = monitor();
      await every(first, 0, 3, _sample(9, 10));
      final second = monitor();
      const twoDays = 2 * 24 * 60;
      await at(second, twoDays, _sample(9, 10));
      expect(discord.posts, isEmpty);
      await every(second, twoDays + 3, twoDays + 14, _sample(9, 10));
      expect(discord.posts, isEmpty);
      await at(second, twoDays + 15, _sample(9, 10));
      expect(discord.titles, ['⚠️ Indexers down: 9 of 10 failing for 15 min']);
    });

    test(
      'the file is not rewritten every sample while nothing is pending',
      () async {
        Map<String, Object?> saved() =>
            (jsonDecode(
                  File(p.join(dir.path, alertStateStoreName))
                      .readAsStringSync(),
                ) as Map)['indexersFailing']
                as Map<String, Object?>;
        final m = monitor();
        await every(m, 0, 12, _sample(9, 10));
        // A running wait keeps lastSampleAt current on disk.
        expect(
          saved()['lastSampleAt'],
          instantToJson(t0.add(const Duration(minutes: 12))),
        );
        await at(m, 15, _sample(9, 10));
        final atFire = saved();
        await every(m, 18, 60, _sample(9, 10));
        expect(saved(), atFire);
      },
    );

    test('a corrupt or missing state file starts clean', () async {
      File(p.join(dir.path, alertStateStoreName)).writeAsStringSync('{nope');
      final m = monitor();
      expect(m.rule.state.firing, isFalse);
      await at(m, 0, _sample(1, 10));
    });
  });

  group('delivery', () {
    test('429 is retried after retry_after, then succeeds', () async {
      discord.replies.addAll([
        () => http.Response(
          '{"message": "You are being rate limited.", "retry_after": 1.5, "global": false}',
          429,
        ),
        () => http.Response('', 502),
      ]);
      final ok = await discord.webhook().send({'content': 'x'});
      expect(ok, isTrue);
      expect(discord.posts, hasLength(3));
      expect(discord.sleeps, [
        const Duration(milliseconds: 1500),
        const Duration(seconds: 4),
      ]);
    });

    test('429 falls back to the Retry-After header', () async {
      discord.replies.add(
        () => http.Response('', 429, headers: {'retry-after': '3'}),
      );
      expect(await discord.webhook().send({'content': 'x'}), isTrue);
      expect(discord.sleeps, [const Duration(seconds: 3)]);
    });

    test(
      '429 without retry_after or Retry-After backs off and retries',
      () async {
        // Cloudflare's 429 page is HTML without either.
        discord.replies.addAll([
          () => http.Response('<html>Too Many Requests</html>', 429),
          () => http.Response('', 429),
        ]);
        expect(await discord.webhook().send({'content': 'x'}), isTrue);
        expect(discord.posts, hasLength(3));
        expect(discord.sleeps, [
          const Duration(seconds: 2),
          const Duration(seconds: 4),
        ]);
      },
    );

    test('429 with a retry_after over the cap gives up at once', () async {
      discord.replies.add(() => http.Response('{"retry_after": 3600}', 429));
      expect(await discord.webhook().send({'content': 'x'}), isFalse);
      expect(discord.posts, hasLength(1));
      expect(discord.sleeps, isEmpty);
    });

    test('gives up after a few failed attempts', () async {
      discord.replies.addAll(List.filled(10, () => http.Response('', 500)));
      expect(await discord.webhook().send({'content': 'x'}), isFalse);
      expect(discord.posts, hasLength(4));
      expect(discord.sleeps, [
        const Duration(seconds: 2),
        const Duration(seconds: 4),
        const Duration(seconds: 8),
      ]);
    });

    test('a deleted webhook (404) is not retried', () async {
      discord.replies.add(() => http.Response('{"code": 10015}', 404));
      expect(await discord.webhook().send({'content': 'x'}), isFalse);
      expect(discord.posts, hasLength(1));
    });

    test('network errors and timeouts are retried', () async {
      var calls = 0;
      final webhook = DiscordWebhook(
        url: _webhookUrl,
        client: MockClient((r) async {
          calls++;
          if (calls == 1) throw http.ClientException('boom ${r.url}', r.url);
          if (calls == 2) return Completer<http.Response>().future; // hangs
          return http.Response('', 204);
        }),
        timeout: const Duration(milliseconds: 20),
        sleep: (_) async {},
      );
      expect(await webhook.send({'content': 'x'}), isTrue);
      expect(calls, 3);
    });

    test('an undeliverable alert is not repeated by the rule', () async {
      discord.replies.addAll(List.filled(4, () => http.Response('', 503)));
      final m = monitor();
      await every(m, 0, 18, _sample(10, 10));
      expect(discord.posts, hasLength(4)); // the attempts of one message
      expect(m.rule.state.firing, isTrue);
    });

    test('the webhook URL never appears in the logs', () async {
      discord.replies.addAll([
        () => http.Response('', 429, headers: {'retry-after': '1'}),
        () => throw http.ClientException('failed: $_webhookUrl', _webhookUrl),
        () => http.Response('', 500),
        () => http.Response('', 500),
      ]);
      final m = monitor();
      await every(m, 0, 15, _sample(10, 10));
      discord.replies.add(() => http.Response('', 404));
      await every(m, 18, 23, _sample(0, 10));
      expect(discord.urls.toSet(), {_webhookUrl});
      expect(logs.raw, isNotEmpty);
      for (final line in [...logs.lines, ...logs.raw]) {
        expect(line, isNot(contains(_token)));
        expect(line, isNot(contains('123456789012345678')));
      }
      expect(logs.raw.join('\n'), contains('not sent'));
    });
  });

  group('message', () {
    test(
      'lists up to 10 names, links the indexers page, pings nobody',
      () async {
        final m = monitor(
          page: indexersPageUrl([Uri.parse('https://hub.example.ts.net/')]),
        );
        final s = IndexerFailureSample(
          enabled: 12,
          failing: [for (var i = 1; i <= 12; i++) 'Idx $i'],
        );
        await every(m, 0, 15, s);
        final post = discord.posts.single;
        expect(post['allowed_mentions'], {'parse': <String>[]});
        final embed = (post['embeds']! as List).single as Map;
        expect(embed['title'], '⚠️ Indexers down: 12 of 12 failing for 15 min');
        expect(embed['url'], 'https://hub.example.ts.net/indexers');
        final description = embed['description'] as String;
        expect(description, contains('Idx 10'));
        expect(description, isNot(contains('Idx 11')));
        expect(description, endsWith('and 2 more'));
      },
    );

    test('no link without publicUrls; markdown in names is stripped', () {
      final payload = discordMessage(
        IndexersDown(
          const IndexerFailureSample(
            enabled: 2,
            failing: ['**@everyone**', 'a_b'],
          ),
          failingFor: const Duration(minutes: 150),
        ),
      );
      final embed = (payload['embeds']! as List).single as Map;
      expect(embed.containsKey('url'), isFalse);
      expect(embed['title'], contains('for 2 h'));
      expect(embed['description'], 'Failing: everyone, ab');
    });

    test('indexersPageUrl keeps a base path', () {
      expect(indexersPageUrl(const []), isNull);
      expect(
        indexersPageUrl([Uri.parse('http://nas:8090/hub/?x=1')]).toString(),
        'http://nas:8090/hub/indexers',
      );
    });
  });

  group('module', () {
    test(
      'off without DISCORD_ALERT_WEBHOOK_URL, logged once at info',
      () async {
        final hub = TestHub(startOnly: const {'indexers'});
        addTearDown(hub.close);
        await hub.ready;
        final module = hub.hub.modules.whereType<IndexersModule>().single;
        expect(module.alertMonitor, isNull);
        expect(
          logs.raw.where((l) => l.contains('Discord alerts off')),
          hasLength(1),
        );
      },
    );

    test('on with a valid URL, which is never logged', () async {
      final hub = TestHub(
        startOnly: const {'indexers'},
        env: {'DISCORD_ALERT_WEBHOOK_URL': _webhookUrl.toString()},
      );
      addTearDown(hub.close);
      await hub.ready;
      final module = hub.hub.modules.whereType<IndexersModule>().single;
      expect(module.alertMonitor, isNotNull);
      expect(module.alertMonitor!.rule.thresholdPercent, 80);
      expect(logs.raw.join('\n'), contains('Discord indexer alert on: 80%'));
      for (final line in [...logs.lines, ...logs.raw]) {
        expect(line, isNot(contains(_token)));
      }
    });
  });
}
