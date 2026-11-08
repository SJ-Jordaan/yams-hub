/// The interface every feature implements (ARCHITECTURE §5.5).
library;

import 'package:yams_models/yams_models.dart';

import 'http/api_request.dart';
import 'http/api_router.dart';

/// One feature of the gateway (`requests`, `library`, ...). Modules get a
/// `FeatureContext` through their constructor.
abstract class FeatureModule {
  /// Feature id: requests, library, activity, calendar, indexers, subtitles,
  /// containers, system, media.
  String get id;

  /// Registers this feature's routes. Paths are absolute below `/api/v1` and
  /// must be the ones API.md assigns to the feature; static segments before
  /// parameterised ones, numeric parameters regex-constrained.
  void registerRoutes(ApiRouter router);

  /// Dashboard card for `GET /api/v1/dashboard`, or null if the feature has
  /// no card. Throwing is fine: the core turns it into an error Section for
  /// this card only. Stubs throw `ApiException.notImplemented()`, which core
  /// maps to `{status: error, code: not_implemented}`; a
  /// `service_not_configured` error becomes `{status: disabled}`.
  Future<DashboardContribution?> dashboard(ApiRequest req) async => null;

  /// Starts background pollers/streams (not called by `TestHub` unless the
  /// test opts in).
  Future<void> start() async {}

  /// Stops background work.
  Future<void> stop() async {}
}

/// A feature's dashboard card.
final class DashboardContribution {
  const DashboardContribution({
    required this.data,
    this.alerts = const [],
    this.stale = false,
    this.fetchedAt,
    this.error,
  });

  /// The feature's card DTO `.toJson()`.
  final Map<String, Object?> data;

  /// Alerts from `yams_models` `common.dart`.
  final List<Alert> alerts;

  /// The data was served from cache after a failed refresh ([error] says
  /// why).
  final bool stale;

  /// When [data] was fetched (defaults to now).
  final DateTime? fetchedAt;

  /// The refresh failure behind a [stale] card.
  final ApiError? error;
}
