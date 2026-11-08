/// Labels, colours and icons for activity states.
library;

import 'package:flutter/material.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_models/yams_models.dart';

String torrentStateLabel(TorrentState s) => switch (s) {
  TorrentState.downloading => 'Downloading',
  TorrentState.seeding => 'Seeding',
  TorrentState.stalled => 'Stalled',
  TorrentState.stopped => 'Stopped',
  TorrentState.queued => 'Queued',
  TorrentState.checking => 'Checking',
  TorrentState.moving => 'Moving',
  TorrentState.error => 'Error',
  TorrentState.metadata => 'Fetching metadata',
  TorrentState.unknown => 'Unknown',
};

StatusTone torrentStateTone(TorrentState s) => switch (s) {
  TorrentState.downloading || TorrentState.metadata => StatusTone.info,
  TorrentState.seeding => StatusTone.ok,
  TorrentState.stalled => StatusTone.warning,
  TorrentState.error => StatusTone.error,
  _ => StatusTone.neutral,
};

IconData torrentStateIcon(TorrentState s) => switch (s) {
  TorrentState.downloading => Icons.arrow_downward,
  TorrentState.metadata => Icons.manage_search,
  TorrentState.seeding => Icons.arrow_upward,
  TorrentState.stalled => Icons.hourglass_empty,
  TorrentState.stopped => Icons.pause_circle_outline,
  TorrentState.queued => Icons.queue,
  TorrentState.checking => Icons.fact_check_outlined,
  TorrentState.moving => Icons.drive_file_move_outline,
  TorrentState.error => Icons.error_outline,
  TorrentState.unknown => Icons.help_outline,
};

String queueStateLabel(QueueItemState s) => switch (s) {
  QueueItemState.importPending => 'Import pending',
  QueueItemState.importBlocked => 'Import blocked',
  QueueItemState.importing => 'Importing',
  QueueItemState.failed => 'Failed',
  QueueItemState.delayed => 'Delayed',
  QueueItemState.completed => 'Completed',
  QueueItemState.downloading => 'Downloading',
  QueueItemState.seeding => 'Seeding',
  QueueItemState.stalled => 'Stalled',
  QueueItemState.stopped => 'Stopped',
  QueueItemState.queued => 'Queued',
  QueueItemState.checking => 'Checking',
  QueueItemState.moving => 'Moving',
  QueueItemState.error => 'Error',
  QueueItemState.metadata => 'Fetching metadata',
  QueueItemState.unknown => 'Unknown',
};

StatusTone queueStateTone(QueueItemState s) => switch (s) {
  QueueItemState.importPending || QueueItemState.importBlocked || QueueItemState.stalled => StatusTone.warning,
  QueueItemState.failed || QueueItemState.error => StatusTone.error,
  QueueItemState.downloading || QueueItemState.metadata || QueueItemState.importing => StatusTone.info,
  QueueItemState.seeding || QueueItemState.completed => StatusTone.ok,
  _ => StatusTone.neutral,
};

/// Colour of an attention item's left border.
StatusTone attentionTone(QueueAttention a) => switch (a) {
  QueueAttention.failed || QueueAttention.error || QueueAttention.trackerError => StatusTone.error,
  _ => StatusTone.warning,
};

String attentionLabel(QueueAttention a) => switch (a) {
  QueueAttention.importBlocked || QueueAttention.importPending => 'Manual import needed',
  QueueAttention.failed => 'Download failed',
  QueueAttention.trackerError => 'Tracker error',
  QueueAttention.error => 'Error',
  QueueAttention.warning => 'Warning',
  QueueAttention.unknown => 'Needs attention',
};

String arrLabel(ArrService s) => switch (s) {
  ArrService.sonarr => 'Sonarr',
  ArrService.radarr => 'Radarr',
  ArrService.unknown => 'the *arr',
};

ExternalApp arrApp(ArrService s) => s == ArrService.radarr ? ExternalApp.radarr : ExternalApp.sonarr;

String trackerStatusLabel(TrackerInfoStatus s) => switch (s) {
  TrackerInfoStatus.disabled => 'Disabled',
  TrackerInfoStatus.notContacted => 'Not contacted',
  TrackerInfoStatus.working => 'Working',
  TrackerInfoStatus.updating => 'Updating',
  TrackerInfoStatus.notWorking => 'Not working',
  TrackerInfoStatus.trackerError => 'Tracker error',
  TrackerInfoStatus.unreachable => 'Unreachable',
  TrackerInfoStatus.unknown => 'Unknown',
};

StatusTone trackerStatusTone(TrackerInfoStatus s) => switch (s) {
  TrackerInfoStatus.working => StatusTone.ok,
  TrackerInfoStatus.updating || TrackerInfoStatus.notContacted => StatusTone.info,
  TrackerInfoStatus.notWorking || TrackerInfoStatus.trackerError || TrackerInfoStatus.unreachable => StatusTone.error,
  _ => StatusTone.neutral,
};

String filePriorityLabel(TorrentFilePriority p) => switch (p) {
  TorrentFilePriority.skip => 'Skip',
  TorrentFilePriority.normal => 'Normal',
  TorrentFilePriority.high => 'High',
  TorrentFilePriority.max => 'Max',
  TorrentFilePriority.unknown => 'Normal',
};

String shareActionLabel(ShareLimitsAction a) => switch (a) {
  ShareLimitsAction.byDefault => 'Default',
  ShareLimitsAction.stop => 'Stop',
  ShareLimitsAction.remove => 'Remove',
  ShareLimitsAction.removeWithContent => 'Remove with files',
  ShareLimitsAction.enableSuperSeeding => 'Super seeding',
  ShareLimitsAction.unknown => 'Default',
};

String scheduleDaysLabel(TransferScheduleDays d) => switch (d) {
  TransferScheduleDays.everyDay => 'every day',
  TransferScheduleDays.weekdays => 'weekdays',
  TransferScheduleDays.weekends => 'weekends',
  TransferScheduleDays.unknown => '',
  _ => '${d.name[0].toUpperCase()}${d.name.substring(1)}s',
};

/// "Scheduled 08:00–17:00" (+ days unless every day).
String scheduleLabel(TransferSchedule s) {
  final days = s.days == TransferScheduleDays.everyDay ? '' : ' · ${scheduleDaysLabel(s.days)}';
  return 'Scheduled ${s.from}–${s.to}$days';
}

StatusTone connectionTone(TransferConnectionStatus s) => switch (s) {
  TransferConnectionStatus.connected => StatusTone.ok,
  TransferConnectionStatus.firewalled => StatusTone.warning,
  TransferConnectionStatus.disconnected => StatusTone.error,
  TransferConnectionStatus.unknown => StatusTone.neutral,
};

String connectionLabel(TransferConnectionStatus s) => switch (s) {
  TransferConnectionStatus.connected => 'Connected',
  TransferConnectionStatus.firewalled => 'Firewalled',
  TransferConnectionStatus.disconnected => 'Disconnected',
  TransferConnectionStatus.unknown => 'Unknown',
};

StatusTone vpnTone(VpnConnectionState s) => switch (s) {
  VpnConnectionState.connected => StatusTone.ok,
  VpnConnectionState.degraded => StatusTone.warning,
  VpnConnectionState.down => StatusTone.error,
  VpnConnectionState.unknown => StatusTone.neutral,
};

/// "VPN · France · port 36681 ✓" / "VPN down".
String vpnSummary(VpnStatus v) {
  if (v.status == VpnConnectionState.down) return 'VPN down';
  final parts = <String>['VPN', ?v.country];
  if (v.forwardedPort case final p?) {
    parts.add('port $p ${v.portInSync ? '✓' : '✗'}');
  } else {
    parts.add('no forwarded port');
  }
  return parts.join(' · ');
}

String ratioText(double r) => r.toStringAsFixed(2);
