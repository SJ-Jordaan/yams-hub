/// One row of the requests list (APP.md §4.4).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import 'request_actions.dart';
import 'request_ui.dart';

/// Which row actions a [RequestTile] offers.
enum RequestTileActions {
  /// None (dashboard rows of members).
  none,

  /// Approve / Decline only (the admin's dashboard rows, APP.md §3.3).
  decide,

  /// Every action the request allows (the requests list).
  all,
}

class RequestTile extends ConsumerStatefulWidget {
  const RequestTile({
    super.key,
    required this.request,
    this.compact = false,
    RequestTileActions? actions,
    this.onActionDone,
  }) : actions = actions ?? (compact ? RequestTileActions.none : RequestTileActions.all);

  final RequestSummary request;

  /// Dashboard card rows: smaller poster, no progress bar.
  final bool compact;

  /// The row actions; by default none when [compact], else all.
  final RequestTileActions actions;

  /// Called after an action succeeded (the dashboard refreshes its card).
  final VoidCallback? onActionDone;

  @override
  ConsumerState<RequestTile> createState() => _RequestTileState();
}

class _RequestTileState extends ConsumerState<RequestTile> {
  bool _busy = false;

  RequestSummary get r => widget.request;

  Future<void> _run(RequestAction action) async {
    setState(() => _busy = true);
    final ok = await runRequestAction(context, ref, r, action);
    if (ok) widget.onActionDone?.call();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final seasons = [for (final s in r.seasons) s.seasonNumber];
    final download = r.downloads.firstOrNull;
    final posterWidth = widget.compact ? 36.0 : 48.0;
    final actions = _actions();
    return InkWell(
      // Dashboard rows live in the Home branch: switch branches with go.
      onTap: () =>
          widget.compact ? context.go(AppPaths.requestDetail(r.id)) : context.push(AppPaths.requestDetail(r.id)),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: widget.compact ? 0 : 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: posterWidth,
              child: AspectRatio(
                aspectRatio: 2 / 3,
                child: HubImage(
                  r.posterPath,
                  width: posterWidth,
                  height: posterWidth * 3 / 2,
                  borderRadius: BorderRadius.circular(8),
                  placeholderIcon: mediaTypeIcon(r.mediaType),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.year == null ? r.title : '${r.title} (${r.year})',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Icon(mediaTypeIcon(r.mediaType), size: 16, color: theme.colorScheme.onSurfaceVariant),
                      RequestStatusChip(request: r),
                      if (seasons.isNotEmpty) Text(seasonsLabel(seasons), style: muted),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      SeerrAvatar(name: r.requestedBy.displayName, path: r.requestedBy.avatarPath, size: 18),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Tooltip(
                          message: formatDateTime(r.createdAt),
                          child: Text(
                            '${r.requestedBy.displayName} · ${formatRelative(r.createdAt)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (download != null && !widget.compact)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: ProgressBar(
                        value: download.progress,
                        trailing: [
                          formatPercent(download.progress * 100),
                          if (download.etaSeconds != null) formatEta(download.etaSeconds),
                        ].join(' · '),
                      ),
                    ),
                ],
              ),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              ...actions,
          ],
        ),
      ),
    );
  }

  List<Widget> _actions() {
    if (widget.actions == RequestTileActions.none) return const [];
    final all = widget.actions == RequestTileActions.all;
    final colors = Theme.of(context).colorScheme;
    final overflow = [if (all && r.canDelete) RequestAction.delete];
    return [
      if (r.canApprove)
        IconButton(
          tooltip: 'Approve',
          color: colors.primary,
          icon: const Icon(Icons.check_circle_outline),
          onPressed: () => _run(RequestAction.approve),
        ),
      if (r.canDecline)
        IconButton(
          tooltip: 'Decline',
          icon: const Icon(Icons.highlight_off),
          onPressed: () => _run(RequestAction.decline),
        ),
      if (all && r.canRetry)
        IconButton(tooltip: 'Retry', icon: const Icon(Icons.refresh), onPressed: () => _run(RequestAction.retry)),
      if (overflow.isNotEmpty)
        PopupMenuButton<RequestAction>(
          tooltip: 'More',
          onSelected: _run,
          itemBuilder: (_) => [
            for (final a in overflow)
              PopupMenuItem(
                value: a,
                child: ListTile(leading: Icon(a.icon), title: Text(a.label), contentPadding: EdgeInsets.zero),
              ),
          ],
        ),
    ];
  }
}
