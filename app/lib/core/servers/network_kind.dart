/// Classifies hub URLs: LAN, Tailscale or the internet (ARCHITECTURE §7.5).
library;

/// Where a URL points, as shown on the dashboard chip.
enum NetworkKind {
  lan('LAN'),
  tailscale('Tailscale'),
  internet('Internet');

  const NetworkKind(this.label);

  final String label;
}

/// `100.64.0.0/10` (CGNAT range used by Tailscale) or a MagicDNS `*.ts.net`
/// name. Used for ordering, labels and the plain-HTTP warning only: the name
/// alone does not prove the traffic goes through WireGuard, so such URLs
/// still need the server proof once signed in.
bool isTailscaleHost(String host) {
  final h = _normalise(host);
  if (h.endsWith('.ts.net')) return true;
  final ip = _ipv4(h);
  return ip != null && ip[0] == 100 && ip[1] >= 64 && ip[1] <= 127;
}

/// RFC 1918, link-local, loopback / `localhost` (IPv4 and IPv6).
bool isPrivateHost(String host) {
  final h = _normalise(host);
  if (h == 'localhost' || h.endsWith('.localhost')) return true;
  final ip = _ipv4(h);
  if (ip != null) {
    return ip[0] == 10 ||
        (ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31) ||
        (ip[0] == 192 && ip[1] == 168) ||
        (ip[0] == 169 && ip[1] == 254) ||
        ip[0] == 127;
  }
  if (h.contains(':')) {
    // IPv6: loopback, link-local fe80::/10, unique local fc00::/7.
    if (h == '::1') return true;
    final first = int.tryParse(h.split(':').first, radix: 16);
    if (first == null) return false;
    return (first & 0xffc0) == 0xfe80 || (first & 0xfe00) == 0xfc00;
  }
  return false;
}

/// The network a URL is on.
NetworkKind networkKindOf(Uri url) {
  if (isTailscaleHost(url.host)) return NetworkKind.tailscale;
  if (isPrivateHost(url.host)) return NetworkKind.lan;
  return NetworkKind.internet;
}

/// Whether onboarding / the server editor must warn that passwords and tokens
/// would travel unencrypted: plain `http://` to a host that is neither
/// private nor on the tailnet.
bool needsPlainHttpWarning(Uri url) =>
    url.scheme == 'http' && !isPrivateHost(url.host) && !isTailscaleHost(url.host);

String _normalise(String host) {
  var h = host.trim().toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
  if (h.endsWith('.')) h = h.substring(0, h.length - 1);
  return h;
}

List<int>? _ipv4(String h) {
  final parts = h.split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final p in parts) {
    if (p.isEmpty || p.length > 3) return null;
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return null;
    out.add(n);
  }
  return out;
}
