/// The Servarr "Allowed Hosts" setting (issue #2): detection of the
/// `400 Invalid Hostname` answer, the host matching rules and the messages
/// that tell the user how to fix it.
///
/// Sonarr, Radarr and Prowlarr store the setting as `allowedHosts` in
/// `GET /api/v3/config/host` (Prowlarr `/api/v1/config/host`) and
/// `<AllowedHosts>` in config.xml. ASP.NET's host filtering reads it at start,
/// so a change applies only after the app restarts; from then on a request
/// whose `Host` is not listed gets `400 Bad Request - Invalid Hostname` (HTML).
/// Bazarr has no such setting.
library;

import 'dart:convert';

import 'package:yams_models/yams_models.dart';

/// The services with an Allowed Hosts setting.
const allowedHostsServices = {
  ServiceId.sonarr,
  ServiceId.radarr,
  ServiceId.prowlarr,
};

/// Hosts the *arrs accept whatever the list says (checked against
/// Sonarr/Radarr/Prowlarr 4.x/6.x/2.x: loopback always passes).
const _implicitHosts = {'localhost', '127.0.0.1', '::1'};

/// Whether [body] is ASP.NET's host-filtering rejection
/// (`<h2>Bad Request - Invalid Hostname</h2>`).
bool isInvalidHostnameResponse(int status, List<int> body) {
  if (status != 400 || body.isEmpty) return false;
  final head = body.length > 2048 ? body.sublist(0, 2048) : body;
  return utf8
      .decode(head, allowMalformed: true)
      .toLowerCase()
      .contains('invalid hostname');
}

String _normalize(String host) {
  var h = host.trim().toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
  if (h.endsWith('.')) h = h.substring(0, h.length - 1);
  return h;
}

/// The entries of an `allowedHosts` value (comma or semicolon separated).
List<String> allowedHostsEntries(String allowedHosts) => [
  for (final e in allowedHosts.split(RegExp('[,;]')))
    if (_normalize(e) case final n when n.isNotEmpty) n,
];

/// Whether an *arr with [allowedHosts] accepts requests for [host]: an empty
/// list accepts everything, `*` too, `*.example.com` matches subdomains, other
/// entries match exactly (case-insensitive). Loopback names always pass.
bool allowedHostsAccepts(String allowedHosts, String host) {
  final h = _normalize(host);
  final entries = allowedHostsEntries(allowedHosts);
  if (entries.isEmpty || _implicitHosts.contains(h)) return true;
  for (final e in entries) {
    if (e == '*' || e == h) return true;
    if (e.startsWith('*.') && h.endsWith(e.substring(1))) return true;
  }
  return false;
}

String _fix(ServiceId service, String host) =>
    'In ${service.displayName} → Settings → General → Allowed Hosts, add '
    '$host (or clear the list)';

/// The *arr already rejects the hub ([host] is the hostname of the hub's
/// URL for it).
String hostRejectedMessage(ServiceId service, String host) {
  final name = service.displayName;
  return "$name rejects the hub's hostname '$host'. ${_fix(service, host)}, "
      'then restart $name.';
}

/// The saved setting leaves [host] out but is not active yet.
String hostPendingMessage(ServiceId service, String host, String allowedHosts) {
  final name = service.displayName;
  var list = allowedHostsEntries(allowedHosts).join(', ');
  if (list.length > 80) list = '${list.substring(0, 77)}...';
  return "$name's saved Allowed Hosts ($list) leaves out '$host', the "
      'hostname the hub uses: $name will reject the hub after its next '
      'restart. ${_fix(service, host)}.';
}

/// Appended to the *arrs' own "Allowed Hosts is not configured" health
/// warning (`AllowedHostsCheck`): a list set later must include [host].
String allowedHostsHint(ServiceId service, String host) =>
    'If you set Allowed Hosts, include $host (the hostname the hub uses), '
    'then restart ${service.displayName}.';
