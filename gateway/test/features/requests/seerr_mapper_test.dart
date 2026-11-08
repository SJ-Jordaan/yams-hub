import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/features/requests/seerr_client.dart';
import 'package:yams_hub_gateway/src/features/requests/seerr_mapper.dart';

import '../../support/test_hub.dart';
import 'requests_test_support.dart';

final _now = DateTime.utc(2026, 11, 8, 9);

final _mapper = SeerrMapper(
  images: ImageUrls(const ['image.tmdb.org']),
  now: () => _now,
  link: (id, server) => ExternalLink(
    ExternalApp.jellyfin,
    '/web/#/details?id=$id&serverId=$server',
  ),
);

List<TvSeason> _seasons(JsonMap d, {bool specials = false}) =>
    SeerrMapper.tvSeasons(d, specials: specials, poster: _mapper.poster);

void main() {
  group('strict Seerr query encoding (seerr.md §1.2)', () {
    test('spaces are %20 and ! \' ( ) * are escaped', () {
      expect(seerrEncode('the office'), 'the%20office');
      expect(seerrEncode("grey's"), 'grey%27s');
      expect(seerrEncode('dune(2021)'), 'dune%282021%29');
      expect(seerrEncode('wow!'), 'wow%21');
      expect(seerrEncode('a*b'), 'a%2Ab');
      expect(seerrEncode('tmdb:603'), 'tmdb%3A603');
      expect(seerrEncode('a~b'), 'a~b');
      expect(seerrEncode('a+b'), 'a%2Bb');
    });

    test('seerrQuery skips nulls', () {
      expect(
        seerrQuery({'query': 'the office', 'page': 2, 'genre': null}),
        'query=the%20office&page=2',
      );
    });
  });

  group('enums', () {
    test('MediaStatus and MediaRequestStatus are different enums', () {
      expect(SeerrMapper.availability(null), Availability.none);
      expect(SeerrMapper.availability(1), Availability.none);
      expect(SeerrMapper.availability(4), Availability.partial);
      expect(SeerrMapper.availability(7), Availability.deleted);
      expect(SeerrMapper.availability(42), Availability.unknown);
      expect(SeerrMapper.requestStatus(2), RequestStatus.approved);
      expect(SeerrMapper.requestStatus(4), RequestStatus.failed);
      expect(SeerrMapper.requestStatus(9), RequestStatus.unknown);
      expect(SeerrMapper.issueType(4), IssueType.other);
      expect(SeerrMapper.issueStatus(2), IssueStatus.resolved);
      expect(SeerrMapper.issueStatus(3), IssueStatus.unknown);
      expect(SeerrMapper.issueTypeCode(IssueType.subtitles), 3);
    });
  });

  group('title cards', () {
    test('discover results: poster paths, availability, requested', () {
      final page = _mapper.titlePage(
        fixtureMap('seerr/seerr_discover_trending.json'),
      );
      expect(page.totalPages, 500);
      final first = page.items.first;
      expect(first.mediaType, MediaType.movie);
      expect(first.tmdbId, 1368337);
      expect(first.title, 'The Odyssey');
      expect(first.year, 2026);
      expect(first.releaseDate, '2026-07-15');
      expect(
        first.posterPath,
        '/api/v1/img/tmdb/w342/5rhTDKUhPYvpdQIijFIs5VoWsON.jpg',
      );
      expect(first.backdropPath, startsWith('/api/v1/img/tmdb/w780/'));
      expect(first.availability, Availability.processing);
      expect(first.requested, isTrue);
      expect(page.items[1].availability, Availability.none);
      expect(page.items[1].requested, isFalse);
    });

    test('persons are dropped and tv names are titles', () {
      final page = _mapper.titlePage(
        fixtureMap('seerr/seerr_search_tmdb_id.json'),
      );
      expect(page.items.map((c) => c.mediaType), [
        MediaType.movie,
        MediaType.tv,
      ]);
      expect(page.items.last.title, "Veronica's Closet");
    });

    test('rows without mediaType take the fallback type', () {
      final page = _mapper.titlePage(
        fixtureMap('seerr/seerr_movie_recommendations.json'),
        fallbackType: MediaType.movie,
      );
      expect(page.items, isNotEmpty);
      expect(page.items.every((c) => c.mediaType == MediaType.movie), isTrue);
    });

    test('totalPages is clamped to 500', () {
      final page = _mapper.titlePage({
        'page': 1,
        'totalPages': 1001,
        'totalResults': 20020,
        'results': [],
      });
      expect(page.totalPages, 500);
    });

    test('watchlist rows are a different shape', () {
      final row = readList(
        fixtureMap('seerr/seerr_discover_watchlist.json')['results'],
        (m) => m,
      ).single;
      final card = _mapper.watchlistCard(
        row,
        const TitleInfo(
          title: 'X',
          year: 2025,
          posterPath: '/api/v1/img/tmdb/w342/p.jpg',
        ),
      )!;
      expect(card.mediaType, MediaType.tv);
      expect(card.tmdbId, 260463);
      expect(card.title, 'Daemons of the Shadow Realm');
      expect(card.year, 2025);
      expect(card.availability, Availability.partial);
    });
  });

  group('requests', () {
    const info = TitleInfo(title: 'Gachiakuta', year: 2025);

    test('summary: ids, links, seasons; never email/mediaUrl/serviceUrl', () {
      final raw = readList(
        fixtureMap('seerr/seerr_request_list.json')['results'],
        (m) => m,
      ).first;
      final s = _mapper.requestSummary(
        raw,
        info: info,
        viewer: const RequestViewer(isAdmin: true, seerrUserId: 1),
        jellyfinServerId: '79315eab3c4c401f8391d5c26210b6d7',
      );
      expect(s.id, 197);
      expect(s.status, RequestStatus.completed);
      expect(s.mediaType, MediaType.tv);
      expect(s.tmdbId, 256721);
      expect(s.seerrMediaId, 359);
      expect(s.libraryId, 164);
      expect(s.availability, Availability.available);
      expect(s.seasons.single.seasonNumber, 1);
      expect(s.requestedBy.displayName, 'Paul Greyrat');
      expect(
        s.requestedBy.avatarPath,
        '/api/v1/img/seerr-avatar/1?v=1791693617000',
      );
      expect(
        s.jellyfin!.path,
        '/web/#/details?id=3ad7fd89a120030c9188fdf7bd9c0d83&serverId=79315eab3c4c401f8391d5c26210b6d7',
      );
      expect(s.canApprove, isFalse);
      expect(s.canDelete, isTrue);
      final json = s.toJson().toString();
      expect(json, isNot(contains('redacted@example.com')));
      expect(json, isNot(contains('192.168.10.183')));
      expect(json, isNot(contains('sonarr:8989')));
    });

    test('failed request: retry for admins, no library id yet', () {
      final raw = fixtureMap('seerr/seerr_request_detail_failed.json');
      final admin = _mapper.requestSummary(
        raw,
        info: info,
        viewer: const RequestViewer(isAdmin: true, seerrUserId: 1),
      );
      expect(admin.status, RequestStatus.failed);
      expect(admin.seasons.single.status, RequestStatus.approved);
      expect(admin.availability, Availability.none);
      expect(admin.libraryId, isNull);
      expect(admin.canRetry, isTrue);
      final member = _mapper.requestSummary(
        raw,
        info: info,
        viewer: const RequestViewer(isAdmin: false, seerrUserId: 2),
      );
      expect(member.canRetry, isFalse);
      expect(member.canDelete, isFalse);
    });

    test('owners may delete their pending requests', () {
      final raw =
          synthetic('seerr_request_created_pending.synthetic.json')! as JsonMap;
      final owner = _mapper.requestSummary(
        raw,
        info: info,
        viewer: const RequestViewer(isAdmin: false, seerrUserId: 2),
      );
      expect(owner.canDelete, isTrue);
      expect(owner.canApprove, isFalse);
      final other = _mapper.requestSummary(
        raw,
        info: info,
        viewer: const RequestViewer(isAdmin: false, seerrUserId: 3),
      );
      expect(other.canDelete, isFalse);
      final admin = _mapper.requestSummary(
        raw,
        info: info,
        viewer: const RequestViewer(isAdmin: true),
      );
      expect(admin.canApprove && admin.canDecline && admin.canDelete, isTrue);
    });

    test(
      'downloads: progress = 1 - sizeLeft/size, eta from completion time',
      () {
        final d = _mapper.downloads({
          'downloadStatus': [
            {
              'mediaType': 'movie',
              'externalId': 818,
              'size': 1000,
              'sizeLeft': 250,
              'status': 'downloading',
              'timeLeft': '00:10:00',
              'estimatedCompletionTime': '2026-11-08T09:10:00.000Z',
              'title': 'Austin.Powers.2002.1080p',
              'downloadId': 'abc',
            },
            {'size': 0, 'sizeLeft': 0, 'status': 'queued', 'title': 'x'},
          ],
        });
        expect(d.first.progress, 0.75);
        expect(d.first.etaSeconds, 600);
        expect(d.first.status, 'downloading');
        expect(d.last.progress, 0);
        expect(d.last.etaSeconds, isNull);
      },
    );

    test(
      'counts: failed = total - pending - approved - declined - completed',
      () {
        final c = SeerrMapper.requestCounts(
          fixtureMap('seerr/seerr_request_count.json'),
        );
        expect(c.total, 127);
        expect(c.processing, 3);
        expect(c.failed, 1);
        expect(
          SeerrMapper.requestCounts({'total': 1, 'completed': 5}).failed,
          0,
        );
      },
    );

    test('service options keep serverId 0', () {
      final server = readList(
        fixture('seerr/seerr_service_sonarr.json'),
        (m) => m,
      ).single;
      final o = SeerrMapper.serviceOptions(
        server,
        fixtureMap('seerr/seerr_service_sonarr_detail.json'),
      );
      expect(o.serverId, 0);
      expect(o.defaultProfileId, 9);
      expect(o.defaultAnimeProfileId, 7);
      expect(o.defaultRootFolder, '/data/tvshows');
      expect(o.profiles, hasLength(5));
      expect(o.rootFolders.single.freeBytes, 4048914296832);
    });
  });

  group('titles', () {
    test('available movie: slimmed fields, media state, not requestable', () {
      final d = fixtureMap('seerr/seerr_movie_details_available.json');
      final info = _mapper.titleInfo(d);
      final media = _mapper.mediaState(
        d,
        info: info,
        viewer: const RequestViewer(isAdmin: true, seerrUserId: 1),
        jellyfinServerId: '79315eab3c4c401f8391d5c26210b6d7',
      )!;
      final m = _mapper.movieTitle(
        d,
        media: media,
        eligibility: SeerrMapper.movieEligibility(d, linked: true),
      );
      expect(m.tmdbId, 818);
      expect(m.imdbId, 'tt0295178');
      expect(m.year, 2002);
      expect(m.runtimeMinutes, 94);
      expect(m.genres, ['Comedy', 'Crime']);
      expect(m.trailer!.youtubeKey, 'JuOVbayBr0I');
      expect(m.directors, ['Jay Roach']);
      expect(m.cast.first.name, 'Mike Myers');
      expect(m.cast.length, lessThanOrEqualTo(12));
      expect(m.cast.first.profilePath, startsWith('/api/v1/img/tmdb/w185/'));
      expect(m.collection!.tmdbId, 1006);
      // The trimmed fixture has neither ZA nor US entries.
      expect(m.certification, isNull);
      expect(m.watchProviders, isEmpty);
      expect(
        media.seerrMediaId,
        d['mediaInfo'] is Map ? (d['mediaInfo']! as Map)['id'] : null,
      );
      expect(media.availability, Availability.available);
      expect(media.requests.single.id, 195);
      expect(media.requests.single.title, 'Austin Powers in Goldmember');
      expect(media.jellyfin, isNotNull);
      expect(media.openIssues, 0);
      expect(m.request.canRequest, isFalse);
      expect(m.request.reason, RequestEligibilityReason.available);
    });

    test('ZA certification and providers win over US', () {
      final d = fixtureMap('seerr/seerr_movie_details_available.json')
        ..['releases'] = {
          'results': [
            {
              'iso_3166_1': 'US',
              'release_dates': [
                {'certification': 'PG-13', 'type': 3},
              ],
            },
            {
              'iso_3166_1': 'ZA',
              'release_dates': [
                {'certification': '', 'type': 1},
                {'certification': '13', 'type': 3},
              ],
            },
          ],
        }
        ..['watchProviders'] = [
          {
            'iso_3166_1': 'US',
            'flatrate': [
              {'name': 'Hulu', 'logoPath': '/h.png'},
            ],
          },
          {
            'iso_3166_1': 'ZA',
            'flatrate': [
              {'name': 'Netflix', 'logoPath': '/n.png'},
            ],
            'rent': [
              {'name': 'Apple TV', 'logoPath': '/a.png'},
            ],
          },
        ];
      final m = _mapper.movieTitle(
        d,
        media: null,
        eligibility: const RequestEligibility(canRequest: false),
      );
      expect(m.certification, '13');
      expect(m.watchProviders.map((p) => '${p.name}:${p.type.name}'), [
        'Netflix:flatrate',
        'Apple TV:rent',
      ]);
      expect(m.watchProviders.first.logoPath, '/api/v1/img/tmdb/w92/n.png');
    });

    test('movie not in Seerr: no media, requestable unless unlinked', () {
      final d = fixtureMap('seerr/seerr_movie_details_not_in_db.json');
      expect(
        _mapper.mediaState(
          d,
          info: _mapper.titleInfo(d),
          viewer: const RequestViewer(isAdmin: true),
        ),
        isNull,
      );
      expect(SeerrMapper.movieEligibility(d, linked: true).canRequest, isTrue);
      final unlinked = SeerrMapper.movieEligibility(d, linked: false);
      expect(unlinked.canRequest, isFalse);
      expect(unlinked.reason, RequestEligibilityReason.notLinked);
    });

    test(
      'partially available series: per-season state, seasons 4-7 requestable',
      () {
        final d = fixtureMap('seerr/seerr_tv_details_partially_available.json');
        final seasons = _seasons(d);
        expect(seasons.map((s) => s.seasonNumber), [1, 2, 3, 4, 5, 6, 7]);
        expect(seasons[0].availability, Availability.available);
        expect(seasons[0].requestStatus, RequestStatus.completed);
        expect(seasons[2].availability, Availability.processing);
        expect(seasons[2].requestable, isFalse);
        expect(seasons[3].availability, Availability.none);
        expect(seasons[3].requestable, isTrue);
        expect(seasons.first.posterPath, startsWith('/api/v1/img/tmdb/w342/'));
        final e = SeerrMapper.tvEligibility(d, seasons, linked: true);
        expect(e.canRequest, isTrue);
        expect(e.reason, isNull);
        expect(e.requestableSeasons, [4, 5, 6, 7]);
        final t = _mapper.tvTitle(
          d,
          media: null,
          eligibility: e,
          seasons: seasons,
        );
        expect(t.title, 'True Blood');
        expect(t.status, 'Ended');
        expect(t.networks, ['HBO']);
        expect(t.creators, ['Alan Ball']);
        expect(t.episodeRuntimeMinutes, 60);
        expect(t.tvdbId, 82283);
        expect(t.certification, 'TV-MA');
        expect(t.trailer, isNotNull);
        expect(t.nextEpisode, isNull);
      },
    );

    test('specials only appear when Seerr enables them', () {
      final d = fixtureMap('seerr/seerr_tv_details_partially_available.json');
      expect(_seasons(d, specials: true).first.seasonNumber, 0);
    });

    test('a failed request still blocks its season', () {
      final d = fixtureMap('seerr/seerr_tv_details_failed_request.json');
      final seasons = _seasons(d);
      expect(seasons.first.seasonNumber, 1);
      expect(seasons.first.requestable, isFalse);
      expect(seasons.first.requestStatus, RequestStatus.approved);
      final e = SeerrMapper.tvEligibility(d, seasons, linked: true);
      expect(e.requestableSeasons, [2, 3, 4, 5, 6, 7, 8, 9]);
    });

    test('everything requested: alreadyRequested', () {
      final d = fixtureMap('seerr/seerr_tv_details_processing.json');
      final seasons = _seasons(d);
      final e = SeerrMapper.tvEligibility(d, seasons, linked: true);
      expect(e.canRequest, isFalse);
      expect(e.reason, RequestEligibilityReason.alreadyRequested);
      expect(e.requestableSeasons, isEmpty);
    });

    test('ratings: movie combined, tv RT only', () {
      final movie = SeerrMapper.ratings(
        MediaType.movie,
        fixtureMap('seerr/seerr_movie_ratingscombined.json'),
      );
      expect(movie.rottenTomatoes!.criticsScore, 52);
      expect(movie.rottenTomatoes!.criticsRating, 'Rotten');
      expect(movie.imdb!.score, 6.3);
      final tv = SeerrMapper.ratings(
        MediaType.tv,
        fixtureMap('seerr/seerr_tv_ratings.json'),
      );
      expect(tv.rottenTomatoes!.audienceScore, 73);
      expect(tv.imdb, isNull);
    });

    test('season episodes', () {
      final s = _mapper.seasonEpisodes(
        fixtureMap('seerr/seerr_tv_season.json'),
      );
      expect(s.seasonNumber, 1);
      expect(s.name, 'Season 1');
      expect(s.episodes.first.episodeNumber, 1);
      expect(s.episodes.first.name, 'Strange Love');
      expect(s.episodes.first.airDate, '2008-09-07');
    });
  });

  group('issues', () {
    test('list rows carry commentCount; 0 season/episode means all', () {
      final rows = readList(
        (synthetic('seerr_issue_list.synthetic.json')! as JsonMap)['results'],
        (m) => m,
      );
      const info = TitleInfo(title: 'True Blood');
      final first = _mapper.issue(rows.first, info: info, withComments: false);
      expect(first.type, IssueType.audio);
      expect(first.status, IssueStatus.open);
      expect(first.mediaType, MediaType.tv);
      expect(first.season, 2);
      expect(first.episode, 5);
      expect(first.commentCount, 2);
      expect(first.comments, isEmpty);
      expect(first.createdBy.id, 2);
      final second = _mapper.issue(rows.last, info: info);
      expect(second.season, isNull);
      expect(second.episode, isNull);
      expect(second.comments.single.author.displayName, 'Paul Greyrat');
    });

    test('counts: others → other, closed → resolved', () {
      final c = SeerrMapper.issueCounts(
        synthetic('seerr_issue_count.synthetic.json')! as JsonMap,
      );
      expect(c.other, 1);
      expect(c.resolved, 1);
      expect(c.open, 2);
      expect(
        SeerrMapper.issueCounts(fixtureMap('seerr/seerr_issue_count.json'))
            .total,
        0,
      );
    });
  });
}
