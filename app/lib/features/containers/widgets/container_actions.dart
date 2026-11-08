/// Container actions with their confirmations (APP.md §2.4, §9.1, §9.2).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/jobs/job_provider.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/containers_api.dart';
import '../providers/containers_providers.dart';
import 'job_progress_sheet.dart';

String containerActionLabel(ContainerAction a) => switch (a) {
  ContainerAction.restart => 'Restart',
  ContainerAction.stop => 'Stop',
  ContainerAction.start => 'Start',
  ContainerAction.unknown => 'Run',
};

/// The confirmation the user sees before [action], or null when none is
/// needed (gateway rule: every stop, and every action on confirm-list
/// containers).
({String title, String message})? containerActionConfirmation(ContainerSummary c, ContainerAction action) {
  final name = c.name;
  final gluetun = name == 'gluetun';
  if (action == ContainerAction.stop) {
    return (
      title: 'Stop $name?',
      message: gluetun
          ? 'qBittorrent will lose network until gluetun is back.'
          : '$name stays stopped until you start it again.',
    );
  }
  if (c.protection != ContainerProtection.confirm) return null;
  return (
    title: '${containerActionLabel(action)} $name?',
    message: gluetun
        ? 'qBittorrent is restarted automatically once gluetun is healthy again.'
        : '$name will be offline for a moment.',
  );
}

/// Asks for confirmation when needed, starts [action] on [c] and follows the
/// job (its chip appears where [containerJobsProvider] is watched). Returns
/// the job, or null when cancelled or refused.
Future<Job?> runContainerAction(BuildContext context, WidgetRef ref, ContainerSummary c, ContainerAction action) async {
  final ask = containerActionConfirmation(c, action);
  var confirmed = false;
  if (ask != null) {
    confirmed = await ConfirmDialog.show(
      context,
      title: ask.title,
      message: ask.message,
      confirmLabel: containerActionLabel(action),
      destructive: action == ContainerAction.stop,
    );
    if (!confirmed || !context.mounted) return null;
  }
  final api = ref.read(containersApiProvider);
  try {
    Job job;
    try {
      job = await api.action(c.name, action, confirm: confirmed);
    } on ApiException catch (e) {
      // The gateway's policy may ask for confirmation the app did not expect.
      if (e.code != ApiErrorCode.confirmationRequired || !context.mounted) rethrow;
      final impact = readString(e.details?['impact']) ?? '${containerActionLabel(action)} ${c.name}?';
      final ok = await ConfirmDialog.show(
        context,
        title: '${containerActionLabel(action)} ${c.name}?',
        message: impact,
        confirmLabel: containerActionLabel(action),
        destructive: action == ContainerAction.stop,
      );
      if (!ok) return null;
      job = await api.action(c.name, action, confirm: true);
    }
    ref.read(containerJobsProvider.notifier).track(ContainerJobKeys.action(c.name), job.id);
    return job;
  } catch (e) {
    if (context.mounted) context.showError(e);
    return null;
  }
}

/// Confirms and starts an image update of [name], then opens the job sheet.
Future<Job?> runContainerUpdate(BuildContext context, WidgetRef ref, String name) async {
  final ok = await ConfirmDialog.show(
    context,
    title: 'Update $name?',
    message: 'Pull the latest image and recreate $name? It will be offline for a moment.',
    confirmLabel: 'Update',
  );
  if (!ok || !context.mounted) return null;
  try {
    final job = await ref.read(containersApiProvider).update(name);
    ref.read(containerJobsProvider.notifier).track(ContainerJobKeys.update(name), job.id);
    if (context.mounted) unawaitedSheet(JobProgressSheet.show(context, jobId: job.id, title: 'Update $name'));
    return job;
  } catch (e) {
    if (context.mounted) context.showError(e);
    return null;
  }
}

/// Fire-and-forget for sheets (the job keeps running when it is closed).
void unawaitedSheet(Future<void> sheet) {
  sheet.ignore();
}

/// Consecutive failed job polls before the chip gives up on a job.
const containerJobMaxPollFailures = 3;

/// The chip of a job followed under [jobKey], or nothing. When the job
/// finishes, [onDone] runs (refresh the screen) and the key is released.
///
/// The core job provider stops polling after an error, so a network blip
/// (LAN/Tailscale switch) or an expired job (404) would otherwise keep the
/// key, and with it the disabled action buttons, forever. Failed polls are
/// retried a few times; then the key is released with "refresh to check".
class ContainerJobChip extends ConsumerStatefulWidget {
  const ContainerJobChip({super.key, required this.jobKey, this.onDone});

  final String jobKey;
  final VoidCallback? onDone;

  @override
  ConsumerState<ContainerJobChip> createState() => _ContainerJobChipState();
}

class _ContainerJobChipState extends ConsumerState<ContainerJobChip> {
  Timer? _retry;
  int _failures = 0;
  String? _following;

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  void _release(String id, {String? message}) {
    _retry?.cancel();
    ref.read(containerJobsProvider.notifier).done(widget.jobKey, id);
    if (message != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
    }
    widget.onDone?.call();
  }

  void _onPoll(String id, AsyncValue<Job> next) {
    if (next.isLoading) return;
    if (!next.hasError) {
      _failures = 0;
      return;
    }
    final e = ApiException.from(next.error!);
    if (e.status == 404 || e.code == ApiErrorCode.notFound || ++_failures >= containerJobMaxPollFailures) {
      _release(id, message: 'Lost track of the job. Refresh to check the result.');
      return;
    }
    _retry?.cancel();
    _retry = Timer(jobPollInterval, () {
      if (mounted) ref.invalidate(jobProvider(id));
    });
  }

  @override
  Widget build(BuildContext context) {
    final id = ref.watch(containerJobsProvider.select((m) => m[widget.jobKey]));
    if (id != _following) {
      _following = id;
      _failures = 0;
      _retry?.cancel();
    }
    if (id == null) return const SizedBox.shrink();
    ref.listen<AsyncValue<Job>>(jobProvider(id), (_, next) => _onPoll(id, next));
    return JobChip(
      id,
      key: ValueKey(id),
      onDone: (_) {
        _retry?.cancel();
        ref.read(containerJobsProvider.notifier).done(widget.jobKey, id);
        widget.onDone?.call();
      },
    );
  }
}
