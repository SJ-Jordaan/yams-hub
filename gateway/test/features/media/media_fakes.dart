/// Fake Jellyfin, Jellystat, Audiobookshelf, Kavita, Shelfmark and Seerr
/// answers for the media tests: captured fixtures from `fixtures/` plus the
/// synthetic samples in `data/` (ARCHITECTURE §5.19).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../support/test_hub.dart';

/// Movies and Shows library ids of the fixtures.
const moviesLibraryId = 'f137a2dd21bbc1b99aa5c0f6bf02a805';
const showsLibraryId = 'a656b907eb3a73532e40e44b968d0225';
const jellyfinServerId = '79315eab3c4c401f8391d5c26210b6d7';
const jellyfinAdminId = '4c0628aacef24bdfacd40f946ea33ee7';
const absLibraryId = '5bbbf8b6-d60d-4ffa-837e-aaecb77d2995';

/// The bytes of `test/features/media/data/<name>`.
List<int> syntheticBytes(String name) {
  var dir = Directory.current.absolute.path;
  // Tests run from gateway/ (dart test) or the repo root.
  final rel = p.join('test', 'features', 'media', 'data', name);
  if (!File(p.join(dir, rel)).existsSync()) {
    dir = p.join(dir, 'gateway');
  }
  return File(p.join(dir, rel)).readAsBytesSync();
}

/// A JSON answer from a synthetic sample.
FakeResponse synthetic(String name, {int status = 200}) => FakeResponse(
  status,
  body: Stream.value(syntheticBytes(name)),
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

extension MediaFakes on FakeUpstreams {
  void fakeJellyfin({bool mixedSessions = false}) {
    const s = ServiceId.jellyfin;
    onFixture(
      s,
      'GET',
      '/System/Info/Public',
      'seerr/jellyfin_system_info_public.json',
    );
    onFixture(s, 'GET', '/System/Info', 'seerr/jellyfin_system_info.json');
    onFixture(
      s,
      'GET',
      '/System/Configuration/encoding',
      'seerr/jellyfin_encoding_config.json',
    );
    if (mixedSessions) {
      on(
        s,
        'GET',
        '/Sessions',
        (_) => synthetic('jellyfin_sessions_mixed.synthetic.json'),
      );
    } else {
      onFixture(s, 'GET', '/Sessions', 'seerr/jellyfin_sessions.json');
    }
    onFixture(s, 'GET', '/Items/Counts', 'seerr/jellyfin_items_counts.json');
    onFixture(
      s,
      'GET',
      '/Library/VirtualFolders',
      'seerr/jellyfin_library_virtualfolders.json',
    );
    onFixture(s, 'GET', '/Users', 'seerr/jellyfin_users.json');
    on(s, 'GET', '/Items/Latest', (r) {
      final parent = r.uri.queryParameters['parentId'];
      return FakeResponse.fixture(
        parent == moviesLibraryId
            ? 'seerr/jellyfin_items_latest_movies.json'
            : 'seerr/jellyfin_items_latest_shows_grouped.json',
      );
    });
    onFixture(s, 'GET', '/Items', 'seerr/jellyfin_items_recently_added.json');
    onFixture(
      s,
      'GET',
      '/UserItems/Resume',
      'seerr/jellyfin_items_resume.json',
    );
    on(
      s,
      'GET',
      '/Shows/NextUp',
      (_) => synthetic('jellyfin_shows_nextup.synthetic.json'),
    );
    on(
      s,
      'POST',
      RegExp(r'^/Sessions/[0-9a-f]{32}/'),
      (_) => FakeResponse(204),
    );
    on(s, 'POST', '/Library/Refresh', (_) => FakeResponse(204));
  }

  void fakeJellystat() {
    const s = ServiceId.jellystat;
    onFixture(
      s,
      'GET',
      '/stats/getLibraryMetadata',
      'seerr/jellystat_getLibraryMetadata.json',
    );
    on(
      s,
      'GET',
      '/stats/getViewsOverTime',
      (_) => synthetic('jellystat_getViewsOverTime_played.synthetic.json'),
    );
    onFixture(
      s,
      'GET',
      '/stats/getViewsByDays',
      'seerr/jellystat_getViewsByDays.json',
    );
    onFixture(
      s,
      'GET',
      '/stats/getViewsByHour',
      'seerr/jellystat_getViewsByHour.json',
    );
    onFixture(
      s,
      'POST',
      '/stats/getPlaybackMethodStats',
      'seerr/jellystat_getPlaybackMethodStats.json',
    );
    on(s, 'POST', '/stats/getMostViewedByType', (r) {
      final type = (r.json() as Map)['type'];
      return FakeResponse.fixture(
        type == 'Series'
            ? 'seerr/jellystat_getMostViewedByType_series.json'
            : 'seerr/jellystat_getMostViewedByType_movie_empty.json',
      );
    });
    onFixture(
      s,
      'POST',
      '/stats/getMostPopularByType',
      'seerr/jellystat_getMostPopularByType_series.json',
    );
    onFixture(
      s,
      'POST',
      '/stats/getMostActiveUsers',
      'seerr/jellystat_getMostActiveUsers.json',
    );
    onFixture(
      s,
      'POST',
      '/stats/getMostUsedClient',
      'seerr/jellystat_getMostUsedClient.json',
    );
    onFixture(
      s,
      'POST',
      '/stats/getMostViewedLibraries',
      'seerr/jellystat_getMostViewedLibraries.json',
    );
    onFixture(
      s,
      'GET',
      '/stats/getAllUserActivity',
      'seerr/jellystat_getAllUserActivity.json',
    );
    onFixture(
      s,
      'GET',
      '/stats/getPlaybackActivity',
      'seerr/jellystat_getPlaybackActivity.json',
    );
  }

  void fakeAudiobookshelf() {
    const s = ServiceId.audiobookshelf;
    onFixture(s, 'GET', '/status', 'system/audiobookshelf_status.json');
    onFixture(
      s,
      'GET',
      '/api/libraries',
      'system/audiobookshelf_libraries.json',
    );
    onFixture(
      s,
      'GET',
      '/api/libraries/$absLibraryId/stats',
      'system/audiobookshelf_library_stats.json',
    );
    onFixture(
      s,
      'GET',
      '/api/libraries/$absLibraryId/items',
      'system/audiobookshelf_library_items_recent.json',
    );
    onFixture(
      s,
      'GET',
      '/api/me/items-in-progress',
      'system/audiobookshelf_me_items_in_progress.json',
    );
    onFixture(s, 'GET', '/api/me', 'system/audiobookshelf_me.json');
    onFixture(
      s,
      'GET',
      '/api/me/listening-stats',
      'system/audiobookshelf_me_listening_stats.json',
    );
  }

  void fakeKavita({bool emptyStats = false}) {
    const s = ServiceId.kavita;
    on(
      s,
      'GET',
      '/api/Server/server-info-slim',
      (_) => synthetic('kavita_server_info_slim.synthetic.json'),
    );
    on(
      s,
      'GET',
      '/api/Library/libraries',
      (_) => synthetic('kavita_libraries.synthetic.json'),
    );
    on(
      s,
      'GET',
      '/api/Stats/server/stats',
      (_) => synthetic(
        emptyStats
            ? 'kavita_server_stats_empty.synthetic.json'
            : 'kavita_server_stats.synthetic.json',
      ),
    );
    on(
      s,
      'POST',
      '/api/Series/recently-added-v2',
      (_) => emptyStats
          ? FakeResponse.json(<Object?>[])
          : synthetic('kavita_series_recently_added.synthetic.json'),
    );
    on(
      s,
      'POST',
      '/api/Series/on-deck',
      (_) => emptyStats
          ? FakeResponse.json(<Object?>[])
          : synthetic('kavita_series_on_deck.synthetic.json'),
    );
    on(s, 'GET', '/api/health', (_) => FakeResponse.text('Ok'));
  }

  void fakeShelfmark({bool stopped = false}) {
    const s = ServiceId.shelfmark;
    if (stopped) {
      on(
        s,
        'GET',
        '/api/health',
        (_) =>
            synthetic('shelfmark_health_stopped.synthetic.json', status: 503),
      );
      on(
        s,
        'GET',
        '/api/stats',
        (_) => synthetic('shelfmark_stats_active.synthetic.json'),
      );
    } else {
      onFixture(s, 'GET', '/api/health', 'system/shelfmark_health.json');
      onFixture(s, 'GET', '/api/stats', 'system/shelfmark_stats.json');
    }
  }

  void fakeSeerrCounts() {
    onFixture(
      ServiceId.seerr,
      'GET',
      '/api/v1/request/count',
      'seerr/seerr_request_count.json',
    );
    onFixture(
      ServiceId.seerr,
      'GET',
      '/api/v1/status',
      'seerr/seerr_status.json',
    );
  }

  void fakeAllMedia() {
    fakeJellyfin();
    fakeJellystat();
    fakeAudiobookshelf();
    fakeKavita();
    fakeShelfmark();
    fakeSeerrCounts();
  }
}
