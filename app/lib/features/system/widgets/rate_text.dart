/// Download/upload rates with arrow icons (the bundled Roboto has no arrow
/// glyphs, so `↓`/`↑` would render as boxes on web).
library;

import 'package:flutter/material.dart';
import 'package:yams_hub/core/widgets/formatters.dart';

class RateText extends StatelessWidget {
  const RateText({super.key, this.rxBps, this.txBps, this.style});

  /// Shown with a down arrow when set.
  final int? rxBps;

  /// Shown with an up arrow when set.
  final int? txBps;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final s = style ?? DefaultTextStyle.of(context).style;
    final size = (s.fontSize ?? 14) + 1;
    final color = s.color ?? Theme.of(context).colorScheme.onSurface;
    Widget part(IconData icon, String label, int bps) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: size, color: color, semanticLabel: label),
        Text(formatBps(bps), style: s),
      ],
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (rxBps case final rx?) part(Icons.arrow_downward, 'Download', rx),
        if (rxBps != null && txBps != null) const SizedBox(width: 8),
        if (txBps case final tx?) part(Icons.arrow_upward, 'Upload', tx),
      ],
    );
  }
}
