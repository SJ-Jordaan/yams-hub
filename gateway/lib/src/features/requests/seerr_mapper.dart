/// Seerr JSON → requests DTOs (API.md §6, integrations/seerr.md §1.3–§1.12).
///
/// Seerr's magic numbers end here: MediaStatus, MediaRequestStatus,
/// IssueType and IssueStatus become the named enums of `yams_models`. Seerr
/// `email`, `mediaUrl` and `serviceUrl` are never copied.
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

/// The joined title facts of a request or issue (key `type:tmdbId`).
final class TitleInfo {
  const TitleInfo({required this.title, this.year, this.posterPath});

  /// Used when the TMDB lookup failed.
  factory TitleInfo.fallback(MediaType type, int tmdbId) => TitleInfo(
    title: type == MediaType.tv ? 'Series $tmdbId' : 'Movie $tmdbId',
  );

  final String title;
  final int? year;

  /// Gateway image path.
  final String? posterPath;
}

/// What the caller may do with requests (computed per request).
final class RequestViewer {
  const RequestViewer({required this.isAdmin, this.seerrUserId});

  final bool isAdmin;

  /// The caller's Seerr user, if linked.
  final int? seerrUserId;
}

/// TMDB image sizes used in DTOs.
abstract final class RequestsImageSizes {
  static const poster = 'w342';
  static const backdrop = 'w780';
  static const profile = 'w185';
  static const logo = 'w92';
  static const still = 'w342';
}

/// Region for certifications and watch providers (the household is in ZA).
const requestsRegion = 'ZA';
const _fallbackRegion = 'US';

/// Maps Seerr JSON to DTOs. Pure apart from [now] (download ETAs).
final class SeerrMapper {
  SeerrMapper({required this.images, required this.now, required this.link});

  final ImageUrls images;
  final DateTime Function() now;

  /// `ctx.jellyfin.itemLink`.
  final ExternalLink Function(String itemId, String serverId) link;

  // -------------------------------------------------------------------------
  // Enums
  // -------------------------------------------------------------------------

  /// Seerr MediaStatus (1..7); null or a missing media row is `none`.
  static Availability availability(Object? status) => switch (readInt(status)) {
    null || 1 => Availability.none,
    2 => Availability.pending,
    3 => Availability.processing,
    4 => Availability.partial,
    5 => Availability.available,
    6 => Availability.blocklisted,
    7 => Availability.deleted,
    _ => Availability.unknown,
  };

  /// Seerr MediaRequestStatus (1..5).
  static RequestStatus requestStatus(Object? status) =>
      switch (readInt(status)) {
        1 => RequestStatus.pending,
        2 => RequestStatus.approved,
        3 => RequestStatus.declined,
        4 => RequestStatus.failed,
        5 => RequestStatus.completed,
        _ => RequestStatus.unknown,
      };

  /// The Seerr MediaRequestStatus integer of [status] (filters).
  static int? requestStatusCode(RequestStatus status) => switch (status) {
    RequestStatus.pending => 1,
    RequestStatus.approved => 2,
    RequestStatus.declined => 3,
    RequestStatus.failed => 4,
    RequestStatus.completed => 5,
    RequestStatus.unknown => null,
  };

  static MediaType mediaType(Object? v) => switch (readString(v)) {
    'movie' => MediaType.movie,
    'tv' => MediaType.tv,
    _ => MediaType.unknown,
  };

  static IssueType issueType(Object? v) => switch (readInt(v)) {
    1 => IssueType.video,
    2 => IssueType.audio,
    3 => IssueType.subtitles,
    4 => IssueType.other,
    _ => IssueType.unknown,
  };

  /// Seerr IssueType integer of [type].
  static int? issueTypeCode(IssueType type) => switch (type) {
    IssueType.video => 1,
    IssueType.audio => 2,
    IssueType.subtitles => 3,
    IssueType.other => 4,
    IssueType.unknown => null,
  };

  static IssueStatus issueStatus(Object? v) => switch (readInt(v)) {
    1 => IssueStatus.open,
    2 => IssueStatus.resolved,
    _ => IssueStatus.unknown,
  };

  /// Whether a request with Seerr status [status] still blocks its seasons
  /// (the server rule: anything but DECLINED and COMPLETED).
  static bool isActiveRequest(Object? status) {
    final s = readInt(status);
    return s != 3 && s != 5;
  }

  /// `YYYY` of a `YYYY-MM-DD` date; empty or invalid → null.
  static int? yearOf(String? date) {
    if (date == null || date.length < 4) return null;
    return int.tryParse(date.substring(0, 4));
  }

  static String? _date(Object? v) {
    final s = readString(v)?.trim();
    if (s == null || s.isEmpty) return null;
    return s.length > 10 ? s.substring(0, 10) : s;
  }

  String? poster(Object? path) =>
      images.tmdb(readString(path), RequestsImageSizes.poster);

  String? backdrop(Object? path) =>
      images.tmdb(readString(path), RequestsImageSizes.backdrop);

  // -------------------------------------------------------------------------
  // Discover and search
  // -------------------------------------------------------------------------

  /// A TMDB search/discover result; null for `person` results and rows
  /// without an id. [fallbackType] applies when the row has no `mediaType`
  /// (recommendations, similar, popular-*).
  TitleCard? titleCard(JsonMap r, {MediaType? fallbackType}) {
    final rawType = readString(r['mediaType']);
    if (rawType == 'person') return null;
    final type = rawType == null ? fallbackType : mediaType(rawType);
    final id = readInt(r['id']);
    if (type == null || type == MediaType.unknown || id == null) return null;
    final date = _date(r['releaseDate']) ?? _date(r['firstAirDate']);
    final status = readMap(r['mediaInfo'])?['status'];
    final availability = SeerrMapper.availability(status);
    return TitleCard(
      mediaType: type,
      tmdbId: id,
      title: readString(r['title']) ?? readString(r['name']) ?? '',
      year: yearOf(date),
      releaseDate: date,
      overview: _nonEmpty(r['overview']),
      posterPath: poster(r['posterPath']),
      backdropPath: backdrop(r['backdropPath']),
      voteAverage: readDouble(r['voteAverage']),
      availability: availability,
      requested:
          availability == Availability.pending ||
          availability == Availability.processing,
    );
  }

  /// A Seerr `{page, totalPages, totalResults, results}` page.
  TitlePage titlePage(JsonMap j, {MediaType? fallbackType}) => TitlePage(
    page: readInt(j['page']) ?? 1,
    totalPages: (readInt(j['totalPages']) ?? 0).clamp(0, 500),
    totalResults: readInt(j['totalResults']) ?? 0,
    items: [
      for (final r in readList(j['results'], (m) => m))
        ?titleCard(r, fallbackType: fallbackType),
    ],
  );

  /// A Seerr watchlist row (`{title, mediaType, tmdbId, media?}`), enriched
  /// with the joined [info] when it is known.
  TitleCard? watchlistCard(JsonMap r, TitleInfo? info) {
    final type = mediaType(r['mediaType']);
    final id = readInt(r['tmdbId']);
    if (type == MediaType.unknown || id == null) return null;
    final availability = SeerrMapper.availability(
      readMap(r['media'])?['status'],
    );
    return TitleCard(
      mediaType: type,
      tmdbId: id,
      title: readString(r['title']) ?? info?.title ?? '',
      year: info?.year,
      posterPath: info?.posterPath,
      availability: availability,
      requested:
          availability == Availability.pending ||
          availability == Availability.processing,
    );
  }

  /// The join facts of a Seerr movie/tv details response.
  TitleInfo titleInfo(JsonMap details) => TitleInfo(
    title: readString(details['title']) ?? readString(details['name']) ?? '',
    year: yearOf(
      _date(details['releaseDate']) ?? _date(details['firstAirDate']),
    ),
    posterPath: poster(details['posterPath']),
  );

  // -------------------------------------------------------------------------
  // Users, downloads, links
  // -------------------------------------------------------------------------

  /// A Seerr User (email and the rest are dropped).
  RequestUser requestUser(JsonMap u) {
    final id = req(readInt(u['id']), 'requestedBy.id');
    return RequestUser(
      id: id,
      displayName: _displayName(u),
      avatarPath: images.seerrAvatar(id, version: _avatarVersion(u)),
    );
  }

  IssueUser issueUser(JsonMap u) {
    final r = requestUser(u);
    return IssueUser(
      id: r.id,
      displayName: r.displayName,
      avatarPath: r.avatarPath,
    );
  }

  static String _displayName(JsonMap u) =>
      _nonEmpty(u['displayName']) ??
      _nonEmpty(u['jellyfinUsername']) ??
      _nonEmpty(u['username']) ??
      _nonEmpty(u['plexUsername']) ??
      'User ${readInt(u['id'])}';

  static String? _avatarVersion(JsonMap u) {
    final avatar = readString(u['avatar']);
    final v = avatar == null
        ? null
        : Uri.tryParse(avatar)?.queryParameters['v'];
    return v ?? readString(u['avatarVersion']);
  }

  /// `media.downloadStatus` entries (`progress = 1 - sizeLeft/size`).
  List<RequestDownloadProgress> downloads(JsonMap? media) => [
    for (final d in readList(media?['downloadStatus'], (m) => m)) _download(d),
  ];

  RequestDownloadProgress _download(JsonMap d) {
    final size = readInt(d['size']) ?? 0;
    final left = readInt(d['sizeLeft']) ?? 0;
    final eta = readInstant(d['estimatedCompletionTime']);
    final seconds = eta?.difference(now()).inSeconds;
    return RequestDownloadProgress(
      title: readString(d['title']) ?? '',
      progress: size > 0 ? (1 - left / size).clamp(0.0, 1.0) : 0,
      etaSeconds: seconds == null ? null : (seconds < 0 ? 0 : seconds),
      status: readString(d['status']) ?? '',
    );
  }

  /// "Play in Jellyfin" from `media.jellyfinMediaId` (never `mediaUrl`).
  ExternalLink? jellyfinLink(JsonMap? media, String? serverId) {
    final id = normaliseJellyfinId(readString(media?['jellyfinMediaId']));
    if (id == null || serverId == null) return null;
    return link(id, serverId);
  }

  // -------------------------------------------------------------------------
  // Requests
  // -------------------------------------------------------------------------

  /// A Seerr MediaRequest joined with [info]. [media] is used when the
  /// request carries no `media` (requests embedded in a details response).
  RequestSummary requestSummary(
    JsonMap r, {
    required TitleInfo info,
    required RequestViewer viewer,
    String? jellyfinServerId,
    JsonMap? media,
  }) {
    final m = readMap(r['media']) ?? media;
    final status = requestStatus(r['status']);
    final requestedBy = requestUser(
      readMap(r['requestedBy']) ?? (throw const FormatException('requestedBy')),
    );
    final type = mediaType(r['type'] ?? m?['mediaType']);
    final pending = status == RequestStatus.pending;
    final owner =
        viewer.seerrUserId != null && viewer.seerrUserId == requestedBy.id;
    return RequestSummary(
      id: req(readInt(r['id']), 'id'),
      status: status,
      mediaType: type,
      tmdbId: req(readInt(m?['tmdbId']), 'media.tmdbId'),
      title: info.title,
      year: info.year,
      posterPath: info.posterPath,
      seasons: [
        for (final s in readList(r['seasons'], (x) => x))
          if (readInt(s['seasonNumber']) case final n?)
            RequestSeason(seasonNumber: n, status: requestStatus(s['status'])),
      ]..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber)),
      availability: availability(m?['status']),
      requestedBy: requestedBy,
      modifiedBy: switch (readMap(r['modifiedBy'])) {
        final u? => requestUser(u),
        null => null,
      },
      createdAt: req(readInstant(r['createdAt']), 'createdAt'),
      updatedAt:
          readInstant(r['updatedAt']) ??
          req(readInstant(r['createdAt']), 'createdAt'),
      profileName: _nonEmpty(r['profileName']),
      downloads: downloads(m),
      jellyfin: jellyfinLink(m, jellyfinServerId),
      seerrMediaId: readInt(m?['id']),
      libraryId: readInt(m?['externalServiceId']),
      canApprove: viewer.isAdmin && pending,
      canDecline: viewer.isAdmin && pending,
      canRetry: viewer.isAdmin && status == RequestStatus.failed,
      canDelete: viewer.isAdmin || (owner && pending),
    );
  }

  /// [requestSummary], or null for a malformed row (a title page must not
  /// fail because one embedded request lacks its requester).
  RequestSummary? _tryRequestSummary(
    JsonMap r, {
    required TitleInfo info,
    required RequestViewer viewer,
    String? jellyfinServerId,
    JsonMap? media,
  }) {
    try {
      return requestSummary(
        r,
        info: info,
        viewer: viewer,
        jellyfinServerId: jellyfinServerId,
        media: media,
      );
    } on FormatException {
      return null;
    }
  }

  /// `GET /request/count` → [RequestCounts] (`failed` derived, floored at 0).
  static RequestCounts requestCounts(JsonMap j) {
    int n(String k) => readInt(j[k]) ?? 0;
    final failed =
        n('total') -
        n('pending') -
        n('approved') -
        n('declined') -
        n('completed');
    return RequestCounts(
      total: n('total'),
      movie: n('movie'),
      tv: n('tv'),
      pending: n('pending'),
      approved: n('approved'),
      processing: n('processing'),
      available: n('available'),
      declined: n('declined'),
      completed: n('completed'),
      failed: failed < 0 ? 0 : failed,
    );
  }

  /// One Radarr/Sonarr server from `GET /service/{type}` plus its
  /// `GET /service/{type}/{id}` detail.
  static ServiceOptions serviceOptions(JsonMap server, JsonMap? detail) =>
      ServiceOptions(
        serverId: req(readInt(server['id']), 'id'),
        name: readString(server['name']) ?? '',
        isDefault: readBool(server['isDefault']) ?? false,
        defaultProfileId: readInt(server['activeProfileId']) ?? 0,
        defaultAnimeProfileId: readInt(server['activeAnimeProfileId']),
        defaultRootFolder: readString(server['activeDirectory']) ?? '',
        profiles: [
          for (final p in readList(detail?['profiles'], (m) => m))
            if (readInt(p['id']) case final id?)
              RequestOptionsProfile(id: id, name: readString(p['name']) ?? ''),
        ],
        rootFolders: [
          for (final f in readList(detail?['rootFolders'], (m) => m))
            if (readString(f['path']) case final path?)
              RequestOptionsRootFolder(
                path: path,
                freeBytes: readInt(f['freeSpace']),
              ),
        ],
      );

  // -------------------------------------------------------------------------
  // Title details
  // -------------------------------------------------------------------------

  /// The [MediaState] of a details response (null without `mediaInfo`).
  MediaState? mediaState(
    JsonMap details, {
    required TitleInfo info,
    required RequestViewer viewer,
    String? jellyfinServerId,
  }) {
    final mi = readMap(details['mediaInfo']);
    final id = readInt(mi?['id']);
    if (mi == null || id == null) return null;
    final requests = <RequestSummary>[
      for (final r in readList(mi['requests'], (m) => m))
        ?_tryRequestSummary(
          r,
          info: info,
          viewer: viewer,
          jellyfinServerId: jellyfinServerId,
          media: mi,
        ),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return MediaState(
      seerrMediaId: id,
      availability: availability(mi['status']),
      requests: requests,
      downloads: downloads(mi),
      jellyfin: jellyfinLink(mi, jellyfinServerId),
      libraryId: readInt(mi['externalServiceId']),
      openIssues: [
        for (final i in readList(mi['issues'], (m) => m))
          if (readInt(i['status']) == 1) i,
      ].length,
    );
  }

  /// Movie eligibility (API.md §6.3). [linked] is false for unlinked members.
  static RequestEligibility movieEligibility(
    JsonMap details, {
    required bool linked,
  }) {
    final mi = readMap(details['mediaInfo']);
    final a = availability(mi?['status']);
    if (a == Availability.available) {
      return const RequestEligibility(
        canRequest: false,
        reason: RequestEligibilityReason.available,
      );
    }
    if (a == Availability.blocklisted) {
      return const RequestEligibility(
        canRequest: false,
        reason: RequestEligibilityReason.blocklisted,
      );
    }
    final active = readList(
      mi?['requests'],
      (m) => m,
    ).any((r) => isActiveRequest(r['status']));
    if (a == Availability.pending ||
        a == Availability.processing ||
        a == Availability.partial ||
        active) {
      return const RequestEligibility(
        canRequest: false,
        reason: RequestEligibilityReason.alreadyRequested,
      );
    }
    if (!linked) {
      return const RequestEligibility(
        canRequest: false,
        reason: RequestEligibilityReason.notLinked,
      );
    }
    return const RequestEligibility(canRequest: true);
  }

  /// The season list of a tv details response (integrations/seerr.md §1.7):
  /// TMDB seasons with episodes (season 0 only when [specials]), Seerr's
  /// per-season status, and the server's requestable rule.
  static List<TvSeason> tvSeasons(
    JsonMap details, {
    required bool specials,
    required String? Function(Object? path) poster,
  }) {
    final mi = readMap(details['mediaInfo']);
    final statusBySeason = <int, Availability>{
      for (final s in readList(mi?['seasons'], (m) => m))
        ?readInt(s['seasonNumber']): availability(s['status']),
    };
    // Newest request first, so the first match is the latest one.
    final requests = readList(
      mi?['requests'],
      (m) => m,
    )..sort((a, b) => (readInt(b['id']) ?? 0).compareTo(readInt(a['id']) ?? 0));
    RequestStatus? requestStatusFor(int n, {required bool activeOnly}) {
      for (final r in requests) {
        if (activeOnly && !isActiveRequest(r['status'])) continue;
        for (final s in readList(r['seasons'], (m) => m)) {
          if (readInt(s['seasonNumber']) == n) {
            return requestStatus(s['status']);
          }
        }
      }
      return null;
    }

    final out = <TvSeason>[];
    for (final s in readList(details['seasons'], (m) => m)) {
      final n = readInt(s['seasonNumber']);
      final episodes = readInt(s['episodeCount']) ?? 0;
      if (n == null || n < 0 || (n == 0 && !specials) || episodes <= 0) {
        continue;
      }
      final a = statusBySeason[n] ?? Availability.none;
      final active = requestStatusFor(n, activeOnly: true);
      out.add(
        TvSeason(
          seasonNumber: n,
          name: readString(s['name']) ?? 'Season $n',
          episodeCount: episodes,
          airDate: _date(s['airDate']),
          posterPath: poster(s['posterPath']),
          availability: a,
          requestStatus: active ?? requestStatusFor(n, activeOnly: false),
          requestable:
              (a == Availability.none || a == Availability.deleted) &&
              active == null,
        ),
      );
    }
    out.sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
    return out;
  }

  /// Series eligibility from its [seasons] (API.md §6.3).
  static RequestEligibility tvEligibility(
    JsonMap details,
    List<TvSeason> seasons, {
    required bool linked,
  }) {
    final a = availability(readMap(details['mediaInfo'])?['status']);
    final requestable = [
      for (final s in seasons)
        if (s.requestable) s.seasonNumber,
    ];
    if (a == Availability.blocklisted) {
      return const RequestEligibility(
        canRequest: false,
        reason: RequestEligibilityReason.blocklisted,
      );
    }
    if (requestable.isEmpty) {
      final anyRequested = seasons.any((s) => s.requestStatus != null);
      return RequestEligibility(
        canRequest: false,
        reason: a == Availability.available
            ? RequestEligibilityReason.available
            : (anyRequested ||
                  a == Availability.pending ||
                  a == Availability.processing ||
                  a == Availability.partial)
            ? RequestEligibilityReason.alreadyRequested
            : null,
      );
    }
    if (!linked) {
      return RequestEligibility(
        canRequest: false,
        reason: RequestEligibilityReason.notLinked,
        requestableSeasons: requestable,
      );
    }
    return RequestEligibility(
      canRequest: true,
      requestableSeasons: requestable,
    );
  }

  /// Top 12 cast members by `order`.
  List<RequestsCastMember> cast(JsonMap details) {
    final cast = readList(readMap(details['credits'])?['cast'], (m) => m)
      ..sort(
        (a, b) =>
            (readInt(a['order']) ?? 999).compareTo(readInt(b['order']) ?? 999),
      );
    return [
      for (final c in cast.take(12))
        RequestsCastMember(
          name: readString(c['name']) ?? '',
          character: _nonEmpty(c['character']),
          profilePath: images.tmdb(
            readString(c['profilePath']),
            RequestsImageSizes.profile,
          ),
        ),
    ];
  }

  /// The first YouTube `Trailer` of `relatedVideos`.
  static RequestsTrailer? trailer(JsonMap details) {
    for (final v in readList(details['relatedVideos'], (m) => m)) {
      final key = readString(v['key']);
      if (readString(v['site']) == 'YouTube' &&
          readString(v['type']) == 'Trailer' &&
          key != null &&
          key.isNotEmpty) {
        return RequestsTrailer(youtubeKey: key, name: _nonEmpty(v['name']));
      }
    }
    return null;
  }

  /// Providers of `watchProviders` for [requestsRegion].
  List<RequestsWatchProvider> watchProviders(JsonMap details) {
    for (final region in readList(details['watchProviders'], (m) => m)) {
      if (readString(region['iso_3166_1']) != requestsRegion) continue;
      return [
        for (final (key, type) in const [
          ('flatrate', RequestsWatchProviderType.flatrate),
          ('rent', RequestsWatchProviderType.rent),
          ('buy', RequestsWatchProviderType.buy),
        ])
          for (final p in readList(region[key], (m) => m))
            RequestsWatchProvider(
              name: readString(p['name']) ?? '',
              logoPath: images.tmdb(
                readString(p['logoPath']),
                RequestsImageSizes.logo,
              ),
              type: type,
            ),
      ];
    }
    return const [];
  }

  /// First non-empty movie certification for ZA, else US.
  static String? movieCertification(JsonMap details) {
    final results = readList(
      readMap(details['releases'])?['results'],
      (m) => m,
    );
    for (final region in const [requestsRegion, _fallbackRegion]) {
      for (final r in results) {
        if (readString(r['iso_3166_1']) != region) continue;
        for (final d in readList(r['release_dates'], (m) => m)) {
          final c = _nonEmpty(d['certification']);
          if (c != null) return c;
        }
      }
    }
    return null;
  }

  /// The tv content rating for ZA, else US.
  static String? tvCertification(JsonMap details) {
    final results = readList(
      readMap(details['contentRatings'])?['results'],
      (m) => m,
    );
    for (final region in const [requestsRegion, _fallbackRegion]) {
      for (final r in results) {
        if (readString(r['iso_3166_1']) == region) {
          final c = _nonEmpty(r['rating']);
          if (c != null) return c;
        }
      }
    }
    return null;
  }

  static List<String> _names(Object? list) => [
    for (final g in readList(list, (m) => m)) ?_nonEmpty(g['name']),
  ];

  /// `GET /movie/{id}` → [MovieTitle].
  MovieTitle movieTitle(
    JsonMap d, {
    required MediaState? media,
    required RequestEligibility eligibility,
  }) {
    final date = _date(d['releaseDate']);
    final collection = readMap(d['collection']);
    final collectionId = readInt(collection?['id']);
    final crew = readList(readMap(d['credits'])?['crew'], (m) => m);
    return MovieTitle(
      tmdbId: req(readInt(d['id']), 'id'),
      imdbId:
          _nonEmpty(d['imdbId']) ??
          _nonEmpty(readMap(d['externalIds'])?['imdbId']),
      title: readString(d['title']) ?? '',
      originalTitle: _nonEmpty(d['originalTitle']),
      tagline: _nonEmpty(d['tagline']),
      overview: _nonEmpty(d['overview']),
      releaseDate: date,
      year: yearOf(date),
      runtimeMinutes: switch (readInt(d['runtime'])) {
        final r? when r > 0 => r,
        _ => null,
      },
      genres: _names(d['genres']),
      certification: movieCertification(d),
      voteAverage: readDouble(d['voteAverage']),
      voteCount: readInt(d['voteCount']),
      posterPath: poster(d['posterPath']),
      backdropPath: backdrop(d['backdropPath']),
      trailer: trailer(d),
      cast: cast(d),
      directors: {
        for (final c in crew)
          if (readString(c['job']) == 'Director') ?_nonEmpty(c['name']),
      }.toList(),
      collection: collectionId == null
          ? null
          : RequestsCollectionRef(
              tmdbId: collectionId,
              name: readString(collection?['name']) ?? '',
            ),
      watchProviders: watchProviders(d),
      media: media,
      request: eligibility,
    );
  }

  /// `GET /tv/{id}` → [TvTitle].
  TvTitle tvTitle(
    JsonMap d, {
    required MediaState? media,
    required RequestEligibility eligibility,
    required List<TvSeason> seasons,
  }) {
    final first = _date(d['firstAirDate']);
    final next = readMap(d['nextEpisodeToAir']);
    final nextSeason = readInt(next?['seasonNumber']);
    final nextEpisode = readInt(next?['episodeNumber']);
    final runtimes = readIntList(d['episodeRunTime']);
    return TvTitle(
      tmdbId: req(readInt(d['id']), 'id'),
      imdbId: _nonEmpty(readMap(d['externalIds'])?['imdbId']),
      title: readString(d['name']) ?? '',
      originalTitle: _nonEmpty(d['originalName']),
      tagline: _nonEmpty(d['tagline']),
      overview: _nonEmpty(d['overview']),
      year: yearOf(first),
      genres: _names(d['genres']),
      certification: tvCertification(d),
      voteAverage: readDouble(d['voteAverage']),
      voteCount: readInt(d['voteCount']),
      posterPath: poster(d['posterPath']),
      backdropPath: backdrop(d['backdropPath']),
      trailer: trailer(d),
      cast: cast(d),
      watchProviders: watchProviders(d),
      media: media,
      request: eligibility,
      firstAirDate: first,
      lastAirDate: _date(d['lastAirDate']),
      status: readString(d['status']) ?? '',
      networks: _names(d['networks']),
      creators: _names(d['createdBy']),
      episodeRuntimeMinutes: runtimes.isEmpty ? null : runtimes.first,
      numberOfSeasons: readInt(d['numberOfSeasons']) ?? 0,
      numberOfEpisodes: readInt(d['numberOfEpisodes']) ?? 0,
      tvdbId: readInt(readMap(d['externalIds'])?['tvdbId']),
      nextEpisode: nextSeason == null || nextEpisode == null
          ? null
          : RequestsNextEpisode(
              seasonNumber: nextSeason,
              episodeNumber: nextEpisode,
              name: _nonEmpty(next?['name']),
              airDate: _date(next?['airDate']),
            ),
      seasons: seasons,
    );
  }

  /// `GET /movie/{id}/ratingscombined` or `GET /tv/{id}/ratings`.
  static Ratings ratings(MediaType type, JsonMap j) {
    final rt = type == MediaType.movie ? readMap(j['rt']) : j;
    final imdb = type == MediaType.movie ? readMap(j['imdb']) : null;
    final hasRt =
        rt != null &&
        (rt['criticsScore'] != null || rt['audienceScore'] != null);
    final hasImdb = imdb != null && imdb['criticsScore'] != null;
    return Ratings(
      rottenTomatoes: hasRt
          ? RatingsRottenTomatoes(
              criticsScore: readInt(rt['criticsScore']),
              audienceScore: readInt(rt['audienceScore']),
              criticsRating: _nonEmpty(rt['criticsRating']),
              url: _nonEmpty(rt['url']),
            )
          : null,
      imdb: hasImdb
          ? RatingsImdb(
              score: readDouble(imdb['criticsScore']),
              url: _nonEmpty(imdb['url']),
            )
          : null,
    );
  }

  /// `GET /tv/{id}/season/{n}` → [SeasonEpisodes].
  SeasonEpisodes seasonEpisodes(JsonMap j) => SeasonEpisodes(
    seasonNumber: req(readInt(j['seasonNumber']), 'seasonNumber'),
    name: readString(j['name']) ?? '',
    overview: _nonEmpty(j['overview']),
    episodes: [
      for (final e in readList(j['episodes'], (m) => m))
        if (readInt(e['episodeNumber']) case final n?)
          SeasonEpisode(
            episodeNumber: n,
            name: readString(e['name']) ?? 'Episode $n',
            airDate: _date(e['airDate']),
            overview: _nonEmpty(e['overview']),
            stillPath: images.tmdb(
              readString(e['stillPath']),
              RequestsImageSizes.still,
            ),
          ),
    ],
  );

  // -------------------------------------------------------------------------
  // Issues
  // -------------------------------------------------------------------------

  /// A Seerr Issue joined with [info]; [withComments] false gives the list
  /// shape (`commentCount` only).
  Issue issue(JsonMap i, {required TitleInfo info, bool withComments = true}) {
    final media = readMap(i['media']);
    final comments = readList(i['comments'], (m) => m);
    int? zeroIsNull(Object? v) => switch (readInt(v)) {
      final n? when n > 0 => n,
      _ => null,
    };
    final createdBy = readMap(i['createdBy']);
    return Issue(
      id: req(readInt(i['id']), 'id'),
      type: issueType(i['issueType']),
      status: issueStatus(i['status']),
      mediaType: mediaType(media?['mediaType']),
      tmdbId: req(readInt(media?['tmdbId']), 'media.tmdbId'),
      title: info.title,
      posterPath: info.posterPath,
      season: zeroIsNull(i['problemSeason']),
      episode: zeroIsNull(i['problemEpisode']),
      createdBy: createdBy == null
          ? const IssueUser(id: 0, displayName: 'Unknown')
          : issueUser(createdBy),
      createdAt: req(readInstant(i['createdAt']), 'createdAt'),
      updatedAt:
          readInstant(i['updatedAt']) ??
          req(readInstant(i['createdAt']), 'createdAt'),
      commentCount: comments.length,
      comments: withComments
          ? [
              for (final c in comments)
                IssueComment(
                  id: req(readInt(c['id']), 'comment.id'),
                  message: readString(c['message']) ?? '',
                  author: switch (readMap(c['user'])) {
                    final u? => issueUser(u),
                    null => const IssueUser(id: 0, displayName: 'Unknown'),
                  },
                  createdAt: req(readInstant(c['createdAt']), 'createdAt'),
                ),
            ]
          : const [],
    );
  }

  /// `GET /issue/count`: `others → other`, `closed → resolved`.
  static IssueCounts issueCounts(JsonMap j) => IssueCounts(
    total: readInt(j['total']) ?? 0,
    video: readInt(j['video']) ?? 0,
    audio: readInt(j['audio']) ?? 0,
    subtitles: readInt(j['subtitles']) ?? 0,
    other: readInt(j['others']) ?? 0,
    open: readInt(j['open']) ?? 0,
    resolved: readInt(j['closed']) ?? 0,
  );

  static String? _nonEmpty(Object? v) {
    final s = readString(v)?.trim();
    return (s == null || s.isEmpty) ? null : s;
  }
}
