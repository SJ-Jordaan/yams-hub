/// Gateway-shaped samples for the requests feature tests.
library;

import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import '../../support/fake_api.dart';

TitleCard card(
  int id,
  String title, {
  MediaType type = MediaType.movie,
  Availability availability = Availability.none,
  int? year = 2021,
}) => TitleCard(
  mediaType: type,
  tmdbId: id,
  title: title,
  year: year,
  posterPath: '/api/v1/img/tmdb/w342/p$id.jpg',
  availability: availability,
  requested: availability == Availability.processing || availability == Availability.pending,
);

JsonMap page(List<TitleCard> items, {int totalPages = 1}) =>
    TitlePage(page: 1, totalPages: totalPages, totalResults: items.length, items: items).toJson();

const paul = RequestUser(id: 1, displayName: 'Paul Greyrat');
const zenith = RequestUser(id: 2, displayName: 'Zenith Greyrat');

RequestSummary request(
  int id, {
  String title = 'True Blood',
  MediaType type = MediaType.tv,
  int tmdbId = 10545,
  RequestStatus status = RequestStatus.pending,
  Availability availability = Availability.pending,
  RequestUser by = zenith,
  bool admin = true,
  int? libraryId,
  List<RequestSeason> seasons = const [
    RequestSeason(seasonNumber: 4, status: RequestStatus.pending),
    RequestSeason(seasonNumber: 5, status: RequestStatus.pending),
  ],
}) => RequestSummary(
  id: id,
  status: status,
  mediaType: type,
  tmdbId: tmdbId,
  title: title,
  year: 2008,
  seasons: type == MediaType.tv ? seasons : const [],
  availability: availability,
  requestedBy: by,
  createdAt: testNow.subtract(const Duration(hours: 2)),
  updatedAt: testNow.subtract(const Duration(hours: 1)),
  libraryId: libraryId,
  canApprove: admin && status == RequestStatus.pending,
  canDecline: admin && status == RequestStatus.pending,
  canRetry: admin && status == RequestStatus.failed,
  canDelete: admin || status == RequestStatus.pending,
);

JsonMap requestPage(List<RequestSummary> items) =>
    PagedList.of(items: items, page: 1, pageSize: 25, total: items.length).toJson((r) => r.toJson());

const counts = RequestCounts(total: 129, pending: 2, approved: 4, processing: 3, completed: 122, failed: 1);

MovieTitle movie({
  int tmdbId = 603,
  String title = 'The Matrix',
  MediaState? media,
  RequestEligibility request = const RequestEligibility(canRequest: true),
}) => MovieTitle(
  tmdbId: tmdbId,
  title: title,
  year: 1999,
  runtimeMinutes: 136,
  certification: '16',
  genres: const ['Action', 'Science Fiction'],
  voteAverage: 8.2,
  overview: 'A hacker learns the truth about reality.',
  tagline: 'Welcome to the Real World.',
  directors: const ['Lana Wachowski'],
  cast: const [RequestsCastMember(name: 'Keanu Reeves', character: 'Neo')],
  trailer: const RequestsTrailer(youtubeKey: 'vKQi3bBA1y8', name: 'Official Trailer'),
  media: media,
  request: request,
);

const jellyfinLink = ExternalLink(
  ExternalApp.jellyfin,
  '/web/#/details?id=4f5731b2c357273bf4002dd8d042a856&serverId=79315eab3c4c401f8391d5c26210b6d7',
);

MediaState availableMedia({List<RequestSummary> requests = const []}) => MediaState(
  seerrMediaId: 79,
  availability: Availability.available,
  requests: requests,
  jellyfin: jellyfinLink,
  libraryId: 818,
);

TvTitle trueBlood({RequestEligibility? request, MediaState? media}) => TvTitle(
  tmdbId: 10545,
  title: 'True Blood',
  year: 2008,
  status: 'Ended',
  networks: const ['HBO'],
  creators: const ['Alan Ball'],
  numberOfSeasons: 7,
  numberOfEpisodes: 80,
  media:
      media ??
      const MediaState(seerrMediaId: 428, availability: Availability.partial, libraryId: 163, jellyfin: jellyfinLink),
  request: request ?? const RequestEligibility(canRequest: true, requestableSeasons: [4, 5, 6, 7]),
  seasons: [
    for (var n = 1; n <= 7; n++)
      TvSeason(
        seasonNumber: n,
        name: 'Season $n',
        episodeCount: n < 6 ? 12 : 10,
        airDate: '${2007 + n}-06-01',
        availability: switch (n) {
          1 || 2 => Availability.available,
          3 => Availability.processing,
          _ => Availability.none,
        },
        requestable: n >= 4,
      ),
  ],
);

Issue issue(
  int id, {
  IssueStatus status = IssueStatus.open,
  IssueUser by = const IssueUser(id: 2, displayName: 'Zenith Greyrat'),
  int commentCount = 2,
  List<IssueComment> comments = const [],
}) => Issue(
  id: id,
  type: IssueType.audio,
  status: status,
  mediaType: MediaType.tv,
  tmdbId: 10545,
  title: 'True Blood',
  season: 2,
  episode: 5,
  createdBy: by,
  createdAt: testNow.subtract(const Duration(days: 1)),
  updatedAt: testNow.subtract(const Duration(hours: 3)),
  commentCount: commentCount,
  comments: comments,
);

/// `/auth/me` for a member linked to Seerr user 2 with [quota].
JsonMap linkedMe({Role role = Role.member, SeerrQuota? quota, bool linked = true}) => MeResponse(
  user: buildUser(role: role),
  session: buildSession(),
  seerr: linked
      ? MeSeerrInfo(linked: true, seerrUserId: 2, displayName: 'Zenith Greyrat', quota: quota)
      : const MeSeerrInfo.unlinked(),
).toJson();

/// `/server` with Seerr partial requests on (the live setting).
JsonMap serverWithPartialRequests() {
  final json = buildServerConfig().toJson();
  json['seerr'] = const ServerSeerrSettings(partialRequestsEnabled: true).toJson();
  return json;
}

/// Answers every discover slider with [items] (watchlist empty).
void serveDiscover(FakeApi api, {List<TitleCard>? items}) {
  final list = items ?? [card(1, 'Dune', availability: Availability.available), card(2, 'Arrival')];
  for (final s in const ['trending', 'popular-movies', 'popular-tv', 'upcoming-movies', 'upcoming-tv']) {
    api.getJson('/discover/$s', page(list));
  }
  api
    ..getJson('/discover/watchlist', const TitlePage.empty().toJson())
    ..getJson('/requests/counts', counts.toJson());
}
