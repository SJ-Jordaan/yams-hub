import 'package:flutter/material.dart';

import 'hub_image.dart';

/// A 2:3 poster with a title and an optional subtitle and badge.
class PosterTile extends StatelessWidget {
  const PosterTile({
    super.key,
    required this.imagePath,
    required this.title,
    this.subtitle,
    this.badge,
    this.onTap,
    this.onLongPress,
    this.placeholderIcon = Icons.movie_outlined,
  });

  final String? imagePath;
  final String title;
  final String? subtitle;

  /// Overlaid at the top-right corner (e.g. a status chip).
  final Widget? badge;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final IconData placeholderIcon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: Stack(
              fit: StackFit.expand,
              children: [
                LayoutBuilder(
                  builder: (context, c) => HubImage(
                    imagePath,
                    width: c.maxWidth,
                    height: c.maxHeight,
                    placeholderIcon: placeholderIcon,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                if (badge != null) Positioned(top: 6, right: 6, child: badge!),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
          if (subtitle != null)
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}
