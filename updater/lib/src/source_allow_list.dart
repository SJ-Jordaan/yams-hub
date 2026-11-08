/// Which peers may open a connection to the updater
/// (`UPDATER_ALLOWED_SOURCES`, ARCHITECTURE §5.17 and §6).
///
/// On Zenith, UGOS puts an `ACCEPT` for all inter-bridge traffic into
/// `DOCKER-USER`, so Docker's `internal: true` does not keep other containers
/// off `yams_hub_ctl`: any container on `yams_network` can connect to the
/// updater by IP. Such a peer arrives with its own container address or, when
/// Docker's per-bridge MASQUERADE rewrites it, with the control bridge's
/// gateway address (172.30.250.1); the gateway has a fixed address of its own
/// (172.30.250.2) that neither can be. This list is checked before the bearer
/// token, so nobody else even gets a 401 to probe.
library;

import 'dart:io';
import 'dart:typed_data';

/// One address range (`172.30.250.0/29`, `fd00::/8`, or a single address).
final class IpRange {
  IpRange._(this._network, this.prefixLength);

  final Uint8List _network;

  /// Number of leading bits that must match.
  final int prefixLength;

  /// Parses `addr` or `addr/prefix`. Throws [FormatException] when malformed
  /// or when bits below the prefix are set (`172.30.250.2/29` is almost
  /// certainly a typo for one address or for `172.30.250.0/29`).
  factory IpRange.parse(String text) {
    final t = text.trim();
    final slash = t.indexOf('/');
    final addr = InternetAddress.tryParse(
      slash < 0 ? t : t.substring(0, slash),
    );
    if (addr == null || addr.type == InternetAddressType.unix) {
      throw FormatException('"$t" is not an IP address or CIDR range');
    }
    final bytes = _unmapped(addr.rawAddress);
    final bits = bytes.length * 8;
    var prefix = bits;
    if (slash >= 0) {
      final p = int.tryParse(t.substring(slash + 1));
      if (p == null || p < 0 || p > bits) {
        throw FormatException('"$t" has an invalid prefix length');
      }
      prefix = p;
    }
    final range = IpRange._(Uint8List.fromList(bytes), prefix);
    if (!range._hostBitsClear()) {
      throw FormatException('"$t" has host bits set (did you mean $range?)');
    }
    return range;
  }

  /// Whether [address] lies in this range. IPv4-mapped IPv6 addresses
  /// (`::ffff:a.b.c.d`) count as IPv4.
  bool contains(InternetAddress address) {
    final bytes = _unmapped(address.rawAddress);
    if (bytes.length != _network.length) return false;
    for (var i = 0; i < bytes.length; i++) {
      final mask = _maskAt(i);
      if ((bytes[i] & mask) != (_network[i] & mask)) return false;
    }
    return true;
  }

  /// The netmask byte at index [i].
  int _maskAt(int i) {
    final bits = prefixLength - i * 8;
    if (bits >= 8) return 0xff;
    if (bits <= 0) return 0;
    return (0xff << (8 - bits)) & 0xff;
  }

  bool _hostBitsClear() {
    for (var i = 0; i < _network.length; i++) {
      if ((_network[i] & ~_maskAt(i) & 0xff) != 0) return false;
    }
    return true;
  }

  static List<int> _unmapped(List<int> b) {
    if (b.length != 16) return b;
    for (var i = 0; i < 10; i++) {
      if (b[i] != 0) return b;
    }
    return b[10] == 0xff && b[11] == 0xff ? b.sublist(12) : b;
  }

  @override
  String toString() {
    final masked = Uint8List.fromList([
      for (var i = 0; i < _network.length; i++) _network[i] & _maskAt(i),
    ]);
    final text = InternetAddress.fromRawAddress(masked).address;
    return prefixLength == _network.length * 8 ? text : '$text/$prefixLength';
  }
}

/// The peers allowed to connect: the configured ranges plus loopback, which
/// is always allowed (the Docker `HEALTHCHECK` runs `updater healthcheck`
/// inside the container against 127.0.0.1).
final class SourceAllowList {
  SourceAllowList(Iterable<IpRange> ranges)
    : ranges = List.unmodifiable(ranges);

  /// Parses `UPDATER_ALLOWED_SOURCES` (comma or whitespace separated).
  /// Throws [FormatException] for a malformed entry or an empty list.
  factory SourceAllowList.parse(String raw) {
    final ranges = [
      for (final part in raw.split(RegExp(r'[,\s]+')))
        if (part.trim().isNotEmpty) IpRange.parse(part),
    ];
    if (ranges.isEmpty) {
      throw const FormatException('no address or range given');
    }
    return SourceAllowList(ranges);
  }

  /// The configured ranges (loopback is implicit).
  final List<IpRange> ranges;

  /// Whether a connection from [address] may be served.
  bool allows(InternetAddress address) {
    final bytes = IpRange._unmapped(address.rawAddress);
    final plain = InternetAddress.fromRawAddress(Uint8List.fromList(bytes));
    if (plain.isLoopback) return true;
    return ranges.any((r) => r.contains(plain));
  }

  @override
  String toString() => ranges.join(',');
}
