import 'package:flutter/material.dart';

/// A grey rounded placeholder box for first-load skeletons (APP.md §2.1).
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({super.key, this.width, this.height = 16, this.radius = 8});

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// A list-shaped skeleton: [count] rows of a leading box and two text lines.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.count = 6, this.leadingSize = 40, this.padding = const EdgeInsets.all(16)});

  final int count;
  final double leadingSize;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: padding,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: count,
      separatorBuilder: (_, _) => const SizedBox(height: 16),
      itemBuilder: (_, _) => Row(
        children: [
          SkeletonBox(width: leadingSize, height: leadingSize),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(height: 14),
                SizedBox(height: 8),
                FractionallySizedBox(widthFactor: 0.6, child: SkeletonBox(height: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A grid of poster-shaped (2:3) skeleton boxes.
class SkeletonPosterGrid extends StatelessWidget {
  const SkeletonPosterGrid({super.key, this.count = 12, this.maxTileWidth = 140});

  final int count;
  final double maxTileWidth;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: maxTileWidth,
        childAspectRatio: 2 / 3,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
      ),
      itemCount: count,
      itemBuilder: (_, _) => const SkeletonBox(radius: 12),
    );
  }
}
