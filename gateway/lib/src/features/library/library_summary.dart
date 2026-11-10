/// `GET /library/summary`, `GET /library/profiles` and the `library`
/// dashboard card with its alerts (API.md §7.6, §7.7, §7.11).
library;

import 'package:shelf/shelf.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'library_data.dart';
import 'library_support.dart';

/// Health checks the indexers card already reports.
const _indexerChecks = {'IndexerLongTermStatusCheck', 'IndexerStatusCheck'};

String _firstSentence(String message) {
  final m = RegExp(r'^(.+?[.!?])(\s|$)').firstMatch(message.trim());
  final s = (m?[1] ?? message).trim();
  return s.endsWith('.') ? s.substring(0, s.length - 1) : s;
}

/// The dashboard alerts of a summary (API.md §7.11). [hubHosts]: the
/// hostname of the hub's URL for each *arr (for the Allowed Hosts hint).
List<Alert> libraryAlerts(
  LibrarySummary summary, {
  Map<ArrService, String> hubHosts = const {},
}) {
  final out = <Alert>[];
  for (final (svc, s) in [
    (ArrService.sonarr, summary.sonarr),
    (ArrService.radarr, summary.radarr),
  ]) {
    if (!s.configured) continue;
    final name = arrName(svc);
    for (final h in s.health) {
      if (h.type != HealthMessageType.warning &&
          h.type != HealthMessageType.error) {
        continue;
      }
      if (_indexerChecks.contains(h.source) ||
          h.source == libraryUnreachableSource) {
        continue;
      }
      final allowedHosts = h.source == 'AllowedHostsCheck';
      final host = hubHosts[svc];
      out.add(
        Alert(
          id: '${svc.name}.health.${h.source}',
          severity: allowedHosts
              ? AlertSeverity.info
              : (h.type == HealthMessageType.error
                    ? AlertSeverity.error
                    : AlertSeverity.warning),
          source: svc.serviceId,
          feature: 'library',
          title: '$name: ${_firstSentence(h.message)}',
          message: allowedHosts && host != null
              ? '${h.message} ${allowedHostsHint(svc.serviceId, host)}'
              : h.message,
          route: '/library',
          dismissible: allowedHosts,
        ),
      );
    }
    if (s.queue.errors) {
      out.add(
        Alert(
          id: '${svc.name}.queue.errors',
          severity: AlertSeverity.warning,
          source: svc.serviceId,
          feature: 'library',
          title: '$name has downloads with errors',
          message: 'Open Activity to see what failed or needs a manual import.',
          route: '/activity',
        ),
      );
    }
  }
  return out;
}

ApiError? _toApiError(Object? error, String requestId) => switch (error) {
  null => null,
  ApiException() => error.toApiError(requestId),
  UpstreamException() =>
    error.toApiException(resourceNotFound: false).toApiError(requestId),
  _ => ApiException.internal().toApiError(requestId),
};

/// Handlers of the header, profiles and the dashboard card.
final class LibrarySummaryRoutes {
  LibrarySummaryRoutes(this.data);

  final LibraryData data;

  void _requireConfigured() {
    if (!data.sonarr.configured && !data.radarr.configured) {
      throw ApiException.serviceNotConfigured(
        ServiceId.sonarr,
        'Neither Sonarr nor Radarr is configured in the gateway.',
      );
    }
  }

  Future<Response> summary(ApiRequest req) async {
    _requireConfigured();
    final r = await arrCall(data.summary());
    return ApiResponse.json(r.value.toJson());
  }

  Future<Response> profiles(ApiRequest req) async {
    _requireConfigured();
    return ApiResponse.json((await arrCall(data.profiles())).toJson());
  }

  Future<DashboardContribution> card(ApiRequest req) async {
    _requireConfigured();
    final health = data.ctx.health;
    // Never throw (a failing summary keeps its own error mapping).
    final hostAlerts = [
      for (final id in [ServiceId.sonarr, ServiceId.radarr])
        health.allowedHostsAlert(id, feature: 'library', route: '/library'),
    ];
    final r = await data.summary();
    final sonarrHosts = await hostAlerts[0];
    final radarrHosts = await hostAlerts[1];
    return DashboardContribution(
      data: LibraryCard.fromSummary(r.value).toJson(),
      alerts: [
        ?sonarrHosts,
        ?radarrHosts,
        ...libraryAlerts(
          r.value,
          hubHosts: {
            ArrService.sonarr: data.sonarr.baseUrl.host,
            ArrService.radarr: data.radarr.baseUrl.host,
          },
        ),
      ],
      stale: r.stale,
      fetchedAt: r.fetchedAt,
      error: r.stale ? _toApiError(r.error, req.requestId) : null,
    );
  }
}
