import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/features/requests/widgets/request_sheet.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'requests_samples.dart';

/// The JSON body of the last [method] [path] request.
Object? _body(FakeApi api, String path, {String method = 'POST'}) {
  final data = api.requestsTo(path, method: method).last.data;
  return data is String ? jsonDecode(data) : data;
}

FakeApi _api({Role role = Role.admin, JsonMap? me}) {
  final api = buildCoreFakeApi(role: role)
    ..getJson('/server', serverWithPartialRequests())
    ..getJson('/titles/movie/603/ratings', const Ratings().toJson())
    ..getJson('/titles/movie/603/recommendations', page(const []))
    ..getJson('/titles/movie/603/similar', page(const []))
    ..getJson('/titles/tv/10545/ratings', const Ratings().toJson())
    ..getJson('/titles/tv/10545/recommendations', page(const []))
    ..getJson('/titles/tv/10545/similar', page(const []))
    ..getJson('/requests/counts', counts.toJson());
  if (me != null) api.getJson('/auth/me', me);
  return api;
}

void main() {
  testWidgets('movie: one tap requests it and confirms with a SnackBar', (tester) async {
    final api = _api()
      ..getJson('/titles/movie/603', movie().toJson())
      ..postJson(
        '/requests',
        CreateRequestResult(
          outcome: CreateRequestOutcome.autoApproved,
          request: request(
            202,
            title: 'The Matrix',
            type: MediaType.movie,
            tmdbId: 603,
            status: RequestStatus.approved,
          ),
        ).toJson(),
        status: 201,
      );
    await pumpHubApp(tester, api: api, location: '/requests/title/movie/603');

    expect(find.text('The Matrix'), findsWidgets);
    expect(find.text('1999 · 2 h 16 min · 16'), findsOneWidget);
    expect(find.text('Welcome to the Real World.'), findsOneWidget);
    expect(find.text('Lana Wachowski'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Request'));
    await settle(tester);
    expect(_body(api, '/requests'), {'mediaType': 'movie', 'tmdbId': 603});
    expect(find.text('Requested · sent to Radarr'), findsOneWidget);
  });

  testWidgets('series: season picker sends the chosen seasons', (tester) async {
    final api = _api()
      ..getJson('/titles/tv/10545', trueBlood().toJson())
      ..postJson(
        '/requests',
        CreateRequestResult(outcome: CreateRequestOutcome.created, request: request(201)).toJson(),
        status: 201,
      );
    await pumpHubApp(tester, api: api, location: '/requests/title/tv/10545');

    // Partially available: "Request more" next to "Play in Jellyfin".
    expect(find.text('Play in Jellyfin'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Request more'));
    await settle(tester);
    expect(find.byType(RequestSheet), findsOneWidget);
    expect(find.text('Request 4 seasons'), findsOneWidget);
    // Seasons 1-3 are not requestable.
    final s1 = tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'Season 1'));
    expect(s1.onChanged, isNull);
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Season 4'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Season 5'));
    await tester.pump();
    expect(find.text('Request 2 seasons'), findsOneWidget);
    // Admins get the advanced options.
    await tester.scrollUntilVisible(
      find.text('Advanced'),
      200,
      scrollable: find.descendant(of: find.byType(RequestSheet), matching: find.byType(Scrollable)).first,
    );
    expect(find.text('Advanced'), findsOneWidget);
    await tester.tap(find.text('Request 2 seasons'));
    await settle(tester);
    expect(_body(api, '/requests'), {
      'mediaType': 'tv',
      'tmdbId': 10545,
      'seasons': [6, 7],
    });
    expect(find.text('Requested · waiting for approval'), findsNothing, reason: 'admins see "Requested"');
    expect(find.text('Requested'), findsWidgets);
  });

  testWidgets('member quota line and quota_exceeded message', (tester) async {
    const quota = SeerrQuota(movie: QuotaInfo(limit: 5, days: 7, used: 2, remaining: 3), tv: QuotaInfo());
    final api =
        _api(
            role: Role.member,
            me: linkedMe(quota: quota),
          )
          ..getJson('/titles/movie/603', movie().toJson())
          ..on(
            'POST',
            '/requests',
            (_) => FakeResponse.error(
              403,
              ApiErrorCode.quotaExceeded,
              message: 'Movie Quota exceeded.',
              details: {
                'quota': const SeerrQuota(
                  movie: QuotaInfo(limit: 5, days: 7, used: 5, remaining: 0, restricted: true),
                  tv: QuotaInfo(),
                ).toJson(),
              },
            ),
          );
    await pumpHubApp(tester, api: api, role: Role.member, location: '/requests/title/movie/603');
    expect(find.text('3 of 5 movie requests left this week'), findsOneWidget);
    // Members never get the advanced options.
    expect(find.byTooltip('Request with options'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Request'));
    await settle(tester);
    expect(find.textContaining('Movie Quota exceeded.'), findsOneWidget);
    expect(find.textContaining('No movie requests left'), findsOneWidget);
  });

  testWidgets('no quota left disables the button', (tester) async {
    const quota = SeerrQuota(
      movie: QuotaInfo(limit: 5, days: 7, used: 5, remaining: 0, restricted: true),
      tv: QuotaInfo(),
    );
    final api = _api(
      role: Role.member,
      me: linkedMe(quota: quota),
    )..getJson('/titles/movie/603', movie().toJson());
    await pumpHubApp(tester, api: api, role: Role.member, location: '/requests/title/movie/603');
    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'No requests left'));
    expect(button.onPressed, isNull);
  });

  testWidgets('unlinked members see why they cannot request', (tester) async {
    final api = _api(role: Role.member, me: linkedMe(linked: false))
      ..getJson(
        '/titles/movie/603',
        movie(request: const RequestEligibility(canRequest: false, reason: RequestEligibilityReason.notLinked))
            .toJson(),
      );
    await pumpHubApp(tester, api: api, role: Role.member, location: '/requests/title/movie/603');
    expect(find.text("Your account isn't linked to Seerr. Ask the admin."), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Request')).onPressed, isNull);
    expect(find.text('Report issue'), findsNothing);
  });

  testWidgets('available movie: play, report issue, open in library, requests list', (tester) async {
    final api = _api()
      ..getJson(
        '/titles/movie/603',
        movie(
          media: availableMedia(
            requests: [
              request(
                195,
                title: 'The Matrix',
                type: MediaType.movie,
                tmdbId: 603,
                status: RequestStatus.completed,
                availability: Availability.available,
                by: paul,
              ),
            ],
          ),
          request: const RequestEligibility(canRequest: false, reason: RequestEligibilityReason.available),
        ).toJson(),
      )
      ..postJson('/issues', issue(9).toJson(), status: 201);
    await pumpHubApp(tester, api: api, location: '/requests/title/movie/603');
    expect(find.widgetWithText(FilledButton, 'Play in Jellyfin'), findsOneWidget);
    expect(find.text('Open in Library'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Paul Greyrat'),
      200,
      scrollable: find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first,
    );
    expect(find.text('Paul Greyrat'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Report issue'),
      -200,
      scrollable: find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first,
    );
    expect(find.widgetWithText(FilledButton, 'Request'), findsNothing);

    await tester.tap(find.text('Report issue'));
    await settle(tester);
    await tester.tap(find.text('Audio'));
    await tester.enterText(find.widgetWithText(TextField, 'What is wrong?'), 'Out of sync');
    await tester.tap(find.widgetWithText(FilledButton, 'Report issue'));
    await settle(tester);
    expect(_body(api, '/issues'), {'mediaType': 'movie', 'tmdbId': 603, 'type': 'audio', 'message': 'Out of sync'});
    expect(find.text('Issue reported'), findsOneWidget);
  });

  testWidgets('pending title shows a disabled Requested button', (tester) async {
    final api = _api()
      ..getJson(
        '/titles/movie/603',
        movie(
          media: const MediaState(seerrMediaId: 1, availability: Availability.pending),
          request: const RequestEligibility(canRequest: false, reason: RequestEligibilityReason.alreadyRequested),
        ).toJson(),
      );
    await pumpHubApp(tester, api: api, location: '/requests/title/movie/603');
    final button = find.widgetWithText(FilledButton, 'Requested · waiting for approval');
    expect(button, findsOneWidget);
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
  });

  testWidgets('unknown title: "This title doesn\'t exist on TMDB"', (tester) async {
    final api = _api()
      ..on(
        'GET',
        '/titles/movie/999',
        (_) => FakeResponse.error(404, ApiErrorCode.notFound, message: 'Unable to retrieve movie.'),
      );
    await pumpHubApp(tester, api: api, location: '/requests/title/movie/999');
    expect(find.text("This title doesn't exist on TMDB"), findsOneWidget);
  });

  testWidgets('a failed first load offers Retry', (tester) async {
    final api = _api()
      ..on(
        'GET',
        '/titles/movie/603',
        (_) => FakeResponse.error(503, ApiErrorCode.upstreamUnavailable, message: 'Seerr is not reachable.'),
      );
    await pumpHubApp(tester, api: api, location: '/requests/title/movie/603');
    expect(find.text('Seerr is not reachable.'), findsOneWidget);
    api.getJson('/titles/movie/603', movie().toJson());
    await tester.tap(find.text('Retry'));
    await settle(tester);
    expect(find.text('Welcome to the Real World.'), findsOneWidget);
  });
}
