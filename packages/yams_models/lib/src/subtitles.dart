/// Subtitles (Bazarr) DTOs (API.md §12).
library;

import 'package:meta/meta.dart';

import 'json.dart';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Whether a subtitle record belongs to an episode or a movie.
enum SubtitleMediaType {
  episode,
  movie,
  unknown;

  static SubtitleMediaType fromJson(Object? v) =>
      readEnum(v, SubtitleMediaType.values, SubtitleMediaType.unknown);

  String toJson() => name;
}

/// The two Bazarr lists (`type=` of `GET /subtitles/wanted|history`, body of
/// `POST /subtitles/search-all`).
enum SubtitleListType {
  episodes,
  movies,
  unknown;

  static SubtitleListType fromJson(Object? v) =>
      readEnum(v, SubtitleListType.values, SubtitleListType.unknown);

  String toJson() => name;
}

/// What happened in a [SubtitleHistoryItem] (Bazarr action codes 0..7 are
/// mapped by the gateway).
enum SubtitleHistoryAction {
  deleted,
  downloaded,
  manual,
  upgraded,
  uploaded,
  synced,
  translated,
  extracted,
  unknown;

  static SubtitleHistoryAction fromJson(Object? v) =>
      readEnum(v, SubtitleHistoryAction.values, SubtitleHistoryAction.unknown);

  String toJson() => name;
}

/// State of Bazarr's SignalR link to Sonarr or Radarr.
enum SubtitleSignalrState {
  live,
  down,
  unknown;

  static SubtitleSignalrState fromJson(Object? v) =>
      readEnum(v, SubtitleSignalrState.values, SubtitleSignalrState.unknown);

  String toJson() => name;
}

// ---------------------------------------------------------------------------
// Items
// ---------------------------------------------------------------------------

/// A subtitle language, e.g. `{"code": "en", "name": "English", "forced":
/// false, "hi": false}`.
@immutable
final class SubtitleLanguage {
  const SubtitleLanguage({
    required this.code,
    required this.name,
    this.forced = false,
    this.hi = false,
  });

  factory SubtitleLanguage.fromJson(JsonMap j) => SubtitleLanguage(
    code: req(readString(j['code']), 'code'),
    name: readString(j['name']) ?? readString(j['code']) ?? '',
    forced: readBool(j['forced']) ?? false,
    hi: readBool(j['hi']) ?? false,
  );

  /// ISO 639-1 style code as Bazarr uses it (`en`, `pb`, ...).
  final String code;
  final String name;

  /// Forced (foreign parts only) subtitles.
  final bool forced;

  /// Hearing impaired subtitles.
  final bool hi;

  JsonMap toJson() => {'code': code, 'name': name, 'forced': forced, 'hi': hi};

  @override
  bool operator ==(Object other) =>
      other is SubtitleLanguage &&
      other.code == code &&
      other.name == name &&
      other.forced == forced &&
      other.hi == hi;

  @override
  int get hashCode => Object.hash(code, name, forced, hi);

  @override
  String toString() =>
      'SubtitleLanguage($code${forced ? ', forced' : ''}${hi ? ', hi' : ''})';
}

/// An episode or movie with missing subtitles.
@immutable
final class WantedSubtitle {
  const WantedSubtitle({
    required this.type,
    required this.title,
    this.episodeLabel,
    this.episodeTitle,
    this.seriesId,
    this.episodeId,
    this.movieId,
    this.missing = const [],
    this.posterPath,
    this.seriesType,
  });

  factory WantedSubtitle.fromJson(JsonMap j) => WantedSubtitle(
    type: SubtitleMediaType.fromJson(j['type']),
    title: req(readString(j['title']), 'title'),
    episodeLabel: readString(j['episodeLabel']),
    episodeTitle: readString(j['episodeTitle']),
    seriesId: readInt(j['seriesId']),
    episodeId: readInt(j['episodeId']),
    movieId: readInt(j['movieId']),
    missing: readList(j['missing'], SubtitleLanguage.fromJson),
    posterPath: readString(j['posterPath']),
    seriesType: readString(j['seriesType']),
  );

  final SubtitleMediaType type;

  /// Series or movie title.
  final String title;

  /// `S01E11` (episodes only).
  final String? episodeLabel;
  final String? episodeTitle;

  /// Sonarr series id (episodes).
  final int? seriesId;

  /// Sonarr episode id (episodes).
  final int? episodeId;

  /// Radarr movie id (movies).
  final int? movieId;
  final List<SubtitleLanguage> missing;

  /// Sonarr/Radarr poster through `/img/arr`.
  final String? posterPath;

  /// `anime`, `standard`, `daily` (episodes).
  final String? seriesType;

  /// A key that identifies this item across pages (`episode:7941`,
  /// `movie:190`).
  String get key => switch (type) {
    SubtitleMediaType.episode => 'episode:${episodeId ?? '?'}',
    SubtitleMediaType.movie => 'movie:${movieId ?? '?'}',
    SubtitleMediaType.unknown => 'unknown:$title',
  };

  JsonMap toJson() => compactJson({
    'type': type.toJson(),
    'title': title,
    'episodeLabel': episodeLabel,
    'episodeTitle': episodeTitle,
    'seriesId': seriesId,
    'episodeId': episodeId,
    'movieId': movieId,
    'missing': [for (final l in missing) l.toJson()],
    'posterPath': posterPath,
    'seriesType': seriesType,
  });
}

/// One entry of Bazarr's subtitle history.
@immutable
final class SubtitleHistoryItem {
  const SubtitleHistoryItem({
    required this.type,
    required this.title,
    required this.action,
    this.episodeLabel,
    this.language,
    this.provider,
    this.score,
    this.description,
    this.at,
  });

  factory SubtitleHistoryItem.fromJson(JsonMap j) => SubtitleHistoryItem(
    type: SubtitleMediaType.fromJson(j['type']),
    title: req(readString(j['title']), 'title'),
    episodeLabel: readString(j['episodeLabel']),
    action: SubtitleHistoryAction.fromJson(j['action']),
    language: switch (readMap(j['language'])) {
      final m? => SubtitleLanguage.fromJson(m),
      null => null,
    },
    provider: readString(j['provider']),
    score: readString(j['score']),
    description: readString(j['description']),
    at: readInstant(j['at']),
  );

  final SubtitleMediaType type;
  final String title;
  final String? episodeLabel;
  final SubtitleHistoryAction action;
  final SubtitleLanguage? language;
  final String? provider;

  /// As Bazarr formats it, e.g. `100.0%`.
  final String? score;
  final String? description;
  final DateTime? at;

  JsonMap toJson() => compactJson({
    'type': type.toJson(),
    'title': title,
    'episodeLabel': episodeLabel,
    'action': action.toJson(),
    'language': language?.toJson(),
    'provider': provider,
    'score': score,
    'description': description,
    'at': optionalInstantToJson(at),
  });
}

// ---------------------------------------------------------------------------
// Summary (GET /subtitles/summary)
// ---------------------------------------------------------------------------

/// A subtitle provider and whether it is throttled.
@immutable
final class SubtitleProvider {
  const SubtitleProvider({
    required this.name,
    required this.status,
    this.retry,
    required this.ok,
  });

  factory SubtitleProvider.fromJson(JsonMap j) => SubtitleProvider(
    name: req(readString(j['name']), 'name'),
    status: readString(j['status']) ?? '',
    retry: readString(j['retry']),
    ok: readBool(j['ok']) ?? false,
  );

  final String name;

  /// `Good`, or the throttle reason.
  final String status;

  /// When a throttled provider is retried (humanised, as Bazarr sends it).
  final String? retry;

  /// The provider is not throttled.
  final bool ok;

  JsonMap toJson() =>
      compactJson({'name': name, 'status': status, 'retry': retry, 'ok': ok});
}

/// Bazarr's SignalR links to Sonarr and Radarr.
@immutable
final class SubtitleSignalr {
  const SubtitleSignalr({required this.sonarr, required this.radarr});

  factory SubtitleSignalr.fromJson(JsonMap j) => SubtitleSignalr(
    sonarr: SubtitleSignalrState.fromJson(j['sonarr']),
    radarr: SubtitleSignalrState.fromJson(j['radarr']),
  );

  final SubtitleSignalrState sonarr;
  final SubtitleSignalrState radarr;

  /// Either link is not live.
  bool get anyDown =>
      sonarr != SubtitleSignalrState.live ||
      radarr != SubtitleSignalrState.live;

  JsonMap toJson() => {'sonarr': sonarr.toJson(), 'radarr': radarr.toJson()};
}

/// A Bazarr health issue.
@immutable
final class SubtitleHealthIssue {
  const SubtitleHealthIssue({required this.object, required this.issue});

  factory SubtitleHealthIssue.fromJson(JsonMap j) => SubtitleHealthIssue(
    object: readString(j['object']) ?? '',
    issue: readString(j['issue']) ?? '',
  );

  final String object;
  final String issue;

  JsonMap toJson() => {'object': object, 'issue': issue};
}

/// A Bazarr scheduled task. [interval] and [nextRun] are humanised English
/// strings ("every 6 hours", "in 3 hours"): display them as-is.
@immutable
final class SubtitleTask {
  const SubtitleTask({
    required this.id,
    required this.name,
    required this.interval,
    required this.nextRun,
    required this.running,
  });

  factory SubtitleTask.fromJson(JsonMap j) => SubtitleTask(
    id: req(readString(j['id']), 'id'),
    name: readString(j['name']) ?? readString(j['id']) ?? '',
    interval: readString(j['interval']) ?? '',
    nextRun: readString(j['nextRun']) ?? '',
    running: readBool(j['running']) ?? false,
  );

  final String id;
  final String name;
  final String interval;
  final String nextRun;
  final bool running;

  JsonMap toJson() => {
    'id': id,
    'name': name,
    'interval': interval,
    'nextRun': nextRun,
    'running': running,
  };
}

/// Header of the Subtitles screen.
@immutable
final class SubtitlesSummary {
  const SubtitlesSummary({
    required this.missingEpisodes,
    required this.missingMovies,
    required this.throttledProviders,
    this.providers = const [],
    required this.signalr,
    this.health = const [],
    this.version,
    this.tasks = const [],
  });

  factory SubtitlesSummary.fromJson(JsonMap j) => SubtitlesSummary(
    missingEpisodes: readInt(j['missingEpisodes']) ?? 0,
    missingMovies: readInt(j['missingMovies']) ?? 0,
    throttledProviders: readInt(j['throttledProviders']) ?? 0,
    providers: readList(j['providers'], SubtitleProvider.fromJson),
    signalr: SubtitleSignalr.fromJson(readMap(j['signalr']) ?? const {}),
    health: readList(j['health'], SubtitleHealthIssue.fromJson),
    version: readString(j['version']),
    tasks: readList(j['tasks'], SubtitleTask.fromJson),
  );

  final int missingEpisodes;
  final int missingMovies;

  /// Providers whose status is not `Good` (not Bazarr's badge, API.md
  /// §12.5).
  final int throttledProviders;
  final List<SubtitleProvider> providers;
  final SubtitleSignalr signalr;
  final List<SubtitleHealthIssue> health;

  /// Bazarr version, e.g. `1.6.2`.
  final String? version;
  final List<SubtitleTask> tasks;

  JsonMap toJson() => compactJson({
    'missingEpisodes': missingEpisodes,
    'missingMovies': missingMovies,
    'throttledProviders': throttledProviders,
    'providers': [for (final p in providers) p.toJson()],
    'signalr': signalr.toJson(),
    'health': [for (final h in health) h.toJson()],
    'version': version,
    'tasks': [for (final t in tasks) t.toJson()],
  });
}

// ---------------------------------------------------------------------------
// Jobs (GET /subtitles/jobs)
// ---------------------------------------------------------------------------

/// An entry of Bazarr's job queue (searches triggered by the hub run here).
@immutable
final class SubtitleJob {
  const SubtitleJob({
    required this.id,
    required this.name,
    required this.status,
    this.progress,
    this.message,
    this.lastRunAt,
  });

  factory SubtitleJob.fromJson(JsonMap j) => SubtitleJob(
    id: req(readInt(j['id']), 'id'),
    name: readString(j['name']) ?? '',
    status: readString(j['status']) ?? 'unknown',
    progress: readDouble(j['progress']),
    message: readString(j['message']),
    lastRunAt: readInstant(j['lastRunAt']),
  );

  final int id;
  final String name;

  /// `pending`, `running`, `failed` or `completed`.
  final String status;

  /// 0..1 when Bazarr reports progress.
  final double? progress;
  final String? message;
  final DateTime? lastRunAt;

  /// Queued or running.
  bool get isActive => status == 'running' || status == 'pending';

  JsonMap toJson() => compactJson({
    'id': id,
    'name': name,
    'status': status,
    'progress': progress,
    'message': message,
    'lastRunAt': optionalInstantToJson(lastRunAt),
  });
}

// ---------------------------------------------------------------------------
// Writes
// ---------------------------------------------------------------------------

/// Body of `POST /subtitles/search`: search one missing language of an
/// episode (`seriesId` + `episodeId`) or a movie (`movieId`).
@immutable
final class SubtitleSearchRequest {
  const SubtitleSearchRequest({
    required this.type,
    this.seriesId,
    this.episodeId,
    this.movieId,
    required this.language,
    this.forced = false,
    this.hi = false,
  });

  /// The request for one missing [language] of [item].
  factory SubtitleSearchRequest.forWanted(
    WantedSubtitle item,
    SubtitleLanguage language,
  ) => SubtitleSearchRequest(
    type: item.type,
    seriesId: item.seriesId,
    episodeId: item.episodeId,
    movieId: item.movieId,
    language: language.code,
    forced: language.forced,
    hi: language.hi,
  );

  factory SubtitleSearchRequest.fromJson(JsonMap j) => SubtitleSearchRequest(
    type: SubtitleMediaType.fromJson(j['type']),
    seriesId: readInt(j['seriesId']),
    episodeId: readInt(j['episodeId']),
    movieId: readInt(j['movieId']),
    language: readString(j['language']) ?? '',
    forced: readBool(j['forced']) ?? false,
    hi: readBool(j['hi']) ?? false,
  );

  final SubtitleMediaType type;
  final int? seriesId;
  final int? episodeId;
  final int? movieId;

  /// Language code from the wanted entry (`en`).
  final String language;
  final bool forced;
  final bool hi;

  JsonMap toJson() => compactJson({
    'type': type.toJson(),
    'seriesId': seriesId,
    'episodeId': episodeId,
    'movieId': movieId,
    'language': language,
    'forced': forced,
    'hi': hi,
  });
}

// ---------------------------------------------------------------------------
// Dashboard card (API.md §12.6)
// ---------------------------------------------------------------------------

/// The `subtitles` dashboard card. `missingEpisodes` is also read raw by the
/// app shell (API.md §4).
@immutable
final class SubtitlesCard {
  const SubtitlesCard({
    required this.missingEpisodes,
    required this.missingMovies,
    required this.throttledProviders,
    required this.signalrDown,
  });

  factory SubtitlesCard.fromJson(JsonMap j) => SubtitlesCard(
    missingEpisodes: readInt(j['missingEpisodes']) ?? 0,
    missingMovies: readInt(j['missingMovies']) ?? 0,
    throttledProviders: readInt(j['throttledProviders']) ?? 0,
    signalrDown: readBool(j['signalrDown']) ?? false,
  );

  final int missingEpisodes;
  final int missingMovies;
  final int throttledProviders;
  final bool signalrDown;

  JsonMap toJson() => {
    'missingEpisodes': missingEpisodes,
    'missingMovies': missingMovies,
    'throttledProviders': throttledProviders,
    'signalrDown': signalrDown,
  };
}
