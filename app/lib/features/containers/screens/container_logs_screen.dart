/// `/containers/:name/logs` (admin): log viewer (APP.md §9.3).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/container_logs_controller.dart';

class ContainerLogsScreen extends ConsumerStatefulWidget {
  const ContainerLogsScreen({super.key, required this.name});

  final String name;

  @override
  ConsumerState<ContainerLogsScreen> createState() => _ContainerLogsScreenState();
}

class _ContainerLogsScreenState extends ConsumerState<ContainerLogsScreen> {
  bool _timestamps = true;
  String _filter = '';

  List<LogLine> _visible(List<LogLine> lines) {
    final f = _filter.toLowerCase();
    if (f.isEmpty) return lines;
    return [
      for (final l in lines)
        if (l.text.toLowerCase().contains(f)) l,
    ];
  }

  String _lineText(LogLine l) => _timestamps && l.at != null ? '${_stamp(l.at!)}  ${l.text}' : l.text;

  static String _stamp(DateTime at) {
    final t = at.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Future<void> _copy(List<LogLine> lines) async {
    await Clipboard.setData(ClipboardData(text: lines.map(_lineText).join('\n')));
    if (mounted) context.showSnack('Copied ${lines.length} lines');
  }

  @override
  Widget build(BuildContext context) {
    final provider = containerLogsProvider(widget.name);
    final s = ref.watch(provider);
    final controller = ref.read(provider.notifier);
    final visible = _visible(s.lines);
    final error = s.error == null ? null : ApiException.from(s.error!);
    final disabled = error?.code == ApiErrorCode.serviceNotConfigured;

    return Scaffold(
      appBar: AppBar(
        title: Text('Logs · ${widget.name}'),
        actions: [
          IconButton(
            tooltip: s.follow ? 'Stop following' : 'Follow',
            isSelected: s.follow,
            icon: const Icon(Icons.play_circle_outline),
            selectedIcon: const Icon(Icons.pause_circle_filled),
            onPressed: disabled ? null : () => controller.setFollow(!s.follow),
          ),
          IconButton(
            tooltip: _timestamps ? 'Hide timestamps' : 'Show timestamps',
            isSelected: _timestamps,
            icon: const Icon(Icons.schedule_outlined),
            selectedIcon: const Icon(Icons.schedule),
            onPressed: () => setState(() => _timestamps = !_timestamps),
          ),
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: visible.isEmpty ? null : () => _copy(visible),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: [for (final t in containerLogTails) ButtonSegment(value: t, label: Text('$t'))],
                  selected: {s.tail},
                  onSelectionChanged: (v) => controller.setTail(v.first),
                ),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'all', label: Text('All')),
                    ButtonSegment(value: 'stdout', label: Text('stdout')),
                    ButtonSegment(value: 'stderr', label: Text('stderr')),
                  ],
                  selected: {s.stream},
                  onSelectionChanged: (v) => controller.setStream(v.first),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SearchField(hint: 'Filter lines', onChanged: (v) => setState(() => _filter = v)),
          ),
          if (s.loading && s.lines.isNotEmpty) const LinearProgressIndicator(minHeight: 2),
          if (error != null && s.lines.isNotEmpty && !disabled)
            StaleBanner(message: "Couldn't refresh · ${error.message}", onRetry: controller.reload),
          Expanded(child: _body(context, s, visible, error, disabled, controller)),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    ContainerLogsState s,
    List<LogLine> visible,
    ApiException? error,
    bool disabled,
    ContainerLogsController controller,
  ) {
    if (disabled) {
      // The gateway explains why (ALLOW_LOGS=1 missing, or Docker not set up).
      final reason = error?.message ?? '';
      return EmptyView(
        icon: Icons.lock_outline,
        title: 'Logs are unavailable',
        message: reason.isEmpty ? 'Logs need ALLOW_LOGS=1 on socket-proxy-hub.' : reason,
      );
    }
    if (s.lines.isEmpty && s.loading) return const SkeletonList(count: 12, leadingSize: 0);
    if (s.lines.isEmpty && error != null) return ErrorView(error: error, onRetry: controller.reload);
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final base = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Courier'],
      height: 1.35,
    );
    return RefreshIndicator(
      onRefresh: controller.reload,
      child: visible.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                EmptyView(
                  icon: Icons.notes,
                  title: s.lines.isEmpty ? 'No log lines' : 'No lines match',
                  message: s.lines.isEmpty
                      ? 'The container has not written anything yet.'
                      : 'Clear the filter to see every line.',
                ),
              ],
            )
          : ListView.builder(
              // Newest at the bottom, scrolled there by default.
              reverse: true,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              itemCount: visible.length + (s.truncated ? 1 : 0),
              itemBuilder: (context, i) {
                if (i == visible.length) {
                  return Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      'Older lines are not shown (tail ${s.tail}).',
                      style: theme.textTheme.labelSmall,
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                final l = visible[visible.length - 1 - i];
                final stderr = l.stream == ContainerLogStream.stderr;
                return Container(
                  decoration: stderr
                      ? BoxDecoration(
                          color: colors.warning.withValues(alpha: 0.08),
                          border: Border(left: BorderSide(color: colors.warning, width: 2)),
                        )
                      : null,
                  padding: const EdgeInsets.symmetric(vertical: 1, horizontal: 4),
                  child: SelectableText(_lineText(l), style: base),
                );
              },
            ),
    );
  }
}
