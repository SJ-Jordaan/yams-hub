/// `/img/**`: the image proxy (ARCHITECTURE §5.8, API.md §3).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:yams_models/yams_models.dart';

import '../../config/config.dart';
import '../clock.dart';
import '../http/api_exception.dart';
import '../http/api_request.dart';
import '../http/api_response.dart';
import '../http/api_router.dart';
import '../services/seerr_identity.dart';
import '../upstream/remote_fetcher.dart';
import '../upstream/upstream_client.dart';
import '../upstream/upstreams.dart';
import 'image_cache.dart';
import 'image_spec.dart';

final _log = Logger('core.images');

/// Largest accepted image (enforced while streaming).
const maxImageBytes = 15 * 1024 * 1024;

const _fetchTimeout = Duration(seconds: 10);

/// Headers on every `/img` response.
const imageSecurityHeaders = {
  'content-security-policy': "default-src 'none'; sandbox",
  'x-content-type-options': 'nosniff',
  'cross-origin-resource-policy': 'same-origin',
  'content-disposition': 'inline',
};

/// `Cache-Control` of an image `404`.
const imageNotFoundCacheControl = 'private, max-age=300';

final class _Fetched {
  const _Fetched(this.bytes, this.contentType);

  final Uint8List bytes;
  final String contentType;
}

/// Bounds concurrent upstream image fetches (queued, never rejected).
final class _FetchSlots {
  _FetchSlots(this.max);

  final int max;
  int _running = 0;
  final _waiting = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() f) async {
    if (_running >= max) {
      final c = Completer<void>();
      _waiting.add(c);
      await c.future;
    } else {
      _running++;
    }
    try {
      return await f();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _running--;
      }
    }
  }
}

/// Serves `/img/**` from the disk cache or the upstream.
final class ImageService {
  ImageService({
    required HubConfig config,
    required Upstreams upstreams,
    required this._remote,
    required SeerrIdentityResolver seerrIdentity,
    required this.cache,
    required Clock clock,
  }) : _config = config,
       _up = upstreams,
       _seerr = seerrIdentity,
       _limiter = RemoteEntryLimiter(
         config.imageCache.newRemoteEntriesPerUserPerMinute,
         clock,
       );

  final HubConfig _config;
  final Upstreams _up;
  final RemoteFetcher _remote;
  final SeerrIdentityResolver _seerr;
  final ImageDiskCache cache;
  final RemoteEntryLimiter _limiter;
  final _slots = _FetchSlots(8);
  final _inflight = <String, Future<_Fetched>>{};
  Timer? _pruneTimer;

  List<String> get _hosts => _config.remoteImageHosts;

  /// Starts the 10-minute reconciliation of the size counter with the disk.
  void start() {
    _pruneTimer?.cancel();
    _pruneTimer = Timer.periodic(
      const Duration(minutes: 10),
      (_) => unawaited(cache.scan()),
    );
  }

  void stop() {
    _pruneTimer?.cancel();
    _pruneTimer = null;
  }

  void registerRoutes(ApiRouter router) {
    Future<Response> Function(ApiRequest) h(String kind) =>
        (req) => serve(
          req,
          ImageSpec.parse(kind, req.pathParams, req.query, remoteHosts: _hosts),
        );
    router
      ..get('/img/arr/<svc>/<id|[^/]+>/<coverType>', h('arr'))
      ..get('/img/remote', h('remote'))
      ..get('/img/tmdb/<size>/<file>', h('tmdb'))
      ..get('/img/jellyfin/<itemId>/<imageType>', h('jellyfin'))
      ..get('/img/jellyfin-user/<userId>', h('jellyfin-user'))
      ..get('/img/abs/<itemId>', h('abs'))
      ..get('/img/kavita/series/<seriesId|[^/]+>', h('kavita'))
      ..get('/img/seerr-avatar/<seerrUserId|[^/]+>', h('seerr-avatar'));
  }

  /// Serves [spec] for [req]. A `404` lets the browser cache the miss for
  /// five minutes, so a missing poster or avatar is not asked for again on
  /// every navigation; other errors stay uncacheable (`no-store`).
  Future<Response> serve(ApiRequest req, ImageSpec spec) async {
    try {
      return await _serve(req, spec);
    } on ApiException catch (e) {
      if (e.status != 404) rethrow;
      return ApiResponse.error(
        e,
        req.requestId,
      ).change(headers: const {'cache-control': imageNotFoundCacheControl});
    }
  }

  Future<Response> _serve(ApiRequest req, ImageSpec spec) async {
    final key = spec.cacheKey;
    final cached = await cache.read(key);
    final stale =
        cached != null &&
        spec is ArrImageSpec &&
        spec.version != null &&
        cached.version != spec.version;
    if (cached != null && !stale) {
      return _respond(req, spec, cached.bytes, cached.contentType, cached.hash);
    }
    final fetched = await _singleFlight(
      '$key#${spec.version ?? ''}',
      () => _slots.run(() => _fetch(spec)),
    );
    var store = cache.canWrite(fetched.bytes.length);
    if (store && spec.isRemote && cached == null && req.isAuthenticated) {
      store = _limiter.tryAcquire(req.user.id);
    }
    if (store) {
      await cache.write(
        key,
        fetched.bytes,
        contentType: fetched.contentType,
        version: spec.version,
      );
    }
    return _respond(
      req,
      spec,
      fetched.bytes,
      fetched.contentType,
      ImageDiskCache.hashOf(key),
    );
  }

  Future<_Fetched> _singleFlight(String key, Future<_Fetched> Function() f) {
    final running = _inflight[key];
    if (running != null) return running;
    final future = f();
    _inflight[key] = future;
    future.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      _inflight.remove(key);
    });
    return future;
  }

  Response _respond(
    ApiRequest req,
    ImageSpec spec,
    Uint8List bytes,
    String contentType,
    String hash,
  ) {
    final etag = '"$hash"';
    final headers = <String, Object>{
      ...imageSecurityHeaders,
      'cache-control': spec.versioned
          ? 'private, max-age=31536000, immutable'
          : 'private, max-age=86400',
      'etag': etag,
    };
    final inm = req.request.headers['if-none-match'];
    if (inm != null && inm.split(',').map((s) => s.trim()).contains(etag)) {
      return Response.notModified(headers: headers);
    }
    return Response.ok(
      bytes,
      headers: {...headers, 'content-type': contentType},
    );
  }

  // -------------------------------------------------------------------------
  // Upstream fetches
  // -------------------------------------------------------------------------

  Future<_Fetched> _fetch(ImageSpec spec) async {
    switch (spec) {
      case ArrImageSpec():
        final client = _up.arr(spec.service);
        final r = await _send(
          client,
          '/MediaCover/${spec.id}/${spec.upstreamFile}',
        );
        if (r.status == 404) {
          final fb = spec.fallback;
          // The fallback (often a TMDB `/t/p/original/` URL) is fetched at
          // the requested size bucket; the cache key stays the arr spec.
          if (fb != null) {
            final width = spec.size == 'full' ? null : int.parse(spec.size);
            return _fetchRemote(RemoteImageSpec(fb, width).upstreamUrl);
          }
          throw ApiException.notFound('Image not found.');
        }
        return _check(r);
      case RemoteImageSpec():
        return _fetchRemote(spec.upstreamUrl);
      case TmdbImageSpec():
        return _fetchRemote(spec.upstreamUrl);
      case JellyfinImageSpec():
        final up = spec.upstream;
        return _check(
          await _send(
            _up.jellyfin,
            '/${up.segments.join('/')}',
            query: up.query,
          ),
          notFound: true,
        );
      case JellyfinUserImageSpec():
        return _check(
          await _send(
            _up.jellyfin,
            '/Users/${spec.userId}/Images/Primary',
            query: {'tag': ?spec.tag},
          ),
          notFound: true,
        );
      case AbsImageSpec():
        return _check(
          await _send(
            _up.audiobookshelf,
            '/api/items/${spec.itemId}/cover',
            query: {'width': spec.width, 'format': 'webp'},
          ),
          notFound: true,
        );
      case KavitaImageSpec():
        return _check(
          await _send(
            _up.kavita,
            '/api/Image/series-cover',
            query: {'seriesId': spec.seriesId},
          ),
          notFound: true,
        );
      case SeerrAvatarImageSpec():
        return _fetchSeerrAvatar(spec.seerrUserId);
    }
  }

  Future<UpstreamResponse> _send(
    UpstreamClient c,
    String path, {
    Map<String, Object?>? query,
  }) async {
    final r = await c.send(
      'GET',
      path,
      query: query,
      timeout: _fetchTimeout,
      maxBytes: maxImageBytes,
      headers: const {
        'accept':
            'image/avif,image/webp,image/png,image/jpeg,image/gif,*/*;q=0.1',
      },
    );
    return r;
  }

  _Fetched _check(UpstreamResponse r, {bool notFound = false}) {
    if (r.status == 404 && notFound) {
      throw ApiException.notFound('Image not found.');
    }
    // Upstream 404/5xx are never cached; they are mapped like other errors.
    r.ensureOk();
    return _validate(r.bodyBytes, r.contentType, r.service);
  }

  _Fetched _validate(Uint8List bytes, String? contentType, ServiceId service) {
    final sniffed = sniffImageType(bytes);
    if (sniffed == null || !acceptableUpstreamImageType(contentType)) {
      _log.warning(
        'refused an image from ${service.name}: content type ${contentType ?? '-'}, '
        'sniffed ${sniffed ?? 'unknown'}',
      );
      throw ApiException(
        502,
        ApiErrorCode.upstreamBadResponse,
        'The upstream image is not a supported raster image.',
        service: service,
      );
    }
    return _Fetched(bytes, sniffed);
  }

  Future<_Fetched> _fetchRemote(Uri url) async {
    try {
      final result = await _remote.fetch(
        url,
        maxBytes: maxImageBytes,
        timeout: _fetchTimeout,
        maxRedirects: 2,
        allowHost: (u) => isAllowedRemoteImage(u, _hosts),
        headers: const {
          'accept':
              'image/avif,image/webp,image/png,image/jpeg,image/gif,*/*;q=0.1',
        },
      );
      return switch (result) {
        RemoteBody() => _validate(
          result.bytes,
          result.contentType,
          ServiceId.unknown,
        ),
        RemoteMagnet() => throw ApiException.notFound('Image not found.'),
      };
    } on RemoteFetchException catch (e) {
      throw switch (e.failure) {
        RemoteFailure.notAllowed || RemoteFailure.tooManyRedirects =>
          ApiException.notFound('Image not found.'),
        RemoteFailure.httpError when e.status == 404 || e.status == 410 =>
          ApiException.notFound('Image not found.'),
        RemoteFailure.httpError => ApiException(
          502,
          ApiErrorCode.upstreamError,
          'The image host returned an error.',
          details: {'upstreamStatus': ?e.status},
        ),
        RemoteFailure.tooLarge => const ApiException(
          502,
          ApiErrorCode.upstreamBadResponse,
          'The image is too large.',
        ),
        RemoteFailure.timeout => const ApiException(
          504,
          ApiErrorCode.upstreamTimeout,
          'The image host did not answer in time.',
        ),
        RemoteFailure.unavailable => const ApiException(
          503,
          ApiErrorCode.upstreamUnavailable,
          'The image host is not reachable.',
        ),
      };
    }
  }

  Future<_Fetched> _fetchSeerrAvatar(int seerrUserId) async {
    final seerr = _up.seerr;
    if (!seerr.configured) throw ApiException.notFound('Image not found.');
    final user = await _seerr.userById(seerrUserId);
    final avatar = user?.avatar;
    if (avatar == null || avatar.isEmpty) {
      throw ApiException.notFound('Image not found.');
    }
    if (avatar.startsWith('/') && !avatar.startsWith('//')) {
      final base = seerr.baseUrl;
      final resolved = base.resolve(avatar);
      if (resolved.scheme != base.scheme ||
          resolved.host != base.host ||
          resolved.port != base.port) {
        throw ApiException.notFound('Image not found.');
      }
      final segments = resolved.pathSegments;
      if (segments.any((s) => s == '..' || s == '.')) {
        throw ApiException.notFound('Image not found.');
      }
      final basePath = base.pathSegments.where((s) => s.isNotEmpty).toList();
      final underBase =
          basePath.isNotEmpty &&
          segments.length >= basePath.length &&
          const ListEquality<String>().equals(
            segments.sublist(0, basePath.length),
            basePath,
          );
      final relative = underBase ? segments.sublist(basePath.length) : segments;
      return _check(
        await _send(
          seerr,
          '/${relative.join('/')}',
          query: resolved.queryParametersAll,
        ),
        notFound: true,
      );
    }
    final abs = Uri.tryParse(avatar);
    if (abs != null && abs.scheme == 'https') return _fetchRemote(abs);
    throw ApiException.notFound('Image not found.');
  }
}
