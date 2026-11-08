/// Builds every image path features put in DTOs (ARCHITECTURE §5.8).
/// Features never hand-build `/img` paths.
library;

import 'package:yams_models/yams_models.dart';

import '../../config/config.dart';
import 'image_spec.dart';

final _version = RegExp(r'^[A-Za-z0-9._:-]{1,128}$');
final _absItemId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
final _tmdbFile = RegExp(r'^[A-Za-z0-9_-]+\.(jpg|jpeg|png|webp)$');

String? _v(String? version) =>
    (version == null || version.isEmpty || !_version.hasMatch(version))
    ? null
    : version;

/// Gateway-relative image paths. Every builder returns null for null or
/// invalid required input, URL-encodes `fallback`/`u`, snaps sizes to the
/// bucket set, and its output round-trips through [ImageSpec.parse].
final class ImageUrls {
  ImageUrls(this._remoteHosts);

  /// Uses the allow-list of [config].
  factory ImageUrls.fromConfig(HubConfig config) =>
      ImageUrls(config.remoteImageHosts);

  final List<String> _remoteHosts;

  /// A Sonarr/Radarr cover. [size] ≤ 250 → `250`, ≤ 500 → `500`, larger →
  /// `full` (clearlogo is always full). [version] is the `lastWrite`/`h`
  /// value of the *arr image URL; [fallbackUrl] (the item's `remoteUrl`) is
  /// used when the cover 404s and is dropped unless it is on the allow-list.
  String? arr(
    ArrService svc,
    int id,
    String coverType, {
    int size = 500,
    String? version,
    String? fallbackUrl,
  }) {
    if (svc == ArrService.unknown ||
        id < 1 ||
        !arrCoverTypes.contains(coverType)) {
      return null;
    }
    final s = coverType == 'clearlogo'
        ? 'full'
        : size <= 250
        ? '250'
        : size <= 500
        ? '500'
        : 'full';
    Uri? fallback;
    if (fallbackUrl != null) {
      final u = Uri.tryParse(fallbackUrl);
      if (u != null && isAllowedRemoteImage(u, _remoteHosts)) fallback = u;
    }
    return ArrImageSpec(svc, id, coverType, s, _v(version), fallback).path;
  }

  /// An internet image on the allow-list (https only); null otherwise.
  String? remote(String? url, {int? width}) {
    if (url == null || url.isEmpty) return null;
    final u = Uri.tryParse(url);
    if (u == null || !isAllowedRemoteImage(u, _remoteHosts)) return null;
    return RemoteImageSpec(
      u,
      width == null || width < 1 ? null : snapImageSize(width),
    ).path;
  }

  /// A TMDB image; [path] with or without the leading `/`.
  String? tmdb(String? path, String size) {
    if (path == null || !tmdbSizes.contains(size)) return null;
    final file = path.startsWith('/') ? path.substring(1) : path;
    if (!_tmdbFile.hasMatch(file)) return null;
    return TmdbImageSpec(size, file).path;
  }

  /// A Jellyfin item image (`Primary`, `Backdrop`, `Thumb`, `Logo`).
  String? jellyfin(
    String? itemId,
    String type, {
    String? tag,
    int? fillHeight,
    int? fillWidth,
    int? maxWidth,
    int? index,
    int? quality,
  }) {
    final id = normaliseJellyfinId(itemId);
    if (id == null || !jellyfinImageTypes.contains(type)) return null;
    if (index != null && (index < 0 || index > 20)) return null;
    int? snap(int? v) => v == null || v < 1 ? null : snapImageSize(v);
    return JellyfinImageSpec(
      id,
      type,
      tag: _v(tag),
      fillHeight: snap(fillHeight),
      fillWidth: snap(fillWidth),
      maxWidth: snap(maxWidth),
      index: index,
      quality: quality?.clamp(60, 90),
    ).path;
  }

  /// A Jellyfin user's avatar.
  String? jellyfinUser(String? userId, {String? tag}) {
    final id = normaliseJellyfinId(userId);
    if (id == null) return null;
    return JellyfinUserImageSpec(id, _v(tag)).path;
  }

  /// An Audiobookshelf cover; [version] = the item's `updatedAt`.
  String? abs(String? itemId, {int width = 400, String? version}) {
    if (itemId == null || !_absItemId.hasMatch(itemId)) return null;
    return AbsImageSpec(
      itemId,
      snapImageSize(width < 1 ? 400 : width),
      _v(version),
    ).path;
  }

  /// A Kavita series cover.
  String? kavitaSeries(int? seriesId, {String? version}) {
    if (seriesId == null || seriesId < 1) return null;
    return KavitaImageSpec(seriesId, _v(version)).path;
  }

  /// A Seerr user's avatar; [version] = the `?v=` of Seerr's avatar path.
  String? seerrAvatar(int? seerrUserId, {String? version}) {
    if (seerrUserId == null || seerrUserId < 1) return null;
    return SeerrAvatarImageSpec(seerrUserId, _v(version)).path;
  }
}
