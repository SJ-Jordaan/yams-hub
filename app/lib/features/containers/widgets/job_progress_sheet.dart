/// A bottom sheet following a job: steps and streaming log lines (APP.md §9.4).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/jobs/job_provider.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

class JobProgressSheet extends ConsumerWidget {
  const JobProgressSheet({super.key, required this.jobId, required this.title});

  final String jobId;
  final String title;

  static Future<void> show(BuildContext context, {required String jobId, required String title}) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (_) => FractionallySizedBox(
          heightFactor: 0.75,
          child: JobProgressSheet(jobId: jobId, title: title),
        ),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final value = ref.watch(jobProvider(jobId));
    final job = value.value;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
              if (job != null) StatusChip.job(job.status),
            ],
          ),
          const SizedBox(height: 12),
          if (job == null && value.hasError)
            ErrorView(error: value.error!, compact: true)
          else if (job == null)
            const LinearProgressIndicator()
          else ...[
            for (final s in job.steps) _StepRow(step: s),
            if (job.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(job.error!.message, style: TextStyle(color: StatusColors.of(context).error)),
              ),
            const SizedBox(height: 12),
            Text('Log', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            Expanded(child: _LogView(lines: job.log)),
          ],
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step});

  final JobStep step;

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    final Widget icon = switch (step.status) {
      JobStatus.succeeded => Icon(Icons.check_circle, size: 18, color: colors.ok),
      JobStatus.failed => Icon(Icons.error, size: 18, color: colors.error),
      JobStatus.running => const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      _ => Icon(Icons.radio_button_unchecked, size: 18, color: colors.neutral),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 24, child: Center(child: icon)),
          const SizedBox(width: 8),
          Expanded(child: Text(step.label)),
        ],
      ),
    );
  }
}

class _LogView extends StatelessWidget {
  const _LogView({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (lines.isEmpty) {
      return Text(
        'No output yet.',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.builder(
        reverse: true,
        padding: const EdgeInsets.all(8),
        itemCount: lines.length,
        itemBuilder: (_, i) => Text(
          lines[lines.length - 1 - i],
          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', fontFamilyFallback: const ['Courier']),
        ),
      ),
    );
  }
}
