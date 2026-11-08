/// Requests list `/requests/list?tab=` and request detail
/// `/requests/list/:id` (APP.md §4.4).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/links/external_links.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/requests_providers.dart';
import '../widgets/paged_list_view.dart';
import '../widgets/request_actions.dart';
import '../widgets/request_tile.dart';
import '../widgets/request_ui.dart';

class RequestsListScreen extends ConsumerWidget {
  const RequestsListScreen({super.key, this.tab});

  /// The `tab` query parameter.
  final String? tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin = ref.watch(isAdminProvider);
    final tabs = RequestsTab.visible(isAdmin: isAdmin);
    if (tabs.length == 1) {
      return Scaffold(
        appBar: AppBar(title: const Text('My requests')),
        body: _RequestsTabView(tab: tabs.single),
      );
    }
    final initial = tabs.indexOf(RequestsTab.fromName(tab) ?? RequestsTab.pending).clamp(0, tabs.length - 1);
    final counts = ref.watch(requestCountsProvider).value;
    String label(RequestsTab t) {
      final n = switch (t) {
        RequestsTab.pending => counts?.pending,
        RequestsTab.failed => counts?.failed,
        _ => null,
      };
      return n == null || n == 0 ? t.label : '${t.label} ($n)';
    }

    return DefaultTabController(
      key: ValueKey(initial),
      length: tabs.length,
      initialIndex: initial,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Requests'),
          bottom: TabBar(
            isScrollable: MediaQuery.sizeOf(context).width < 360,
            tabs: [for (final t in tabs) Tab(text: label(t))],
          ),
        ),
        body: TabBarView(children: [for (final t in tabs) _RequestsTabView(tab: t)]),
      ),
    );
  }
}

class _RequestsTabView extends ConsumerWidget {
  const _RequestsTabView({required this.tab});

  final RequestsTab tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = requestsListProvider(tab);
    final isAdmin = ref.watch(isAdminProvider);
    final swipe = isAdmin && tab == RequestsTab.pending && MediaQuery.sizeOf(context).width < 600;
    return PagedListView<RequestSummary>(
      value: ref.watch(provider),
      controller: () => ref.read(provider.notifier),
      onRetry: () => ref.invalidate(provider),
      empty: switch (tab) {
        RequestsTab.pending => const EmptyView(icon: Icons.inbox_outlined, title: 'No requests waiting'),
        RequestsTab.mine => EmptyView(
          icon: Icons.movie_filter_outlined,
          title: "You haven't requested anything yet",
          action: FilledButton(onPressed: () => context.go(AppPaths.requests()), child: const Text('Discover')),
        ),
        RequestsTab.failed => const EmptyView(icon: Icons.check_circle_outline, title: 'No failed requests'),
        RequestsTab.all => const EmptyView(icon: Icons.inbox_outlined, title: 'No requests yet'),
      },
      itemBuilder: (context, r) {
        final tile = RequestTile(key: ValueKey(r.id), request: r);
        if (!swipe || !r.canApprove) return tile;
        return _SwipeToDecide(
          request: r,
          onDone: () => ref.read(provider.notifier).removeLocally((i) => i.id == r.id),
          child: tile,
        );
      },
    );
  }
}

/// Phones, pending tab: swipe right to approve, left to decline (confirmed).
class _SwipeToDecide extends ConsumerWidget {
  const _SwipeToDecide({required this.request, required this.onDone, required this.child});

  final RequestSummary request;
  final VoidCallback onDone;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = StatusColors.of(context);
    Widget background(Color color, IconData icon, String label, Alignment align) => ColoredBox(
      color: color,
      child: Align(
        alignment: align,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
    return Dismissible(
      key: ValueKey('swipe-${request.id}'),
      background: background(colors.ok, Icons.check, 'Approve', Alignment.centerLeft),
      secondaryBackground: background(colors.error, Icons.close, 'Decline', Alignment.centerRight),
      confirmDismiss: (direction) => runRequestAction(
        context,
        ref,
        request,
        direction == DismissDirection.startToEnd ? RequestAction.approve : RequestAction.decline,
      ),
      onDismissed: (_) => onDone(),
      child: child,
    );
  }
}

/// `/requests/list/:id`.
class RequestDetailScreen extends ConsumerWidget {
  const RequestDetailScreen({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(requestDetailProvider(id));
    return Scaffold(
      appBar: AppBar(title: Text(value.value?.title ?? 'Request')),
      body: AsyncValueView(
        value: value,
        onRetry: () => ref.invalidate(requestDetailProvider(id)),
        data: (context, r) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(requestDetailProvider(id));
            try {
              await ref.read(requestDetailProvider(id).future);
            } catch (_) {}
          },
          child: _RequestDetailBody(request: r),
        ),
      ),
    );
  }
}

class _RequestDetailBody extends ConsumerStatefulWidget {
  const _RequestDetailBody({required this.request});

  final RequestSummary request;

  @override
  ConsumerState<_RequestDetailBody> createState() => _RequestDetailBodyState();
}

class _RequestDetailBodyState extends ConsumerState<_RequestDetailBody> {
  RequestAction? _running;

  RequestSummary get r => widget.request;

  Future<void> _run(RequestAction action) async {
    setState(() => _running = action);
    final ok = await runRequestAction(context, ref, r, action);
    if (!mounted) return;
    setState(() => _running = null);
    if (ok && action == RequestAction.delete) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final library = r.libraryId;
    final jellyfin = r.jellyfin;
    final actions = [
      for (final a in RequestAction.values)
        if (a.allowedFor(r)) a,
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 96,
              child: AspectRatio(
                aspectRatio: 2 / 3,
                child: HubImage(
                  r.posterPath,
                  borderRadius: BorderRadius.circular(12),
                  placeholderIcon: mediaTypeIcon(r.mediaType),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.title, style: theme.textTheme.titleLarge),
                  Text(
                    [?r.year?.toString(), mediaTypeLabel(r.mediaType)].join(' · '),
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  RequestStatusChip(request: r, dense: false),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => context.push(AppPaths.title(r.mediaType.name, r.tmdbId)),
              icon: const Icon(Icons.info_outline),
              label: const Text('Title details'),
            ),
            if (library != null)
              OutlinedButton.icon(
                onPressed: () => context.go(
                  r.mediaType == MediaType.tv ? AppPaths.seriesDetail(library) : AppPaths.movieDetail(library),
                ),
                icon: const Icon(Icons.video_library_outlined),
                label: const Text('Open in Library'),
              ),
            if (jellyfin != null)
              OutlinedButton.icon(
                onPressed: () => openExternal(ref, jellyfin),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play in Jellyfin'),
              ),
          ],
        ),
        const SizedBox(height: 16),
        KeyValueList(
          entries: [
            KeyValue('Status', requestDisplay(r).label),
            KeyValue('Availability', availabilityLabel(r.availability)),
            KeyValue.widget(
              'Requested by',
              Row(
                children: [
                  SeerrAvatar(name: r.requestedBy.displayName, path: r.requestedBy.avatarPath, size: 20),
                  const SizedBox(width: 8),
                  Flexible(child: Text(r.requestedBy.displayName)),
                ],
              ),
            ),
            KeyValue('Requested', '${formatDateTime(r.createdAt)} (${formatRelative(r.createdAt)})'),
            if (r.modifiedBy case final m?) KeyValue('Modified by', m.displayName),
            KeyValue('Updated', formatRelative(r.updatedAt)),
            if (r.profileName case final p?) KeyValue('Quality profile', p),
          ],
        ),
        if (r.seasons.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Seasons', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in r.seasons)
                StatusChip(
                  label: 'S${s.seasonNumber} · ${requestStatusLabel(s.status)}',
                  tone: requestStatusTone(s.status),
                ),
            ],
          ),
        ],
        for (final d in r.downloads) ...[
          const SizedBox(height: 16),
          ProgressBar(
            value: d.progress,
            label: d.title,
            trailing: [formatPercent(d.progress * 100), if (d.etaSeconds != null) formatEta(d.etaSeconds)].join(' · '),
          ),
        ],
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 24),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final a in actions)
                _ActionButton(action: a, running: _running == a, enabled: _running == null, onPressed: () => _run(a)),
            ],
          ),
        ],
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.action, required this.running, required this.enabled, required this.onPressed});

  final RequestAction action;
  final bool running;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final icon = running
        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(action.icon);
    final onTap = enabled ? onPressed : null;
    return switch (action) {
      RequestAction.approve ||
      RequestAction.retry => FilledButton.icon(onPressed: onTap, icon: icon, label: Text(action.label)),
      RequestAction.delete => TextButton.icon(
        onPressed: onTap,
        icon: icon,
        label: Text(action.label),
        style: TextButton.styleFrom(foregroundColor: StatusColors.of(context).error),
      ),
      RequestAction.decline => OutlinedButton.icon(onPressed: onTap, icon: icon, label: Text(action.label)),
    };
  }
}
