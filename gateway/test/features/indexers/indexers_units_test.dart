import 'dart:convert';

import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/core/clock.dart';
import 'package:yams_hub_gateway/src/features/indexers/bencode.dart';
import 'package:yams_hub_gateway/src/features/indexers/prowlarr_mapping.dart';
import 'package:yams_hub_gateway/src/features/indexers/release_grabber.dart';
import 'package:yams_hub_gateway/src/features/indexers/release_store.dart';

import 'indexers_test_support.dart';

void main() {
  group('isTorrentFile', () {
    test('accepts a bencoded dictionary with info', () {
      expect(isTorrentFile(torrentBytes()), isTrue);
      expect(isTorrentFile([...torrentBytes(), 0x0a]), isTrue);
    });

    test('rejects anything else', () {
      for (final s in [
        '',
        '<html></html>',
        '{"a":1}',
        'de',
        'd4:spami1ee',
        'd4:infod',
        'd4:infodee junk',
        'd4:infodei1e',
        'd4:info5:abc',
        'd4:infodei-e',
        'd4:infodeei1ee',
        'l4:infoe',
        'd4:infodee4:infodee',
      ]) {
        expect(isTorrentFile(latin1.encode(s)), isFalse, reason: s);
      }
    });

    test('limits nesting depth', () {
      final deep = 'd4:info${'l' * 100}${'e' * 100}e';
      expect(isTorrentFile(latin1.encode(deep)), isFalse);
      expect(isTorrentFile(latin1.encode('d4:infolleee')), isTrue);
    });
  });

  group('prowlarrDownloadTarget', () {
    final base = Uri.parse('http://prowlarr:9696');

    test('rewrites the proxied download route and drops apikey', () {
      final t = prowlarrDownloadTarget(
        Uri.parse(
          'http://192.168.10.183:9696/4/download?apikey=k&APIKEY=k&link=abc&file=A+B',
        ),
        4,
        base,
      )!;
      expect(t.path, '/4/download');
      expect(t.query, {
        'link': ['abc'],
        'file': ['A B'],
      });
    });

    test('strips the base path of PROWLARR_URL', () {
      final t = prowlarrDownloadTarget(
        Uri.parse('https://hub.example.org/prowlarr/4/download?link=x'),
        4,
        Uri.parse('http://prowlarr:9696/prowlarr'),
      )!;
      expect(t.path, '/4/download');
    });

    test('ignores other paths, ids and schemes', () {
      for (final url in [
        'http://prowlarr:9696/5/download?link=x',
        'http://prowlarr:9696/api/v1/indexer',
        'http://prowlarr:9696/4/downloads',
        'http://prowlarr:9696/4',
        'magnet:?xt=urn:btih:abc',
        'ftp://prowlarr/4/download',
        'http://prowlarr:9696/4/download/%2E%2E/api',
        'http://prowlarr:9696/4/download/a%2Fb',
      ]) {
        expect(
          prowlarrDownloadTarget(Uri.parse(url), 4, base),
          isNull,
          reason: url,
        );
      }
    });
  });

  group('ReleaseStore', () {
    test('expires tokens after 30 minutes and caps entries', () {
      final clock = FakeClock();
      final store = ReleaseStore(clock: clock, maxEntries: 2);
      const links = ProwlarrReleaseLinks(
        indexerId: 4,
        title: 't',
        protocol: 'torrent',
      );
      final a = store.put(links);
      clock.advance(const Duration(minutes: 10));
      final b = store.put(links);
      expect(a, isNot(b));
      expect(store.get(a), isNotNull);
      clock.advance(const Duration(minutes: 21));
      expect(store.get(a), isNull);
      expect(store.get(b), isNotNull);
      final c = store.put(links);
      final d = store.put(links);
      expect(store.get(b), isNull, reason: 'evicted');
      expect(store.get(c), isNotNull);
      expect(store.get(d), isNotNull);
    });
  });

  group('mapping', () {
    test('release links prefer a real magnet', () {
      final l = releaseLinks({
        'indexerId': 5,
        'title': 'x',
        'protocol': 'torrent',
        'magnetUrl': 'https://not-a-magnet',
        'downloadUrl': 'magnet:?xt=urn:btih:abc',
      });
      expect(l.magnetUrl, isNull);
      expect(l.magnetLinkUrl, 'https://not-a-magnet');
      expect(l.hasMagnet, isTrue);
    });

    test('release age falls back to days', () {
      final r = mapRelease(
        {'title': 't', 'indexerId': 4, 'age': 2},
        'rel_x',
        {4: '1337x'},
      );
      expect(r.ageHours, 48);
      expect(r.indexer, '1337x');
    });

    test('history records with unknown event types map to unknown', () {
      final h = mapHistoryRecord({
        'id': 1,
        'indexerId': 99,
        'date': '2026-11-08T08:00:00Z',
        'successful': true,
        'eventType': 'somethingNew',
        'data': {'query': '', 'elapsedTime': 'n/a'},
      }, const {});
      expect(h.indexerName, '#99');
      expect(h.query, isNull);
      expect(h.elapsedMs, isNull);
      expect(h.type.name, 'unknown');
    });
  });
}
