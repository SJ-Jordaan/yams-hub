/// SSRF-safe outbound internet fetches (ARCHITECTURE §5.6 `RemoteFetcher`).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:logging/logging.dart';

import '../../version.dart';
import 'body_reader.dart';

final _log = Logger('core.upstream.remote');

/// Resolves a host name to its addresses.
typedef AddressLookup = Future<List<InternetAddress>> Function(String host);

/// Why a remote fetch was refused or failed. [toString] never contains the
/// URL (it may carry credentials, e.g. tracker passkeys).
enum RemoteFailure {
  /// Scheme, host allow-list, private address or single-label name.
  notAllowed,

  /// More redirects than allowed, or a redirect without a usable `Location`.
  tooManyRedirects,
  tooLarge,
  timeout,
  unavailable,

  /// The final response was not 2xx; see [RemoteFetchException.status].
  httpError,
}

final class RemoteFetchException implements Exception {
  const RemoteFetchException(this.failure, {this.status, this.reason});

  final RemoteFailure failure;
  final int? status;
  final String? reason;

  @override
  String toString() =>
      'RemoteFetchException(${failure.name}${status == null ? '' : ' $status'}'
      '${reason == null ? '' : ': $reason'})';
}

/// The outcome of [RemoteFetcher.fetch].
sealed class RemoteResult {
  const RemoteResult();
}

/// A fetched body.
final class RemoteBody extends RemoteResult {
  const RemoteBody({
    required this.uri,
    required this.status,
    required this.headers,
    required this.bytes,
  });

  /// The final URI after redirects.
  final Uri uri;
  final int status;

  /// Lower-case header names.
  final Map<String, String> headers;
  final Uint8List bytes;

  String? get contentType => headers['content-type'];
}

/// A redirect to a `magnet:` link (handed to qBittorrent, never fetched).
final class RemoteMagnet extends RemoteResult {
  const RemoteMagnet(this.uri);

  final Uri uri;
}

/// Pins a validated address per `host:port` for the production HTTP client,
/// so the connection goes to the address that passed the public-IP check
/// (no DNS rebinding between check and connect).
final class _AddressPins {
  final _pins = <String, InternetAddress>{};

  void pin(String host, int port, InternetAddress address) =>
      _pins['${host.toLowerCase()}:$port'] = address;

  InternetAddress? lookup(String host, int port) =>
      _pins['${host.toLowerCase()}:$port'];
}

/// Fetches internet resources: automatic redirects disabled, at most
/// `maxRedirects` followed manually, every hop `https` (unless the caller
/// allows plain http) and resolving only to public addresses; single-label
/// names (Docker service names) are refused. Bodies are capped while
/// streaming.
final class RemoteFetcher {
  RemoteFetcher({required this._client, AddressLookup? lookup, this._pin})
    : _lookup = lookup ?? InternetAddress.lookup;

  /// The production fetcher: a dedicated `HttpClient` that connects to the
  /// pinned, checked address while keeping TLS verification for the host
  /// name.
  factory RemoteFetcher.production() {
    final pins = _AddressPins();
    final io = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..idleTimeout = const Duration(seconds: 15)
      ..maxConnectionsPerHost = 4
      ..autoUncompress = true
      ..userAgent = 'yams-hub/$hubVersion'
      ..findProxy = ((_) => 'DIRECT');
    io.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) {
      final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
      final address = pins.lookup(uri.host, port);
      if (address == null) {
        return Future.error(
          const SocketException('remote host was not validated'),
        );
      }
      final Future<Socket> socket = uri.scheme == 'https'
          ? Socket.connect(
              address,
              port,
            ).then((s) => SecureSocket.secure(s, host: uri.host))
          : Socket.connect(address, port);
      return Future.value(ConnectionTask.fromSocket(socket, () {}));
    };
    return RemoteFetcher(client: IOClient(io), pin: pins.pin);
  }

  final http.Client _client;
  final AddressLookup _lookup;
  final void Function(String host, int port, InternetAddress address)? _pin;

  /// Fetches [uri]. [allowHost] (when given) must accept every hop. With
  /// [allowHttp] plain-http hops are allowed too (still public-IP checked).
  Future<RemoteResult> fetch(
    Uri uri, {
    int maxBytes = 15 * 1024 * 1024,
    Duration timeout = const Duration(seconds: 10),
    int maxRedirects = 3,
    bool Function(Uri uri)? allowHost,
    bool allowHttp = false,
    Map<String, String>? headers,
  }) async {
    final deadline = DateTime.now().add(timeout);
    var current = uri;
    for (var hop = 0; ; hop++) {
      if (current.scheme == 'magnet') return RemoteMagnet(current);
      await _checkHop(current, allowHost: allowHost, allowHttp: allowHttp);
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw const RemoteFetchException(RemoteFailure.timeout);
      }
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll({
          'accept': '*/*',
          'user-agent': 'yams-hub/$hubVersion',
          ...?headers,
        });
      final http.StreamedResponse r;
      try {
        r = await _client.send(request).timeout(remaining);
      } on TimeoutException {
        throw const RemoteFetchException(RemoteFailure.timeout);
      } on Exception {
        throw const RemoteFetchException(RemoteFailure.unavailable);
      }
      final status = r.statusCode;
      if (status >= 300 && status < 400 && status != 304) {
        unawaited(r.stream.drain<void>().catchError((Object _) {}));
        final location = r.headers['location'];
        if (location == null || hop >= maxRedirects) {
          throw const RemoteFetchException(RemoteFailure.tooManyRedirects);
        }
        final next = Uri.tryParse(location.trim());
        if (next == null) {
          throw const RemoteFetchException(
            RemoteFailure.notAllowed,
            reason: 'invalid redirect location',
          );
        }
        current = current.resolveUri(next);
        continue;
      }
      if (status < 200 || status >= 300) {
        unawaited(r.stream.drain<void>().catchError((Object _) {}));
        throw RemoteFetchException(RemoteFailure.httpError, status: status);
      }
      final left = deadline.difference(DateTime.now());
      try {
        final bytes = await readCapped(
          r.stream,
          maxBytes: maxBytes,
          timeout: left.isNegative ? Duration.zero : left,
        );
        return RemoteBody(
          uri: current,
          status: status,
          headers: {
            for (final e in r.headers.entries) e.key.toLowerCase(): e.value,
          },
          bytes: bytes,
        );
      } on BodyTooLargeException {
        throw const RemoteFetchException(RemoteFailure.tooLarge);
      } on TimeoutException {
        throw const RemoteFetchException(RemoteFailure.timeout);
      } on Exception {
        throw const RemoteFetchException(RemoteFailure.unavailable);
      }
    }
  }

  Future<void> _checkHop(
    Uri uri, {
    bool Function(Uri uri)? allowHost,
    required bool allowHttp,
  }) async {
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && !(allowHttp && scheme == 'http')) {
      throw const RemoteFetchException(
        RemoteFailure.notAllowed,
        reason: 'scheme not allowed',
      );
    }
    final host = uri.host.toLowerCase();
    if (host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const RemoteFetchException(
        RemoteFailure.notAllowed,
        reason: 'bad host',
      );
    }
    if (allowHost != null && !allowHost(uri)) {
      throw const RemoteFetchException(
        RemoteFailure.notAllowed,
        reason: 'host not on the allow-list',
      );
    }
    final literal = InternetAddress.tryParse(host);
    final List<InternetAddress> addresses;
    if (literal != null) {
      addresses = [literal];
    } else {
      if (!host.contains('.') || host.endsWith('.')) {
        throw const RemoteFetchException(
          RemoteFailure.notAllowed,
          reason: 'single-label host',
        );
      }
      try {
        addresses = await _lookup(host).timeout(const Duration(seconds: 5));
      } on Exception {
        throw const RemoteFetchException(
          RemoteFailure.unavailable,
          reason: 'DNS lookup failed',
        );
      }
    }
    if (addresses.isEmpty) {
      throw const RemoteFetchException(
        RemoteFailure.unavailable,
        reason: 'no address',
      );
    }
    for (final a in addresses) {
      if (!isPublicAddress(a)) {
        _log.warning('refused a remote fetch to a non-public address ($host)');
        throw const RemoteFetchException(
          RemoteFailure.notAllowed,
          reason: 'non-public address',
        );
      }
    }
    final port = uri.hasPort ? uri.port : (scheme == 'https' ? 443 : 80);
    _pin?.call(host, port, addresses.first);
  }
}

/// Whether [a] is a public unicast address. Loopback, `0/8`, `10/8`,
/// `100.64/10`, `127/8`, `169.254/16`, `172.16/12` (includes `yams_network`
/// 172.28.0.0/24), `192.0.0/24`, `192.168/16`, `198.18/15`, multicast and
/// reserved ranges, `::`, `::1`, `fc00::/7`, `fe80::/10`, multicast and
/// IPv4-mapped private addresses are not.
bool isPublicAddress(InternetAddress a) {
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) return _publicV4(b);
  if (a.type != InternetAddressType.IPv6 || b.length != 16) return false;
  // IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d).
  final zeros10 = b.sublist(0, 10).every((x) => x == 0);
  if (zeros10 && b[10] == 0xff && b[11] == 0xff) {
    return _publicV4(b.sublist(12));
  }
  if (b.every((x) => x == 0)) return false; // ::
  if (b.sublist(0, 15).every((x) => x == 0) && b[15] == 1) return false; // ::1
  if (zeros10 && b[10] == 0 && b[11] == 0) return false; // ::a.b.c.d
  if ((b[0] & 0xfe) == 0xfc) return false; // fc00::/7
  if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return false; // fe80::/10
  if (b[0] == 0xff) return false; // multicast
  if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) {
    return false; // 2001:db8::/32 documentation
  }
  if (b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b) {
    return false; // 64:ff9b::/96 NAT64 (could reach private v4)
  }
  return true;
}

bool _publicV4(List<int> b) {
  final x = b[0], y = b[1];
  if (x == 0 || x == 10 || x == 127) return false;
  if (x == 100 && y >= 64 && y <= 127) return false;
  if (x == 169 && y == 254) return false;
  if (x == 172 && y >= 16 && y <= 31) return false;
  if (x == 192 && y == 168) return false;
  if (x == 192 && y == 0 && b[2] == 0) return false;
  if (x == 198 && (y == 18 || y == 19)) return false;
  if (x >= 224) return false; // multicast, reserved, broadcast
  return true;
}
