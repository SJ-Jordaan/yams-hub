/// Requests feature DTOs: Seerr discover, search, titles, requests and issues
/// (API.md §6).
library;

import 'package:meta/meta.dart';

import 'common.dart';
import 'json.dart';

// ---------------------------------------------------------------------------
// Enums (API.md §6.1, §6.6)
// ---------------------------------------------------------------------------

/// A TMDB title kind.
enum MediaType {
  movie,
  tv,
  unknown;

  static MediaType fromJson(Object? v) =>
      readEnum(v, MediaType.values, MediaType.unknown);

  String toJson() => name;
}

/// Seerr's media status of a title or season.
enum Availability {
  /// Not requested and not tracked (Seerr 1, or no media row).
  none,
  pending,
  processing,
  partial,
  available,
  blocklisted,
  deleted,
  unknown;

  static Availability fromJson(Object? v) =>
      readEnum(v, Availability.values, Availability.unknown);

  String toJson() => name;
}

/// Seerr's status of a request (and of a season inside a request).
enum RequestStatus {
  pending,
  approved,
  declined,
  failed,
  completed,
  unknown;

  static RequestStatus fromJson(Object? v) =>
      readEnum(v, RequestStatus.values, RequestStatus.unknown);

  /// Like [fromJson] but null for a missing value.
  static RequestStatus? fromJsonOrNull(Object? v) =>
      v == null ? null : fromJson(v);

  String toJson() => name;
}

/// The kind of problem an [Issue] reports.
enum IssueType {
  video,
  audio,
  subtitles,
  other,
  unknown;

  static IssueType fromJson(Object? v) =>
      readEnum(v, IssueType.values, IssueType.unknown);

  String toJson() => name;
}

/// Whether an [Issue] is still open.
enum IssueStatus {
  open,
  resolved,
  unknown;

  static IssueStatus fromJson(Object? v) =>
      readEnum(v, IssueStatus.values, IssueStatus.unknown);

  String toJson() => name;
}

/// Why a title cannot be requested ([RequestEligibility.reason]).
enum RequestEligibilityReason {
  available,
  alreadyRequested,
  blocklisted,
  notLinked,
  unknown;

  static RequestEligibilityReason? fromJsonOrNull(Object? v) => v == null
      ? null
      : readEnum(
          v,
          RequestEligibilityReason.values,
          RequestEligibilityReason.unknown,
        );

  String toJson() => name;
}

/// The result of `POST /requests` ([CreateRequestResult.outcome]).
enum CreateRequestOutcome {
  /// Created and waiting for approval.
  created,

  /// Created and approved straight away (sent to Sonarr/Radarr).
  autoApproved,

  /// Every requested season is already requested or available.
  nothingToRequest,
  unknown;

  static CreateRequestOutcome fromJson(Object? v) =>
      readEnum(v, CreateRequestOutcome.values, CreateRequestOutcome.unknown);

  String toJson() => name;
}

/// How a streaming provider offers a title.
enum RequestsWatchProviderType {
  flatrate,
  rent,
  buy,
  unknown;

  static RequestsWatchProviderType fromJson(Object? v) => readEnum(
    v,
    RequestsWatchProviderType.values,
    RequestsWatchProviderType.unknown,
  );

  String toJson() => name;
}

// ---------------------------------------------------------------------------
// Discover and search (API.md §6.2)
// ---------------------------------------------------------------------------

/// One title in a discover carousel or search result.
@immutable
final class TitleCard {
  const TitleCard({
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    this.year,
    this.releaseDate,
    this.overview,
    this.posterPath,
    this.backdropPath,
    this.voteAverage,
    this.availability = Availability.none,
    this.requested = false,
  });

  factory TitleCard.fromJson(JsonMap j) => TitleCard(
    mediaType: MediaType.fromJson(j['mediaType']),
    tmdbId: req(readInt(j['tmdbId']), 'tmdbId'),
    title: readString(j['title']) ?? '',
    year: readInt(j['year']),
    releaseDate: readString(j['releaseDate']),
    overview: readString(j['overview']),
    posterPath: readString(j['posterPath']),
    backdropPath: readString(j['backdropPath']),
    voteAverage: readDouble(j['voteAverage']),
    availability: Availability.fromJson(j['availability'] ?? 'none'),
    requested: readBool(j['requested']) ?? false,
  );

  final MediaType mediaType;
  final int tmdbId;
  final String title;
  final int? year;

  /// `YYYY-MM-DD` (release date, or first air date for series).
  final String? releaseDate;
  final String? overview;
  final String? posterPath;
  final String? backdropPath;
  final double? voteAverage;
  final Availability availability;

  /// A request exists (Seerr status pending or processing).
  final bool requested;

  JsonMap toJson() => compactJson({
    'mediaType': mediaType.toJson(),
    'tmdbId': tmdbId,
    'title': title,
    'year': year,
    'releaseDate': releaseDate,
    'overview': overview,
    'posterPath': posterPath,
    'backdropPath': backdropPath,
    'voteAverage': voteAverage,
    'availability': availability.toJson(),
    'requested': requested,
  });
}

/// A page of [TitleCard]s (`totalPages` is clamped to 500).
@immutable
final class TitlePage {
  const TitlePage({
    required this.page,
    required this.totalPages,
    required this.totalResults,
    required this.items,
  });

  /// The empty page (unlinked members' watchlist).
  const TitlePage.empty()
    : page = 1,
      totalPages = 0,
      totalResults = 0,
      items = const [];

  factory TitlePage.fromJson(JsonMap j) => TitlePage(
    page: readInt(j['page']) ?? 1,
    totalPages: readInt(j['totalPages']) ?? 0,
    totalResults: readInt(j['totalResults']) ?? 0,
    items: readList(j['items'], TitleCard.fromJson),
  );

  final int page;
  final int totalPages;
  final int totalResults;
  final List<TitleCard> items;

  bool get hasMore => page < totalPages;

  JsonMap toJson() => {
    'page': page,
    'totalPages': totalPages,
    'totalResults': totalResults,
    'items': [for (final i in items) i.toJson()],
  };
}

/// A TMDB genre.
@immutable
final class Genre {
  const Genre({required this.id, required this.name});

  factory Genre.fromJson(JsonMap j) =>
      Genre(id: req(readInt(j['id']), 'id'), name: readString(j['name']) ?? '');

  final int id;
  final String name;

  JsonMap toJson() => {'id': id, 'name': name};
}

// ---------------------------------------------------------------------------
// Requests (API.md §6.1, §6.4, §6.5)
// ---------------------------------------------------------------------------

/// A Seerr user as shown next to a request.
@immutable
final class RequestUser {
  const RequestUser({
    required this.id,
    required this.displayName,
    this.avatarPath,
  });

  factory RequestUser.fromJson(JsonMap j) => RequestUser(
    id: req(readInt(j['id']), 'id'),
    displayName: readString(j['displayName']) ?? '',
    avatarPath: readString(j['avatarPath']),
  );

  /// Seerr user id.
  final int id;
  final String displayName;
  final String? avatarPath;

  JsonMap toJson() => compactJson({
    'id': id,
    'displayName': displayName,
    'avatarPath': avatarPath,
  });
}

/// One season of a request.
@immutable
final class RequestSeason {
  const RequestSeason({required this.seasonNumber, required this.status});

  factory RequestSeason.fromJson(JsonMap j) => RequestSeason(
    seasonNumber: req(readInt(j['seasonNumber']), 'seasonNumber'),
    status: RequestStatus.fromJson(j['status']),
  );

  final int seasonNumber;
  final RequestStatus status;

  JsonMap toJson() => {'seasonNumber': seasonNumber, 'status': status.toJson()};
}

/// A download Seerr tracks for a title (`progress` 0..1).
@immutable
final class RequestDownloadProgress {
  const RequestDownloadProgress({
    required this.title,
    required this.progress,
    required this.status,
    this.etaSeconds,
  });

  factory RequestDownloadProgress.fromJson(JsonMap j) =>
      RequestDownloadProgress(
        title: readString(j['title']) ?? '',
        progress: readDouble(j['progress']) ?? 0,
        etaSeconds: readInt(j['etaSeconds']),
        status: readString(j['status']) ?? '',
      );

  final String title;
  final double progress;
  final int? etaSeconds;
  final String status;

  JsonMap toJson() => compactJson({
    'title': title,
    'progress': progress,
    'etaSeconds': etaSeconds,
    'status': status,
  });
}

/// A Seerr request joined with its title.
@immutable
final class RequestSummary {
  const RequestSummary({
    required this.id,
    required this.status,
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    required this.requestedBy,
    required this.createdAt,
    required this.updatedAt,
    this.year,
    this.posterPath,
    this.seasons = const [],
    this.availability = Availability.none,
    this.modifiedBy,
    this.profileName,
    this.downloads = const [],
    this.jellyfin,
    this.seerrMediaId,
    this.libraryId,
    this.canApprove = false,
    this.canDecline = false,
    this.canRetry = false,
    this.canDelete = false,
  });

  factory RequestSummary.fromJson(JsonMap j) => RequestSummary(
    id: req(readInt(j['id']), 'id'),
    status: RequestStatus.fromJson(j['status']),
    mediaType: MediaType.fromJson(j['mediaType']),
    tmdbId: req(readInt(j['tmdbId']), 'tmdbId'),
    title: readString(j['title']) ?? '',
    year: readInt(j['year']),
    posterPath: readString(j['posterPath']),
    seasons: readList(j['seasons'], RequestSeason.fromJson),
    availability: Availability.fromJson(j['availability'] ?? 'none'),
    requestedBy: RequestUser.fromJson(
      readMap(j['requestedBy']) ?? (throw const FormatException('requestedBy')),
    ),
    modifiedBy: switch (readMap(j['modifiedBy'])) {
      final m? => RequestUser.fromJson(m),
      null => null,
    },
    createdAt: req(readInstant(j['createdAt']), 'createdAt'),
    updatedAt: req(readInstant(j['updatedAt']), 'updatedAt'),
    profileName: readString(j['profileName']),
    downloads: readList(j['downloads'], RequestDownloadProgress.fromJson),
    jellyfin: switch (readMap(j['jellyfin'])) {
      final m? => ExternalLink.fromJson(m),
      null => null,
    },
    seerrMediaId: readInt(j['seerrMediaId']),
    libraryId: readInt(j['libraryId']),
    canApprove: readBool(j['canApprove']) ?? false,
    canDecline: readBool(j['canDecline']) ?? false,
    canRetry: readBool(j['canRetry']) ?? false,
    canDelete: readBool(j['canDelete']) ?? false,
  );

  final int id;
  final RequestStatus status;
  final MediaType mediaType;
  final int tmdbId;
  final String title;
  final int? year;
  final String? posterPath;
  final List<RequestSeason> seasons;
  final Availability availability;
  final RequestUser requestedBy;
  final RequestUser? modifiedBy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? profileName;
  final List<RequestDownloadProgress> downloads;

  /// "Play in Jellyfin" once the title is in the library.
  final ExternalLink? jellyfin;

  /// Seerr's media id (`media.id`).
  final int? seerrMediaId;

  /// Sonarr series id (tv) or Radarr movie id (movie), once the *arr has it.
  final int? libraryId;
  final bool canApprove;
  final bool canDecline;
  final bool canRetry;
  final bool canDelete;

  JsonMap toJson() => compactJson({
    'id': id,
    'status': status.toJson(),
    'mediaType': mediaType.toJson(),
    'tmdbId': tmdbId,
    'title': title,
    'year': year,
    'posterPath': posterPath,
    'seasons': [for (final s in seasons) s.toJson()],
    'availability': availability.toJson(),
    'requestedBy': requestedBy.toJson(),
    'modifiedBy': modifiedBy?.toJson(),
    'createdAt': instantToJson(createdAt),
    'updatedAt': instantToJson(updatedAt),
    'profileName': profileName,
    'downloads': [for (final d in downloads) d.toJson()],
    'jellyfin': jellyfin?.toJson(),
    'seerrMediaId': seerrMediaId,
    'libraryId': libraryId,
    'canApprove': canApprove,
    'canDecline': canDecline,
    'canRetry': canRetry,
    'canDelete': canDelete,
  });
}

/// Admin overrides of a request (server, quality profile, root folder).
/// Omitted fields keep Seerr's defaults; `serverId` 0 is valid.
@immutable
final class CreateRequestAdvanced {
  const CreateRequestAdvanced({this.serverId, this.profileId, this.rootFolder});

  factory CreateRequestAdvanced.fromJson(JsonMap j) => CreateRequestAdvanced(
    serverId: readInt(j['serverId']),
    profileId: readInt(j['profileId']),
    rootFolder: readString(j['rootFolder']),
  );

  final int? serverId;
  final int? profileId;
  final String? rootFolder;

  bool get isEmpty =>
      serverId == null && profileId == null && rootFolder == null;

  JsonMap toJson() => compactJson({
    'serverId': serverId,
    'profileId': profileId,
    'rootFolder': rootFolder,
  });
}

/// Body of `POST /requests`. For tv, either [seasons] or [allSeasons].
@immutable
final class CreateRequest {
  const CreateRequest({
    required this.mediaType,
    required this.tmdbId,
    this.seasons,
    this.allSeasons = false,
    this.advanced,
  });

  /// Parses the body; `seasons` is an int array or the string `"all"`.
  factory CreateRequest.fromJson(JsonMap j) {
    final s = j['seasons'];
    return CreateRequest(
      mediaType: MediaType.fromJson(j['mediaType']),
      tmdbId: req(readInt(j['tmdbId']), 'tmdbId'),
      seasons: s is List ? readIntList(s) : null,
      allSeasons: s == 'all',
      advanced: switch (readMap(j['advanced'])) {
        final m? => CreateRequestAdvanced.fromJson(m),
        null => null,
      },
    );
  }

  final MediaType mediaType;
  final int tmdbId;

  /// Season numbers (tv only).
  final List<int>? seasons;

  /// Request every season (`"seasons": "all"`).
  final bool allSeasons;
  final CreateRequestAdvanced? advanced;

  JsonMap toJson() => compactJson({
    'mediaType': mediaType.toJson(),
    'tmdbId': tmdbId,
    'seasons': allSeasons ? 'all' : seasons,
    'advanced': advanced?.toJson(),
  });
}

/// Answer of `POST /requests`: [request] is absent for
/// [CreateRequestOutcome.nothingToRequest].
@immutable
final class CreateRequestResult {
  const CreateRequestResult({required this.outcome, this.request});

  factory CreateRequestResult.fromJson(JsonMap j) => CreateRequestResult(
    outcome: CreateRequestOutcome.fromJson(j['outcome']),
    request: switch (readMap(j['request'])) {
      final m? => RequestSummary.fromJson(m),
      null => null,
    },
  );

  final CreateRequestOutcome outcome;
  final RequestSummary? request;

  JsonMap toJson() =>
      compactJson({'outcome': outcome.toJson(), 'request': request?.toJson()});
}

/// Body of `PUT /requests/{id}` (edit a pending request).
@immutable
final class RequestUpdate {
  const RequestUpdate({this.seasons, this.advanced});

  factory RequestUpdate.fromJson(JsonMap j) => RequestUpdate(
    seasons: j['seasons'] is List ? readIntList(j['seasons']) : null,
    advanced: switch (readMap(j['advanced'])) {
      final m? => CreateRequestAdvanced.fromJson(m),
      null => null,
    },
  );

  final List<int>? seasons;
  final CreateRequestAdvanced? advanced;

  JsonMap toJson() =>
      compactJson({'seasons': seasons, 'advanced': advanced?.toJson()});
}

/// Global request counters (`failed` is derived by the gateway).
@immutable
final class RequestCounts {
  const RequestCounts({
    this.total = 0,
    this.movie = 0,
    this.tv = 0,
    this.pending = 0,
    this.approved = 0,
    this.processing = 0,
    this.available = 0,
    this.declined = 0,
    this.completed = 0,
    this.failed = 0,
  });

  factory RequestCounts.fromJson(JsonMap j) => RequestCounts(
    total: readInt(j['total']) ?? 0,
    movie: readInt(j['movie']) ?? 0,
    tv: readInt(j['tv']) ?? 0,
    pending: readInt(j['pending']) ?? 0,
    approved: readInt(j['approved']) ?? 0,
    processing: readInt(j['processing']) ?? 0,
    available: readInt(j['available']) ?? 0,
    declined: readInt(j['declined']) ?? 0,
    completed: readInt(j['completed']) ?? 0,
    failed: readInt(j['failed']) ?? 0,
  );

  final int total;
  final int movie;
  final int tv;
  final int pending;
  final int approved;

  /// Approved requests whose media is not available yet.
  final int processing;

  /// Approved requests whose media is available.
  final int available;
  final int declined;
  final int completed;
  final int failed;

  JsonMap toJson() => {
    'total': total,
    'movie': movie,
    'tv': tv,
    'pending': pending,
    'approved': approved,
    'processing': processing,
    'available': available,
    'declined': declined,
    'completed': completed,
    'failed': failed,
  };
}

/// A quality profile of a Radarr/Sonarr server.
@immutable
final class RequestOptionsProfile {
  const RequestOptionsProfile({required this.id, required this.name});

  factory RequestOptionsProfile.fromJson(JsonMap j) => RequestOptionsProfile(
    id: req(readInt(j['id']), 'id'),
    name: readString(j['name']) ?? '',
  );

  final int id;
  final String name;

  JsonMap toJson() => {'id': id, 'name': name};
}

/// A root folder of a Radarr/Sonarr server.
@immutable
final class RequestOptionsRootFolder {
  const RequestOptionsRootFolder({required this.path, this.freeBytes});

  factory RequestOptionsRootFolder.fromJson(JsonMap j) =>
      RequestOptionsRootFolder(
        path: req(readString(j['path']), 'path'),
        freeBytes: readInt(j['freeBytes']),
      );

  final String path;
  final int? freeBytes;

  JsonMap toJson() => compactJson({'path': path, 'freeBytes': freeBytes});
}

/// One Radarr/Sonarr server as Seerr knows it, for the advanced request
/// options.
@immutable
final class ServiceOptions {
  const ServiceOptions({
    required this.serverId,
    required this.name,
    required this.isDefault,
    required this.defaultProfileId,
    required this.defaultRootFolder,
    this.defaultAnimeProfileId,
    this.profiles = const [],
    this.rootFolders = const [],
  });

  factory ServiceOptions.fromJson(JsonMap j) => ServiceOptions(
    serverId: req(readInt(j['serverId']), 'serverId'),
    name: readString(j['name']) ?? '',
    isDefault: readBool(j['isDefault']) ?? false,
    defaultProfileId: readInt(j['defaultProfileId']) ?? 0,
    defaultAnimeProfileId: readInt(j['defaultAnimeProfileId']),
    defaultRootFolder: readString(j['defaultRootFolder']) ?? '',
    profiles: readList(j['profiles'], RequestOptionsProfile.fromJson),
    rootFolders: readList(j['rootFolders'], RequestOptionsRootFolder.fromJson),
  );

  /// Seerr's server id (0 is a valid id).
  final int serverId;
  final String name;
  final bool isDefault;
  final int defaultProfileId;
  final int? defaultAnimeProfileId;
  final String defaultRootFolder;
  final List<RequestOptionsProfile> profiles;
  final List<RequestOptionsRootFolder> rootFolders;

  JsonMap toJson() => compactJson({
    'serverId': serverId,
    'name': name,
    'isDefault': isDefault,
    'defaultProfileId': defaultProfileId,
    'defaultAnimeProfileId': defaultAnimeProfileId,
    'defaultRootFolder': defaultRootFolder,
    'profiles': [for (final p in profiles) p.toJson()],
    'rootFolders': [for (final r in rootFolders) r.toJson()],
  });
}

/// The advanced request options (`GET /requests/options`, admin). API.md
/// calls it RequestOptions; the Dart name avoids dio's `RequestOptions`,
/// which every app file importing both packages would see as ambiguous.
@immutable
final class RequestsOptions {
  const RequestsOptions({this.radarr = const [], this.sonarr = const []});

  factory RequestsOptions.fromJson(JsonMap j) => RequestsOptions(
    radarr: readList(j['radarr'], ServiceOptions.fromJson),
    sonarr: readList(j['sonarr'], ServiceOptions.fromJson),
  );

  final List<ServiceOptions> radarr;
  final List<ServiceOptions> sonarr;

  /// The servers for [type] (radarr for movies, sonarr for tv).
  List<ServiceOptions> forMediaType(MediaType type) =>
      type == MediaType.tv ? sonarr : radarr;

  JsonMap toJson() => {
    'radarr': [for (final s in radarr) s.toJson()],
    'sonarr': [for (final s in sonarr) s.toJson()],
  };
}

// ---------------------------------------------------------------------------
// Title details (API.md §6.3)
// ---------------------------------------------------------------------------

/// A YouTube trailer.
@immutable
final class RequestsTrailer {
  const RequestsTrailer({required this.youtubeKey, this.name});

  factory RequestsTrailer.fromJson(JsonMap j) => RequestsTrailer(
    youtubeKey: req(readString(j['youtubeKey']), 'youtubeKey'),
    name: readString(j['name']),
  );

  final String youtubeKey;
  final String? name;

  /// The YouTube watch URL.
  Uri get url => Uri.https('www.youtube.com', '/watch', {'v': youtubeKey});

  JsonMap toJson() => compactJson({'youtubeKey': youtubeKey, 'name': name});
}

/// A cast member of a title.
@immutable
final class RequestsCastMember {
  const RequestsCastMember({
    required this.name,
    this.character,
    this.profilePath,
  });

  factory RequestsCastMember.fromJson(JsonMap j) => RequestsCastMember(
    name: readString(j['name']) ?? '',
    character: readString(j['character']),
    profilePath: readString(j['profilePath']),
  );

  final String name;
  final String? character;
  final String? profilePath;

  JsonMap toJson() => compactJson({
    'name': name,
    'character': character,
    'profilePath': profilePath,
  });
}

/// A TMDB collection a movie belongs to.
@immutable
final class RequestsCollectionRef {
  const RequestsCollectionRef({required this.tmdbId, required this.name});

  factory RequestsCollectionRef.fromJson(JsonMap j) => RequestsCollectionRef(
    tmdbId: req(readInt(j['tmdbId']), 'tmdbId'),
    name: readString(j['name']) ?? '',
  );

  final int tmdbId;
  final String name;

  JsonMap toJson() => {'tmdbId': tmdbId, 'name': name};
}

/// Where a title streams in the user's region (ZA).
@immutable
final class RequestsWatchProvider {
  const RequestsWatchProvider({
    required this.name,
    required this.type,
    this.logoPath,
  });

  factory RequestsWatchProvider.fromJson(JsonMap j) => RequestsWatchProvider(
    name: readString(j['name']) ?? '',
    logoPath: readString(j['logoPath']),
    type: RequestsWatchProviderType.fromJson(j['type']),
  );

  final String name;
  final String? logoPath;
  final RequestsWatchProviderType type;

  JsonMap toJson() =>
      compactJson({'name': name, 'logoPath': logoPath, 'type': type.toJson()});
}

/// The next episode of a series that is still airing.
@immutable
final class RequestsNextEpisode {
  const RequestsNextEpisode({
    required this.seasonNumber,
    required this.episodeNumber,
    this.name,
    this.airDate,
  });

  factory RequestsNextEpisode.fromJson(JsonMap j) => RequestsNextEpisode(
    seasonNumber: req(readInt(j['seasonNumber']), 'seasonNumber'),
    episodeNumber: req(readInt(j['episodeNumber']), 'episodeNumber'),
    name: readString(j['name']),
    airDate: readString(j['airDate']),
  );

  final int seasonNumber;
  final int episodeNumber;
  final String? name;

  /// `YYYY-MM-DD`.
  final String? airDate;

  JsonMap toJson() => compactJson({
    'seasonNumber': seasonNumber,
    'episodeNumber': episodeNumber,
    'name': name,
    'airDate': airDate,
  });
}

/// What Seerr knows about a title (null when Seerr has no media row).
@immutable
final class MediaState {
  const MediaState({
    required this.seerrMediaId,
    required this.availability,
    this.requests = const [],
    this.downloads = const [],
    this.jellyfin,
    this.libraryId,
    this.openIssues = 0,
  });

  factory MediaState.fromJson(JsonMap j) => MediaState(
    seerrMediaId: req(readInt(j['seerrMediaId']), 'seerrMediaId'),
    availability: Availability.fromJson(j['availability']),
    requests: readList(j['requests'], RequestSummary.fromJson),
    downloads: readList(j['downloads'], RequestDownloadProgress.fromJson),
    jellyfin: switch (readMap(j['jellyfin'])) {
      final m? => ExternalLink.fromJson(m),
      null => null,
    },
    libraryId: readInt(j['libraryId']),
    openIssues: readInt(j['openIssues']) ?? 0,
  );

  final int seerrMediaId;
  final Availability availability;
  final List<RequestSummary> requests;
  final List<RequestDownloadProgress> downloads;
  final ExternalLink? jellyfin;

  /// Radarr movie id or Sonarr series id.
  final int? libraryId;
  final int openIssues;

  JsonMap toJson() => compactJson({
    'seerrMediaId': seerrMediaId,
    'availability': availability.toJson(),
    'requests': [for (final r in requests) r.toJson()],
    'downloads': [for (final d in downloads) d.toJson()],
    'jellyfin': jellyfin?.toJson(),
    'libraryId': libraryId,
    'openIssues': openIssues,
  });
}

/// Whether the caller can request a title, and which seasons (tv).
@immutable
final class RequestEligibility {
  const RequestEligibility({
    required this.canRequest,
    this.reason,
    this.requestableSeasons = const [],
  });

  factory RequestEligibility.fromJson(JsonMap j) => RequestEligibility(
    canRequest: readBool(j['canRequest']) ?? false,
    reason: RequestEligibilityReason.fromJsonOrNull(j['reason']),
    requestableSeasons: readIntList(j['requestableSeasons']),
  );

  final bool canRequest;
  final RequestEligibilityReason? reason;
  final List<int> requestableSeasons;

  JsonMap toJson() => compactJson({
    'canRequest': canRequest,
    'reason': reason?.toJson(),
    'requestableSeasons': requestableSeasons,
  });
}

/// A movie's detail page.
@immutable
final class MovieTitle {
  const MovieTitle({
    required this.tmdbId,
    required this.title,
    required this.request,
    this.imdbId,
    this.originalTitle,
    this.tagline,
    this.overview,
    this.releaseDate,
    this.year,
    this.runtimeMinutes,
    this.genres = const [],
    this.certification,
    this.voteAverage,
    this.voteCount,
    this.posterPath,
    this.backdropPath,
    this.trailer,
    this.cast = const [],
    this.directors = const [],
    this.collection,
    this.watchProviders = const [],
    this.media,
  });

  factory MovieTitle.fromJson(JsonMap j) => MovieTitle(
    tmdbId: req(readInt(j['tmdbId']), 'tmdbId'),
    imdbId: readString(j['imdbId']),
    title: readString(j['title']) ?? '',
    originalTitle: readString(j['originalTitle']),
    tagline: readString(j['tagline']),
    overview: readString(j['overview']),
    releaseDate: readString(j['releaseDate']),
    year: readInt(j['year']),
    runtimeMinutes: readInt(j['runtimeMinutes']),
    genres: readStringList(j['genres']),
    certification: readString(j['certification']),
    voteAverage: readDouble(j['voteAverage']),
    voteCount: readInt(j['voteCount']),
    posterPath: readString(j['posterPath']),
    backdropPath: readString(j['backdropPath']),
    trailer: switch (readMap(j['trailer'])) {
      final m? => RequestsTrailer.fromJson(m),
      null => null,
    },
    cast: readList(j['cast'], RequestsCastMember.fromJson),
    directors: readStringList(j['directors']),
    collection: switch (readMap(j['collection'])) {
      final m? => RequestsCollectionRef.fromJson(m),
      null => null,
    },
    watchProviders: readList(
      j['watchProviders'],
      RequestsWatchProvider.fromJson,
    ),
    media: switch (readMap(j['media'])) {
      final m? => MediaState.fromJson(m),
      null => null,
    },
    request: RequestEligibility.fromJson(readMap(j['request']) ?? const {}),
  );

  final int tmdbId;
  final String? imdbId;
  final String title;
  final String? originalTitle;
  final String? tagline;
  final String? overview;

  /// `YYYY-MM-DD`.
  final String? releaseDate;
  final int? year;
  final int? runtimeMinutes;
  final List<String> genres;
  final String? certification;
  final double? voteAverage;
  final int? voteCount;
  final String? posterPath;
  final String? backdropPath;
  final RequestsTrailer? trailer;
  final List<RequestsCastMember> cast;
  final List<String> directors;
  final RequestsCollectionRef? collection;
  final List<RequestsWatchProvider> watchProviders;
  final MediaState? media;
  final RequestEligibility request;

  JsonMap toJson() => compactJson({
    'tmdbId': tmdbId,
    'imdbId': imdbId,
    'title': title,
    'originalTitle': originalTitle,
    'tagline': tagline,
    'overview': overview,
    'releaseDate': releaseDate,
    'year': year,
    'runtimeMinutes': runtimeMinutes,
    'genres': genres,
    'certification': certification,
    'voteAverage': voteAverage,
    'voteCount': voteCount,
    'posterPath': posterPath,
    'backdropPath': backdropPath,
    'trailer': trailer?.toJson(),
    'cast': [for (final c in cast) c.toJson()],
    'directors': directors,
    'collection': collection?.toJson(),
    'watchProviders': [for (final w in watchProviders) w.toJson()],
    'media': media?.toJson(),
    'request': request.toJson(),
  });
}

/// One season of a series (specials excluded unless Seerr enables them).
@immutable
final class TvSeason {
  const TvSeason({
    required this.seasonNumber,
    required this.name,
    required this.episodeCount,
    this.airDate,
    this.posterPath,
    this.availability = Availability.none,
    this.requestStatus,
    this.requestable = false,
  });

  factory TvSeason.fromJson(JsonMap j) => TvSeason(
    seasonNumber: req(readInt(j['seasonNumber']), 'seasonNumber'),
    name: readString(j['name']) ?? '',
    episodeCount: readInt(j['episodeCount']) ?? 0,
    airDate: readString(j['airDate']),
    posterPath: readString(j['posterPath']),
    availability: Availability.fromJson(j['availability'] ?? 'none'),
    requestStatus: RequestStatus.fromJsonOrNull(j['requestStatus']),
    requestable: readBool(j['requestable']) ?? false,
  );

  final int seasonNumber;
  final String name;
  final int episodeCount;

  /// `YYYY-MM-DD`.
  final String? airDate;
  final String? posterPath;
  final Availability availability;

  /// Status of the active request covering this season, if any.
  final RequestStatus? requestStatus;
  final bool requestable;

  JsonMap toJson() => compactJson({
    'seasonNumber': seasonNumber,
    'name': name,
    'episodeCount': episodeCount,
    'airDate': airDate,
    'posterPath': posterPath,
    'availability': availability.toJson(),
    'requestStatus': requestStatus?.toJson(),
    'requestable': requestable,
  });
}

/// A series' detail page.
@immutable
final class TvTitle {
  const TvTitle({
    required this.tmdbId,
    required this.title,
    required this.request,
    this.imdbId,
    this.originalTitle,
    this.tagline,
    this.overview,
    this.year,
    this.genres = const [],
    this.certification,
    this.voteAverage,
    this.voteCount,
    this.posterPath,
    this.backdropPath,
    this.trailer,
    this.cast = const [],
    this.watchProviders = const [],
    this.media,
    this.firstAirDate,
    this.lastAirDate,
    this.status = '',
    this.networks = const [],
    this.creators = const [],
    this.episodeRuntimeMinutes,
    this.numberOfSeasons = 0,
    this.numberOfEpisodes = 0,
    this.tvdbId,
    this.nextEpisode,
    this.seasons = const [],
  });

  factory TvTitle.fromJson(JsonMap j) => TvTitle(
    tmdbId: req(readInt(j['tmdbId']), 'tmdbId'),
    imdbId: readString(j['imdbId']),
    title: readString(j['title']) ?? '',
    originalTitle: readString(j['originalTitle']),
    tagline: readString(j['tagline']),
    overview: readString(j['overview']),
    year: readInt(j['year']),
    genres: readStringList(j['genres']),
    certification: readString(j['certification']),
    voteAverage: readDouble(j['voteAverage']),
    voteCount: readInt(j['voteCount']),
    posterPath: readString(j['posterPath']),
    backdropPath: readString(j['backdropPath']),
    trailer: switch (readMap(j['trailer'])) {
      final m? => RequestsTrailer.fromJson(m),
      null => null,
    },
    cast: readList(j['cast'], RequestsCastMember.fromJson),
    watchProviders: readList(
      j['watchProviders'],
      RequestsWatchProvider.fromJson,
    ),
    media: switch (readMap(j['media'])) {
      final m? => MediaState.fromJson(m),
      null => null,
    },
    request: RequestEligibility.fromJson(readMap(j['request']) ?? const {}),
    firstAirDate: readString(j['firstAirDate']),
    lastAirDate: readString(j['lastAirDate']),
    status: readString(j['status']) ?? '',
    networks: readStringList(j['networks']),
    creators: readStringList(j['creators']),
    episodeRuntimeMinutes: readInt(j['episodeRuntimeMinutes']),
    numberOfSeasons: readInt(j['numberOfSeasons']) ?? 0,
    numberOfEpisodes: readInt(j['numberOfEpisodes']) ?? 0,
    tvdbId: readInt(j['tvdbId']),
    nextEpisode: switch (readMap(j['nextEpisode'])) {
      final m? => RequestsNextEpisode.fromJson(m),
      null => null,
    },
    seasons: readList(j['seasons'], TvSeason.fromJson),
  );

  final int tmdbId;
  final String? imdbId;
  final String title;
  final String? originalTitle;
  final String? tagline;
  final String? overview;
  final int? year;
  final List<String> genres;
  final String? certification;
  final double? voteAverage;
  final int? voteCount;
  final String? posterPath;
  final String? backdropPath;
  final RequestsTrailer? trailer;
  final List<RequestsCastMember> cast;
  final List<RequestsWatchProvider> watchProviders;
  final MediaState? media;
  final RequestEligibility request;

  /// `YYYY-MM-DD`.
  final String? firstAirDate;

  /// `YYYY-MM-DD`.
  final String? lastAirDate;

  /// TMDB status, e.g. `Returning Series`.
  final String status;
  final List<String> networks;
  final List<String> creators;
  final int? episodeRuntimeMinutes;
  final int numberOfSeasons;
  final int numberOfEpisodes;
  final int? tvdbId;
  final RequestsNextEpisode? nextEpisode;
  final List<TvSeason> seasons;

  JsonMap toJson() => compactJson({
    'tmdbId': tmdbId,
    'imdbId': imdbId,
    'title': title,
    'originalTitle': originalTitle,
    'tagline': tagline,
    'overview': overview,
    'year': year,
    'genres': genres,
    'certification': certification,
    'voteAverage': voteAverage,
    'voteCount': voteCount,
    'posterPath': posterPath,
    'backdropPath': backdropPath,
    'trailer': trailer?.toJson(),
    'cast': [for (final c in cast) c.toJson()],
    'watchProviders': [for (final w in watchProviders) w.toJson()],
    'media': media?.toJson(),
    'request': request.toJson(),
    'firstAirDate': firstAirDate,
    'lastAirDate': lastAirDate,
    'status': status,
    'networks': networks,
    'creators': creators,
    'episodeRuntimeMinutes': episodeRuntimeMinutes,
    'numberOfSeasons': numberOfSeasons,
    'numberOfEpisodes': numberOfEpisodes,
    'tvdbId': tvdbId,
    'nextEpisode': nextEpisode?.toJson(),
    'seasons': [for (final s in seasons) s.toJson()],
  });
}

/// Rotten Tomatoes scores.
@immutable
final class RatingsRottenTomatoes {
  const RatingsRottenTomatoes({
    this.criticsScore,
    this.audienceScore,
    this.criticsRating,
    this.url,
  });

  factory RatingsRottenTomatoes.fromJson(JsonMap j) => RatingsRottenTomatoes(
    criticsScore: readInt(j['criticsScore']),
    audienceScore: readInt(j['audienceScore']),
    criticsRating: readString(j['criticsRating']),
    url: readString(j['url']),
  );

  /// 0..100.
  final int? criticsScore;

  /// 0..100.
  final int? audienceScore;

  /// `Fresh`, `Rotten`, `Certified Fresh`.
  final String? criticsRating;
  final String? url;

  JsonMap toJson() => compactJson({
    'criticsScore': criticsScore,
    'audienceScore': audienceScore,
    'criticsRating': criticsRating,
    'url': url,
  });
}

/// IMDb score.
@immutable
final class RatingsImdb {
  const RatingsImdb({this.score, this.url});

  factory RatingsImdb.fromJson(JsonMap j) =>
      RatingsImdb(score: readDouble(j['score']), url: readString(j['url']));

  /// 0..10.
  final double? score;
  final String? url;

  JsonMap toJson() => compactJson({'score': score, 'url': url});
}

/// External ratings of a title (loaded lazily; both parts may be absent).
@immutable
final class Ratings {
  const Ratings({this.rottenTomatoes, this.imdb});

  factory Ratings.fromJson(JsonMap j) => Ratings(
    rottenTomatoes: switch (readMap(j['rottenTomatoes'])) {
      final m? => RatingsRottenTomatoes.fromJson(m),
      null => null,
    },
    imdb: switch (readMap(j['imdb'])) {
      final m? => RatingsImdb.fromJson(m),
      null => null,
    },
  );

  final RatingsRottenTomatoes? rottenTomatoes;
  final RatingsImdb? imdb;

  bool get isEmpty => rottenTomatoes == null && imdb == null;

  JsonMap toJson() => compactJson({
    'rottenTomatoes': rottenTomatoes?.toJson(),
    'imdb': imdb?.toJson(),
  });
}

/// One episode of a TMDB season.
@immutable
final class SeasonEpisode {
  const SeasonEpisode({
    required this.episodeNumber,
    required this.name,
    this.airDate,
    this.overview,
    this.stillPath,
  });

  factory SeasonEpisode.fromJson(JsonMap j) => SeasonEpisode(
    episodeNumber: req(readInt(j['episodeNumber']), 'episodeNumber'),
    name: readString(j['name']) ?? '',
    airDate: readString(j['airDate']),
    overview: readString(j['overview']),
    stillPath: readString(j['stillPath']),
  );

  final int episodeNumber;
  final String name;

  /// `YYYY-MM-DD`.
  final String? airDate;
  final String? overview;
  final String? stillPath;

  JsonMap toJson() => compactJson({
    'episodeNumber': episodeNumber,
    'name': name,
    'airDate': airDate,
    'overview': overview,
    'stillPath': stillPath,
  });
}

/// The episodes of one season (`GET /titles/tv/{id}/seasons/{n}`).
@immutable
final class SeasonEpisodes {
  const SeasonEpisodes({
    required this.seasonNumber,
    required this.name,
    this.overview,
    this.episodes = const [],
  });

  factory SeasonEpisodes.fromJson(JsonMap j) => SeasonEpisodes(
    seasonNumber: req(readInt(j['seasonNumber']), 'seasonNumber'),
    name: readString(j['name']) ?? '',
    overview: readString(j['overview']),
    episodes: readList(j['episodes'], SeasonEpisode.fromJson),
  );

  final int seasonNumber;
  final String name;
  final String? overview;
  final List<SeasonEpisode> episodes;

  JsonMap toJson() => compactJson({
    'seasonNumber': seasonNumber,
    'name': name,
    'overview': overview,
    'episodes': [for (final e in episodes) e.toJson()],
  });
}

// ---------------------------------------------------------------------------
// Issues (API.md §6.6)
// ---------------------------------------------------------------------------

/// A Seerr user as shown on an issue or comment.
@immutable
final class IssueUser {
  const IssueUser({
    required this.id,
    required this.displayName,
    this.avatarPath,
  });

  factory IssueUser.fromJson(JsonMap j) => IssueUser(
    id: req(readInt(j['id']), 'id'),
    displayName: readString(j['displayName']) ?? '',
    avatarPath: readString(j['avatarPath']),
  );

  /// Seerr user id.
  final int id;
  final String displayName;
  final String? avatarPath;

  JsonMap toJson() => compactJson({
    'id': id,
    'displayName': displayName,
    'avatarPath': avatarPath,
  });
}

/// One comment of an issue.
@immutable
final class IssueComment {
  const IssueComment({
    required this.id,
    required this.message,
    required this.author,
    required this.createdAt,
  });

  factory IssueComment.fromJson(JsonMap j) => IssueComment(
    id: req(readInt(j['id']), 'id'),
    message: readString(j['message']) ?? '',
    author: IssueUser.fromJson(
      readMap(j['author']) ?? (throw const FormatException('author')),
    ),
    createdAt: req(readInstant(j['createdAt']), 'createdAt'),
  );

  final int id;
  final String message;
  final IssueUser author;
  final DateTime createdAt;

  JsonMap toJson() => {
    'id': id,
    'message': message,
    'author': author.toJson(),
    'createdAt': instantToJson(createdAt),
  };
}

/// A reported problem with a title. Lists carry [commentCount] and an empty
/// [comments] list.
@immutable
final class Issue {
  const Issue({
    required this.id,
    required this.type,
    required this.status,
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    this.posterPath,
    this.season,
    this.episode,
    this.commentCount = 0,
    this.comments = const [],
  });

  factory Issue.fromJson(JsonMap j) => Issue(
    id: req(readInt(j['id']), 'id'),
    type: IssueType.fromJson(j['type']),
    status: IssueStatus.fromJson(j['status']),
    mediaType: MediaType.fromJson(j['mediaType']),
    tmdbId: req(readInt(j['tmdbId']), 'tmdbId'),
    title: readString(j['title']) ?? '',
    posterPath: readString(j['posterPath']),
    season: readInt(j['season']),
    episode: readInt(j['episode']),
    createdBy: IssueUser.fromJson(
      readMap(j['createdBy']) ?? (throw const FormatException('createdBy')),
    ),
    createdAt: req(readInstant(j['createdAt']), 'createdAt'),
    updatedAt: req(readInstant(j['updatedAt']), 'updatedAt'),
    commentCount: readInt(j['commentCount']) ?? 0,
    comments: readList(j['comments'], IssueComment.fromJson),
  );

  final int id;
  final IssueType type;
  final IssueStatus status;
  final MediaType mediaType;
  final int tmdbId;
  final String title;
  final String? posterPath;

  /// Null when the issue concerns every season.
  final int? season;

  /// Null when the issue concerns every episode.
  final int? episode;
  final IssueUser createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int commentCount;
  final List<IssueComment> comments;

  JsonMap toJson() => compactJson({
    'id': id,
    'type': type.toJson(),
    'status': status.toJson(),
    'mediaType': mediaType.toJson(),
    'tmdbId': tmdbId,
    'title': title,
    'posterPath': posterPath,
    'season': season,
    'episode': episode,
    'createdBy': createdBy.toJson(),
    'createdAt': instantToJson(createdAt),
    'updatedAt': instantToJson(updatedAt),
    'commentCount': commentCount,
    'comments': [for (final c in comments) c.toJson()],
  });
}

/// Global issue counters.
@immutable
final class IssueCounts {
  const IssueCounts({
    this.total = 0,
    this.video = 0,
    this.audio = 0,
    this.subtitles = 0,
    this.other = 0,
    this.open = 0,
    this.resolved = 0,
  });

  factory IssueCounts.fromJson(JsonMap j) => IssueCounts(
    total: readInt(j['total']) ?? 0,
    video: readInt(j['video']) ?? 0,
    audio: readInt(j['audio']) ?? 0,
    subtitles: readInt(j['subtitles']) ?? 0,
    other: readInt(j['other']) ?? 0,
    open: readInt(j['open']) ?? 0,
    resolved: readInt(j['resolved']) ?? 0,
  );

  final int total;
  final int video;
  final int audio;
  final int subtitles;
  final int other;
  final int open;
  final int resolved;

  JsonMap toJson() => {
    'total': total,
    'video': video,
    'audio': audio,
    'subtitles': subtitles,
    'other': other,
    'open': open,
    'resolved': resolved,
  };
}

/// Body of `POST /issues`.
@immutable
final class CreateIssue {
  const CreateIssue({
    required this.mediaType,
    required this.tmdbId,
    required this.type,
    required this.message,
    this.season,
    this.episode,
  });

  factory CreateIssue.fromJson(JsonMap j) => CreateIssue(
    mediaType: MediaType.fromJson(j['mediaType']),
    tmdbId: req(readInt(j['tmdbId']), 'tmdbId'),
    type: IssueType.fromJson(j['type']),
    message: readString(j['message']) ?? '',
    season: readInt(j['season']),
    episode: readInt(j['episode']),
  );

  final MediaType mediaType;
  final int tmdbId;
  final IssueType type;

  /// 1..2000 characters.
  final String message;
  final int? season;
  final int? episode;

  JsonMap toJson() => compactJson({
    'mediaType': mediaType.toJson(),
    'tmdbId': tmdbId,
    'type': type.toJson(),
    'message': message,
    'season': season,
    'episode': episode,
  });
}

// ---------------------------------------------------------------------------
// Dashboard card (API.md §6.9)
// ---------------------------------------------------------------------------

/// The `requests` dashboard card. `counts.pending` is a raw key read by the
/// shell badge (API.md §4); every part is lenient so partial data decodes.
@immutable
final class RequestsCard {
  const RequestsCard({
    this.counts = const RequestCounts(),
    this.pending = const [],
    this.recent = const [],
    this.openIssues = 0,
  });

  factory RequestsCard.fromJson(JsonMap j) => RequestsCard(
    counts: RequestCounts.fromJson(readMap(j['counts']) ?? const {}),
    pending: readList(j['pending'], RequestSummary.fromJson),
    recent: readList(j['recent'], RequestSummary.fromJson),
    openIssues: readInt(j['openIssues']) ?? 0,
  );

  final RequestCounts counts;

  /// Up to 5 pending requests (admins only, else empty).
  final List<RequestSummary> pending;

  /// The latest 5 requests (members: their own).
  final List<RequestSummary> recent;
  final int openIssues;

  JsonMap toJson() => {
    'counts': counts.toJson(),
    'pending': [for (final r in pending) r.toJson()],
    'recent': [for (final r in recent) r.toJson()],
    'openIssues': openIssues,
  };
}
