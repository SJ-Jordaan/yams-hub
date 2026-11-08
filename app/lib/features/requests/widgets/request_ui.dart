/// Labels, colours and small widgets shared by the requests screens.
library;

import 'package:flutter/material.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

IconData mediaTypeIcon(MediaType type) => type == MediaType.tv ? Icons.tv_outlined : Icons.movie_outlined;

String mediaTypeLabel(MediaType type) => type == MediaType.tv ? 'Series' : 'Movie';

/// The *arr a title goes to.
String arrName(MediaType type) => type == MediaType.tv ? 'Sonarr' : 'Radarr';

String availabilityLabel(Availability a) => switch (a) {
  Availability.none => 'Not requested',
  Availability.pending => 'Pending',
  Availability.processing => 'Requested',
  Availability.partial => 'Partially available',
  Availability.available => 'Available',
  Availability.blocklisted => 'Blocklisted',
  Availability.deleted => 'Deleted',
  Availability.unknown => 'Unknown',
};

StatusTone availabilityTone(Availability a) => switch (a) {
  Availability.available => StatusTone.ok,
  Availability.partial || Availability.processing => StatusTone.info,
  Availability.pending => StatusTone.warning,
  Availability.blocklisted => StatusTone.error,
  _ => StatusTone.neutral,
};

/// The corner badge of a poster (APP.md §4.1): Available ✓, Partial
/// half-filled, Requested/Processing clock, Pending hourglass.
class AvailabilityBadge extends StatelessWidget {
  const AvailabilityBadge({super.key, required this.availability});

  final Availability availability;

  /// Null when the title has no Seerr state worth a badge.
  static Widget? maybe(Availability a) => switch (a) {
    Availability.available ||
    Availability.partial ||
    Availability.processing ||
    Availability.pending ||
    Availability.blocklisted => AvailabilityBadge(availability: a),
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    final color = colors.forTone(availabilityTone(availability));
    final icon = switch (availability) {
      Availability.available => Icons.check,
      Availability.partial => Icons.incomplete_circle,
      Availability.pending => Icons.hourglass_top,
      Availability.blocklisted => Icons.block,
      _ => Icons.schedule,
    };
    return Tooltip(
      message: availabilityLabel(availability),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          // A hairline instead of a blurred shadow: no blur pass per poster.
          border: Border.all(color: const Color(0x66000000)),
        ),
        child: Icon(icon, size: 14, color: Colors.white, semanticLabel: availabilityLabel(availability)),
      ),
    );
  }
}

/// What a request row shows as its status (APP.md §4.4): Pending amber,
/// Approved blue, Processing blue (with progress), Available green,
/// Declined grey, Failed red.
({String label, StatusTone tone}) requestDisplay(RequestSummary r) => switch (r.status) {
  RequestStatus.pending => (label: 'Pending', tone: StatusTone.warning),
  RequestStatus.declined => (label: 'Declined', tone: StatusTone.neutral),
  RequestStatus.failed => (label: 'Failed', tone: StatusTone.error),
  RequestStatus.completed => (label: 'Available', tone: StatusTone.ok),
  RequestStatus.approved => switch (r.availability) {
    Availability.available => (label: 'Available', tone: StatusTone.ok),
    Availability.partial => (label: 'Partially available', tone: StatusTone.info),
    Availability.processing when r.downloads.isNotEmpty => (label: 'Downloading', tone: StatusTone.info),
    Availability.processing => (label: 'Processing', tone: StatusTone.info),
    _ => (label: 'Approved', tone: StatusTone.info),
  },
  RequestStatus.unknown => (label: 'Unknown', tone: StatusTone.neutral),
};

String requestStatusLabel(RequestStatus s) => switch (s) {
  RequestStatus.pending => 'Pending',
  RequestStatus.approved => 'Approved',
  RequestStatus.declined => 'Declined',
  RequestStatus.failed => 'Failed',
  RequestStatus.completed => 'Completed',
  RequestStatus.unknown => 'Unknown',
};

StatusTone requestStatusTone(RequestStatus s) => switch (s) {
  RequestStatus.pending => StatusTone.warning,
  RequestStatus.approved => StatusTone.info,
  RequestStatus.declined => StatusTone.neutral,
  RequestStatus.failed => StatusTone.error,
  RequestStatus.completed => StatusTone.ok,
  RequestStatus.unknown => StatusTone.neutral,
};

class RequestStatusChip extends StatelessWidget {
  const RequestStatusChip({super.key, required this.request, this.dense = true});

  final RequestSummary request;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final d = requestDisplay(request);
    return StatusChip(label: d.label, tone: d.tone, dense: dense);
  }
}

/// "S1 S2 S3" (or "S1–S7" for long runs).
String seasonsLabel(List<int> seasons) {
  if (seasons.isEmpty) return '';
  final sorted = [...seasons]..sort();
  final contiguous = sorted.last - sorted.first == sorted.length - 1;
  if (sorted.length > 4 && contiguous) return 'S${sorted.first}–S${sorted.last}';
  return sorted.map((s) => 'S$s').join(' ');
}

String issueTypeLabel(IssueType t) => switch (t) {
  IssueType.video => 'Video',
  IssueType.audio => 'Audio',
  IssueType.subtitles => 'Subtitles',
  IssueType.other => 'Other',
  IssueType.unknown => 'Issue',
};

IconData issueTypeIcon(IssueType t) => switch (t) {
  IssueType.video => Icons.videocam_off_outlined,
  IssueType.audio => Icons.volume_off_outlined,
  IssueType.subtitles => Icons.subtitles_off_outlined,
  _ => Icons.report_problem_outlined,
};

/// "S2E5", "S2" or null for the whole title.
String? issueEpisodeLabel(Issue i) {
  final s = i.season;
  if (s == null) return null;
  final e = i.episode;
  return e == null ? 'S$s' : 'S${s}E$e';
}

/// The quota line under the Request button (APP.md §4.3), or null when the
/// quota is unlimited.
String? quotaLine(QuotaInfo? q, MediaType type) {
  if (q == null || q.isUnlimited) return null;
  final noun = type == MediaType.tv ? 'series' : 'movie';
  final window = switch (q.days) {
    null => '',
    7 => ' this week',
    1 => ' today',
    final d => ' in $d days',
  };
  final remaining = q.remaining ?? (q.limit! - q.used).clamp(0, q.limit!);
  if (remaining <= 0) {
    final resets = q.days == null ? '' : ' (limit ${q.limit} every ${q.days == 1 ? 'day' : '${q.days} days'})';
    return 'No $noun requests left$resets';
  }
  return '$remaining of ${q.limit} $noun requests left$window';
}

/// Whether the quota blocks a new request of [type].
bool quotaBlocks(QuotaInfo? q) {
  if (q == null || q.isUnlimited) return false;
  return q.restricted || (q.remaining ?? 1) <= 0;
}

/// The quota for [type] from the caller's Seerr info.
QuotaInfo? quotaFor(MeSeerrInfo? seerr, MediaType type) {
  final q = seerr?.quota;
  if (q == null) return null;
  return type == MediaType.tv ? q.tv : q.movie;
}

/// The SnackBar text for a create result (APP.md §4.3).
String requestResultMessage(CreateRequestResult r, {required MediaType type, required bool isAdmin}) =>
    switch (r.outcome) {
      CreateRequestOutcome.autoApproved => 'Requested · sent to ${arrName(type)}',
      CreateRequestOutcome.created => isAdmin ? 'Requested' : 'Requested · waiting for approval',
      CreateRequestOutcome.nothingToRequest => 'Everything is already requested',
      CreateRequestOutcome.unknown => 'Requested',
    };

/// The SnackBar text for a failed create: the gateway message, plus the
/// quota line for `quota_exceeded`.
String requestErrorMessage(Object error, MediaType type) {
  final e = ApiException.from(error);
  if (e.code == ApiErrorCode.quotaExceeded) {
    final raw = e.details?['quota'];
    if (raw is Map<String, Object?>) {
      final quota = SeerrQuota.fromJson(raw);
      final line = quotaLine(type == MediaType.tv ? quota.tv : quota.movie, type);
      if (line != null) return '${e.message} $line.';
    }
  }
  return e.message;
}

/// A round Seerr avatar with the initial as fallback.
class SeerrAvatar extends StatelessWidget {
  const SeerrAvatar({super.key, required this.name, this.path, this.size = 24});

  final String name;
  final String? path;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: path == null
            ? ColoredBox(
                color: scheme.secondaryContainer,
                child: Center(
                  child: Text(
                    initial,
                    style: TextStyle(fontSize: size * 0.45, color: scheme.onSecondaryContainer),
                  ),
                ),
              )
            : HubImage(path, width: size, height: size, placeholderIcon: Icons.person_outline),
      ),
    );
  }
}
