import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cached_network_image_platform_interface/cached_network_image_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/token_manager.dart';
import '../servers/server_connection.dart';

/// The full URL of a gateway image path (`/api/v1/img/...`, ARCHITECTURE
/// §3, §7.8) for [connection]; the prefix becomes `/yh/api/v1/img/` on cookie
/// transport. Null when no server is resolved or [path] is empty.
///
/// Only gateway-relative paths are accepted: an absolute (`https://...`) or
/// protocol-relative (`//host/...`) value is rejected (null), so the bearer
/// token sent with hub images can never reach another host.
String? hubImageUrl(String? path, ServerConnection connection) =>
    hubImageUrlFor(path, connection.baseUrl, connection.transport);

/// [hubImageUrl] from the two connection fields it depends on.
String? hubImageUrlFor(String? path, Uri? base, ApiTransport transport) {
  if (path == null || path.isEmpty || base == null) return null;
  if (path.startsWith('//') || _hasScheme.hasMatch(path)) return null;
  var p = path.startsWith('/') ? path : '/$path';
  if (transport == ApiTransport.cookie && p.startsWith('/api/v1/')) {
    p = '/yh$p';
  }
  final root = base.toString();
  return '${root.endsWith('/') ? root.substring(0, root.length - 1) : root}$p';
}

final RegExp _hasScheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:');

/// Whether [HubImage] takes the web path (a plain [Image.network]). Tests flip
/// it to exercise either branch on the VM.
@visibleForTesting
bool debugHubImageWebPath = kIsWeb;

/// An image served by the gateway's image proxy.
///
/// Bearer transport sends the access token; cookie transport (web, same
/// origin) relies on the browser sending the session cookie.
///
/// On web the image is a plain [NetworkImage] (started after the frame, see
/// [DeferredNetworkImage]): one fetch and one decode at the served size (the gateway already serves small size buckets), cached by
/// Flutter's image cache and then the browser's HTTP cache. cached_network_image
/// 3.x re-decodes from an emptied `<img>` when a resized image scrolls back
/// into view on browsers without WebCodecs (Safari, and any plain-HTTP origin),
/// leaving the tile blank.
///
/// Elsewhere it is a [CachedNetworkImage] whose `cacheKey` is the
/// gateway-relative path, so LAN and Tailscale share one disk cache, decoded at
/// the displayed height (or width) times the device pixel ratio.
///
/// [opacity] dims the image without an [Opacity] layer.
class HubImage extends ConsumerWidget {
  const HubImage(
    this.path, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholderIcon = Icons.image_outlined,
    this.borderRadius,
    this.opacity = 1.0,
  });

  /// Gateway-relative image path from a DTO; null shows the placeholder.
  final String? path;
  final double? width;
  final double? height;
  final BoxFit fit;
  final IconData placeholderIcon;
  final BorderRadius? borderRadius;

  /// 0–1; below 1 the image is drawn translucent.
  final double opacity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(
      activeServerProvider.select(
        (c) => (baseUrl: c.baseUrl, transport: c.transport),
      ),
    );
    final url = hubImageUrlFor(path, conn.baseUrl, conn.transport);
    Widget box(IconData icon) =>
        _ImageBox(icon: icon, width: width, height: height, opacity: opacity);

    Widget child;
    if (url == null) {
      child = box(placeholderIcon);
    } else {
      final token = conn.transport == ApiTransport.bearer
          ? ref.watch(accessTokenProvider)
          : null;
      final headers = token == null ? null : {'Authorization': 'Bearer $token'};
      final dimmed = opacity < 1;
      if (debugHubImageWebPath) {
        child = Image(
          image: DeferredNetworkImage(NetworkImage(url, headers: headers)),
          width: width,
          height: height,
          fit: fit,
          opacity: dimmed ? AlwaysStoppedAnimation(opacity) : null,
          frameBuilder: (_, image, frame, _) =>
              frame == null ? box(placeholderIcon) : image,
          errorBuilder: (_, _, _) => box(Icons.broken_image_outlined),
        );
      } else {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final h = height, w = width;
        final byHeight = h != null && h.isFinite;
        child = CachedNetworkImage(
          imageUrl: url,
          cacheKey: path,
          httpHeaders: headers,
          imageRenderMethodForWeb: ImageRenderMethodForWeb.HttpGet,
          width: width,
          height: height,
          fit: fit,
          memCacheHeight: byHeight ? (h * dpr).round() : null,
          memCacheWidth: !byHeight && w != null && w.isFinite
              ? (w * dpr).round()
              : null,
          color: dimmed ? Colors.white.withValues(alpha: opacity) : null,
          colorBlendMode: dimmed ? BlendMode.modulate : null,
          fadeInDuration: const Duration(milliseconds: 150),
          fadeOutDuration: Duration.zero,
          placeholder: (_, _) => box(placeholderIcon),
          errorWidget: (_, _, _) => box(Icons.broken_image_outlined),
        );
      }
    }
    return borderRadius == null
        ? child
        : ClipRRect(borderRadius: borderRadius!, child: child);
  }
}

class _ImageBox extends StatelessWidget {
  const _ImageBox({
    required this.icon,
    this.width,
    this.height,
    this.opacity = 1,
  });

  final IconData icon;
  final double? width;
  final double? height;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      color: opacity < 1
          ? scheme.surfaceContainerHighest.withValues(alpha: opacity)
          : scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        icon,
        color: opacity < 1
            ? scheme.onSurfaceVariant.withValues(alpha: opacity)
            : scheme.onSurfaceVariant,
      ),
    );
  }
}

/// A [NetworkImage] whose fetch starts in a task after the current one.
///
/// Flutter's web [NetworkImage] opens and sends its XMLHttpRequest
/// synchronously while the image is resolved, i.e. inside the frame that
/// builds the widget; a poster grid or the dashboard then pays a few ms per
/// image in its first frame. Deferring the start by one task keeps that work
/// out of the frame. The cache key is the inner [NetworkImage], so the
/// [ImageCache] entry is the same as for a plain [NetworkImage]; an image that
/// is already cached is shown synchronously as before.
@immutable
class DeferredNetworkImage extends ImageProvider<NetworkImage> {
  const DeferredNetworkImage(this.inner);

  final NetworkImage inner;

  @override
  Future<NetworkImage> obtainKey(ImageConfiguration configuration) =>
      inner.obtainKey(configuration);

  @override
  ImageStreamCompleter loadImage(
    NetworkImage key,
    ImageDecoderCallback decode,
  ) => _DeferredImageStreamCompleter(
    () => key.loadImage(key, decode),
    debugLabel: key.url,
  );

  @override
  bool operator ==(Object other) =>
      other is DeferredNetworkImage && other.inner == inner;

  @override
  int get hashCode => inner.hashCode;

  @override
  String toString() => 'DeferredNetworkImage($inner)';
}

/// Starts [start] in a later task and forwards its frames, chunks and errors.
///
/// The inner completer is kept alive for as long as this one, but it is only
/// listened to while this one has listeners: an animated image (a GIF avatar)
/// that sits in the [ImageCache] off screen stops scheduling frames, as it
/// would with a plain [NetworkImage].
class _DeferredImageStreamCompleter extends ImageStreamCompleter {
  _DeferredImageStreamCompleter(
    ImageStreamCompleter Function() start, {
    String? debugLabel,
  }) {
    this.debugLabel = debugLabel;
    Timer.run(() {
      if (_disposed) return;
      try {
        final inner = start();
        _inner = inner;
        _innerHandle = inner.keepAlive();
        if (hasListeners) _attach();
      } catch (e, st) {
        reportError(exception: e, stack: st, silent: true);
      }
    });
  }

  ImageStreamCompleter? _inner;
  ImageStreamCompleterHandle? _innerHandle;
  bool _attached = false;
  bool _disposed = false;

  late final ImageStreamListener _listener = ImageStreamListener(
    (image, _) => setImage(image),
    onChunk: reportImageChunkEvent,
    onError: (e, st) => reportError(exception: e, stack: st),
  );

  void _attach() {
    final inner = _inner;
    if (inner == null || _attached || _disposed) return;
    _attached = true;
    inner.addListener(_listener);
  }

  void _detach() {
    if (!_attached) return;
    _attached = false;
    _inner?.removeListener(_listener);
  }

  @override
  void addListener(ImageStreamListener listener) {
    super.addListener(listener);
    _attach();
  }

  @override
  void removeListener(ImageStreamListener listener) {
    super.removeListener(listener);
    if (!hasListeners) _detach();
  }

  @override
  void onDisposed() {
    _disposed = true;
    _detach();
    _innerHandle?.dispose();
    _innerHandle = null;
    super.onDisposed();
  }
}
