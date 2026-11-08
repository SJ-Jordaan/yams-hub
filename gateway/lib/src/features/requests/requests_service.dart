/// Shared state of the requests feature: the Seerr client, the caller's
/// Seerr identity, the caches and the title join (API.md §6).
library;

import 'dart:async';

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'seerr_client.dart';
import 'seerr_mapper.dart';

/// Upstream timeout for `POST /request` (Seerr sends approved requests to
/// the *arr inside the call).
const seerrCreateTimeout = Duration(seconds: 30);

/// Timeout for TMDB-backed Seerr lookups (details are 100–150 KB cold).
const seerrDetailsTimeout = Duration(seconds: 15);

/// Who a call runs as in Seerr (API.md §6 identity rule).
final class SeerrActor {
  const SeerrActor({required this.isAdmin, this.link});

  final bool isAdmin;

  /// The caller's Seerr user: their link, or Seerr user 1 for admins
  /// without one. Null for unlinked members.
  final SeerrLink? link;

  bool get linked => link != null;

  int? get seerrUserId => link?.seerrUserId;

  /// The `X-API-User` value: members act as their Seerr user, admins as the
  /// Seerr admin (no header).
  int? get asUser => isAdmin ? null : link?.seerrUserId;

  RequestViewer get viewer =>
      RequestViewer(isAdmin: isAdmin, seerrUserId: seerrUserId);

  /// Cache key of per-caller data.
  String get cacheKey =>
      isAdmin ? 'admin:${seerrUserId ?? 1}' : 'user:${seerrUserId ?? '-'}';

  /// `403 seerr_user_not_linked` for members without a Seerr account.
  void requireLinked() {
    if (isAdmin || linked) return;
    throw const ApiException(
      403,
      ApiErrorCode.seerrUserNotLinked,
      'Your account is not linked to Seerr. Ask the admin to link it.',
      service: ServiceId.seerr,
    );
  }
}

/// One Seerr request list page as returned upstream.
final class SeerrRequestPage {
  const SeerrRequestPage(this.results, this.total);

  final List<JsonMap> results;
  final int total;
}

/// Caches, identity and joins shared by the requests handlers.
final class RequestsService {
  RequestsService(this.ctx)
    : seerr = SeerrClient(ctx.upstreams.seerr),
      mapper = SeerrMapper(
        images: ctx.images,
        now: ctx.clock.now,
        link: ctx.jellyfin.itemLink,
      ),
      discover = ctx.caches.ttl<String, TitlePage>(
        'requests.discover',
        const Duration(minutes: 10),
        maxEntries: 300,
      ),
      watchlist = ctx.caches.ttl<String, TitlePage>(
        'requests.watchlist',
        const Duration(minutes: 10),
        maxEntries: 200,
      ),
      search = ctx.caches.ttl<String, TitlePage>(
        'requests.search',
        const Duration(minutes: 5),
        maxEntries: 300,
      ),
      genres = ctx.caches.ttl<MediaType, List<Genre>>(
        'requests.genres',
        const Duration(hours: 24),
      ),
      details = ctx.caches.ttl<String, JsonMap>(
        'requests.details',
        const Duration(seconds: 30),
        maxStale: const Duration(hours: 6),
        maxEntries: 200,
      ),
      titles = ctx.caches.ttl<String, TitleInfo>(
        'requests.titles',
        const Duration(hours: 24),
        maxEntries: 500,
      ),
      ratings = ctx.caches.ttl<String, Ratings>(
        'requests.ratings',
        const Duration(hours: 24),
        maxEntries: 300,
      ),
      related = ctx.caches.ttl<String, TitlePage>(
        'requests.related',
        const Duration(hours: 6),
        maxEntries: 300,
      ),
      seasons = ctx.caches.ttl<String, SeasonEpisodes>(
        'requests.seasons',
        const Duration(hours: 6),
        maxEntries: 200,
      ),
      requestPages = ctx.caches.ttl<String, SeerrRequestPage>(
        'requests.list',
        const Duration(seconds: 15),
        maxEntries: 200,
      ),
      declined = ctx.caches.ttl<String, List<JsonMap>>(
        'requests.declined',
        const Duration(seconds: 15),
        maxEntries: 50,
      ),
      counts = ctx.caches.ttl<int, RequestCounts>(
        'requests.counts',
        const Duration(seconds: 15),
      ),
      issueCounts = ctx.caches.ttl<int, IssueCounts>(
        'requests.issueCounts',
        const Duration(seconds: 15),
      ),
      options = ctx.caches.ttl<int, RequestsOptions>(
        'requests.options',
        const Duration(minutes: 10),
      ),
      card = ctx.caches.ttl<String, RequestsCard>(
        'requests.card',
        const Duration(seconds: 30),
        maxEntries: 100,
      );

  final FeatureContext ctx;
  final SeerrClient seerr;
  final SeerrMapper mapper;

  final TtlCache<String, TitlePage> discover;

  /// Keyed by `seerrUserId:page`.
  final TtlCache<String, TitlePage> watchlist;
  final TtlCache<String, TitlePage> search;
  final TtlCache<MediaType, List<Genre>> genres;

  /// Slimmed Seerr details by `type:tmdbId` (30 s, served stale up to 6 h).
  final TtlCache<String, JsonMap> details;

  /// The title join (`type:tmdbId`, 24 h, LRU 500).
  final TtlCache<String, TitleInfo> titles;
  final TtlCache<String, Ratings> ratings;
  final TtlCache<String, TitlePage> related;
  final TtlCache<String, SeasonEpisodes> seasons;

  /// Raw request list pages by upstream query (+ caller).
  final TtlCache<String, SeerrRequestPage> requestPages;

  /// `take=500` lists for the declined filter by (caller, sort, mediaType).
  final TtlCache<String, List<JsonMap>> declined;
  final TtlCache<int, RequestCounts> counts;
  final TtlCache<int, IssueCounts> issueCounts;
  final TtlCache<int, RequestsOptions> options;

  /// The dashboard card by caller.
  final TtlCache<String, RequestsCard> card;

  /// The caller's Seerr identity. `503 service_not_configured` when Seerr
  /// has no URL/key.
  Future<SeerrActor> actor(ApiRequest req) async {
    if (!seerr.configured) {
      throw ApiException.serviceNotConfigured(ServiceId.seerr);
    }
    final link = await ctx.seerrIdentity.forUser(req.user);
    return SeerrActor(isAdmin: req.isAdmin, link: link);
  }

  /// Seerr's flags (4K, partial requests, specials); defaults when the call
  /// fails.
  Future<SeerrFlags> flags() async {
    try {
      return await ctx.seerrSettings.flags();
    } on Object catch (e) {
      ctx.log.fine('Seerr settings unavailable: $e');
      return const SeerrFlags();
    }
  }

  /// The Jellyfin server id for "Play in Jellyfin" links (null if unknown).
  Future<String?> jellyfinServerId() => ctx.jellyfin.serverId();

  // -------------------------------------------------------------------------
  // Titles
  // -------------------------------------------------------------------------

  static String titleKey(MediaType type, int tmdbId) => '${type.name}:$tmdbId';

  static String _detailsPath(MediaType type, int tmdbId) =>
      type == MediaType.tv ? '/api/v1/tv/$tmdbId' : '/api/v1/movie/$tmdbId';

  /// The (slimmed) Seerr details of a title; unknown TMDB ids are
  /// `404 not_found`. Also refreshes the title join.
  Future<JsonMap> titleDetails(MediaType type, int tmdbId) {
    final key = titleKey(type, tmdbId);
    return details.value(key, () async {
      final raw = await seerr.getMap(
        _detailsPath(type, tmdbId),
        timeout: seerrDetailsTimeout,
        tmdbLookup: true,
      );
      final slim = _slim(raw);
      titles.put(key, mapper.titleInfo(slim));
      return slim;
    });
  }

  /// The joined title of [type]/[tmdbId]; a fallback name when the lookup
  /// fails (never cached).
  Future<TitleInfo> titleInfo(MediaType type, int tmdbId) async {
    if (type == MediaType.unknown) return TitleInfo.fallback(type, tmdbId);
    try {
      return await titles.value(
        titleKey(type, tmdbId),
        () async => mapper.titleInfo(await titleDetails(type, tmdbId)),
      );
    } on Object catch (e) {
      ctx.log.fine('title join failed for ${type.name}:$tmdbId: $e');
      return TitleInfo.fallback(type, tmdbId);
    }
  }

  /// Joins many titles, at most 6 upstream lookups at a time.
  Future<Map<String, TitleInfo>> titleInfos(
    Iterable<(MediaType, int)> keys,
  ) async {
    final unique = {for (final k in keys) titleKey(k.$1, k.$2): k};
    final out = <String, TitleInfo>{};
    final entries = unique.entries.toList();
    for (var i = 0; i < entries.length; i += 6) {
      final batch = entries.skip(i).take(6);
      await Future.wait([
        for (final e in batch)
          titleInfo(e.value.$1, e.value.$2).then((info) => out[e.key] = info),
      ]);
    }
    return out;
  }

  /// Keeps what the hub uses of a 100–150 KB details response: top cast,
  /// directors, ZA/US certifications, ZA providers.
  static JsonMap _slim(JsonMap d) {
    const keep = {
      'id',
      'imdbId',
      'title',
      'name',
      'originalTitle',
      'originalName',
      'tagline',
      'overview',
      'releaseDate',
      'firstAirDate',
      'lastAirDate',
      'runtime',
      'episodeRunTime',
      'status',
      'genres',
      'voteAverage',
      'voteCount',
      'posterPath',
      'backdropPath',
      'relatedVideos',
      'collection',
      'externalIds',
      'mediaInfo',
      'networks',
      'createdBy',
      'numberOfSeasons',
      'numberOfEpisodes',
      'nextEpisodeToAir',
      'seasons',
    };
    const regions = {requestsRegion, 'US'};
    final out = <String, Object?>{
      for (final e in d.entries)
        if (keep.contains(e.key)) e.key: e.value,
    };
    final credits = readMap(d['credits']);
    if (credits != null) {
      final cast = readList(credits['cast'], (m) => m)
        ..sort(
          (a, b) => (readInt(a['order']) ?? 999).compareTo(
            readInt(b['order']) ?? 999,
          ),
        );
      out['credits'] = {
        'cast': cast.take(12).toList(),
        'crew': [
          for (final c in readList(credits['crew'], (m) => m))
            if (readString(c['job']) == 'Director') c,
        ],
      };
    }
    final releases = readMap(d['releases']);
    if (releases != null) {
      out['releases'] = {
        'results': [
          for (final r in readList(releases['results'], (m) => m))
            if (regions.contains(readString(r['iso_3166_1']))) r,
        ],
      };
    }
    final ratings = readMap(d['contentRatings']);
    if (ratings != null) {
      out['contentRatings'] = {
        'results': [
          for (final r in readList(ratings['results'], (m) => m))
            if (regions.contains(readString(r['iso_3166_1']))) r,
        ],
      };
    }
    out['watchProviders'] = [
      for (final w in readList(d['watchProviders'], (m) => m))
        if (readString(w['iso_3166_1']) == requestsRegion) w,
    ];
    return out;
  }

  // -------------------------------------------------------------------------
  // Requests
  // -------------------------------------------------------------------------

  /// A raw Seerr request list page (cached 15 s by query and caller).
  Future<SeerrRequestPage> requestPage(String query, {int? asUser}) =>
      requestPages.value('${asUser ?? 'admin'}|$query', () async {
        final j = await seerr.getMap(
          '/api/v1/request',
          query: query,
          asUser: asUser,
          resourceNotFound: false,
        );
        final results = readList(j['results'], (m) => m);
        final total =
            readInt(readMap(j['pageInfo'])?['results']) ?? results.length;
        return SeerrRequestPage(results, total);
      });

  /// Maps raw requests to summaries with the title join.
  Future<List<RequestSummary>> summaries(
    List<JsonMap> raw,
    SeerrActor actor,
  ) async {
    if (raw.isEmpty) return const [];
    final serverId = await jellyfinServerId();
    final infos = await titleInfos([
      for (final r in raw)
        (_typeOf(r), readInt(readMap(r['media'])?['tmdbId']) ?? 0),
    ]);
    return [
      for (final r in raw)
        mapper.requestSummary(
          r,
          info:
              infos[titleKey(
                _typeOf(r),
                readInt(readMap(r['media'])?['tmdbId']) ?? 0,
              )] ??
              TitleInfo.fallback(_typeOf(r), 0),
          viewer: actor.viewer,
          jellyfinServerId: serverId,
        ),
    ];
  }

  /// One request as a summary.
  Future<RequestSummary> summary(JsonMap raw, SeerrActor actor) async =>
      (await summaries([raw], actor)).single;

  static MediaType _typeOf(JsonMap r) =>
      SeerrMapper.mediaType(r['type'] ?? readMap(r['media'])?['mediaType']);

  /// `GET /request/count` (cached 15 s).
  Future<RequestCounts> requestCounts() => counts.value(0, () async {
    final j = await seerr.getMap(
      '/api/v1/request/count',
      resourceNotFound: false,
    );
    return SeerrMapper.requestCounts(j);
  });

  /// `GET /issue/count` (cached 15 s).
  Future<IssueCounts> issueCountsValue() => issueCounts.value(0, () async {
    final j = await seerr.getMap(
      '/api/v1/issue/count',
      resourceNotFound: false,
    );
    return SeerrMapper.issueCounts(j);
  });

  /// After any request write: lists, counts and the card.
  void invalidateRequests() {
    requestPages.clear();
    declined.clear();
    counts.clear();
    card.clear();
  }

  /// After a write that changes a title's Seerr state.
  void invalidateTitle(MediaType type, int tmdbId) {
    details.invalidate(titleKey(type, tmdbId));
    // Availability badges on carousels and search results.
    discover.clear();
    search.clear();
    watchlist.clear();
    related.clear();
  }

  /// After an issue write.
  void invalidateIssues() {
    issueCounts.clear();
    card.clear();
  }
}
