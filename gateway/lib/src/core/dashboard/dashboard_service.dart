/// `GET /dashboard`: card aggregation (ARCHITECTURE §5.11, API.md §4).
library;

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:yams_models/yams_models.dart';

import '../clock.dart';
import '../feature_module.dart';
import '../http/api_exception.dart';
import '../http/api_request.dart';
import '../http/api_response.dart';
import '../http/api_router.dart';
import '../upstream/upstream_exception.dart';
import 'alert_policy.dart';

final _log = Logger('core.dashboard');

/// Calls every module's `dashboard()` in parallel with a per-card budget.
final class DashboardService {
  DashboardService({
    required this._modules,
    required this._clock,
    this.cardBudget = const Duration(seconds: 4),
    Duration transientGrace = transientAlertGrace,
  }) : _tracker = AlertTracker(_clock, grace: transientGrace);

  final List<FeatureModule> _modules;
  final Clock _clock;
  final Duration cardBudget;

  /// First-seen times of the alerts (per process).
  final AlertTracker _tracker;

  void registerRoutes(ApiRouter router) {
    router.get('/dashboard', _get);
  }

  Future<Response> _get(ApiRequest req) async {
    final requested = req.queryList('cards');
    for (final k in requested) {
      if (!DashboardCardKeys.all.contains(k)) {
        throw ApiException.badRequest('unknown card "$k"');
      }
    }
    final keys = requested.isEmpty
        ? DashboardCardKeys.all
        : requested.toSet().toList();
    final response = await build(req, keys);
    return ApiResponse.json(response);
  }

  /// Builds the dashboard for the card [keys].
  Future<DashboardResponse> build(ApiRequest req, List<String> keys) async {
    final byId = {for (final m in _modules) m.id: m};
    final entries = await Future.wait([
      for (final k in keys)
        if (byId[k] case final m?) _card(m, req).then((r) => MapEntry(k, r)),
    ]);
    final cards = <String, Section>{};
    final alerts = <String, Alert>{};
    final superseded = <String>{};
    for (final e in entries) {
      final r = e.value;
      if (r.known) _tracker.observe(e.key, [for (final a in r.alerts) a.id]);
      final section = r.section;
      if (section == null) continue;
      cards[e.key] = section;
      superseded.addAll(r.supersedes);
      for (final a in r.alerts) {
        alerts.putIfAbsent(a.id, () => a);
      }
    }
    superseded.forEach(alerts.remove);
    final sorted = _tracker.apply(alerts.values)
      ..sort((a, b) {
        final s = b.severity.rank.compareTo(a.severity.rank);
        if (s != 0) return s;
        final src = a.source.name.compareTo(b.source.name);
        return src != 0 ? src : a.id.compareTo(b.id);
      });
    return DashboardResponse(
      generatedAt: _clock.now(),
      alerts: sorted,
      cards: {for (final k in keys) k: ?cards[k]},
    );
  }

  Future<_CardResult> _card(FeatureModule m, ApiRequest req) async {
    final load = Future.sync(() => m.dashboard(req));
    try {
      final c = await load.timeout(cardBudget);
      if (c == null) return const _CardResult(null, known: true);
      if (c.failure case final failure?) {
        return _CardResult(
          _failedSection(m, req, failure, null),
          alerts: c.alerts,
          known: true,
        );
      }
      final section = Section.ok(
        c.data,
        fetchedAt: c.fetchedAt ?? _clock.now(),
        stale: c.stale,
        error: c.error,
      );
      return _CardResult(
        section,
        alerts: c.alerts,
        supersedes: c.supersedes,
        known: true,
      );
    } on TimeoutException {
      // The load continues in the background and warms the feature's caches.
      unawaited(load.then<void>((_) {}, onError: (Object _) {}));
      return _CardResult(
        Section.failure(
          ApiException(
            504,
            ApiErrorCode.upstreamTimeout,
            'The ${m.id} card did not load in time.',
          ).toApiError(req.requestId),
          fetchedAt: _clock.now(),
        ),
      );
    } catch (e, st) {
      return _CardResult(_failedSection(m, req, e, st));
    }
  }

  /// The error section of a failed card (`disabled` when the service is not
  /// configured).
  Section _failedSection(
    FeatureModule m,
    ApiRequest req,
    Object e,
    StackTrace? st,
  ) {
    final api = switch (e) {
      ApiException() => e,
      UpstreamException() => e.toApiException(resourceNotFound: false),
      FormatException() || TypeError() => const ApiException(
        502,
        ApiErrorCode.upstreamBadResponse,
        'An upstream response could not be read.',
      ),
      _ => ApiException.internal(),
    };
    if (api.status == 500) {
      _log.severe('dashboard card ${m.id} failed', e, st);
    }
    final error = api.toApiError(req.requestId);
    return api.code == ApiErrorCode.serviceNotConfigured
        ? Section.disabled(error, fetchedAt: _clock.now())
        : Section.failure(error, fetchedAt: _clock.now());
  }
}

/// One card's section and alerts. [known]: the card answered, so its alerts
/// are the whole truth (a timed-out or failed card's alerts are unknown, and
/// their first-seen times are kept).
final class _CardResult {
  const _CardResult(
    this.section, {
    this.alerts = const [],
    this.supersedes = const {},
    this.known = false,
  });

  final Section? section;
  final List<Alert> alerts;
  final Set<String> supersedes;
  final bool known;
}
