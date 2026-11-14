/// What the dashboard does with the alerts the feature modules raise before
/// they reach the home screen (API.md §4, "Dashboard alerts"): first-seen times, a grace period
/// for transient problems, collapsing per-download import alerts and the
/// fingerprinted dismissal keys of notices.
///
/// Every alert stays visible on its feature's own screen; only the home
/// panel gets quieter.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:yams_models/yams_models.dart';

import '../clock.dart';

/// How long a transient problem must persist before the dashboard shows it.
const transientAlertGrace = Duration(minutes: 5);

/// Prefix of the per-download manual import alerts (`queue.import.<key>`).
const queueImportAlertPrefix = 'queue.import.';

/// Id of the alert that stands in for several manual imports.
const queueImportsAlertId = 'queue.imports';

/// Problems that often clear on their own (a VPN reconnect, a container
/// restart, a download that Sonarr imports a minute later): the dashboard
/// shows them only once they have lasted [transientAlertGrace].
///
/// Not listed, so shown at once: `critical` alerts, configuration problems
/// (`qbittorrent.auth`, `*.allowedHosts`, `privacy.*`, `kavita.auth`), and
/// slow-moving ones (`host.*`, `raid.*`, `seerr.*`, `updates.available`).
bool isTransientAlert(String id) =>
    const {
      'vpn.down',
      'vpn.port',
      'bazarr.signalr',
      'uptime.incident',
    }.contains(id) ||
    id.startsWith('container.stopped.') ||
    id.startsWith('container.unhealthy.') ||
    id.startsWith('uptime.down.') ||
    id.startsWith(queueImportAlertPrefix) ||
    id.endsWith('.queue.errors');

/// A dismissal key for [id] that changes whenever [parts] change, e.g.
/// `updates.available:3f9a1c2e`. The app remembers dismissals by this key,
/// so a dismissed notice comes back when its content changes.
String fingerprintedDismissKey(String id, Iterable<Object?> parts) {
  final digest = sha256.convert(utf8.encode(parts.join('\u0000')));
  return '$id:${digest.toString().substring(0, 8)}';
}

/// Remembers when each alert id was first seen (per gateway process) and
/// applies the dashboard's alert policy.
final class AlertTracker {
  AlertTracker(this._clock, {this.grace = transientAlertGrace});

  final Clock _clock;
  final Duration grace;

  /// Card key → alert id → first seen.
  final Map<String, Map<String, DateTime>> _firstSeen = {};

  /// Records the alerts a card raised just now. Ids the card no longer raises
  /// are forgotten, so a problem that comes back starts its grace period
  /// again. Call it only for cards whose alerts are known (not for a card
  /// that timed out or threw: its alerts are not "gone").
  void observe(String card, Iterable<String> ids) {
    final now = _clock.now();
    final previous = _firstSeen[card] ?? const <String, DateTime>{};
    _firstSeen[card] = {for (final id in ids) id: previous[id] ?? now};
  }

  /// When [id] was first seen by any card (null when never observed).
  DateTime? firstSeen(String id) {
    DateTime? out;
    for (final m in _firstSeen.values) {
      final t = m[id];
      if (t != null && (out == null || t.isBefore(out))) out = t;
    }
    return out;
  }

  /// [alerts] as the dashboard shows them: `since` is when the problem was
  /// first seen (or the upstream's own earlier start), transient problems
  /// younger than [grace] are held back (never `critical` ones), and several
  /// manual imports become one alert.
  List<Alert> apply(Iterable<Alert> alerts) {
    final now = _clock.now();
    final out = <Alert>[];
    for (final a in alerts) {
      final seen = firstSeen(a.id) ?? now;
      final upstream = a.since;
      final since = upstream != null && upstream.isBefore(seen)
          ? upstream
          : seen;
      if (a.severity != AlertSeverity.critical &&
          isTransientAlert(a.id) &&
          now.difference(since) < grace) {
        continue;
      }
      out.add(a.copyWith(since: since));
    }
    return collapseImports(out);
  }
}

/// More than one `queue.import.<key>` alert becomes one [queueImportsAlertId]
/// alert ("3 downloads need manual import") that opens the queue.
List<Alert> collapseImports(List<Alert> alerts) {
  final imports = [
    for (final a in alerts)
      if (a.id.startsWith(queueImportAlertPrefix)) a,
  ];
  if (imports.length < 2) return alerts;
  DateTime? since;
  var severity = AlertSeverity.unknown;
  for (final a in imports) {
    final s = a.since;
    if (s != null && (since == null || s.isBefore(since))) since = s;
    if (a.severity.rank > severity.rank) severity = a.severity;
  }
  final sources = {for (final a in imports) a.source};
  final names = [for (final s in sources) s.displayName]..sort();
  return [
    for (final a in alerts)
      if (!a.id.startsWith(queueImportAlertPrefix)) a,
    Alert(
      id: queueImportsAlertId,
      severity: severity,
      source: sources.length == 1 ? sources.single : imports.first.source,
      feature: imports.first.feature,
      title: '${imports.length} downloads need manual import',
      message:
          '${names.join(' and ')} could not import them on '
          'their own. Open the queue to import them.',
      route: Uri(
        path: '/activity',
        queryParameters: {'tab': 'queue'},
      ).toString(),
      since: since,
    ),
  ];
}
