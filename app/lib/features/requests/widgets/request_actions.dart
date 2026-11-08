/// Approve / decline / retry / delete with the confirmations of APP.md §2.4.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/requests_api.dart';
import '../providers/requests_providers.dart';
import 'request_ui.dart';

enum RequestAction {
  approve('Approve', Icons.check),
  decline('Decline', Icons.close),
  retry('Retry', Icons.refresh),
  delete('Delete', Icons.delete_outline);

  const RequestAction(this.label, this.icon);

  final String label;
  final IconData icon;

  /// Whether [r] offers this action to the caller.
  bool allowedFor(RequestSummary r) => switch (this) {
    approve => r.canApprove,
    decline => r.canDecline,
    retry => r.canRetry,
    delete => r.canDelete,
  };
}

/// Asks for confirmation where APP.md §2.4 wants one (decline, delete).
Future<bool> confirmRequestAction(BuildContext context, RequestSummary r, RequestAction action) async {
  switch (action) {
    case RequestAction.decline:
      return ConfirmDialog.show(
        context,
        title: 'Decline request?',
        message: '${r.title} requested by ${r.requestedBy.displayName} will be marked as declined.',
        confirmLabel: 'Decline',
        destructive: true,
      );
    case RequestAction.delete:
      return ConfirmDialog.show(
        context,
        title: 'Delete this request?',
        message: 'Nothing is removed from the library.',
        confirmLabel: 'Delete',
        destructive: true,
      );
    case RequestAction.approve || RequestAction.retry:
      return true;
  }
}

/// Runs [action] after confirming it; shows the result as a SnackBar and
/// reloads every requests screen. True when it succeeded.
Future<bool> runRequestAction(
  BuildContext context,
  WidgetRef ref,
  RequestSummary r,
  RequestAction action, {
  bool confirmed = false,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (!confirmed && !await confirmRequestAction(context, r, action)) return false;
  final api = ref.read(requestsApiProvider);
  void snack(String text) => messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
  try {
    switch (action) {
      case RequestAction.approve:
        await api.approve(r.id);
        snack('Approved · sent to ${arrName(r.mediaType)}');
      case RequestAction.decline:
        await api.decline(r.id);
        snack('Declined');
      case RequestAction.retry:
        final updated = await api.retry(r.id);
        snack(
          updated.status == RequestStatus.failed ? 'Retry failed again' : 'Retrying · sent to ${arrName(r.mediaType)}',
        );
      case RequestAction.delete:
        await api.delete(r.id);
        snack('Request deleted');
    }
    ref.read(requestsGenerationProvider.notifier).bump();
    return true;
  } catch (e) {
    snack(ApiException.from(e).message);
    // A timed-out write may have run: reload to show the truth.
    if (ApiException.from(e).code == ClientErrorCode.resultUnknown) {
      ref.read(requestsGenerationProvider.notifier).bump();
    }
    return false;
  }
}
