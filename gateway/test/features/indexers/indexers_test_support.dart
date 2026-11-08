/// Shared fakes for the indexers feature tests.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../support/test_hub.dart';

/// The decoded JSON of a synthetic sample in `fixtures/` next to this file.
Object? syntheticFixture(String name) {
  final candidates = [
    p.join('test', 'features', 'indexers', 'fixtures', name),
    p.join('gateway', 'test', 'features', 'indexers', 'fixtures', name),
  ];
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) return jsonDecode(f.readAsStringSync());
  }
  throw StateError('synthetic fixture $name not found');
}

/// The captured indexer list plus a synthetic "Uindex" (id 15, tag 1), the
/// indexer that `prowlarr_indexerstatus.json` reports as failing.
List<Object?> indexersWithUindex() {
  final list = (fixture('downloads/prowlarr_indexer.json')! as List).toList();
  final template = Map<String, Object?>.of(readMap(list.first)!);
  list.add({
    ...template,
    'id': 15,
    'name': 'Uindex',
    'sortName': 'uindex',
    'definitionName': 'uindex',
    'indexerUrls': ['https://uindex.org/'],
    'description': 'Uindex is a Public torrent indexer',
    'tags': [1],
    'fields': [
      {
        'order': 1,
        'name': 'baseUrl',
        'value': 'https://uindex.org/',
        'type': 'select',
        'privacy': 'normal',
      },
      {
        'order': 2,
        'name': 'apiKey',
        'value': '********',
        'type': 'textbox',
        'privacy': 'apiKey',
      },
    ],
  });
  return list;
}

/// Registers the Prowlarr read endpoints with fixtures.
void fakeProwlarrReads(FakeUpstreams f) {
  final indexers = indexersWithUindex();
  f
    ..on(
      ServiceId.prowlarr,
      'GET',
      '/api/v1/indexer',
      (_) => FakeResponse.json(indexers),
    )
    ..onFixture(
      ServiceId.prowlarr,
      'GET',
      '/api/v1/indexerstatus',
      'downloads/prowlarr_indexerstatus.json',
    )
    ..onFixture(
      ServiceId.prowlarr,
      'GET',
      '/api/v1/tag',
      'downloads/prowlarr_tag.json',
    )
    ..onFixture(
      ServiceId.prowlarr,
      'GET',
      '/api/v1/health',
      'downloads/prowlarr_health.json',
    )
    ..onFixture(
      ServiceId.prowlarr,
      'GET',
      '/api/v1/indexerstats',
      'downloads/prowlarr_indexerstats.json',
    )
    ..on(ServiceId.prowlarr, 'GET', RegExp(r'^/api/v1/indexer/\d+$'), (r) {
      final id = int.parse(r.path.split('/').last);
      final match = indexers.map(readMap).where((i) => i?['id'] == id);
      if (match.isEmpty) {
        return FakeResponse.fixture(
          'downloads/prowlarr_error_404.json',
          status: 404,
        );
      }
      return FakeResponse.json(match.first);
    });
}

/// A minimal valid `.torrent` (a bencoded dictionary with `info`).
List<int> torrentBytes({String name = 'example'}) {
  String str(String s) => '${s.length}:$s';
  final pieces = String.fromCharCodes(List.filled(20, 0x41));
  final info =
      'd${str('length')}i1048576e${str('name')}${str(name)}'
      '${str('piece length')}i262144e${str('pieces')}${str(pieces)}e';
  return latin1.encode(
    'd${str('announce')}${str('https://tracker.example.org/announce')}'
    '${str('created by')}${str('yams-hub')}${str('info')}${info}e',
  );
}

/// qBittorrent fakes: categories (without `manual` unless [withManual]),
/// createCategory and torrents/add. Returns the add requests.
List<FakeRequest> fakeQbit(FakeUpstreams f, {bool withManual = false}) {
  final adds = <FakeRequest>[];
  f
    ..on(
      ServiceId.qbittorrent,
      'GET',
      '/api/v2/torrents/categories',
      (_) => FakeResponse.json({
        'tv-sonarr': {'name': 'tv-sonarr', 'savePath': ''},
        'radarr': {'name': 'radarr', 'savePath': ''},
        'books': {'name': 'books', 'savePath': ''},
        if (withManual) 'manual': {'name': 'manual', 'savePath': ''},
      }),
    )
    ..on(
      ServiceId.qbittorrent,
      'POST',
      '/api/v2/torrents/createCategory',
      (_) => FakeResponse.text(''),
    )
    ..on(ServiceId.qbittorrent, 'POST', '/api/v2/torrents/add', (r) {
      adds.add(r);
      return FakeResponse.text('Ok.');
    });
  return adds;
}
