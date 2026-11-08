import 'package:cached_network_image/cached_network_image.dart';
import 'package:cached_network_image_platform_interface/cached_network_image_platform_interface.dart';
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
String? hubImageUrl(String? path, ServerConnection connection) {
  final base = connection.baseUrl;
  if (path == null || path.isEmpty || base == null) return null;
  if (path.startsWith('//') || _hasScheme.hasMatch(path)) return null;
  var p = path.startsWith('/') ? path : '/$path';
  if (connection.transport == ApiTransport.cookie && p.startsWith('/api/v1/')) {
    p = '/yh$p';
  }
  final root = base.toString();
  return '${root.endsWith('/') ? root.substring(0, root.length - 1) : root}$p';
}

final RegExp _hasScheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:');

/// An image served by the gateway's image proxy.
///
/// `cacheKey` is the gateway-relative path, so LAN and Tailscale share one
/// cache. Bearer transport sends the access token; on web the image is
/// fetched with an HTTP GET so cookies are sent.
class HubImage extends ConsumerWidget {
  const HubImage(
    this.path, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholderIcon = Icons.image_outlined,
    this.borderRadius,
  });

  /// Gateway-relative image path from a DTO; null shows the placeholder.
  final String? path;
  final double? width;
  final double? height;
  final BoxFit fit;
  final IconData placeholderIcon;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(activeServerProvider);
    final url = hubImageUrl(path, connection);
    Widget box(IconData icon) => _ImageBox(icon: icon, width: width, height: height);

    Widget child;
    if (url == null) {
      child = box(placeholderIcon);
    } else {
      final token = connection.transport == ApiTransport.bearer ? ref.watch(accessTokenProvider) : null;
      final dpr = MediaQuery.devicePixelRatioOf(context);
      child = CachedNetworkImage(
        imageUrl: url,
        cacheKey: path,
        httpHeaders: token == null ? null : {'Authorization': 'Bearer $token'},
        imageRenderMethodForWeb: ImageRenderMethodForWeb.HttpGet,
        width: width,
        height: height,
        fit: fit,
        memCacheHeight: height == null || !height!.isFinite ? null : (height! * dpr).round(),
        fadeInDuration: const Duration(milliseconds: 150),
        fadeOutDuration: Duration.zero,
        placeholder: (_, _) => box(placeholderIcon),
        errorWidget: (_, _, _) => box(Icons.broken_image_outlined),
      );
    }
    return borderRadius == null ? child : ClipRRect(borderRadius: borderRadius!, child: child);
  }
}

class _ImageBox extends StatelessWidget {
  const _ImageBox({required this.icon, this.width, this.height});

  final IconData icon;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(icon, color: scheme.onSurfaceVariant),
    );
  }
}
