/// Validated image requests: the single parser and printer of `/img` paths
/// (ARCHITECTURE §5.8, API.md §3).
library;

import 'package:yams_models/yams_models.dart';

import '../../config/config.dart';
import '../http/api_exception.dart';

/// Gateway-relative prefix of every image path in DTOs.
const imagePathPrefix = '/api/v1/img';

/// Size buckets for size parameters (values are snapped up; larger → 1280).
const imageSizeBuckets = [96, 160, 250, 342, 500, 780, 1280];

/// Snaps [v] up to the next bucket.
int snapImageSize(int v) {
  for (final b in imageSizeBuckets) {
    if (v <= b) return b;
  }
  return imageSizeBuckets.last;
}

const arrCoverTypes = ['poster', 'fanart', 'banner', 'clearlogo'];
const arrSizes = ['250', '500', 'full'];
const tmdbSizes = [
  'w92',
  'w154',
  'w185',
  'w342',
  'w500',
  'w780',
  'w1280',
  'original',
  'h632',
  'w45',
];
const jellyfinImageTypes = ['Primary', 'Backdrop', 'Thumb', 'Logo'];

/// TMDB widths `/img/remote?w=` may rewrite `/t/p/original/` to.
const tmdbRewriteWidths = [185, 342, 500, 780, 1280];

final _absItemId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
final _tmdbFile = RegExp(r'^[A-Za-z0-9_-]+\.(jpg|jpeg|png|webp)$');
final _version = RegExp(r'^[A-Za-z0-9._:-]{1,128}$');

String _withQuery(String path, Map<String, String> query) =>
    query.isEmpty ? path : '$path?${Uri(queryParameters: query).query}';

/// Whether [u] may be fetched as a remote image: https, no credentials, host
/// on the allow-list.
bool isAllowedRemoteImage(Uri u, List<String> allowedHosts) =>
    u.scheme == 'https' &&
    u.userInfo.isEmpty &&
    u.host.isNotEmpty &&
    allowedHosts.contains(u.host.toLowerCase()) &&
    (!u.hasPort || u.port == 443);

/// A validated image request. [path] prints it in canonical form (the form
/// [ImageSpec.parse] accepts and `ImageUrls` builds).
sealed class ImageSpec {
  const ImageSpec();

  /// The canonical gateway path with query, starting with `/api/v1/img/`.
  String get path;

  /// The disk-cache key (normalised path and snapped query; for arr covers
  /// without the version).
  String get cacheKey => path;

  /// The version/tag (`v=` or `tag=`), if any.
  String? get version;

  bool get versioned => version != null;

  /// Counts against the per-user limit for new remote cache entries.
  bool get isRemote => false;

  static String? _optVersion(Map<String, String> q, String key) {
    final v = q[key];
    if (v == null || v.isEmpty) return null;
    if (!_version.hasMatch(v)) throw ApiException.badRequest('invalid $key');
    return v;
  }

  static int? _optSize(Map<String, String> q, String key) {
    final v = q[key];
    if (v == null || v.isEmpty) return null;
    final n = int.tryParse(v);
    if (n == null || n < 1) {
      throw ApiException.badRequest('$key must be a positive integer');
    }
    return snapImageSize(n);
  }

  static int _positive(String? v, String name) {
    final n = v == null ? null : int.tryParse(v);
    if (n == null || n < 1 || '$n' != v) {
      throw ApiException.badRequest('$name must be a positive integer');
    }
    return n;
  }

  static String _enum(String? v, List<String> allowed, String name) {
    if (v == null || !allowed.contains(v)) {
      throw ApiException.badRequest(
        '$name must be one of ${allowed.join(', ')}',
      );
    }
    return v;
  }

  /// Parses the route [kind] (`arr`, `remote`, `tmdb`, `jellyfin`,
  /// `jellyfin-user`, `abs`, `kavita`, `seerr-avatar`) with its path
  /// [params] and [query]. Throws `400 bad_request` for any parameter that
  /// fails validation.
  static ImageSpec parse(
    String kind,
    Map<String, String> params,
    Map<String, String> query, {
    required List<String> remoteHosts,
  }) {
    switch (kind) {
      case 'arr':
        final svc = ArrService.fromJson(params['svc']);
        if (svc == ArrService.unknown) {
          throw ApiException.badRequest('svc must be sonarr or radarr');
        }
        final id = _positive(params['id'], 'id');
        final coverType = _enum(
          params['coverType'],
          arrCoverTypes,
          'coverType',
        );
        final size = query['size'] == null || query['size']!.isEmpty
            ? '500'
            : _enum(query['size'], arrSizes, 'size');
        Uri? fallback;
        final fb = query['fallback'];
        if (fb != null && fb.isNotEmpty) {
          final u = Uri.tryParse(fb);
          if (u == null || !isAllowedRemoteImage(u, remoteHosts)) {
            throw ApiException.badRequest(
              'fallback is not an allowed image URL',
            );
          }
          fallback = u;
        }
        return ArrImageSpec(
          svc,
          id,
          coverType,
          coverType == 'clearlogo' ? 'full' : size,
          _optVersion(query, 'v'),
          fallback,
        );
      case 'remote':
        final raw = query['u'];
        final u = raw == null ? null : Uri.tryParse(raw);
        if (u == null || !isAllowedRemoteImage(u, remoteHosts)) {
          throw ApiException.badRequest('u is not an allowed image URL');
        }
        return RemoteImageSpec(u, _optSize(query, 'w'));
      case 'tmdb':
        final size = _enum(params['size'], tmdbSizes, 'size');
        final file = params['file'];
        if (file == null || !_tmdbFile.hasMatch(file)) {
          throw ApiException.badRequest('invalid TMDB file');
        }
        return TmdbImageSpec(size, file);
      case 'jellyfin':
        final itemId = normaliseJellyfinId(params['itemId']);
        if (itemId == null) {
          throw ApiException.badRequest('itemId must be a Jellyfin id');
        }
        final type = _enum(
          params['imageType'],
          jellyfinImageTypes,
          'imageType',
        );
        int? index;
        final rawIndex = query['index'];
        if (rawIndex != null && rawIndex.isNotEmpty) {
          index = int.tryParse(rawIndex);
          if (index == null || index < 0 || index > 20) {
            throw ApiException.badRequest('index must be 0..20');
          }
        }
        int? quality;
        final rawQuality = query['quality'];
        if (rawQuality != null && rawQuality.isNotEmpty) {
          final q = int.tryParse(rawQuality);
          if (q == null) {
            throw ApiException.badRequest('quality must be an integer');
          }
          quality = q.clamp(60, 90);
        }
        return JellyfinImageSpec(
          itemId,
          type,
          tag: _optVersion(query, 'tag'),
          fillHeight: _optSize(query, 'fillHeight'),
          fillWidth: _optSize(query, 'fillWidth'),
          maxWidth: _optSize(query, 'maxWidth'),
          index: index,
          quality: quality,
        );
      case 'jellyfin-user':
        final userId = normaliseJellyfinId(params['userId']);
        if (userId == null) {
          throw ApiException.badRequest('userId must be a Jellyfin id');
        }
        return JellyfinUserImageSpec(userId, _optVersion(query, 'tag'));
      case 'abs':
        final itemId = params['itemId'];
        if (itemId == null || !_absItemId.hasMatch(itemId)) {
          throw ApiException.badRequest('invalid itemId');
        }
        return AbsImageSpec(
          itemId,
          _optSize(query, 'w') ?? snapImageSize(400),
          _optVersion(query, 'v'),
        );
      case 'kavita':
        return KavitaImageSpec(
          _positive(params['seriesId'], 'seriesId'),
          _optVersion(query, 'v'),
        );
      case 'seerr-avatar':
        return SeerrAvatarImageSpec(
          _positive(params['seerrUserId'], 'seerrUserId'),
          _optVersion(query, 'v'),
        );
    }
    throw ArgumentError.value(kind, 'kind');
  }
}

/// `/img/arr/{svc}/{id}/{coverType}?size=&v=&fallback=`.
final class ArrImageSpec extends ImageSpec {
  const ArrImageSpec(
    this.service,
    this.id,
    this.coverType,
    this.size,
    this.version,
    this.fallback,
  );

  final ArrService service;
  final int id;
  final String coverType;

  /// `250`, `500` or `full`.
  final String size;
  @override
  final String? version;
  final Uri? fallback;

  String get _base => '$imagePathPrefix/arr/${service.name}/$id/$coverType';

  @override
  String get path => _withQuery(_base, {
    'size': size,
    'v': ?version,
    if (fallback != null) 'fallback': fallback.toString(),
  });

  /// `(svc, id, coverType, size)` only: a newer `v` replaces the entry.
  @override
  String get cacheKey => '$_base?size=$size';

  /// The MediaCover file name: `poster-250.jpg`, `fanart-360.jpg`,
  /// `banner-70.jpg`, `clearlogo.png`, `poster.jpg` (full).
  String get upstreamFile {
    if (coverType == 'clearlogo') return 'clearlogo.png';
    if (size == 'full') return '$coverType.jpg';
    final variant = switch (coverType) {
      'fanart' => size == '250' ? 180 : 360,
      'banner' => size == '250' ? 35 : 70,
      _ => int.parse(size),
    };
    return '$coverType-$variant.jpg';
  }

  @override
  bool operator ==(Object other) => other is ArrImageSpec && other.path == path;
  @override
  int get hashCode => path.hashCode;
}

/// `/img/remote?u=&w=`.
final class RemoteImageSpec extends ImageSpec {
  const RemoteImageSpec(this.url, this.width);

  final Uri url;

  /// Snapped width hint.
  final int? width;

  @override
  String? get version => null;

  @override
  bool get isRemote => true;

  @override
  String get path => _withQuery('$imagePathPrefix/remote', {
    'u': url.toString(),
    if (width != null) 'w': '$width',
  });

  /// The URL to fetch: for `image.tmdb.org` a width hint rewrites
  /// `/t/p/original/` to the closest TMDB width.
  Uri get upstreamUrl {
    final w = width;
    if (w == null || url.host.toLowerCase() != 'image.tmdb.org') return url;
    final s = url.path;
    if (!s.startsWith('/t/p/original/')) return url;
    final tw = tmdbRewriteWidths.firstWhere(
      (x) => x >= w,
      orElse: () => tmdbRewriteWidths.last,
    );
    return url.replace(
      path: '/t/p/w$tw/${s.substring('/t/p/original/'.length)}',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteImageSpec && other.path == path;
  @override
  int get hashCode => path.hashCode;
}

/// `/img/tmdb/{size}/{file}`.
final class TmdbImageSpec extends ImageSpec {
  const TmdbImageSpec(this.size, this.file);

  final String size;
  final String file;

  @override
  String? get version => null;

  /// TMDB paths are content-addressed: treat them as versioned.
  @override
  bool get versioned => true;

  @override
  bool get isRemote => true;

  @override
  String get path => '$imagePathPrefix/tmdb/$size/$file';

  Uri get upstreamUrl => Uri(
    scheme: 'https',
    host: 'image.tmdb.org',
    pathSegments: ['t', 'p', size, file],
  );

  @override
  bool operator ==(Object other) =>
      other is TmdbImageSpec && other.path == path;
  @override
  int get hashCode => path.hashCode;
}

/// `/img/jellyfin/{itemId}/{imageType}`.
final class JellyfinImageSpec extends ImageSpec {
  const JellyfinImageSpec(
    this.itemId,
    this.imageType, {
    this.tag,
    this.fillHeight,
    this.fillWidth,
    this.maxWidth,
    this.index,
    this.quality,
  });

  final String itemId;
  final String imageType;
  final String? tag;
  final int? fillHeight;
  final int? fillWidth;
  final int? maxWidth;
  final int? index;
  final int? quality;

  @override
  String? get version => tag;

  Map<String, String> get _query => {
    'tag': ?tag,
    if (fillHeight != null) 'fillHeight': '$fillHeight',
    if (fillWidth != null) 'fillWidth': '$fillWidth',
    if (maxWidth != null) 'maxWidth': '$maxWidth',
    if (index != null) 'index': '$index',
    if (quality != null) 'quality': '$quality',
  };

  @override
  String get path =>
      _withQuery('$imagePathPrefix/jellyfin/$itemId/$imageType', _query);

  /// Upstream path segments and query.
  ({List<String> segments, Map<String, String> query}) get upstream => (
    segments: [
      'Items',
      itemId,
      'Images',
      imageType,
      if (index != null) '$index',
    ],
    query: {
      'tag': ?tag,
      if (fillHeight != null) 'fillHeight': '$fillHeight',
      if (fillWidth != null) 'fillWidth': '$fillWidth',
      if (maxWidth != null) 'maxWidth': '$maxWidth',
      'quality': '${quality ?? 90}',
    },
  );

  @override
  bool operator ==(Object other) =>
      other is JellyfinImageSpec && other.path == path;
  @override
  int get hashCode => path.hashCode;
}

/// `/img/jellyfin-user/{userId}?tag=`.
final class JellyfinUserImageSpec extends ImageSpec {
  const JellyfinUserImageSpec(this.userId, this.tag);

  final String userId;
  final String? tag;

  @override
  String? get version => tag;

  @override
  String get path =>
      _withQuery('$imagePathPrefix/jellyfin-user/$userId', {'tag': ?tag});

  @override
  bool operator ==(Object other) =>
      other is JellyfinUserImageSpec && other.path == path;
  @override
  int get hashCode => path.hashCode;
}

/// `/img/abs/{itemId}?w=&v=`.
final class AbsImageSpec extends ImageSpec {
  const AbsImageSpec(this.itemId, this.width, this.version);

  final String itemId;
  final int width;
  @override
  final String? version;

  @override
  String get path => _withQuery('$imagePathPrefix/abs/$itemId', {
    'w': '$width',
    'v': ?version,
  });

  @override
  bool operator ==(Object other) => other is AbsImageSpec && other.path == path;
  @override
  int get hashCode => path.hashCode;
}

/// `/img/kavita/series/{seriesId}?v=`.
final class KavitaImageSpec extends ImageSpec {
  const KavitaImageSpec(this.seriesId, this.version);

  final int seriesId;
  @override
  final String? version;

  @override
  String get path =>
      _withQuery('$imagePathPrefix/kavita/series/$seriesId', {'v': ?version});

  @override
  bool operator ==(Object other) =>
      other is KavitaImageSpec && other.path == path;
  @override
  int get hashCode => path.hashCode;
}

/// `/img/seerr-avatar/{seerrUserId}?v=`.
final class SeerrAvatarImageSpec extends ImageSpec {
  const SeerrAvatarImageSpec(this.seerrUserId, this.version);

  final int seerrUserId;
  @override
  final String? version;

  @override
  String get path =>
      _withQuery('$imagePathPrefix/seerr-avatar/$seerrUserId', {'v': ?version});

  @override
  bool operator ==(Object other) =>
      other is SeerrAvatarImageSpec && other.path == path;
  @override
  int get hashCode => path.hashCode;
}
