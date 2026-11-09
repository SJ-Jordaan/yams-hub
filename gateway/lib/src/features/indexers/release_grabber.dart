/// `POST /indexers/grab`: hands a manual-search release to qBittorrent with
/// the SSRF rules of API.md §10.4.
///
/// - A magnet link goes to qBittorrent `torrents/add urls=`.
/// - A Prowlarr proxied download URL (`/<indexerId>/download...`) is fetched
///   from `PROWLARR_URL` with the Prowlarr client (key in the header, the
///   `apikey=` query parameter removed); whatever host Prowlarr advertises in
///   the URL is ignored.
/// - Any other URL is fetched only through `RemoteFetcher` (https, public
///   addresses only, redirects followed manually and re-checked).
/// - A redirect to `magnet:` (from either path) becomes a magnet add.
/// - 60 s timeout, 5 MB cap while streaming, and the body must be a bencoded
///   dictionary; it is uploaded to qBittorrent as multipart.
///
/// The download URL is never logged and never part of an error message.
library;

import 'package:logging/logging.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'bencode.dart';
import 'prowlarr_mapping.dart';

/// Download limits for grabbed `.torrent` files.
const grabTimeout = Duration(seconds: 60);
const grabMaxBytes = 5 * 1024 * 1024;

/// Redirects followed after the first hop (3 in total).
const grabMaxRedirects = 3;

/// What qBittorrent receives.
sealed class GrabPayload {
  const GrabPayload();
}

final class GrabMagnet extends GrabPayload {
  const GrabMagnet(this.uri);

  final String uri;
}

final class GrabTorrentFile extends GrabPayload {
  const GrabTorrentFile(this.bytes);

  final List<int> bytes;
}

/// How a release was obtained (for the log line).
enum GrabRoute { magnet, prowlarr, remote }

/// The result of [ReleaseGrabber.grab].
final class GrabOutcome {
  const GrabOutcome(this.route, {required this.categoryCreated});

  final GrabRoute route;
  final bool categoryCreated;
}

/// Downloads releases safely and adds them to qBittorrent.
final class ReleaseGrabber {
  ReleaseGrabber({
    required this.prowlarr,
    required this.qbittorrent,
    required this.remote,
    required this.log,
    this.redact = redactSecrets,
  });

  factory ReleaseGrabber.fromContext(FeatureContext ctx) => ReleaseGrabber(
    prowlarr: ctx.upstreams.prowlarr,
    qbittorrent: ctx.upstreams.qbittorrent,
    remote: ctx.remoteHttp,
    log: ctx.log,
    redact: ctx.redact,
  );

  final UpstreamClient prowlarr;
  final UpstreamClient qbittorrent;
  final RemoteFetcher remote;
  final Logger log;
  final String Function(String) redact;

  /// Downloads [release] (if it is not a magnet) and adds it to qBittorrent in
  /// [category] with [tags]. Throws [ApiException]s with safe messages.
  Future<GrabOutcome> grab(
    ProwlarrReleaseLinks release, {
    required String category,
    List<String> tags = const [],
  }) async {
    if (release.protocol == 'usenet') {
      throw ApiException.invalidField(
        'releaseId',
        'Usenet releases cannot be sent to qBittorrent.',
      );
    }
    final (route, payload) = await _resolve(release);
    log.info(
      'grab: indexer ${release.indexerId} "${redact(release.title)}" '
      'via ${route.name}',
    );
    final created = await _ensureCategory(category);
    await _add(payload, category: category, tags: tags);
    return GrabOutcome(route, categoryCreated: created);
  }

  // -------------------------------------------------------------------------
  // Download
  // -------------------------------------------------------------------------

  Future<(GrabRoute, GrabPayload)> _resolve(ProwlarrReleaseLinks r) async {
    final magnet = r.magnetUrl;
    if (magnet != null) return (GrabRoute.magnet, _magnet(magnet));
    // Prowlarr's proxied magnet link (redirects to `magnet:`) is the fallback.
    final raw = r.downloadUrl ?? r.magnetLinkUrl;
    if (raw == null) {
      throw ApiException.invalidField(
        'releaseId',
        'This release has no download link.',
      );
    }
    if (raw.toLowerCase().startsWith('magnet:')) {
      return (GrabRoute.magnet, _magnet(raw));
    }
    final uri = Uri.tryParse(raw);
    if (uri == null) throw _notAllowed();
    final proxied = prowlarrDownloadTarget(uri, r.indexerId, prowlarr.baseUrl);
    if (proxied != null) {
      return (GrabRoute.prowlarr, await _fromProwlarr(proxied));
    }
    return (GrabRoute.remote, await _fromRemote(uri, grabMaxRedirects));
  }

  Future<GrabPayload> _fromProwlarr(ProwlarrDownloadTarget target) async {
    final UpstreamResponse response;
    try {
      response = await prowlarr.send(
        'GET',
        target.path,
        query: target.query,
        timeout: grabTimeout,
        maxBytes: grabMaxBytes,
        headers: const {'accept': 'application/x-bittorrent, */*'},
      );
    } on UpstreamBadResponse catch (e) {
      if (e.reason == 'response too large') throw _tooLarge();
      throw e.toApiException(resourceNotFound: false);
    } on UpstreamException catch (e) {
      throw e.toApiException(resourceNotFound: false);
    }
    final status = response.status;
    if (status >= 300 && status < 400 && status != 304) {
      final location = response.headers['location']?.trim();
      final next = location == null ? null : Uri.tryParse(location);
      if (next == null) throw _notAllowed();
      final resolved = prowlarr.buildUri(target.path).resolveUri(next);
      if (resolved.scheme.toLowerCase() == 'magnet') {
        return _magnet(resolved.toString());
      }
      // The Prowlarr hop counts as the first redirect.
      return _fromRemote(resolved, grabMaxRedirects - 1);
    }
    if (!response.ok) {
      if (status == 401 || status == 403 || response.isHostRejected) {
        try {
          response.ensureOk();
        } on UpstreamException catch (e) {
          throw e.toApiException(resourceNotFound: false);
        }
      }
      // Prowlarr's error text can quote the tracker URL: never pass it on.
      log.info('grab: Prowlarr download failed ($status)');
      throw ApiException(
        502,
        ApiErrorCode.upstreamError,
        'Prowlarr could not download the release ($status).',
        service: ServiceId.prowlarr,
        details: {'upstreamStatus': status},
      );
    }
    return _torrent(response.bodyBytes);
  }

  Future<GrabPayload> _fromRemote(Uri uri, int maxRedirects) async {
    final RemoteResult result;
    try {
      result = await remote.fetch(
        uri,
        maxBytes: grabMaxBytes,
        timeout: grabTimeout,
        maxRedirects: maxRedirects,
        headers: const {'accept': 'application/x-bittorrent, */*'},
      );
    } on RemoteFetchException catch (e) {
      log.info(
        'grab: remote download refused or failed (${e.failure.name}'
        '${e.status == null ? '' : ' ${e.status}'})',
      );
      throw switch (e.failure) {
        RemoteFailure.notAllowed ||
        RemoteFailure.tooManyRedirects => _notAllowed(),
        RemoteFailure.tooLarge => _tooLarge(),
        RemoteFailure.timeout => const ApiException(
          504,
          ApiErrorCode.upstreamTimeout,
          'The release download did not finish in time.',
        ),
        RemoteFailure.unavailable => const ApiException(
          503,
          ApiErrorCode.upstreamUnavailable,
          'The release download host is not reachable.',
        ),
        RemoteFailure.httpError => ApiException(
          502,
          ApiErrorCode.upstreamError,
          'The release download failed (${e.status}).',
          details: {'upstreamStatus': e.status},
        ),
      };
    }
    return switch (result) {
      RemoteMagnet(:final uri) => _magnet(uri.toString()),
      RemoteBody(:final bytes) => _torrent(bytes),
    };
  }

  /// qBittorrent's `urls=` is newline-separated: a magnet carrying
  /// whitespace or control characters could smuggle a second (http) URL for
  /// qBittorrent to fetch, so only a single clean `magnet:?` link passes.
  static final _cleanMagnet = RegExp(
    r'^magnet:\?[^\s\x00-\x1f\x7f]+$',
    caseSensitive: false,
  );

  GrabMagnet _magnet(String uri) {
    if (uri.length > 8192 || !_cleanMagnet.hasMatch(uri)) throw _notAllowed();
    return GrabMagnet(uri);
  }

  GrabPayload _torrent(List<int> bytes) {
    if (!isTorrentFile(bytes)) {
      throw const ApiException(
        502,
        ApiErrorCode.upstreamBadResponse,
        'The release download is not a valid .torrent file.',
      );
    }
    return GrabTorrentFile(bytes);
  }

  static ApiException _notAllowed() => ApiException.validation(const [
    ApiFieldError(field: 'releaseId', message: 'Release URL not allowed'),
  ], message: 'Release URL not allowed');

  static ApiException _tooLarge() => const ApiException(
    502,
    ApiErrorCode.upstreamBadResponse,
    'The release download is larger than 5 MB.',
  );

  // -------------------------------------------------------------------------
  // qBittorrent
  // -------------------------------------------------------------------------

  /// Makes sure [category] exists; only [ReleaseGrabRequest.defaultCategory]
  /// is created on demand. Returns whether it was created.
  Future<bool> _ensureCategory(String category) async {
    try {
      final body = await qbittorrent.getJson('/api/v2/torrents/categories');
      final existing = readMap(body)?.keys.toSet() ?? const <String>{};
      if (existing.contains(category)) return false;
      if (category != ReleaseGrabRequest.defaultCategory) {
        throw ApiException.invalidField(
          'category',
          'Category "$category" does not exist in qBittorrent.',
        );
      }
      final r = await qbittorrent.send(
        'POST',
        '/api/v2/torrents/createCategory',
        form: {'category': category, 'savePath': ''},
      );
      // 409: created concurrently.
      if (r.status == 409) return false;
      r.ensureOk();
      log.info('grab: created qBittorrent category "$category"');
      return true;
    } on UpstreamException catch (e) {
      throw e.toApiException(resourceNotFound: false);
    }
  }

  Future<void> _add(
    GrabPayload payload, {
    required String category,
    required List<String> tags,
  }) async {
    final UpstreamResponse r;
    try {
      r = switch (payload) {
        GrabMagnet(:final uri) => await qbittorrent.send(
          'POST',
          '/api/v2/torrents/add',
          form: {
            'urls': uri,
            'category': category,
            if (tags.isNotEmpty) 'tags': tags.join(','),
          },
        ),
        GrabTorrentFile(:final bytes) => await qbittorrent.send(
          'POST',
          '/api/v2/torrents/add',
          multipart: [
            MultipartPart.file(
              'torrents',
              'release.torrent',
              bytes,
              'application/x-bittorrent',
            ),
            MultipartPart.field('category', category),
            if (tags.isNotEmpty) MultipartPart.field('tags', tags.join(',')),
          ],
        ),
      };
    } on UpstreamException catch (e) {
      throw e.toApiException(resourceNotFound: false);
    }
    if (r.status == 415) {
      throw ApiException.invalidField(
        'releaseId',
        'qBittorrent rejected the torrent.',
      );
    }
    try {
      r.ensureOk();
    } on UpstreamException catch (e) {
      throw e.toApiException(resourceNotFound: false);
    }
    if (r.text().trim() == 'Fails.') {
      throw ApiException.conflict(
        'qBittorrent did not add the torrent (it may already be in the list).',
      );
    }
  }
}

/// A Prowlarr-relative download request.
final class ProwlarrDownloadTarget {
  const ProwlarrDownloadTarget(this.path, this.query);

  /// Absolute from the Prowlarr root (`/4/download`), without the base path
  /// of `PROWLARR_URL` (the client adds it).
  final String path;

  /// The original query minus `apikey`.
  final Map<String, Object?> query;
}

final _safeSegment = RegExp(r'^[A-Za-z0-9._~!$&()*+,;=:@%-]+$');

/// When [url] is Prowlarr's proxied download route for [indexerId]
/// (`[<urlBase>]/<indexerId>/download[/...]`), the request to send to
/// [prowlarrBase] instead; otherwise null. Scheme, host and port of [url] are
/// ignored: only `PROWLARR_URL` is ever contacted.
ProwlarrDownloadTarget? prowlarrDownloadTarget(
  Uri url,
  int indexerId,
  Uri prowlarrBase,
) {
  final scheme = url.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  if (indexerId <= 0) return null;
  var segments = url.pathSegments;
  final base = [
    for (final s in prowlarrBase.pathSegments)
      if (s.isNotEmpty) s,
  ];
  if (base.isNotEmpty &&
      segments.length > base.length &&
      _startsWith(segments, base)) {
    segments = segments.sublist(base.length);
  }
  if (segments.length < 2 ||
      segments[0] != '$indexerId' ||
      segments[1] != 'download') {
    return null;
  }
  for (final s in segments) {
    if (s.isEmpty || s == '.' || s == '..' || !_safeSegment.hasMatch(s)) {
      return null;
    }
  }
  final query = <String, Object?>{
    for (final e in url.queryParametersAll.entries)
      if (e.key.toLowerCase() != 'apikey') e.key: e.value,
  };
  return ProwlarrDownloadTarget('/${segments.join('/')}', query);
}

bool _startsWith(List<String> list, List<String> prefix) {
  for (var i = 0; i < prefix.length; i++) {
    if (list[i] != prefix[i]) return false;
  }
  return true;
}
