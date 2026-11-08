/// Small building blocks shared by the indexers screens.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

/// "21:06" today, else "Nov 9, 2026 21:06" (device local time).
String formatRetryTime(DateTime instant, {DateTime? now}) {
  final local = instant.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final sameDay =
      local.year == today.year &&
      local.month == today.month &&
      local.day == today.day;
  return sameDay ? formatTime(instant) : formatDateTime(instant);
}

/// OK / Failing until 19:06 / Disabled.
class IndexerStatusChip extends StatelessWidget {
  const IndexerStatusChip({
    super.key,
    required this.indexer,
    this.dense = true,
  });

  final Indexer indexer;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final till = indexer.disabledTill;
    return switch (indexer.status) {
      IndexerStatus.ok => StatusChip(
        label: 'OK',
        tone: StatusTone.ok,
        dense: dense,
      ),
      IndexerStatus.failing => StatusChip(
        label: till == null
            ? 'Failing'
            : 'Failing until ${formatRetryTime(till)}',
        tone: StatusTone.error,
        icon: Icons.error_outline,
        dense: dense,
      ),
      IndexerStatus.disabled => StatusChip(
        label: 'Disabled',
        tone: StatusTone.neutral,
        dense: dense,
      ),
      IndexerStatus.unknown => StatusChip(label: 'Unknown', dense: dense),
    };
  }
}

/// "Public" / "Semi-private" / "Private".
String privacyLabel(String privacy) => switch (privacy) {
  'public' => 'Public',
  'semiPrivate' => 'Semi-private',
  'private' => 'Private',
  _ => privacy,
};

/// "Torrent" / "Usenet".
String protocolLabel(String protocol) => switch (protocol) {
  'torrent' => 'Torrent',
  'usenet' => 'Usenet',
  _ => protocol,
};

/// A compact outlined label (protocol, privacy, categories).
class IndexerLabel extends StatelessWidget {
  const IndexerLabel(this.label, {super.key, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The FlareSolverr marker.
class FlareSolverrIcon extends StatelessWidget {
  const FlareSolverrIcon({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Routed through FlareSolverr',
    child: Icon(
      Icons.shield_outlined,
      size: size,
      color: StatusColors.of(context).info,
    ),
  );
}

/// "605 queries · 8 grabs · 0.4 % failed · 501 ms" (30 days).
String statsLine(IndexerStats? s) {
  if (s == null) return 'No activity in the last 30 days';
  final failed = s.failureRate * 100;
  final pct = failed == 0
      ? '0'
      : (failed < 0.1 ? '<0.1' : failed.toStringAsFixed(1));
  return '${formatCount(s.totalQueries)} queries · ${formatCount(s.grabs)} grabs · $pct % failed · '
      '${formatCount(s.avgResponseMs)} ms';
}

/// Prowlarr health messages (warnings and errors), shown above the list.
class IndexerHealthBanner extends StatelessWidget {
  const IndexerHealthBanner({super.key, required this.health});

  final List<HealthMessage> health;

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final h in health)
        if (h.type != HealthMessageType.ok) h,
    ];
    if (shown.isEmpty) return const SizedBox.shrink();
    final colors = StatusColors.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        children: [
          for (final h in shown)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              color: _tone(colors, h.type).withValues(alpha: 0.12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      h.type == HealthMessageType.error
                          ? Icons.error_outline
                          : Icons.warning_amber_rounded,
                      color: _tone(colors, h.type),
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(h.message, style: theme.textTheme.bodyMedium),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  static Color _tone(StatusColors c, HealthMessageType t) => switch (t) {
    HealthMessageType.error => c.error,
    HealthMessageType.warning => c.warning,
    _ => c.info,
  };
}

/// Asks for a priority 1–50 (lower = preferred). Null when cancelled.
Future<int?> showPriorityDialog(
  BuildContext context, {
  int? initial,
  int count = 1,
}) => showDialog<int>(
  context: context,
  builder: (_) => _PriorityDialog(initial: initial, count: count),
);

class _PriorityDialog extends StatefulWidget {
  const _PriorityDialog({this.initial, required this.count});

  final int? initial;
  final int count;

  @override
  State<_PriorityDialog> createState() => _PriorityDialogState();
}

class _PriorityDialogState extends State<_PriorityDialog> {
  late final _controller = TextEditingController(
    text: widget.initial?.toString() ?? '25',
  );

  int? get _value {
    final v = int.tryParse(_controller.text.trim());
    return v != null && v >= 1 && v <= 50 ? v : null;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _value;
    if (v != null) Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    final valid = _value != null;
    return AlertDialog(
      title: Text(
        widget.count == 1
            ? 'Set priority'
            : 'Set priority of ${widget.count} indexers',
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(2),
        ],
        decoration: InputDecoration(
          labelText: 'Priority (1–50)',
          helperText: 'Lower numbers are preferred. Default 25.',
          errorText: valid || _controller.text.isEmpty
              ? null
              : 'Enter a number from 1 to 50',
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: valid ? _submit : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// The results of a test job: one row per indexer with ✓/✗ and messages.
Future<void> showTestResultsSheet(
  BuildContext context, {
  required List<IndexerTestResult> results,
  required Map<int, String> names,
  String title = 'Test results',
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (context) =>
      _TestResultsSheet(results: results, names: names, title: title),
);

class _TestResultsSheet extends StatelessWidget {
  const _TestResultsSheet({
    required this.results,
    required this.names,
    required this.title,
  });

  final List<IndexerTestResult> results;
  final Map<int, String> names;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final sorted = [...results]
      ..sort((a, b) {
        if (a.valid != b.valid) return a.valid ? 1 : -1;
        return (names[a.id] ?? '').toLowerCase().compareTo(
          (names[b.id] ?? '').toLowerCase(),
        );
      });
    final passed = results.where((r) => r.valid).length;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
            child: Text(title, style: theme.textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              results.isEmpty
                  ? 'No indexers were tested.'
                  : '$passed of ${results.length} passed',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final r in sorted)
            ListTile(
              leading: Icon(
                r.valid ? Icons.check_circle : Icons.cancel,
                color: r.valid ? colors.ok : colors.error,
                semanticLabel: r.valid ? 'Passed' : 'Failed',
              ),
              title: Text(names[r.id] ?? 'Indexer #${r.id}'),
              subtitle: r.failures.isEmpty ? null : Text(r.failures.join('\n')),
            ),
        ],
      ),
    );
  }
}
