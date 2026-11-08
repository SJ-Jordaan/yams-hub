/// Jellyfin: now playing, session commands, the library overview
/// (API.md §14.2, §14.3; integrations/seerr.md §2).
library;

import 'package:logging/logging.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'media_util.dart';

/// Clients whose API-key sessions are never "now playing".
const hiddenSessionClients = {'homepage', 'seerr', 'yams hub'};

/// The parts of [JellyfinOverview] that are the same for every caller.
final class JellyfinShared {
  const JellyfinShared({
    required this.server,
    required this.counts,
    required this.libraries,
    required this.recentlyAdded,
  });

  final JellyfinServerSummary server;
  final JellyfinCounts counts;
  final List<JellyfinLibrary> libraries;
  final List<MediaItem> recentlyAdded;
}

/// The per-user rows of [JellyfinOverview].
final class JellyfinUserRows {
  const JellyfinUserRows({
    this.continueWatching = const [],
    this.nextUp = const [],
  });

  final List<MediaItem> continueWatching;
  final List<MediaItem> nextUp;
}

/// Reads Jellyfin for the media feature. User-scoped calls use
/// `ctx.jellyfin.adminUserId()` (latest items) or the caller's linked
/// `jellyfinUserId` (resume, next up); links come from `ctx.jellyfin`.
final class JellyfinService {
  JellyfinService(this._ctx)
    : _sessions = _ctx.caches.ttl<int, List<JsonMap>>(
        'media.jellyfin.sessions',
        const Duration(seconds: 5),
      ),
      _hwAccel = _ctx.caches.ttl<int, String?>(
        'media.jellyfin.hwAccel',
        const Duration(hours: 1),
      ),
      _shared = _ctx.caches.ttl<int, JellyfinShared>(
        'media.jellyfin.overview',
        const Duration(seconds: 60),
      ),
      _userRows = _ctx.caches.ttl<String, JellyfinUserRows>(
        'media.jellyfin.userRows',
        const Duration(seconds: 60),
        maxEntries: 50,
      ),
      _systemInfo = _ctx.caches.ttl<int, JsonMap>(
        'media.jellyfin.systemInfo',
        const Duration(seconds: 60),
      );

  final FeatureContext _ctx;
  final TtlCache<int, List<JsonMap>> _sessions;
  final TtlCache<int, String?> _hwAccel;
  final TtlCache<int, JellyfinShared> _shared;
  final TtlCache<String, JellyfinUserRows> _userRows;
  final TtlCache<int, JsonMap> _systemInfo;

  UpstreamClient get _jf => _ctx.upstreams.jellyfin;
  Logger get _log => _ctx.log;

  // -------------------------------------------------------------------------
  // Now playing
  // -------------------------------------------------------------------------

  /// `GET /Sessions?activeWithinSeconds=960` (cache 5 s), mapped for the
  /// caller: `remoteAddress` and `canControl` only for admins.
  Future<CacheResult<NowPlaying>> nowPlaying({required bool isAdmin}) async {
    final res = await _sessions.get(0, () async {
      final body = await _jf.getJson(
        '/Sessions',
        query: {'activeWithinSeconds': 960},
      );
      return [
        if (body is List)
          for (final s in body) ?readMap(s),
      ];
    });
    final serverId = await _ctx.jellyfin.serverId();
    final sessions = [
      for (final s in res.value)
        ?mapSession(
          s,
          images: _ctx.images,
          isAdmin: isAdmin,
          link: serverId == null
              ? null
              : (id) => _ctx.jellyfin.itemLink(id, serverId),
        ),
    ];
    final np = NowPlaying(
      sessions: sessions,
      transcoding: sessions.where((s) => s.isTranscoding).length,
      hwAccel: await hwAccel(),
    );
    return CacheResult(
      np,
      fetchedAt: res.fetchedAt,
      stale: res.stale,
      error: res.error,
    );
  }

  /// `HardwareAccelerationType` of `/System/Configuration/encoding` (cache
  /// 1 h); null for `none` or when it cannot be read.
  Future<String?> hwAccel() async {
    try {
      return await _hwAccel.value(0, () async {
        final j = readMap(await _jf.getJson('/System/Configuration/encoding'));
        return normaliseHwAccel(readString(j?['HardwareAccelerationType']));
      });
    } on UpstreamException catch (e) {
      _log.fine('Jellyfin encoding config unavailable: $e');
      return null;
    }
  }

  /// Sends a playback command (`pause`, `unpause`, `stop`) to a session.
  Future<void> playback(String sessionId, MediaPlaybackCommand command) async {
    final verb = switch (command) {
      MediaPlaybackCommand.pause => 'Pause',
      MediaPlaybackCommand.unpause => 'Unpause',
      MediaPlaybackCommand.stop => 'Stop',
      MediaPlaybackCommand.unknown => throw ArgumentError.value(command),
    };
    await _sessionCall(
      'POST',
      '/Sessions/$sessionId/Playing/$verb',
      sessionId: sessionId,
    );
  }

  /// Shows a message on a session's screen.
  Future<void> message(
    String sessionId, {
    required String text,
    required String header,
    required int timeoutMs,
  }) => _sessionCall(
    'POST',
    '/Sessions/$sessionId/Message',
    sessionId: sessionId,
    body: {'Header': header, 'Text': text, 'TimeoutMs': timeoutMs},
  );

  Future<void> _sessionCall(
    String method,
    String path, {
    required String sessionId,
    Object? body,
  }) async {
    try {
      final r = await _jf.send(method, path, jsonBody: body);
      if (r.status == 404) {
        throw ApiException.notFound('That playback session has ended.');
      }
      r.ensureOk();
    } on UpstreamException catch (e) {
      throw e.toApiException();
    } finally {
      _sessions.clear();
    }
  }

  // -------------------------------------------------------------------------
  // Library overview
  // -------------------------------------------------------------------------

  /// `GET /media/jellyfin` for a caller linked to [jellyfinUserId].
  Future<JellyfinOverview> overview({String? jellyfinUserId}) async {
    final r = await Future.wait<Object?>([
      shared(),
      jellyfinUserId == null
          ? Future.value(const JellyfinUserRows())
          : userRows(jellyfinUserId),
    ], eagerError: true);
    final s = r[0] as JellyfinShared;
    final rows = r[1] as JellyfinUserRows;
    return JellyfinOverview(
      server: s.server,
      counts: s.counts,
      libraries: s.libraries,
      recentlyAdded: s.recentlyAdded,
      continueWatching: rows.continueWatching,
      nextUp: rows.nextUp,
    );
  }

  /// Server, counts, libraries and recently added (cache 60 s).
  Future<JellyfinShared> shared() => _shared.value(0, _loadShared);

  /// Like [shared] with the cache metadata (dashboard staleness).
  Future<CacheResult<JellyfinShared>> sharedResult() =>
      _shared.get(0, _loadShared);

  Future<JellyfinShared> _loadShared() async {
    // One Future.wait: every call is listened to, the first failure wins.
    final r = await Future.wait<Object?>([
      _jf.getJson('/System/Info/Public'),
      _jf.getJson('/Items/Counts'),
      _jf.getJson('/Library/VirtualFolders'),
      _librarySizes(),
      hwAccel(),
    ], eagerError: true);
    final info = readMap(r[0]) ?? const {};
    final counts = mapCounts(readMap(r[1]) ?? const {});
    final folders = [
      if (r[2] case final List<Object?> l)
        for (final f in l) ?readMap(f),
    ];
    final sizes = r[3] as Map<String, ({int? size, int? files})>;
    final libraries = mapLibraries(folders, counts: counts, sizes: sizes);
    final recent = await _recentlyAdded(libraries);
    return JellyfinShared(
      server: JellyfinServerSummary(
        name: readString(info['ServerName']) ?? 'Jellyfin',
        version: readString(info['Version']) ?? '',
        hwAccel: r[4] as String?,
      ),
      counts: counts,
      libraries: libraries,
      recentlyAdded: recent,
    );
  }

  /// Jellystat `/stats/getLibraryMetadata` sizes by library id; failures
  /// are ignored (API.md §14.3).
  Future<Map<String, ({int? size, int? files})>> _librarySizes() async {
    final js = _ctx.upstreams.jellystat;
    if (!js.configured) return const {};
    try {
      final body = await js.getJson(
        '/stats/getLibraryMetadata',
        timeout: const Duration(seconds: 5),
      );
      return {
        if (body is List)
          for (final e in body)
            if (readMap(e) case final m?)
              ?normaliseJellyfinId(readString(m['Id'])): (
                size: readInt(m['Size']),
                files: readInt(m['files']),
              ),
      };
    } on UpstreamException catch (e) {
      _log.fine('Jellystat library sizes unavailable: $e');
      return const {};
    }
  }

  /// The newest 16 movies and shows: `/Items/Latest` per movies/tvshows
  /// library as the admin user (grouped: new episodes collapse into their
  /// series), falling back to the global `/Items` query.
  Future<List<MediaItem>> _recentlyAdded(
    List<JellyfinLibrary> libraries,
  ) async {
    final serverId = await _ctx.jellyfin.serverId();
    MediaItem? map(JsonMap j) => mapItem(
      j,
      images: _ctx.images,
      link: serverId == null
          ? null
          : (id) => _ctx.jellyfin.itemLink(id, serverId),
    );
    final targets = [
      for (final l in libraries)
        if (l.type == JellyfinLibraryType.movies ||
            l.type == JellyfinLibraryType.tvshows)
          l.id,
    ];
    String? admin;
    try {
      admin = await _ctx.jellyfin.adminUserId();
    } on UpstreamException catch (e) {
      _log.fine('Jellyfin admin user unavailable: $e');
    }
    if (admin != null && targets.isNotEmpty) {
      try {
        final lists = await Future.wait([
          for (final lib in targets)
            _jf.getJson(
              '/Items/Latest',
              query: {
                'userId': admin,
                'parentId': lib,
                'limit': 16,
                'fields': 'DateCreated',
                'enableImageTypes': 'Primary',
                'imageTypeLimit': 1,
              },
            ),
        ]);
        // Each list is already newest first by Jellyfin's own measure (the
        // newest child for grouped Series/Season rows, whose own
        // `DateCreated` can be months old), so the lists are interleaved
        // rather than re-sorted by `DateCreated`.
        return interleave([
          for (final l in lists)
            [
              if (l is List)
                for (final e in l)
                  if (readMap(e) case final m?) ?map(m),
            ],
        ]).take(16).toList();
      } on UpstreamException catch (e) {
        if (e.status == 401 || e.status == 404) {
          _ctx.jellyfin.invalidateAdminUserId();
        }
        _log.fine('Jellyfin latest items failed, using /Items: $e');
      }
    }
    final body = readMap(
      await _jf.getJson(
        '/Items',
        query: {
          'recursive': true,
          'includeItemTypes': 'Movie,Episode',
          'sortBy': 'DateCreated',
          'sortOrder': 'Descending',
          'limit': 16,
          'fields': 'DateCreated,ProviderIds',
        },
      ),
    );
    return [for (final e in readList(body?['Items'], (m) => m)) ?map(e)];
  }

  /// Continue watching and next up for [jellyfinUserId] (cache 60 s). A
  /// failed row is empty.
  Future<JellyfinUserRows> userRows(String jellyfinUserId) =>
      _userRows.value(jellyfinUserId, () async {
        final serverId = await _ctx.jellyfin.serverId();
        Future<List<MediaItem>> row(String path) async {
          try {
            final body = readMap(
              await _jf.getJson(
                path,
                query: {
                  'userId': jellyfinUserId,
                  'limit': 12,
                  'fields': 'DateCreated',
                },
              ),
            );
            return [
              for (final e in readList(body?['Items'], (m) => m))
                ?mapItem(
                  e,
                  images: _ctx.images,
                  link: serverId == null
                      ? null
                      : (id) => _ctx.jellyfin.itemLink(id, serverId),
                ),
            ];
          } on UpstreamException catch (e) {
            if (e is UpstreamNotConfigured) rethrow;
            _log.fine('Jellyfin $path failed: $e');
            return const [];
          }
        }

        final rows = await Future.wait([
          row('/UserItems/Resume'),
          row('/Shows/NextUp'),
        ], eagerError: true);
        return JellyfinUserRows(continueWatching: rows[0], nextUp: rows[1]);
      });

  /// `POST /Library/Refresh` (scan all libraries).
  Future<void> refreshLibraries() async {
    await upstreamGuard(() async {
      (await _jf.send('POST', '/Library/Refresh')).ensureOk();
    });
    _shared.clear();
  }

  /// `/System/Info` (cache 60 s): `HasPendingRestart` for the alert.
  Future<bool> hasPendingRestart() async {
    final info = await _systemInfo.value(
      0,
      () async => readMap(await _jf.getJson('/System/Info')) ?? const {},
    );
    return readBool(info['HasPendingRestart']) ?? false;
  }
}

// ---------------------------------------------------------------------------
// Mapping (pure, unit-tested against the fixtures)
// ---------------------------------------------------------------------------

/// Round-robin merge of ordered lists (`[a1, b1, a2, b2, a3, ...]`), keeping
/// each list's own order and every element.
List<T> interleave<T>(List<List<T>> lists) {
  final out = <T>[];
  final longest = lists.fold(0, (m, l) => l.length > m ? l.length : m);
  for (var i = 0; i < longest; i++) {
    for (final l in lists) {
      if (i < l.length) out.add(l[i]);
    }
  }
  return out;
}

/// `none`/empty → null, otherwise the lower-case value (`qsv`).
String? normaliseHwAccel(String? v) {
  final s = v?.trim().toLowerCase();
  return (s == null || s.isEmpty || s == 'none') ? null : s;
}

MediaPlayMethod _playMethod(String? v) => switch (v?.toLowerCase()) {
  'directplay' => MediaPlayMethod.directPlay,
  'directstream' => MediaPlayMethod.directStream,
  'transcode' => MediaPlayMethod.transcode,
  _ => MediaPlayMethod.unknown,
};

/// Jellyfin/Jellystat `PlayMethod` strings.
MediaPlayMethod mapPlayMethod(String? v) => _playMethod(v);

List<String> _reasons(Object? v) {
  if (v is String) {
    return [
      for (final p in v.split(','))
        if (p.trim().isNotEmpty) p.trim(),
    ];
  }
  return readStringList(v);
}

/// One `SessionInfoDto` → [NowPlayingSession]; null when nothing is playing
/// or the client is an API-key pseudo-session (Homepage, Seerr, YAMS Hub).
NowPlayingSession? mapSession(
  JsonMap s, {
  required ImageUrls images,
  required bool isAdmin,
  ExternalLink Function(String itemId)? link,
}) {
  final item = readMap(s['NowPlayingItem']);
  if (item == null) return null;
  final client = readString(s['Client']) ?? '';
  if (hiddenSessionClients.contains(client.trim().toLowerCase())) return null;
  final id = readString(s['Id']);
  final itemId = normaliseJellyfinId(readString(item['Id']));
  if (id == null || itemId == null) return null;

  final type = switch (readString(item['Type'])) {
    'Movie' => NowPlayingItemType.movie,
    'Episode' => NowPlayingItemType.episode,
    'Audio' => NowPlayingItemType.audio,
    _ => NowPlayingItemType.other,
  };
  final play = readMap(s['PlayState']) ?? const {};
  final runtimeTicks = readInt(item['RunTimeTicks']);
  final positionTicks = readInt(play['PositionTicks']) ?? 0;
  final info = readMap(s['TranscodingInfo']);
  var method = _playMethod(readString(play['PlayMethod']));
  NowPlayingTranscode? transcode;
  if (info != null) {
    transcode = NowPlayingTranscode(
      videoCodec: readString(info['VideoCodec']),
      audioCodec: readString(info['AudioCodec']),
      container: readString(info['Container']),
      hwAccel: normaliseHwAccel(readString(info['HardwareAccelerationType'])),
      reasons: _reasons(info['TranscodeReasons']),
      bitrate: readInt(info['Bitrate']),
      completionPercent: readDouble(info['CompletionPercentage']),
      videoDirect: readBool(info['IsVideoDirect']),
      audioDirect: readBool(info['IsAudioDirect']),
      width: readInt(info['Width']),
      height: readInt(info['Height']),
    );
    // Only the audio is converted: Jellyfin reports Transcode, the dashboard
    // calls it a direct stream (integrations/seerr.md §2.3).
    if (method == MediaPlayMethod.transcode &&
        transcode.videoDirect == true &&
        transcode.audioDirect == false) {
      method = MediaPlayMethod.directStream;
    }
  } else if (method == MediaPlayMethod.unknown) {
    method = MediaPlayMethod.directPlay;
  }

  final imageTags = readMap(item['ImageTags']) ?? const {};
  final primaryTag = readString(imageTags['Primary']);
  final seriesId = normaliseJellyfinId(readString(item['SeriesId']));
  final seriesTag = readString(item['SeriesPrimaryImageTag']);
  final imagePath = primaryTag != null
      ? images.jellyfin(itemId, 'Primary', tag: primaryTag, fillHeight: 342)
      : (seriesId != null && seriesTag != null)
      ? images.jellyfin(seriesId, 'Primary', tag: seriesTag, fillHeight: 342)
      : null;

  final backdropTags = readStringList(item['BackdropImageTags']);
  final parentBackdropTags = readStringList(item['ParentBackdropImageTags']);
  final parentBackdropId = normaliseJellyfinId(
    readString(item['ParentBackdropItemId']),
  );
  final backdropPath = backdropTags.isNotEmpty
      ? images.jellyfin(
          itemId,
          'Backdrop',
          tag: backdropTags.first,
          index: 0,
          maxWidth: 780,
        )
      : (parentBackdropId != null && parentBackdropTags.isNotEmpty)
      ? images.jellyfin(
          parentBackdropId,
          'Backdrop',
          tag: parentBackdropTags.first,
          index: 0,
          maxWidth: 780,
        )
      : null;

  final userId = normaliseJellyfinId(readString(s['UserId']));
  final userTag = readString(s['UserPrimaryImageTag']);
  final runtime = runtimeTicks == null ? null : runtimeTicks ~/ ticksPerSecond;

  return NowPlayingSession(
    id: id.toLowerCase(),
    userName: readString(s['UserName']) ?? '',
    userId: userId,
    client: client,
    deviceName: readString(s['DeviceName']) ?? '',
    itemId: itemId,
    itemType: type,
    title: readString(item['Name']) ?? '',
    seriesName: readString(item['SeriesName']),
    seasonNumber: type == NowPlayingItemType.episode
        ? readInt(item['ParentIndexNumber'])
        : null,
    episodeNumber: type == NowPlayingItemType.episode
        ? readInt(item['IndexNumber'])
        : null,
    year: type == NowPlayingItemType.episode
        ? null
        : readInt(item['ProductionYear']),
    runtimeSeconds: runtime,
    positionSeconds: positionTicks ~/ ticksPerSecond,
    progress: (runtimeTicks == null || runtimeTicks <= 0)
        ? 0
        : ratio(positionTicks / runtimeTicks),
    paused: readBool(play['IsPaused']) ?? false,
    playMethod: method,
    transcode: transcode,
    imagePath: imagePath,
    backdropPath: backdropPath,
    userImagePath: userTag == null
        ? null
        : images.jellyfinUser(userId, tag: userTag),
    remoteAddress: isAdmin ? readString(s['RemoteEndPoint']) : null,
    jellyfin: link?.call(itemId),
    canControl: isAdmin && readBool(s['SupportsMediaControl']) != false,
  );
}

/// `/Items/Counts` → [JellyfinCounts].
JellyfinCounts mapCounts(JsonMap j) => JellyfinCounts(
  movies: readInt(j['MovieCount']) ?? 0,
  series: readInt(j['SeriesCount']) ?? 0,
  episodes: readInt(j['EpisodeCount']) ?? 0,
  songs: readInt(j['SongCount']) ?? 0,
  albums: readInt(j['AlbumCount']) ?? 0,
  books: readInt(j['BookCount']) ?? 0,
);

/// `/Library/VirtualFolders` + Jellystat sizes → libraries. `itemCount` is
/// filled from [counts] when the library is the only one of its type.
List<JellyfinLibrary> mapLibraries(
  List<JsonMap> folders, {
  required JellyfinCounts counts,
  Map<String, ({int? size, int? files})> sizes = const {},
}) {
  JellyfinLibraryType typeOf(JsonMap f) =>
      switch (readString(f['CollectionType'])) {
        'movies' => JellyfinLibraryType.movies,
        'tvshows' => JellyfinLibraryType.tvshows,
        'music' => JellyfinLibraryType.music,
        'books' => JellyfinLibraryType.books,
        _ => JellyfinLibraryType.other,
      };
  final types = [for (final f in folders) typeOf(f)];
  int? countFor(JellyfinLibraryType t) {
    if (types.where((x) => x == t).length != 1) return null;
    return switch (t) {
      JellyfinLibraryType.movies => counts.movies,
      JellyfinLibraryType.tvshows => counts.series,
      JellyfinLibraryType.music => counts.songs,
      JellyfinLibraryType.books => counts.books,
      _ => null,
    };
  }

  return [
    for (final (i, f) in folders.indexed)
      if (normaliseJellyfinId(readString(f['ItemId'])) case final id?)
        JellyfinLibrary(
          id: id,
          name: readString(f['Name']) ?? '',
          type: types[i],
          sizeBytes: sizes[id]?.size,
          files: sizes[id]?.files,
          itemCount: countFor(types[i]),
          refreshing: readString(f['RefreshStatus'])?.toLowerCase() == 'active',
        ),
  ];
}

String _two(int n) => n.toString().padLeft(2, '0');

/// A `BaseItemDto` → [MediaItem]; episodes and seasons are titled with
/// their series and show the series poster (2:3).
MediaItem? mapItem(
  JsonMap j, {
  required ImageUrls images,
  ExternalLink Function(String itemId)? link,
}) {
  final id = normaliseJellyfinId(readString(j['Id']));
  if (id == null) return null;
  final type = switch (readString(j['Type'])) {
    'Movie' => MediaItemType.movie,
    'Series' => MediaItemType.series,
    'Season' => MediaItemType.season,
    'Episode' => MediaItemType.episode,
    'Audio' => MediaItemType.audio,
    'Book' || 'AudioBook' => MediaItemType.book,
    _ => MediaItemType.other,
  };
  final name = readString(j['Name']) ?? '';
  final seriesName = readString(j['SeriesName']);
  final tags = readMap(j['ImageTags']) ?? const {};
  final ownTag = readString(tags['Primary']);
  final seriesId = normaliseJellyfinId(readString(j['SeriesId']));
  final seriesTag = readString(j['SeriesPrimaryImageTag']);
  String? own() => ownTag == null
      ? null
      : images.jellyfin(id, 'Primary', tag: ownTag, fillHeight: 342);
  String? series() => (seriesId == null || seriesTag == null)
      ? null
      : images.jellyfin(seriesId, 'Primary', tag: seriesTag, fillHeight: 342);

  String title = name;
  String? subtitle;
  String? imagePath;
  switch (type) {
    case MediaItemType.episode:
      title = seriesName ?? name;
      final s = readInt(j['ParentIndexNumber']);
      final e = readInt(j['IndexNumber']);
      final code = (s != null && e != null) ? 'S${_two(s)}E${_two(e)}' : null;
      subtitle = seriesName == null
          ? code
          : [?code, if (name.isNotEmpty) name].join(' · ');
      imagePath = series() ?? own();
    case MediaItemType.season:
      title = seriesName ?? name;
      subtitle = seriesName == null ? null : name;
      imagePath = own() ?? series();
    default:
      imagePath = own() ?? series();
  }
  final userData = readMap(j['UserData']) ?? const {};
  final unplayed = readInt(userData['UnplayedItemCount']);
  final played = readDouble(userData['PlayedPercentage']);
  return MediaItem(
    id: id,
    type: type,
    title: title,
    subtitle: (subtitle == null || subtitle.isEmpty) ? null : subtitle,
    year: type == MediaItemType.episode ? null : readInt(j['ProductionYear']),
    imagePath: imagePath,
    addedAt: readInstant(j['DateCreated']),
    newEpisodeCount:
        (type == MediaItemType.series || type == MediaItemType.season) &&
            unplayed != null &&
            unplayed > 0
        ? unplayed
        : null,
    progress: played == null || played <= 0 ? null : ratio(played / 100),
    jellyfin: link?.call(id),
  );
}
