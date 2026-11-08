import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/routing/more_screen.dart';
import 'package:yams_hub/core/routing/nav_badges.dart';
import 'package:yams_models/yams_models.dart';

import '../support/builders.dart';

Map<String, Section> cardsOf(JsonMap dashboardJson) => DashboardResponse.fromJson(dashboardJson).cards;

void main() {
  test('reads every raw key of API.md §4', () {
    final b = NavBadges.fromCards(cardsOf(buildDashboardJson()));
    expect(b.requestsPending, 3);
    expect(b.activityAttention, 2);
    expect(b.calendarNext7Days, 6);
    expect(b.containersRunning, 21);
    expect(b.containersTotal, 23);
    expect(b.indexersFailing, 1);
    expect(b.subtitlesMissing, 111);
  });

  test('missing cards and keys give no badge', () {
    final b = NavBadges.fromCards(
      cardsOf(
        buildDashboardJson(
          cards: {
            DashboardCardKeys.requests: buildSection({'counts': <String, Object?>{}}).toJson(),
            DashboardCardKeys.activity: buildSection({'top': <Object?>[]}).toJson(),
          },
        ),
      ),
    );
    expect(b.requestsPending, isNull);
    expect(b.activityAttention, isNull);
    expect(b.calendarNext7Days, isNull);
    expect(b.containersRunning, isNull);
    expect(b.indexersFailing, isNull);
    expect(b.subtitlesMissing, isNull);
  });

  test('wrong types give no badge', () {
    final b = NavBadges.fromCards(
      cardsOf(
        buildDashboardJson(
          cards: {
            DashboardCardKeys.requests: buildSection({'counts': 'many'}).toJson(),
            DashboardCardKeys.activity: buildSection({
              'counts': {'attention': '2'},
            }).toJson(),
            DashboardCardKeys.calendar: buildSection({'countNext7Days': -1}).toJson(),
            DashboardCardKeys.containers: buildSection({'running': 2.5, 'total': true}).toJson(),
            DashboardCardKeys.indexers: buildSection({'failing': 3}).toJson(),
            DashboardCardKeys.subtitles: buildSection({'missingEpisodes': null}).toJson(),
          },
        ),
      ),
    );
    expect(b, const NavBadges());
  });

  test('an integral double counts (JSON numbers may decode as double)', () {
    final b = NavBadges.fromCards({
      DashboardCardKeys.subtitles: buildSection({'missingEpisodes': 111.0}),
    });
    expect(b.subtitlesMissing, 111);
  });

  test('failed and disabled cards give no badge', () {
    final b = NavBadges.fromCards({
      DashboardCardKeys.requests: const Section.failure(
        ApiError(code: ApiErrorCode.upstreamUnavailable, message: 'Seerr down', status: 503),
      ),
      DashboardCardKeys.containers: const Section.disabled(
        ApiError(code: ApiErrorCode.serviceNotConfigured, message: '', status: 503),
      ),
    });
    expect(b.requestsPending, isNull);
    expect(b.containersRunning, isNull);
  });

  test('merging a partial response keeps the other counts', () {
    final full = NavBadges.fromCards(cardsOf(buildDashboardJson()));
    final merged = full.merge({
      DashboardCardKeys.activity: buildSection({
        'counts': {'attention': 7},
      }),
    });
    expect(merged.activityAttention, 7);
    expect(merged.requestsPending, 3);
    expect(merged.subtitlesMissing, 111);
  });

  test('More subtitles', () {
    final s = moreSubtitles(NavBadges.fromCards(cardsOf(buildDashboardJson())));
    expect(s.values.whereType<String>(), containsAll(['6 releases this week', '21 running', '1 failing', '111 missing']));
    expect(moreSubtitles(const NavBadges()).values.whereType<String>(), isEmpty);
  });
}
