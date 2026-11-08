import 'package:flutter/material.dart';

import 'formatters.dart';

enum SpeedDirection { down, up }

/// `↓ 12.3 MB/s` / `↑ 1.2 MB/s`.
class SpeedText extends StatelessWidget {
  const SpeedText({super.key, required this.bps, required this.direction, this.style});

  final int? bps;
  final SpeedDirection direction;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final arrow = direction == SpeedDirection.down ? Icons.arrow_downward : Icons.arrow_upward;
    final effective = style ?? Theme.of(context).textTheme.bodyMedium;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(arrow, size: (effective?.fontSize ?? 14) * 1.1, color: effective?.color),
        const SizedBox(width: 2),
        Text(formatBps(bps), style: effective),
      ],
    );
  }
}
