/// Media DTOs: Jellyfin, Jellystat, Audiobookshelf, Kavita and Shelfmark
/// (API.md §14).
///
/// Every public name starts with a DTO name of API.md §14 or one of the
/// feature prefixes `Media`, `Jellyfin`, `Watch`, `Audiobook`, `Books`,
/// `Shelfmark` (ARCHITECTURE §4).
library;

import 'package:meta/meta.dart';

import 'common.dart';
import 'json.dart';

// ---------------------------------------------------------------------------
// Helpers (library-private)
// ---------------------------------------------------------------------------

ExternalLink? _readLink(Object? v) {
  final m = readMap(v);
  return m == null ? null : ExternalLink.fromJson(m);
}

ExternalLink _reqLink(Object? v, String field) =>
    _readLink(v) ?? (throw FormatException(field));

Map<String, int> _readIntMap(Object? v) {
  final m = readMap(v);
  if (m == null) return const {};
  return {for (final e in m.entries) e.key: ?readInt(e.value)};
}

// ---------------------------------------------------------------------------
// Shared enums
// ---------------------------------------------------------------------------

/// How a Jellyfin client plays a stream (`PlayState.PlayMethod`, Jellystat
/// `PlayMethod`).
enum MediaPlayMethod {
  directPlay('Direct play'),
  directStream('Direct stream'),
  transcode('Transcode'),
  unknown('Unknown');

  const MediaPlayMethod(this.label);

  /// Display label ("Direct play").
  final String label;

  static MediaPlayMethod fromJson(Object? v) =>
      readEnum(v, MediaPlayMethod.values, MediaPlayMethod.unknown);

  String toJson() => name;
}

/// The kind of item a [NowPlayingSession] plays.
enum NowPlayingItemType {
  movie,
  episode,
  audio,
  other,
  unknown;

  static NowPlayingItemType fromJson(Object? v) =>
      readEnum(v, NowPlayingItemType.values, NowPlayingItemType.unknown);

  String toJson() => name;
}

/// The kind of a [MediaItem].
enum MediaItemType {
  movie,
  series,
  season,
  episode,
  audio,
  book,
  other,
  unknown;

  static MediaItemType fromJson(Object? v) =>
      readEnum(v, MediaItemType.values, MediaItemType.unknown);

  String toJson() => name;
}

// ---------------------------------------------------------------------------
// Now playing (API.md §14.1, §14.2)
// ---------------------------------------------------------------------------

/// `TranscodingInfo` of a session (only present while transcoding).
@immutable
final class NowPlayingTranscode {
  const NowPlayingTranscode({
    this.videoCodec,
    this.audioCodec,
    this.container,
    this.hwAccel,
    this.reasons = const [],
    this.bitrate,
    this.completionPercent,
    this.videoDirect,
    this.audioDirect,
    this.width,
    this.height,
  });

  factory NowPlayingTranscode.fromJson(JsonMap j) => NowPlayingTranscode(
    videoCodec: readString(j['videoCodec']),
    audioCodec: readString(j['audioCodec']),
    container: readString(j['container']),
    hwAccel: readString(j['hwAccel']),
    reasons: readStringList(j['reasons']),
    bitrate: readInt(j['bitrate']),
    completionPercent: readDouble(j['completionPercent']),
    videoDirect: readBool(j['videoDirect']),
    audioDirect: readBool(j['audioDirect']),
    width: readInt(j['width']),
    height: readInt(j['height']),
  );

  final String? videoCodec;
  final String? audioCodec;
  final String? container;

  /// `qsv`, `vaapi`, ... (`none` is reported as null).
  final String? hwAccel;

  /// Raw `TranscodeReasons` strings (unknown values kept).
  final List<String> reasons;

  /// Bits per second.
  final int? bitrate;
  final double? completionPercent;
  final bool? videoDirect;
  final bool? audioDirect;
  final int? width;
  final int? height;

  JsonMap toJson() => compactJson({
    'videoCodec': videoCodec,
    'audioCodec': audioCodec,
    'container': container,
    'hwAccel': hwAccel,
    'reasons': reasons,
    'bitrate': bitrate,
    'completionPercent': completionPercent,
    'videoDirect': videoDirect,
    'audioDirect': audioDirect,
    'width': width,
    'height': height,
  });
}

/// One Jellyfin session that is playing something.
@immutable
final class NowPlayingSession {
  const NowPlayingSession({
    required this.id,
    required this.userName,
    required this.client,
    required this.deviceName,
    required this.itemId,
    required this.itemType,
    required this.title,
    required this.positionSeconds,
    required this.progress,
    required this.paused,
    required this.playMethod,
    required this.canControl,
    this.userId,
    this.seriesName,
    this.seasonNumber,
    this.episodeNumber,
    this.year,
    this.runtimeSeconds,
    this.transcode,
    this.imagePath,
    this.backdropPath,
    this.userImagePath,
    this.remoteAddress,
    this.jellyfin,
  });

  factory NowPlayingSession.fromJson(JsonMap j) => NowPlayingSession(
    id: req(readString(j['id']), 'id'),
    userName: readString(j['userName']) ?? '',
    userId: readString(j['userId']),
    client: readString(j['client']) ?? '',
    deviceName: readString(j['deviceName']) ?? '',
    itemId: req(readString(j['itemId']), 'itemId'),
    itemType: NowPlayingItemType.fromJson(j['itemType']),
    title: readString(j['title']) ?? '',
    seriesName: readString(j['seriesName']),
    seasonNumber: readInt(j['seasonNumber']),
    episodeNumber: readInt(j['episodeNumber']),
    year: readInt(j['year']),
    runtimeSeconds: readInt(j['runtimeSeconds']),
    positionSeconds: readInt(j['positionSeconds']) ?? 0,
    progress: readDouble(j['progress']) ?? 0,
    paused: readBool(j['paused']) ?? false,
    playMethod: MediaPlayMethod.fromJson(j['playMethod']),
    transcode: switch (readMap(j['transcode'])) {
      final m? => NowPlayingTranscode.fromJson(m),
      null => null,
    },
    imagePath: readString(j['imagePath']),
    backdropPath: readString(j['backdropPath']),
    userImagePath: readString(j['userImagePath']),
    remoteAddress: readString(j['remoteAddress']),
    jellyfin: _readLink(j['jellyfin']),
    canControl: readBool(j['canControl']) ?? false,
  );

  /// Jellyfin session id (for playback commands).
  final String id;
  final String userName;
  final String? userId;
  final String client;
  final String deviceName;
  final String itemId;
  final NowPlayingItemType itemType;

  /// Item name (the episode name for episodes).
  final String title;
  final String? seriesName;
  final int? seasonNumber;
  final int? episodeNumber;
  final int? year;
  final int? runtimeSeconds;
  final int positionSeconds;

  /// 0..1.
  final double progress;
  final bool paused;
  final MediaPlayMethod playMethod;
  final NowPlayingTranscode? transcode;

  /// Episode Primary, else the series Primary.
  final String? imagePath;

  /// A 16:9 backdrop of the item (or its series), when Jellyfin has one.
  final String? backdropPath;

  /// The user's Jellyfin avatar.
  final String? userImagePath;

  /// Client IP; only sent to admins.
  final String? remoteAddress;
  final ExternalLink? jellyfin;

  /// The caller may send playback commands and messages to this session.
  final bool canControl;

  /// `S05E18` for episodes, null otherwise.
  String? get episodeCode {
    final s = seasonNumber;
    final e = episodeNumber;
    if (itemType != NowPlayingItemType.episode || s == null || e == null) {
      return null;
    }
    String two(int n) => n.toString().padLeft(2, '0');
    return 'S${two(s)}E${two(e)}';
  }

  bool get isTranscoding => playMethod == MediaPlayMethod.transcode;

  JsonMap toJson() => compactJson({
    'id': id,
    'userName': userName,
    'userId': userId,
    'client': client,
    'deviceName': deviceName,
    'itemId': itemId,
    'itemType': itemType.toJson(),
    'title': title,
    'seriesName': seriesName,
    'seasonNumber': seasonNumber,
    'episodeNumber': episodeNumber,
    'year': year,
    'runtimeSeconds': runtimeSeconds,
    'positionSeconds': positionSeconds,
    'progress': progress,
    'paused': paused,
    'playMethod': playMethod.toJson(),
    'transcode': transcode?.toJson(),
    'imagePath': imagePath,
    'backdropPath': backdropPath,
    'userImagePath': userImagePath,
    'remoteAddress': remoteAddress,
    'jellyfin': jellyfin?.toJson(),
    'canControl': canControl,
  });
}

/// 200 body of `GET /media/now-playing`.
@immutable
final class NowPlaying {
  const NowPlaying({
    this.sessions = const [],
    this.transcoding = 0,
    this.hwAccel,
  });

  factory NowPlaying.fromJson(JsonMap j) => NowPlaying(
    sessions: readList(j['sessions'], NowPlayingSession.fromJson),
    transcoding: readInt(j['transcoding']) ?? 0,
    hwAccel: readString(j['hwAccel']),
  );

  final List<NowPlayingSession> sessions;

  /// Sessions that are transcoding.
  final int transcoding;

  /// Jellyfin's configured hardware acceleration (`qsv`), null when none.
  final String? hwAccel;

  JsonMap toJson() => compactJson({
    'sessions': [for (final s in sessions) s.toJson()],
    'transcoding': transcoding,
    'hwAccel': hwAccel,
  });
}

/// A playback command for `POST /media/sessions/{id}/playback`.
enum MediaPlaybackCommand {
  pause,
  unpause,
  stop,
  unknown;

  static MediaPlaybackCommand fromJson(Object? v) =>
      readEnum(v, MediaPlaybackCommand.values, MediaPlaybackCommand.unknown);

  String toJson() => name;
}

/// Body of `POST /media/sessions/{id}/message`.
@immutable
final class MediaSessionMessage {
  const MediaSessionMessage({required this.text, this.header, this.timeoutMs});

  factory MediaSessionMessage.fromJson(JsonMap j) => MediaSessionMessage(
    text: readString(j['text']) ?? '',
    header: readString(j['header']),
    timeoutMs: readInt(j['timeoutMs']),
  );

  /// 1..200 characters.
  final String text;

  /// Defaults to "YAMS Hub".
  final String? header;

  /// Defaults to 10000.
  final int? timeoutMs;

  JsonMap toJson() =>
      compactJson({'text': text, 'header': header, 'timeoutMs': timeoutMs});
}

// ---------------------------------------------------------------------------
// Jellyfin library (API.md §14.3)
// ---------------------------------------------------------------------------

/// An item in a Jellyfin row (recently added, continue watching, next up).
@immutable
final class MediaItem {
  const MediaItem({
    required this.id,
    required this.type,
    required this.title,
    this.subtitle,
    this.year,
    this.imagePath,
    this.addedAt,
    this.newEpisodeCount,
    this.progress,
    this.jellyfin,
  });

  factory MediaItem.fromJson(JsonMap j) => MediaItem(
    id: req(readString(j['id']), 'id'),
    type: MediaItemType.fromJson(j['type']),
    title: readString(j['title']) ?? '',
    subtitle: readString(j['subtitle']),
    year: readInt(j['year']),
    imagePath: readString(j['imagePath']),
    addedAt: readInstant(j['addedAt']),
    newEpisodeCount: readInt(j['newEpisodeCount']),
    progress: readDouble(j['progress']),
    jellyfin: _readLink(j['jellyfin']),
  );

  final String id;
  final MediaItemType type;
  final String title;
  final String? subtitle;
  final int? year;

  /// Poster-shaped (2:3) image.
  final String? imagePath;
  final DateTime? addedAt;
  final int? newEpisodeCount;

  /// 0..1 (continue watching).
  final double? progress;
  final ExternalLink? jellyfin;

  JsonMap toJson() => compactJson({
    'id': id,
    'type': type.toJson(),
    'title': title,
    'subtitle': subtitle,
    'year': year,
    'imagePath': imagePath,
    'addedAt': optionalInstantToJson(addedAt),
    'newEpisodeCount': newEpisodeCount,
    'progress': progress,
    'jellyfin': jellyfin?.toJson(),
  });
}

/// `server` of [JellyfinOverview].
@immutable
final class JellyfinServerSummary {
  const JellyfinServerSummary({
    required this.name,
    required this.version,
    this.hwAccel,
  });

  factory JellyfinServerSummary.fromJson(JsonMap j) => JellyfinServerSummary(
    name: readString(j['name']) ?? '',
    version: readString(j['version']) ?? '',
    hwAccel: readString(j['hwAccel']),
  );

  final String name;
  final String version;
  final String? hwAccel;

  JsonMap toJson() =>
      compactJson({'name': name, 'version': version, 'hwAccel': hwAccel});
}

/// `counts` of [JellyfinOverview] (`/Items/Counts`).
@immutable
final class JellyfinCounts {
  const JellyfinCounts({
    this.movies = 0,
    this.series = 0,
    this.episodes = 0,
    this.songs = 0,
    this.albums = 0,
    this.books = 0,
  });

  factory JellyfinCounts.fromJson(JsonMap j) => JellyfinCounts(
    movies: readInt(j['movies']) ?? 0,
    series: readInt(j['series']) ?? 0,
    episodes: readInt(j['episodes']) ?? 0,
    songs: readInt(j['songs']) ?? 0,
    albums: readInt(j['albums']) ?? 0,
    books: readInt(j['books']) ?? 0,
  );

  final int movies;
  final int series;
  final int episodes;
  final int songs;
  final int albums;
  final int books;

  JsonMap toJson() => {
    'movies': movies,
    'series': series,
    'episodes': episodes,
    'songs': songs,
    'albums': albums,
    'books': books,
  };
}

/// `CollectionType` of a Jellyfin library.
enum JellyfinLibraryType {
  movies,
  tvshows,
  music,
  books,
  other,
  unknown;

  static JellyfinLibraryType fromJson(Object? v) =>
      readEnum(v, JellyfinLibraryType.values, JellyfinLibraryType.unknown);

  String toJson() => name;
}

/// One Jellyfin library (`/Library/VirtualFolders` + Jellystat sizes).
@immutable
final class JellyfinLibrary {
  const JellyfinLibrary({
    required this.id,
    required this.name,
    required this.type,
    this.sizeBytes,
    this.files,
    this.itemCount,
    this.refreshing = false,
  });

  factory JellyfinLibrary.fromJson(JsonMap j) => JellyfinLibrary(
    id: req(readString(j['id']), 'id'),
    name: readString(j['name']) ?? '',
    type: JellyfinLibraryType.fromJson(j['type']),
    sizeBytes: readInt(j['sizeBytes']),
    files: readInt(j['files']),
    itemCount: readInt(j['itemCount']),
    refreshing: readBool(j['refreshing']) ?? false,
  );

  final String id;
  final String name;
  final JellyfinLibraryType type;
  final int? sizeBytes;
  final int? files;
  final int? itemCount;

  /// A library scan is running.
  final bool refreshing;

  JsonMap toJson() => compactJson({
    'id': id,
    'name': name,
    'type': type.toJson(),
    'sizeBytes': sizeBytes,
    'files': files,
    'itemCount': itemCount,
    'refreshing': refreshing,
  });
}

/// 200 body of `GET /media/jellyfin`.
@immutable
final class JellyfinOverview {
  const JellyfinOverview({
    required this.server,
    required this.counts,
    this.libraries = const [],
    this.recentlyAdded = const [],
    this.continueWatching = const [],
    this.nextUp = const [],
  });

  factory JellyfinOverview.fromJson(JsonMap j) => JellyfinOverview(
    server: JellyfinServerSummary.fromJson(
      readMap(j['server']) ?? (throw const FormatException('server')),
    ),
    counts: JellyfinCounts.fromJson(readMap(j['counts']) ?? const {}),
    libraries: readList(j['libraries'], JellyfinLibrary.fromJson),
    recentlyAdded: readList(j['recentlyAdded'], MediaItem.fromJson),
    continueWatching: readList(j['continueWatching'], MediaItem.fromJson),
    nextUp: readList(j['nextUp'], MediaItem.fromJson),
  );

  final JellyfinServerSummary server;
  final JellyfinCounts counts;
  final List<JellyfinLibrary> libraries;

  /// At most 16 items, newest first.
  final List<MediaItem> recentlyAdded;

  /// The caller's linked Jellyfin user; empty when unlinked.
  final List<MediaItem> continueWatching;
  final List<MediaItem> nextUp;

  JsonMap toJson() => {
    'server': server.toJson(),
    'counts': counts.toJson(),
    'libraries': [for (final l in libraries) l.toJson()],
    'recentlyAdded': [for (final i in recentlyAdded) i.toJson()],
    'continueWatching': [for (final i in continueWatching) i.toJson()],
    'nextUp': [for (final i in nextUp) i.toJson()],
  };
}

// ---------------------------------------------------------------------------
// Watch statistics (API.md §14.4)
// ---------------------------------------------------------------------------

/// A library in [WatchStats.libraries].
@immutable
final class WatchLibrary {
  const WatchLibrary({required this.id, required this.name});

  factory WatchLibrary.fromJson(JsonMap j) => WatchLibrary(
    id: req(readString(j['id']), 'id'),
    name: readString(j['name']) ?? '',
  );

  final String id;
  final String name;

  JsonMap toJson() => {'id': id, 'name': name};
}

/// One day of [WatchStats.viewsOverTime]; maps are keyed by library id.
@immutable
final class WatchViewsPoint {
  const WatchViewsPoint({
    required this.date,
    this.plays = const {},
    this.durationSeconds = const {},
  });

  factory WatchViewsPoint.fromJson(JsonMap j) => WatchViewsPoint(
    date: req(readString(j['date']), 'date'),
    plays: _readIntMap(j['plays']),
    durationSeconds: _readIntMap(j['durationSeconds']),
  );

  /// `YYYY-MM-DD`.
  final String date;
  final Map<String, int> plays;
  final Map<String, int> durationSeconds;

  int get totalPlays => plays.values.fold(0, (a, b) => a + b);

  JsonMap toJson() => {
    'date': date,
    'plays': plays,
    'durationSeconds': durationSeconds,
  };
}

/// Day of the week in [WatchDayPlays].
enum WatchWeekday {
  monday,
  tuesday,
  wednesday,
  thursday,
  friday,
  saturday,
  sunday,
  unknown;

  static WatchWeekday fromJson(Object? v) =>
      readEnum(v, WatchWeekday.values, WatchWeekday.unknown);

  String toJson() => name;
}

/// Plays on one weekday.
@immutable
final class WatchDayPlays {
  const WatchDayPlays({required this.day, required this.plays});

  factory WatchDayPlays.fromJson(JsonMap j) => WatchDayPlays(
    day: WatchWeekday.fromJson(j['day']),
    plays: readInt(j['plays']) ?? 0,
  );

  final WatchWeekday day;
  final int plays;

  JsonMap toJson() => {'day': day.toJson(), 'plays': plays};
}

/// Plays in one hour of the day (0..23).
@immutable
final class WatchHourPlays {
  const WatchHourPlays({required this.hour, required this.plays});

  factory WatchHourPlays.fromJson(JsonMap j) => WatchHourPlays(
    hour: readInt(j['hour']) ?? 0,
    plays: readInt(j['plays']) ?? 0,
  );

  final int hour;
  final int plays;

  JsonMap toJson() => {'hour': hour, 'plays': plays};
}

/// Plays per play method.
@immutable
final class WatchPlayMethodCount {
  const WatchPlayMethodCount({required this.method, required this.count});

  factory WatchPlayMethodCount.fromJson(JsonMap j) => WatchPlayMethodCount(
    method: MediaPlayMethod.fromJson(j['method']),
    count: readInt(j['count']) ?? 0,
  );

  final MediaPlayMethod method;
  final int count;

  JsonMap toJson() => {'method': method.toJson(), 'count': count};
}

/// A most-viewed movie or series.
@immutable
final class WatchTopItem {
  const WatchTopItem({
    required this.id,
    required this.name,
    required this.plays,
    required this.durationSeconds,
    this.imagePath,
  });

  factory WatchTopItem.fromJson(JsonMap j) => WatchTopItem(
    id: req(readString(j['id']), 'id'),
    name: readString(j['name']) ?? '',
    plays: readInt(j['plays']) ?? 0,
    durationSeconds: readInt(j['durationSeconds']) ?? 0,
    imagePath: readString(j['imagePath']),
  );

  final String id;
  final String name;
  final int plays;
  final int durationSeconds;
  final String? imagePath;

  JsonMap toJson() => compactJson({
    'id': id,
    'name': name,
    'plays': plays,
    'durationSeconds': durationSeconds,
    'imagePath': imagePath,
  });
}

/// A series watched by the most distinct users.
@immutable
final class WatchPopularItem {
  const WatchPopularItem({
    required this.id,
    required this.name,
    required this.uniqueViewers,
    this.imagePath,
  });

  factory WatchPopularItem.fromJson(JsonMap j) => WatchPopularItem(
    id: req(readString(j['id']), 'id'),
    name: readString(j['name']) ?? '',
    uniqueViewers: readInt(j['uniqueViewers']) ?? 0,
    imagePath: readString(j['imagePath']),
  );

  final String id;
  final String name;
  final int uniqueViewers;
  final String? imagePath;

  JsonMap toJson() => compactJson({
    'id': id,
    'name': name,
    'uniqueViewers': uniqueViewers,
    'imagePath': imagePath,
  });
}

/// A most active user.
@immutable
final class WatchTopUser {
  const WatchTopUser({
    required this.userId,
    required this.name,
    required this.plays,
  });

  factory WatchTopUser.fromJson(JsonMap j) => WatchTopUser(
    userId: readString(j['userId']) ?? '',
    name: readString(j['name']) ?? '',
    plays: readInt(j['plays']) ?? 0,
  );

  final String userId;
  final String name;
  final int plays;

  JsonMap toJson() => {'userId': userId, 'name': name, 'plays': plays};
}

/// A most used client.
@immutable
final class WatchTopClient {
  const WatchTopClient({required this.client, required this.plays});

  factory WatchTopClient.fromJson(JsonMap j) => WatchTopClient(
    client: readString(j['client']) ?? '',
    plays: readInt(j['plays']) ?? 0,
  );

  final String client;
  final int plays;

  JsonMap toJson() => {'client': client, 'plays': plays};
}

/// A most viewed library.
@immutable
final class WatchTopLibrary {
  const WatchTopLibrary({
    required this.id,
    required this.name,
    required this.plays,
  });

  factory WatchTopLibrary.fromJson(JsonMap j) => WatchTopLibrary(
    id: readString(j['id']) ?? '',
    name: readString(j['name']) ?? '',
    plays: readInt(j['plays']) ?? 0,
  );

  final String id;
  final String name;
  final int plays;

  JsonMap toJson() => {'id': id, 'name': name, 'plays': plays};
}

/// `totals` of [WatchStats].
@immutable
final class WatchTotals {
  const WatchTotals({this.plays = 0, this.durationSeconds = 0});

  factory WatchTotals.fromJson(JsonMap j) => WatchTotals(
    plays: readInt(j['plays']) ?? 0,
    durationSeconds: readInt(j['durationSeconds']) ?? 0,
  );

  final int plays;
  final int durationSeconds;

  JsonMap toJson() => {'plays': plays, 'durationSeconds': durationSeconds};
}

/// 200 body of `GET /media/stats`.
@immutable
final class WatchStats {
  const WatchStats({
    required this.days,
    this.libraries = const [],
    this.viewsOverTime = const [],
    this.byWeekday = const [],
    this.byHour = const [],
    this.playMethods = const [],
    this.topMovies = const [],
    this.topSeries = const [],
    this.popularSeries = const [],
    this.topUsers = const [],
    this.topClients = const [],
    this.topLibraries = const [],
    this.totals = const WatchTotals(),
    this.partial = false,
  });

  factory WatchStats.fromJson(JsonMap j) => WatchStats(
    days: readInt(j['days']) ?? 30,
    libraries: readList(j['libraries'], WatchLibrary.fromJson),
    viewsOverTime: readList(j['viewsOverTime'], WatchViewsPoint.fromJson),
    byWeekday: readList(j['byWeekday'], WatchDayPlays.fromJson),
    byHour: readList(j['byHour'], WatchHourPlays.fromJson),
    playMethods: readList(j['playMethods'], WatchPlayMethodCount.fromJson),
    topMovies: readList(j['topMovies'], WatchTopItem.fromJson),
    topSeries: readList(j['topSeries'], WatchTopItem.fromJson),
    popularSeries: readList(j['popularSeries'], WatchPopularItem.fromJson),
    topUsers: readList(j['topUsers'], WatchTopUser.fromJson),
    topClients: readList(j['topClients'], WatchTopClient.fromJson),
    topLibraries: readList(j['topLibraries'], WatchTopLibrary.fromJson),
    totals: WatchTotals.fromJson(readMap(j['totals']) ?? const {}),
    partial: readBool(j['partial']) ?? false,
  );

  /// The periods (`days`) `GET /media/stats` accepts.
  static const periods = [7, 30, 90, 365];

  final int days;
  final List<WatchLibrary> libraries;
  final List<WatchViewsPoint> viewsOverTime;

  /// Monday first.
  final List<WatchDayPlays> byWeekday;

  /// Hours 0..23.
  final List<WatchHourPlays> byHour;
  final List<WatchPlayMethodCount> playMethods;
  final List<WatchTopItem> topMovies;
  final List<WatchTopItem> topSeries;
  final List<WatchPopularItem> popularSeries;
  final List<WatchTopUser> topUsers;
  final List<WatchTopClient> topClients;
  final List<WatchTopLibrary> topLibraries;
  final WatchTotals totals;

  /// Some Jellystat queries failed; their parts are empty.
  final bool partial;

  /// Nothing was played in the period.
  bool get isEmpty => totals.plays == 0;

  JsonMap toJson() => compactJson({
    'days': days,
    'libraries': [for (final l in libraries) l.toJson()],
    'viewsOverTime': [for (final p in viewsOverTime) p.toJson()],
    'byWeekday': [for (final d in byWeekday) d.toJson()],
    'byHour': [for (final h in byHour) h.toJson()],
    'playMethods': [for (final m in playMethods) m.toJson()],
    'topMovies': [for (final i in topMovies) i.toJson()],
    'topSeries': [for (final i in topSeries) i.toJson()],
    'popularSeries': [for (final i in popularSeries) i.toJson()],
    'topUsers': [for (final u in topUsers) u.toJson()],
    'topClients': [for (final c in topClients) c.toJson()],
    'topLibraries': [for (final l in topLibraries) l.toJson()],
    'totals': totals.toJson(),
    'partial': partial ? true : null,
  });
}

/// One row of `GET /media/stats/users` (all-time per-user activity).
@immutable
final class WatchUser {
  const WatchUser({
    required this.userId,
    required this.name,
    this.totalPlays = 0,
    this.totalWatchSeconds = 0,
    this.lastSeenAt,
    this.lastWatched,
    this.lastClient,
    this.avatarPath,
  });

  factory WatchUser.fromJson(JsonMap j) => WatchUser(
    userId: req(readString(j['userId']), 'userId'),
    name: readString(j['name']) ?? '',
    totalPlays: readInt(j['totalPlays']) ?? 0,
    totalWatchSeconds: readInt(j['totalWatchSeconds']) ?? 0,
    lastSeenAt: readInstant(j['lastSeenAt']),
    lastWatched: readString(j['lastWatched']),
    lastClient: readString(j['lastClient']),
    avatarPath: readString(j['avatarPath']),
  );

  /// Jellyfin user id.
  final String userId;
  final String name;
  final int totalPlays;
  final int totalWatchSeconds;
  final DateTime? lastSeenAt;

  /// "Series - Episode".
  final String? lastWatched;

  /// "Client - Device".
  final String? lastClient;
  final String? avatarPath;

  JsonMap toJson() => compactJson({
    'userId': userId,
    'name': name,
    'totalPlays': totalPlays,
    'totalWatchSeconds': totalWatchSeconds,
    'lastSeenAt': optionalInstantToJson(lastSeenAt),
    'lastWatched': lastWatched,
    'lastClient': lastClient,
    'avatarPath': avatarPath,
  });
}

/// One row of `GET /media/stats/history` (a Jellystat playback record).
@immutable
final class PlaybackRecord {
  const PlaybackRecord({
    required this.id,
    required this.userName,
    required this.title,
    required this.client,
    required this.device,
    required this.playMethod,
    required this.durationSeconds,
    required this.at,
    this.seriesName,
    this.imagePath,
  });

  factory PlaybackRecord.fromJson(JsonMap j) => PlaybackRecord(
    id: req(readString(j['id']), 'id'),
    userName: readString(j['userName']) ?? '',
    title: readString(j['title']) ?? '',
    seriesName: readString(j['seriesName']),
    client: readString(j['client']) ?? '',
    device: readString(j['device']) ?? '',
    playMethod: MediaPlayMethod.fromJson(j['playMethod']),
    durationSeconds: readInt(j['durationSeconds']) ?? 0,
    at: req(readInstant(j['at']), 'at'),
    imagePath: readString(j['imagePath']),
  );

  final String id;
  final String userName;

  /// The item (episode) name.
  final String title;
  final String? seriesName;
  final String client;
  final String device;
  final MediaPlayMethod playMethod;
  final int durationSeconds;
  final DateTime at;
  final String? imagePath;

  JsonMap toJson() => compactJson({
    'id': id,
    'userName': userName,
    'title': title,
    'seriesName': seriesName,
    'client': client,
    'device': device,
    'playMethod': playMethod.toJson(),
    'durationSeconds': durationSeconds,
    'at': instantToJson(at),
    'imagePath': imagePath,
  });
}

// ---------------------------------------------------------------------------
// Audiobookshelf (API.md §14.5)
// ---------------------------------------------------------------------------

/// `mediaType` of an Audiobookshelf library.
enum AudiobookMediaType {
  book,
  podcast,
  unknown;

  static AudiobookMediaType fromJson(Object? v) =>
      readEnum(v, AudiobookMediaType.values, AudiobookMediaType.unknown);

  String toJson() => name;
}

/// One Audiobookshelf library with its stats.
@immutable
final class AudiobookLibrary {
  const AudiobookLibrary({
    required this.id,
    required this.name,
    required this.mediaType,
    this.items = 0,
    this.authors = 0,
    this.durationSeconds = 0,
    this.sizeBytes = 0,
  });

  factory AudiobookLibrary.fromJson(JsonMap j) => AudiobookLibrary(
    id: req(readString(j['id']), 'id'),
    name: readString(j['name']) ?? '',
    mediaType: AudiobookMediaType.fromJson(j['mediaType']),
    items: readInt(j['items']) ?? 0,
    authors: readInt(j['authors']) ?? 0,
    durationSeconds: readInt(j['durationSeconds']) ?? 0,
    sizeBytes: readInt(j['sizeBytes']) ?? 0,
  );

  final String id;
  final String name;
  final AudiobookMediaType mediaType;
  final int items;
  final int authors;
  final int durationSeconds;
  final int sizeBytes;

  JsonMap toJson() => {
    'id': id,
    'name': name,
    'mediaType': mediaType.toJson(),
    'items': items,
    'authors': authors,
    'durationSeconds': durationSeconds,
    'sizeBytes': sizeBytes,
  };
}

/// A book in progress (continue listening).
@immutable
final class AudiobookProgressItem {
  const AudiobookProgressItem({
    required this.id,
    required this.title,
    required this.coverPath,
    required this.progress,
    required this.currentTimeSeconds,
    required this.durationSeconds,
    required this.link,
    this.author,
    this.narrator,
    this.lastUpdateAt,
  });

  factory AudiobookProgressItem.fromJson(JsonMap j) => AudiobookProgressItem(
    id: req(readString(j['id']), 'id'),
    title: readString(j['title']) ?? '',
    author: readString(j['author']),
    narrator: readString(j['narrator']),
    coverPath: readString(j['coverPath']) ?? '',
    progress: readDouble(j['progress']) ?? 0,
    currentTimeSeconds: readInt(j['currentTimeSeconds']) ?? 0,
    durationSeconds: readInt(j['durationSeconds']) ?? 0,
    lastUpdateAt: readInstant(j['lastUpdateAt']),
    link: _reqLink(j['link'], 'link'),
  );

  final String id;
  final String title;
  final String? author;
  final String? narrator;
  final String coverPath;

  /// 0..1.
  final double progress;
  final int currentTimeSeconds;
  final int durationSeconds;
  final DateTime? lastUpdateAt;
  final ExternalLink link;

  /// Seconds left to listen.
  int get remainingSeconds =>
      (durationSeconds - currentTimeSeconds).clamp(0, durationSeconds);

  JsonMap toJson() => compactJson({
    'id': id,
    'title': title,
    'author': author,
    'narrator': narrator,
    'coverPath': coverPath,
    'progress': progress,
    'currentTimeSeconds': currentTimeSeconds,
    'durationSeconds': durationSeconds,
    'lastUpdateAt': optionalInstantToJson(lastUpdateAt),
    'link': link.toJson(),
  });
}

/// A recently added Audiobookshelf item.
@immutable
final class AudiobookRecentItem {
  const AudiobookRecentItem({
    required this.id,
    required this.title,
    required this.coverPath,
    required this.addedAt,
    required this.link,
    this.author,
    this.durationSeconds,
  });

  factory AudiobookRecentItem.fromJson(JsonMap j) => AudiobookRecentItem(
    id: req(readString(j['id']), 'id'),
    title: readString(j['title']) ?? '',
    author: readString(j['author']),
    coverPath: readString(j['coverPath']) ?? '',
    addedAt: req(readInstant(j['addedAt']), 'addedAt'),
    durationSeconds: readInt(j['durationSeconds']),
    link: _reqLink(j['link'], 'link'),
  );

  final String id;
  final String title;
  final String? author;
  final String coverPath;
  final DateTime addedAt;
  final int? durationSeconds;
  final ExternalLink link;

  JsonMap toJson() => compactJson({
    'id': id,
    'title': title,
    'author': author,
    'coverPath': coverPath,
    'addedAt': instantToJson(addedAt),
    'durationSeconds': durationSeconds,
    'link': link.toJson(),
  });
}

/// Seconds listened on one calendar day.
@immutable
final class AudiobookListeningDay {
  const AudiobookListeningDay({required this.date, required this.seconds});

  factory AudiobookListeningDay.fromJson(JsonMap j) => AudiobookListeningDay(
    date: req(readString(j['date']), 'date'),
    seconds: readInt(j['seconds']) ?? 0,
  );

  /// `YYYY-MM-DD` (server-local day).
  final String date;
  final int seconds;

  JsonMap toJson() => {'date': date, 'seconds': seconds};
}

/// `listening` of [AudiobooksOverview].
@immutable
final class AudiobookListening {
  const AudiobookListening({
    this.todaySeconds = 0,
    this.totalSeconds = 0,
    this.last7Days = const [],
  });

  factory AudiobookListening.fromJson(JsonMap j) => AudiobookListening(
    todaySeconds: readInt(j['todaySeconds']) ?? 0,
    totalSeconds: readInt(j['totalSeconds']) ?? 0,
    last7Days: readList(j['last7Days'], AudiobookListeningDay.fromJson),
  );

  final int todaySeconds;
  final int totalSeconds;

  /// Oldest first, today last.
  final List<AudiobookListeningDay> last7Days;

  JsonMap toJson() => {
    'todaySeconds': todaySeconds,
    'totalSeconds': totalSeconds,
    'last7Days': [for (final d in last7Days) d.toJson()],
  };
}

/// 200 body of `GET /media/audiobooks`.
@immutable
final class AudiobooksOverview {
  const AudiobooksOverview({
    required this.library,
    this.version,
    this.libraries = const [],
    this.continueListening = const [],
    this.recentlyAdded = const [],
    this.listening = const AudiobookListening(),
  });

  factory AudiobooksOverview.fromJson(JsonMap j) => AudiobooksOverview(
    version: readString(j['version']),
    libraries: readList(j['libraries'], AudiobookLibrary.fromJson),
    continueListening: readList(
      j['continueListening'],
      AudiobookProgressItem.fromJson,
    ),
    recentlyAdded: readList(j['recentlyAdded'], AudiobookRecentItem.fromJson),
    listening: AudiobookListening.fromJson(readMap(j['listening']) ?? const {}),
    library: _reqLink(j['library'], 'library'),
  );

  final String? version;
  final List<AudiobookLibrary> libraries;
  final List<AudiobookProgressItem> continueListening;
  final List<AudiobookRecentItem> recentlyAdded;
  final AudiobookListening listening;

  /// The (first) library in the ABS web UI.
  final ExternalLink library;

  int get totalItems => libraries.fold(0, (a, l) => a + l.items);

  JsonMap toJson() => compactJson({
    'version': version,
    'libraries': [for (final l in libraries) l.toJson()],
    'continueListening': [for (final i in continueListening) i.toJson()],
    'recentlyAdded': [for (final i in recentlyAdded) i.toJson()],
    'listening': listening.toJson(),
    'library': library.toJson(),
  });
}

// ---------------------------------------------------------------------------
// Kavita (API.md §14.6)
// ---------------------------------------------------------------------------

/// Whether the gateway can read Kavita with its Auth Key.
enum BooksAuth {
  ok,
  missingKey,
  rejected,
  unknown;

  static BooksAuth fromJson(Object? v) =>
      readEnum(v, BooksAuth.values, BooksAuth.unknown);

  String toJson() => name;
}

/// Kavita library type (`LibraryType` 0..5 mapped by the gateway).
enum BooksLibraryType {
  manga,
  comic,
  book,
  image,
  lightNovel,
  comicVine,
  unknown;

  static BooksLibraryType fromJson(Object? v) =>
      readEnum(v, BooksLibraryType.values, BooksLibraryType.unknown);

  String toJson() => name;
}

/// One Kavita library.
@immutable
final class BooksLibrary {
  const BooksLibrary({
    required this.id,
    required this.name,
    required this.type,
  });

  factory BooksLibrary.fromJson(JsonMap j) => BooksLibrary(
    id: req(readInt(j['id']), 'id'),
    name: readString(j['name']) ?? '',
    type: BooksLibraryType.fromJson(j['type']),
  );

  final int id;
  final String name;
  final BooksLibraryType type;

  JsonMap toJson() => {'id': id, 'name': name, 'type': type.toJson()};
}

/// Kavita server stats.
@immutable
final class BooksStats {
  const BooksStats({
    this.series = 0,
    this.volumes = 0,
    this.chapters = 0,
    this.files = 0,
    this.sizeBytes = 0,
  });

  factory BooksStats.fromJson(JsonMap j) => BooksStats(
    series: readInt(j['series']) ?? 0,
    volumes: readInt(j['volumes']) ?? 0,
    chapters: readInt(j['chapters']) ?? 0,
    files: readInt(j['files']) ?? 0,
    sizeBytes: readInt(j['sizeBytes']) ?? 0,
  );

  final int series;
  final int volumes;
  final int chapters;
  final int files;
  final int sizeBytes;

  JsonMap toJson() => {
    'series': series,
    'volumes': volumes,
    'chapters': chapters,
    'files': files,
    'sizeBytes': sizeBytes,
  };
}

/// Kavita `MangaFormat` mapped by the gateway.
enum BookSeriesFormat {
  image,
  archive,
  epub,
  pdf,
  unknown;

  static BookSeriesFormat fromJson(Object? v) =>
      readEnum(v, BookSeriesFormat.values, BookSeriesFormat.unknown);

  String toJson() => name;
}

/// A Kavita series.
@immutable
final class BookSeries {
  const BookSeries({
    required this.id,
    required this.name,
    required this.libraryId,
    required this.coverPath,
    required this.format,
    required this.link,
    this.libraryName,
    this.pages,
    this.pagesRead,
  });

  factory BookSeries.fromJson(JsonMap j) => BookSeries(
    id: req(readInt(j['id']), 'id'),
    name: readString(j['name']) ?? '',
    libraryId: readInt(j['libraryId']) ?? 0,
    libraryName: readString(j['libraryName']),
    coverPath: readString(j['coverPath']) ?? '',
    pages: readInt(j['pages']),
    pagesRead: readInt(j['pagesRead']),
    format: BookSeriesFormat.fromJson(j['format']),
    link: _reqLink(j['link'], 'link'),
  );

  final int id;
  final String name;
  final int libraryId;
  final String? libraryName;
  final String coverPath;
  final int? pages;
  final int? pagesRead;
  final BookSeriesFormat format;
  final ExternalLink link;

  /// 0..1 when the page counts are known.
  double? get progress {
    final p = pages;
    final r = pagesRead;
    if (p == null || r == null || p <= 0) return null;
    return (r / p).clamp(0, 1).toDouble();
  }

  JsonMap toJson() => compactJson({
    'id': id,
    'name': name,
    'libraryId': libraryId,
    'libraryName': libraryName,
    'coverPath': coverPath,
    'pages': pages,
    'pagesRead': pagesRead,
    'format': format.toJson(),
    'link': link.toJson(),
  });
}

/// 200 body of `GET /media/books`.
@immutable
final class BooksOverview {
  const BooksOverview({
    required this.auth,
    required this.library,
    this.version,
    this.libraries = const [],
    this.stats,
    this.recentlyAdded = const [],
    this.onDeck = const [],
    this.hint,
  });

  factory BooksOverview.fromJson(JsonMap j) => BooksOverview(
    auth: BooksAuth.fromJson(j['auth']),
    version: readString(j['version']),
    libraries: readList(j['libraries'], BooksLibrary.fromJson),
    stats: switch (readMap(j['stats'])) {
      final m? => BooksStats.fromJson(m),
      null => null,
    },
    recentlyAdded: readList(j['recentlyAdded'], BookSeries.fromJson),
    onDeck: readList(j['onDeck'], BookSeries.fromJson),
    hint: readString(j['hint']),
    library: _reqLink(j['library'], 'library'),
  );

  final BooksAuth auth;
  final String? version;
  final List<BooksLibrary> libraries;
  final BooksStats? stats;
  final List<BookSeries> recentlyAdded;
  final List<BookSeries> onDeck;

  /// Set when Kavita found no series (folder layout hint).
  final String? hint;
  final ExternalLink library;

  JsonMap toJson() => compactJson({
    'auth': auth.toJson(),
    'version': version,
    'libraries': [for (final l in libraries) l.toJson()],
    'stats': stats?.toJson(),
    'recentlyAdded': [for (final s in recentlyAdded) s.toJson()],
    'onDeck': [for (final s in onDeck) s.toJson()],
    'hint': hint,
    'library': library.toJson(),
  });
}

// ---------------------------------------------------------------------------
// Shelfmark (API.md §14.7)
// ---------------------------------------------------------------------------

/// Overall Shelfmark state.
enum ShelfmarkServiceState {
  ok,
  degraded,
  down,
  unknown;

  static ShelfmarkServiceState fromJson(Object? v) =>
      readEnum(v, ShelfmarkServiceState.values, ShelfmarkServiceState.unknown);

  String toJson() => name;
}

/// State of Shelfmark's download coordinator.
enum ShelfmarkCoordinator {
  running,
  stopped,
  unknown;

  static ShelfmarkCoordinator fromJson(Object? v) =>
      readEnum(v, ShelfmarkCoordinator.values, ShelfmarkCoordinator.unknown);

  String toJson() => name;
}

/// `queue` of [ShelfmarkStatus].
@immutable
final class ShelfmarkQueue {
  const ShelfmarkQueue({
    this.active = 0,
    this.queued = 0,
    this.awaitingPickup = 0,
  });

  factory ShelfmarkQueue.fromJson(JsonMap j) => ShelfmarkQueue(
    active: readInt(j['active']) ?? 0,
    queued: readInt(j['queued']) ?? 0,
    awaitingPickup: readInt(j['awaitingPickup']) ?? 0,
  );

  final int active;
  final int queued;
  final int awaitingPickup;

  int get total => active + queued + awaitingPickup;

  JsonMap toJson() => {
    'active': active,
    'queued': queued,
    'awaitingPickup': awaitingPickup,
  };
}

/// `requests` of [ShelfmarkStatus].
@immutable
final class ShelfmarkRequests {
  const ShelfmarkRequests({
    this.pending = 0,
    this.delivered = 0,
    this.failed = 0,
    this.cancelled = 0,
    this.rejected = 0,
  });

  factory ShelfmarkRequests.fromJson(JsonMap j) => ShelfmarkRequests(
    pending: readInt(j['pending']) ?? 0,
    delivered: readInt(j['delivered']) ?? 0,
    failed: readInt(j['failed']) ?? 0,
    cancelled: readInt(j['cancelled']) ?? 0,
    rejected: readInt(j['rejected']) ?? 0,
  );

  final int pending;
  final int delivered;
  final int failed;
  final int cancelled;
  final int rejected;

  int get total => pending + delivered + failed + cancelled + rejected;

  JsonMap toJson() => {
    'pending': pending,
    'delivered': delivered,
    'failed': failed,
    'cancelled': cancelled,
    'rejected': rejected,
  };
}

/// `added` of [ShelfmarkStatus].
@immutable
final class ShelfmarkAdded {
  const ShelfmarkAdded({
    this.ebook7d = 0,
    this.ebook30d = 0,
    this.audiobook7d = 0,
    this.audiobook30d = 0,
    this.total7d = 0,
    this.total30d = 0,
  });

  factory ShelfmarkAdded.fromJson(JsonMap j) => ShelfmarkAdded(
    ebook7d: readInt(j['ebook7d']) ?? 0,
    ebook30d: readInt(j['ebook30d']) ?? 0,
    audiobook7d: readInt(j['audiobook7d']) ?? 0,
    audiobook30d: readInt(j['audiobook30d']) ?? 0,
    total7d: readInt(j['total7d']) ?? 0,
    total30d: readInt(j['total30d']) ?? 0,
  );

  final int ebook7d;
  final int ebook30d;
  final int audiobook7d;
  final int audiobook30d;
  final int total7d;
  final int total30d;

  JsonMap toJson() => {
    'ebook7d': ebook7d,
    'ebook30d': ebook30d,
    'audiobook7d': audiobook7d,
    'audiobook30d': audiobook30d,
    'total7d': total7d,
    'total30d': total30d,
  };
}

/// 200 body of `GET /media/shelfmark`.
@immutable
final class ShelfmarkStatus {
  const ShelfmarkStatus({
    required this.status,
    required this.coordinator,
    required this.web,
    this.queue = const ShelfmarkQueue(),
    this.requests = const ShelfmarkRequests(),
    this.added = const ShelfmarkAdded(),
    this.failed7d = 0,
    this.generatedAt,
  });

  factory ShelfmarkStatus.fromJson(JsonMap j) => ShelfmarkStatus(
    status: ShelfmarkServiceState.fromJson(j['status']),
    coordinator: ShelfmarkCoordinator.fromJson(j['coordinator']),
    queue: ShelfmarkQueue.fromJson(readMap(j['queue']) ?? const {}),
    requests: ShelfmarkRequests.fromJson(readMap(j['requests']) ?? const {}),
    added: ShelfmarkAdded.fromJson(readMap(j['added']) ?? const {}),
    failed7d: readInt(j['failed7d']) ?? 0,
    generatedAt: readInstant(j['generatedAt']),
    web: _reqLink(j['web'], 'web'),
  );

  final ShelfmarkServiceState status;
  final ShelfmarkCoordinator coordinator;
  final ShelfmarkQueue queue;
  final ShelfmarkRequests requests;
  final ShelfmarkAdded added;
  final int failed7d;

  /// When Shelfmark computed the counters.
  final DateTime? generatedAt;

  /// Shelfmark's web UI.
  final ExternalLink web;

  /// Every counter is zero (no downloads yet).
  bool get isEmpty =>
      queue.total == 0 &&
      requests.total == 0 &&
      added.total30d == 0 &&
      failed7d == 0;

  JsonMap toJson() => compactJson({
    'status': status.toJson(),
    'coordinator': coordinator.toJson(),
    'queue': queue.toJson(),
    'requests': requests.toJson(),
    'added': added.toJson(),
    'failed7d': failed7d,
    'generatedAt': optionalInstantToJson(generatedAt),
    'web': web.toJson(),
  });
}

// ---------------------------------------------------------------------------
// Launcher and dashboard (API.md §14.8)
// ---------------------------------------------------------------------------

/// The media apps with a rich tile in Media > Apps.
enum MediaAppKind {
  jellyfin,
  audiobookshelf,
  kavita,
  seerr,
  shelfmark,
  unknown;

  static MediaAppKind fromJson(Object? v) =>
      readEnum(v, MediaAppKind.values, MediaAppKind.unknown);

  String toJson() => name;

  /// The launcher app of the same name.
  ExternalApp get externalApp => switch (this) {
    unknown => ExternalApp.unknown,
    _ => ExternalApp.values.byName(name),
  };
}

/// Health of a [MediaApp] (the service's `/health` status).
enum MediaAppStatus {
  up,
  down,
  degraded,
  disabled,
  unknown;

  static MediaAppStatus fromJson(Object? v) =>
      readEnum(v, MediaAppStatus.values, MediaAppStatus.unknown);

  String toJson() => name;
}

/// One rich tile of `GET /media/apps`.
@immutable
final class MediaApp {
  const MediaApp({
    required this.app,
    required this.name,
    required this.status,
    required this.headline,
    required this.web,
    required this.route,
    this.version,
  });

  factory MediaApp.fromJson(JsonMap j) => MediaApp(
    app: MediaAppKind.fromJson(j['app']),
    name: readString(j['name']) ?? '',
    status: MediaAppStatus.fromJson(j['status']),
    version: readString(j['version']),
    headline: readString(j['headline']) ?? '',
    web: _reqLink(j['web'], 'web'),
    route: readString(j['route']) ?? '',
  );

  final MediaAppKind app;
  final String name;
  final MediaAppStatus status;
  final String? version;

  /// "179 movies · 54 shows · 1,694 episodes".
  final String headline;
  final ExternalLink web;

  /// App route with the details (`/media/audiobooks`, `/requests`).
  final String route;

  JsonMap toJson() => compactJson({
    'app': app.toJson(),
    'name': name,
    'status': status.toJson(),
    'version': version,
    'headline': headline,
    'web': web.toJson(),
    'route': route,
  });
}

/// `counts` of [MediaCard].
@immutable
final class MediaCardCounts {
  const MediaCardCounts({this.movies = 0, this.series = 0, this.episodes = 0});

  factory MediaCardCounts.fromJson(JsonMap j) => MediaCardCounts(
    movies: readInt(j['movies']) ?? 0,
    series: readInt(j['series']) ?? 0,
    episodes: readInt(j['episodes']) ?? 0,
  );

  final int movies;
  final int series;
  final int episodes;

  JsonMap toJson() => {
    'movies': movies,
    'series': series,
    'episodes': episodes,
  };
}

/// `audiobooks` of [MediaCard].
@immutable
final class MediaCardAudiobooks {
  const MediaCardAudiobooks({this.items = 0, this.inProgress = 0});

  factory MediaCardAudiobooks.fromJson(JsonMap j) => MediaCardAudiobooks(
    items: readInt(j['items']) ?? 0,
    inProgress: readInt(j['inProgress']) ?? 0,
  );

  final int items;
  final int inProgress;

  JsonMap toJson() => {'items': items, 'inProgress': inProgress};
}

/// `books` of [MediaCard].
@immutable
final class MediaCardBooks {
  const MediaCardBooks({this.series = 0, this.auth = BooksAuth.ok});

  factory MediaCardBooks.fromJson(JsonMap j) => MediaCardBooks(
    series: readInt(j['series']) ?? 0,
    auth: BooksAuth.fromJson(j['auth']),
  );

  final int series;
  final BooksAuth auth;

  JsonMap toJson() => {'series': series, 'auth': auth.toJson()};
}

/// `shelfmark` of [MediaCard].
@immutable
final class MediaCardShelfmark {
  const MediaCardShelfmark({
    this.active = 0,
    this.queued = 0,
    this.failed7d = 0,
  });

  factory MediaCardShelfmark.fromJson(JsonMap j) => MediaCardShelfmark(
    active: readInt(j['active']) ?? 0,
    queued: readInt(j['queued']) ?? 0,
    failed7d: readInt(j['failed7d']) ?? 0,
  );

  final int active;
  final int queued;
  final int failed7d;

  JsonMap toJson() => {
    'active': active,
    'queued': queued,
    'failed7d': failed7d,
  };
}

/// Dashboard card `media` (API.md §14.8).
@immutable
final class MediaCard {
  const MediaCard({
    this.nowPlaying = const [],
    this.transcoding = 0,
    this.counts,
    this.audiobooks,
    this.books,
    this.shelfmark,
    this.recentlyAdded = const [],
  });

  factory MediaCard.fromJson(JsonMap j) => MediaCard(
    nowPlaying: readList(j['nowPlaying'], NowPlayingSession.fromJson),
    transcoding: readInt(j['transcoding']) ?? 0,
    counts: switch (readMap(j['counts'])) {
      final m? => MediaCardCounts.fromJson(m),
      null => null,
    },
    audiobooks: switch (readMap(j['audiobooks'])) {
      final m? => MediaCardAudiobooks.fromJson(m),
      null => null,
    },
    books: switch (readMap(j['books'])) {
      final m? => MediaCardBooks.fromJson(m),
      null => null,
    },
    shelfmark: switch (readMap(j['shelfmark'])) {
      final m? => MediaCardShelfmark.fromJson(m),
      null => null,
    },
    recentlyAdded: readList(j['recentlyAdded'], MediaItem.fromJson),
  );

  /// At most 4 sessions.
  final List<NowPlayingSession> nowPlaying;
  final int transcoding;
  final MediaCardCounts? counts;
  final MediaCardAudiobooks? audiobooks;
  final MediaCardBooks? books;
  final MediaCardShelfmark? shelfmark;

  /// At most 8 items.
  final List<MediaItem> recentlyAdded;

  JsonMap toJson() => compactJson({
    'nowPlaying': [for (final s in nowPlaying) s.toJson()],
    'transcoding': transcoding,
    'counts': counts?.toJson(),
    'audiobooks': audiobooks?.toJson(),
    'books': books?.toJson(),
    'shelfmark': shelfmark?.toJson(),
    'recentlyAdded': [for (final i in recentlyAdded) i.toJson()],
  });
}
