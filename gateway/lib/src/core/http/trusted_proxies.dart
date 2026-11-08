/// The reverse proxies whose `X-Forwarded-*` headers are believed
/// (`YAMS_HUB_TRUST_PROXY` + `YAMS_HUB_TRUSTED_PROXIES`).
library;

import 'dart:io';
import 'dart:typed_data';

/// One address range (`10.0.0.0/8`, `::1/128`, or a single address).
final class IpRange {
  IpRange._(this._network, this.prefixLength);

  final Uint8List _network;
  final int prefixLength;

  /// Parses `addr` or `addr/prefix`; null when malformed.
  static IpRange? tryParse(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    final slash = t.indexOf('/');
    final addr = InternetAddress.tryParse(
      slash < 0 ? t : t.substring(0, slash),
    );
    if (addr == null) return null;
    final bytes = addr.rawAddress;
    final bits = bytes.length * 8;
    var prefix = bits;
    if (slash >= 0) {
      final p = int.tryParse(t.substring(slash + 1));
      if (p == null || p < 0 || p > bits) return null;
      prefix = p;
    }
    return IpRange._(Uint8List.fromList(bytes), prefix);
  }

  /// Whether [address] lies in this range (IPv4-mapped IPv6 addresses
  /// count as IPv4).
  bool contains(InternetAddress address) {
    var bytes = address.rawAddress;
    if (bytes.length == 16 && _network.length == 4 && _isV4Mapped(bytes)) {
      bytes = bytes.sublist(12);
    }
    if (bytes.length != _network.length) return false;
    var remaining = prefixLength;
    for (var i = 0; i < bytes.length && remaining > 0; i++) {
      final take = remaining >= 8 ? 8 : remaining;
      final mask = (0xff << (8 - take)) & 0xff;
      if ((bytes[i] & mask) != (_network[i] & mask)) return false;
      remaining -= take;
    }
    return true;
  }

  static bool _isV4Mapped(List<int> b) {
    for (var i = 0; i < 10; i++) {
      if (b[i] != 0) return false;
    }
    return b[10] == 0xff && b[11] == 0xff;
  }

  @override
  String toString() =>
      '${InternetAddress.fromRawAddress(_network).address}/$prefixLength';
}

/// The proxies allowed to set `X-Forwarded-For` / `X-Forwarded-Proto`.
final class TrustedProxies {
  TrustedProxies(this.ranges);

  /// Loopback only: the default when `YAMS_HUB_TRUSTED_PROXIES` is unset.
  factory TrustedProxies.loopback() => TrustedProxies([
    IpRange.tryParse('127.0.0.0/8')!,
    IpRange.tryParse('::1')!,
  ]);

  final List<IpRange> ranges;

  /// Whether [ip] (text) is a trusted proxy.
  bool trusts(String? ip) {
    if (ip == null) return false;
    final a = InternetAddress.tryParse(ip);
    return a != null && ranges.any((r) => r.contains(a));
  }

  /// Parses a comma-separated list; malformed entries go to [errors].
  static TrustedProxies parse(String text, List<String> errors) {
    final ranges = <IpRange>[];
    for (final raw in text.split(',')) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      final r = IpRange.tryParse(t);
      if (r == null) {
        errors.add(
          'YAMS_HUB_TRUSTED_PROXIES: "$t" is not an IP address or CIDR range',
        );
      } else {
        ranges.add(r);
      }
    }
    return TrustedProxies(ranges);
  }
}
