/// Polls a gateway job until it finishes (ARCHITECTURE §5.9, §7.2).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_models/yams_models.dart';

import '../api/core_api.dart';

/// Poll interval for `GET /jobs/{id}` (APP.md §2.3; not scaled by the preset).
const Duration jobPollInterval = Duration(seconds: 2);

/// `GET /jobs/{id}` every 2 s until `status` is `succeeded` or `failed`.
final jobProvider = FutureProvider.autoDispose.family<Job, String>((ref, id) async {
  final job = await ref.watch(coreApiProvider).job(id);
  if (!job.status.isFinished) {
    final timer = Timer(jobPollInterval, () {
      if (ref.mounted) ref.invalidateSelf();
    });
    ref.onDispose(timer.cancel);
  }
  return job;
});
