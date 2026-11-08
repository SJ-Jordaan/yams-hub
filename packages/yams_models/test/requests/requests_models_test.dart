import 'dart:convert';

import 'package:test/test.dart';
import 'package:yams_models/yams_models.dart';

/// Sends [json] over the wire (encode + decode) like the gateway and app do.
JsonMap _wire(JsonMap json) => jsonDecode(jsonEncode(json)) as JsonMap;

/// Decodes [sample], re-encodes it and checks the result equals [sample].
T _roundTrip<T>(
  JsonMap sample,
  T Function(JsonMap) fromJson,
  JsonMap Function(T) toJson,
) {
  final decoded = fromJson(_wire(sample));
  expect(_wire(toJson(decoded)), equals(sample));
  return decoded;
}

const _user = {
  'id': 1,
  'displayName': 'Paul Greyrat',
  'avatarPath': '/api/v1/img/seerr-avatar/1?v=1791693617000',
};

final _request = <String, Object?>{
  'id': 196,
  'status': 'completed',
  'mediaType': 'tv',
  'tmdbId': 33880,
  'title': 'The Legend of Korra',
  'year': 2012,
  'posterPath': '/api/v1/img/tmdb/w342/abc.jpg',
  'seasons': [
    {'seasonNumber': 1, 'status': 'completed'},
    {'seasonNumber': 2, 'status': 'approved'},
  ],
  'availability': 'available',
  'requestedBy': _user,
  'modifiedBy': _user,
  'createdAt': '2026-10-25T04:53:17Z',
  'updatedAt': '2026-10-25T06:25:08Z',
  'profileName': 'WEB-1080p',
  'downloads': [
    {
      'title': 'Korra.S02E01.1080p',
      'progress': 0.25,
      'etaSeconds': 600,
      'status': 'downloading',
    },
  ],
  'jellyfin': {
    'app': 'jellyfin',
    'path': '/web/#/details?id=6e332b664756b794942cae8a5ea3b1c0&serverId=79315eab3c4c401f8391d5c26210b6d7',
  },
  'seerrMediaId': 428,
  'libraryId': 163,
  'canApprove': false,
  'canDecline': false,
  'canRetry': false,
  'canDelete': true,
};

final _media = <String, Object?>{
  'seerrMediaId': 79,
  'availability': 'partial',
  'requests': [_request],
  'downloads': <Object?>[],
  'libraryId': 163,
  'openIssues': 2,
};

void main() {
  group('enums', () {
    test('map unknown strings to unknown and never throw', () {
      expect(MediaType.fromJson('person'), MediaType.unknown);
      expect(Availability.fromJson('archived'), Availability.unknown);
      expect(RequestStatus.fromJson(3), RequestStatus.unknown);
      expect(RequestStatus.fromJsonOrNull(null), isNull);
      expect(IssueType.fromJson('picture'), IssueType.unknown);
      expect(IssueStatus.fromJson('closed'), IssueStatus.unknown);
      expect(IssueStatus.fromJson('resolved'), IssueStatus.resolved);
      expect(
        CreateRequestOutcome.fromJson('queued'),
        CreateRequestOutcome.unknown,
      );
      expect(RequestEligibilityReason.fromJsonOrNull(null), isNull);
      expect(
        RequestEligibilityReason.fromJsonOrNull('nope'),
        RequestEligibilityReason.unknown,
      );
      expect(
        RequestsWatchProviderType.fromJson('ads'),
        RequestsWatchProviderType.unknown,
      );
    });
  });

  group('discover', () {
    test('TitleCard round trips full and minimal', () {
      _roundTrip(
        {
          'mediaType': 'movie',
          'tmdbId': 438631,
          'title': 'Dune',
          'year': 2021,
          'releaseDate': '2021-09-15',
          'overview': 'Paul Atreides...',
          'posterPath': '/api/v1/img/tmdb/w342/v1tRXZ4JtD2Iv6fjkPvT4GiwslV.jpg',
          'backdropPath': '/api/v1/img/tmdb/w780/back.jpg',
          'voteAverage': 7.8,
          'availability': 'available',
          'requested': false,
        },
        TitleCard.fromJson,
        (c) => c.toJson(),
      );
      final minimal = _roundTrip(
        {
          'mediaType': 'tv',
          'tmdbId': 1,
          'title': 'X',
          'availability': 'none',
          'requested': true,
        },
        TitleCard.fromJson,
        (c) => c.toJson(),
      );
      expect(minimal.year, isNull);
    });

    test('a missing availability means none', () {
      final c = TitleCard.fromJson({
        'mediaType': 'tv',
        'tmdbId': 2,
        'title': 'Y',
      });
      expect(c.availability, Availability.none);
      expect(c.requested, isFalse);
    });

    test('TitlePage round trips and knows when there is more', () {
      final p = _roundTrip(
        {
          'page': 1,
          'totalPages': 500,
          'totalResults': 10000,
          'items': [
            {
              'mediaType': 'movie',
              'tmdbId': 1,
              'title': 'A',
              'availability': 'none',
              'requested': false,
            },
          ],
        },
        TitlePage.fromJson,
        (p) => p.toJson(),
      );
      expect(p.hasMore, isTrue);
      expect(const TitlePage.empty().toJson(), {
        'page': 1,
        'totalPages': 0,
        'totalResults': 0,
        'items': <Object?>[],
      });
      expect(const TitlePage.empty().hasMore, isFalse);
    });

    test('Genre round trips', () {
      _roundTrip(
        {'id': 28, 'name': 'Action'},
        Genre.fromJson,
        (g) => g.toJson(),
      );
    });
  });

  group('requests', () {
    test('RequestSummary round trips with every field', () {
      final r = _roundTrip(
        _request,
        RequestSummary.fromJson,
        (r) => r.toJson(),
      );
      expect(r.status, RequestStatus.completed);
      expect(r.seasons.last.status, RequestStatus.approved);
      expect(r.downloads.single.progress, 0.25);
      expect(r.jellyfin!.app, ExternalApp.jellyfin);
      expect(r.libraryId, 163);
      expect(r.createdAt.isUtc, isTrue);
    });

    test('RequestSummary needs requestedBy', () {
      final broken = Map<String, Object?>.of(_request)..remove('requestedBy');
      expect(() => RequestSummary.fromJson(broken), throwsFormatException);
    });

    test('CreateRequest reads "all" and season lists', () {
      final all = _roundTrip(
        {'mediaType': 'tv', 'tmdbId': 10545, 'seasons': 'all'},
        CreateRequest.fromJson,
        (c) => c.toJson(),
      );
      expect(all.allSeasons, isTrue);
      expect(all.seasons, isNull);
      final some = _roundTrip(
        {
          'mediaType': 'tv',
          'tmdbId': 10545,
          'seasons': [4, 5],
          'advanced': {
            'serverId': 0,
            'profileId': 9,
            'rootFolder': '/data/tvshows',
          },
        },
        CreateRequest.fromJson,
        (c) => c.toJson(),
      );
      expect(some.seasons, [4, 5]);
      expect(some.advanced!.serverId, 0);
      expect(some.advanced!.isEmpty, isFalse);
      final movie = _roundTrip(
        {'mediaType': 'movie', 'tmdbId': 818},
        CreateRequest.fromJson,
        (c) => c.toJson(),
      );
      expect(movie.allSeasons, isFalse);
      expect(const CreateRequestAdvanced().isEmpty, isTrue);
    });

    test('CreateRequestResult round trips with and without a request', () {
      final created = _roundTrip(
        {'outcome': 'autoApproved', 'request': _request},
        CreateRequestResult.fromJson,
        (r) => r.toJson(),
      );
      expect(created.outcome, CreateRequestOutcome.autoApproved);
      final nothing = _roundTrip(
        {'outcome': 'nothingToRequest'},
        CreateRequestResult.fromJson,
        (r) => r.toJson(),
      );
      expect(nothing.request, isNull);
    });

    test('RequestUpdate round trips', () {
      _roundTrip(
        {
          'seasons': [1, 2],
          'advanced': {'profileId': 4},
        },
        RequestUpdate.fromJson,
        (r) => r.toJson(),
      );
      _roundTrip(
        <String, Object?>{},
        RequestUpdate.fromJson,
        (r) => r.toJson(),
      );
    });

    test('RequestCounts round trips and defaults to zero', () {
      _roundTrip(
        {
          'total': 127,
          'movie': 42,
          'tv': 85,
          'pending': 0,
          'approved': 4,
          'processing': 3,
          'available': 1,
          'declined': 0,
          'completed': 122,
          'failed': 1,
        },
        RequestCounts.fromJson,
        (c) => c.toJson(),
      );
      expect(RequestCounts.fromJson({'pending': 3}).total, 0);
    });

    test('RequestsOptions round trips; serverId 0 is valid', () {
      final o = _roundTrip(
        {
          'radarr': [
            {
              'serverId': 0,
              'name': 'Radarr',
              'isDefault': true,
              'defaultProfileId': 7,
              'defaultRootFolder': '/data/movies',
              'profiles': [
                {'id': 7, 'name': 'HD Bluray + WEB'},
              ],
              'rootFolders': [
                {'path': '/data/movies', 'freeBytes': 4048914296832},
              ],
            },
          ],
          'sonarr': [
            {
              'serverId': 0,
              'name': 'Sonarr',
              'isDefault': true,
              'defaultProfileId': 9,
              'defaultAnimeProfileId': 7,
              'defaultRootFolder': '/data/tvshows',
              'profiles': <Object?>[],
              'rootFolders': <Object?>[],
            },
          ],
        },
        RequestsOptions.fromJson,
        (o) => o.toJson(),
      );
      expect(o.radarr.single.serverId, 0);
      expect(o.forMediaType(MediaType.tv).single.defaultAnimeProfileId, 7);
      expect(o.forMediaType(MediaType.movie).single.name, 'Radarr');
    });
  });

  group('titles', () {
    test('MovieTitle round trips with media and eligibility', () {
      final m = _roundTrip(
        {
          'tmdbId': 818,
          'imdbId': 'tt0295178',
          'title': 'Austin Powers in Goldmember',
          'originalTitle': 'Austin Powers in Goldmember',
          'tagline': 'The grooviest movie of the summer',
          'overview': '...',
          'releaseDate': '2002-07-26',
          'year': 2002,
          'runtimeMinutes': 94,
          'genres': ['Comedy'],
          'certification': 'PG-13',
          'voteAverage': 6.2,
          'voteCount': 4321,
          'posterPath': '/api/v1/img/tmdb/w342/p.jpg',
          'backdropPath': '/api/v1/img/tmdb/w780/b.jpg',
          'trailer': {'youtubeKey': 'abc123', 'name': 'Official Trailer'},
          'cast': [
            {
              'name': 'Mike Myers',
              'character': 'Austin Powers',
              'profilePath': '/api/v1/img/tmdb/w185/c.jpg',
            },
          ],
          'directors': ['Jay Roach'],
          'collection': {'tmdbId': 1006, 'name': 'Austin Powers Collection'},
          'watchProviders': [
            {
              'name': 'Netflix',
              'logoPath': '/api/v1/img/tmdb/w92/n.png',
              'type': 'flatrate',
            },
          ],
          'media': _media,
          'request': {
            'canRequest': false,
            'reason': 'available',
            'requestableSeasons': <Object?>[],
          },
        },
        MovieTitle.fromJson,
        (m) => m.toJson(),
      );
      expect(
        m.trailer!.url.toString(),
        'https://www.youtube.com/watch?v=abc123',
      );
      expect(m.media!.requests.single.id, 196);
      expect(m.request.reason, RequestEligibilityReason.available);
      expect(m.watchProviders.single.type, RequestsWatchProviderType.flatrate);
    });

    test('MovieTitle without media keeps a requestable eligibility', () {
      final m = _roundTrip(
        {
          'tmdbId': 603,
          'title': 'The Matrix',
          'genres': <Object?>[],
          'cast': <Object?>[],
          'directors': <Object?>[],
          'watchProviders': <Object?>[],
          'request': {'canRequest': true, 'requestableSeasons': <Object?>[]},
        },
        MovieTitle.fromJson,
        (m) => m.toJson(),
      );
      expect(m.media, isNull);
      expect(m.request.reason, isNull);
    });

    test('TvTitle round trips with seasons', () {
      final t = _roundTrip(
        {
          'tmdbId': 10545,
          'imdbId': 'tt0844441',
          'title': 'True Blood',
          'originalTitle': 'True Blood',
          'overview': '...',
          'year': 2008,
          'genres': ['Drama'],
          'certification': 'TV-MA',
          'voteAverage': 7.0,
          'voteCount': 1800,
          'posterPath': '/api/v1/img/tmdb/w342/p.jpg',
          'cast': <Object?>[],
          'watchProviders': <Object?>[],
          'media': _media,
          'request': {
            'canRequest': true,
            'requestableSeasons': [4, 5, 6, 7],
          },
          'firstAirDate': '2008-09-07',
          'lastAirDate': '2014-08-24',
          'status': 'Ended',
          'networks': ['HBO'],
          'creators': ['Alan Ball'],
          'episodeRuntimeMinutes': 60,
          'numberOfSeasons': 7,
          'numberOfEpisodes': 80,
          'tvdbId': 82283,
          'nextEpisode': {
            'seasonNumber': 8,
            'episodeNumber': 1,
            'name': 'Return',
            'airDate': '2027-01-01',
          },
          'seasons': [
            {
              'seasonNumber': 1,
              'name': 'Season 1',
              'episodeCount': 12,
              'airDate': '2008-09-07',
              'posterPath': '/api/v1/img/tmdb/w342/s1.jpg',
              'availability': 'available',
              'requestStatus': 'completed',
              'requestable': false,
            },
            {
              'seasonNumber': 4,
              'name': 'Season 4',
              'episodeCount': 12,
              'availability': 'none',
              'requestable': true,
            },
          ],
        },
        TvTitle.fromJson,
        (t) => t.toJson(),
      );
      expect(t.seasons.first.requestStatus, RequestStatus.completed);
      expect(t.seasons.last.requestStatus, isNull);
      expect(t.request.requestableSeasons, [4, 5, 6, 7]);
      expect(t.nextEpisode!.episodeNumber, 1);
    });

    test('Ratings round trip and may be empty', () {
      _roundTrip(
        {
          'rottenTomatoes': {
            'criticsScore': 52,
            'audienceScore': 44,
            'criticsRating': 'Rotten',
            'url': 'https://www.rottentomatoes.com/m/x',
          },
          'imdb': {'score': 6.3, 'url': 'https://www.imdb.com/title/tt0295178'},
        },
        Ratings.fromJson,
        (r) => r.toJson(),
      );
      final empty = _roundTrip(
        <String, Object?>{},
        Ratings.fromJson,
        (r) => r.toJson(),
      );
      expect(empty.isEmpty, isTrue);
    });

    test('SeasonEpisodes round trips', () {
      final s = _roundTrip(
        {
          'seasonNumber': 1,
          'name': 'Season 1',
          'overview': 'The first season',
          'episodes': [
            {
              'episodeNumber': 1,
              'name': 'Strange Love',
              'airDate': '2008-09-07',
              'overview': 'Across the country...',
              'stillPath': '/api/v1/img/tmdb/w342/still.jpg',
            },
            {'episodeNumber': 2, 'name': 'The First Taste'},
          ],
        },
        SeasonEpisodes.fromJson,
        (s) => s.toJson(),
      );
      expect(s.episodes, hasLength(2));
    });
  });

  group('issues', () {
    final issue = <String, Object?>{
      'id': 7,
      'type': 'audio',
      'status': 'open',
      'mediaType': 'tv',
      'tmdbId': 10545,
      'title': 'True Blood',
      'posterPath': '/api/v1/img/tmdb/w342/p.jpg',
      'season': 2,
      'episode': 5,
      'createdBy': {'id': 2, 'displayName': 'Zenith Greyrat'},
      'createdAt': '2026-11-01T10:00:00Z',
      'updatedAt': '2026-11-02T10:00:00Z',
      'commentCount': 1,
      'comments': [
        {
          'id': 3,
          'message': 'Audio out of sync from 12:30',
          'author': {'id': 2, 'displayName': 'Zenith Greyrat'},
          'createdAt': '2026-11-01T10:00:00Z',
        },
      ],
    };

    test('Issue round trips with comments', () {
      final i = _roundTrip(issue, Issue.fromJson, (i) => i.toJson());
      expect(i.type, IssueType.audio);
      expect(i.comments.single.author.id, 2);
    });

    test('a list row has commentCount but no comments', () {
      final row = Map<String, Object?>.of(issue)
        ..['comments'] = <Object?>[]
        ..remove('season')
        ..remove('episode');
      final i = _roundTrip(row, Issue.fromJson, (i) => i.toJson());
      expect(i.commentCount, 1);
      expect(i.season, isNull);
    });

    test('IssueCounts and CreateIssue round trip', () {
      _roundTrip(
        {
          'total': 3,
          'video': 1,
          'audio': 1,
          'subtitles': 0,
          'other': 1,
          'open': 2,
          'resolved': 1,
        },
        IssueCounts.fromJson,
        (c) => c.toJson(),
      );
      _roundTrip(
        {
          'mediaType': 'movie',
          'tmdbId': 818,
          'type': 'video',
          'message': 'Green artefacts',
        },
        CreateIssue.fromJson,
        (c) => c.toJson(),
      );
    });
  });

  group('RequestsCard', () {
    test('round trips', () {
      final card = _roundTrip(
        {
          'counts': RequestCounts(pending: 2, failed: 1, total: 3).toJson(),
          'pending': [_request],
          'recent': [_request],
          'openIssues': 4,
        },
        RequestsCard.fromJson,
        (c) => c.toJson(),
      );
      expect(card.counts.pending, 2);
    });

    test('keeps the raw counts.pending key and decodes partial data', () {
      const card = RequestsCard(counts: RequestCounts(pending: 5));
      final counts = card.toJson()['counts']! as Map<String, Object?>;
      expect(counts['pending'], 5);
      final partial = RequestsCard.fromJson({
        'counts': {'pending': 3, 'processing': 1, 'available': 9},
      });
      expect(partial.counts.pending, 3);
      expect(partial.recent, isEmpty);
      expect(partial.openIssues, 0);
    });
  });
}
