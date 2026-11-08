/// `GET /dashboard` (API.md §4).
library;

import 'package:meta/meta.dart';

import 'common.dart';
import 'json.dart';

/// The dashboard card keys (one per feature with a card), in display order.
abstract final class DashboardCardKeys {
  static const system = 'system';
  static const activity = 'activity';
  static const media = 'media';
  static const calendar = 'calendar';
  static const requests = 'requests';
  static const library = 'library';
  static const containers = 'containers';
  static const indexers = 'indexers';
  static const subtitles = 'subtitles';

  static const all = [
    system,
    activity,
    media,
    calendar,
    requests,
    library,
    containers,
    indexers,
    subtitles,
  ];
}

/// 200 body of `GET /dashboard`.
///
/// Each card is a [Section] whose `data` is the feature's card DTO
/// (`SystemCard`, `ActivityCard`, ...); decode it with [Section.decode].
@immutable
final class DashboardResponse {
  const DashboardResponse({
    required this.generatedAt,
    this.alerts = const [],
    this.cards = const {},
  });

  factory DashboardResponse.fromJson(JsonMap j) => DashboardResponse(
    generatedAt: req(readInstant(j['generatedAt']), 'generatedAt'),
    alerts: readList(j['alerts'], Alert.fromJson),
    cards: {
      for (final e
          in (readMap(j['cards']) ?? const <String, Object?>{}).entries)
        if (readMap(e.value) case final m?) e.key: Section.fromJson(m),
    },
  );

  final DateTime generatedAt;
  final List<Alert> alerts;

  /// Card key (see [DashboardCardKeys]) to section. Only requested cards are
  /// present.
  final Map<String, Section> cards;

  /// The section for [key], or null when the card was not requested.
  Section? card(String key) => cards[key];

  JsonMap toJson() => {
    'generatedAt': instantToJson(generatedAt),
    'alerts': [for (final a in alerts) a.toJson()],
    'cards': {for (final e in cards.entries) e.key: e.value.toJson()},
  };
}
