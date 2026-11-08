/// Issues `/requests/issues` and `/requests/issues/:id` (APP.md §4.5).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/requests_api.dart';
import '../providers/requests_providers.dart';
import '../widgets/paged_list_view.dart';
import '../widgets/request_ui.dart';

const _notLinkedHint = 'Link your account to Seerr to comment';

String _filterLabel(IssuesFilter f) => switch (f) {
  IssuesFilter.open => 'Open',
  IssuesFilter.resolved => 'Resolved',
  IssuesFilter.all => 'All',
};

/// Whether the caller can write to issues (admins, or linked members).
bool _canWrite(WidgetRef ref) => ref.watch(isAdminProvider) || (ref.watch(seerrInfoProvider)?.linked ?? false);

class IssuesScreen extends ConsumerStatefulWidget {
  const IssuesScreen({super.key});

  @override
  ConsumerState<IssuesScreen> createState() => _IssuesScreenState();
}

class _IssuesScreenState extends ConsumerState<IssuesScreen> {
  IssuesFilter _filter = IssuesFilter.open;

  @override
  Widget build(BuildContext context) {
    final provider = issuesListProvider(_filter);
    final linkedKnown = ref.watch(seerrInfoProvider) != null;
    final readOnly = linkedKnown && !_canWrite(ref);
    return Scaffold(
      appBar: AppBar(title: const Text('Issues')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: FilterChipsBar<IssuesFilter>(
              options: IssuesFilter.values,
              selected: {_filter},
              labelOf: _filterLabel,
              onSelected: (f) => setState(() => _filter = f ?? IssuesFilter.open),
            ),
          ),
          if (readOnly) const _Hint(icon: Icons.link_off, text: _notLinkedHint),
          Expanded(
            child: PagedListView<Issue>(
              key: ValueKey(_filter),
              value: ref.watch(provider),
              controller: () => ref.read(provider.notifier),
              onRetry: () => ref.invalidate(provider),
              empty: EmptyView(
                icon: Icons.task_alt,
                title: switch (_filter) {
                  IssuesFilter.open => 'No open issues',
                  IssuesFilter.resolved => 'No resolved issues',
                  IssuesFilter.all => 'No issues reported',
                },
                message: 'Report a problem from a title page.',
              ),
              itemBuilder: (context, issue) => _IssueTile(issue: issue),
            ),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
          ],
        ),
      ),
    );
  }
}

class _IssueTile extends StatelessWidget {
  const _IssueTile({required this.issue});

  final Issue issue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final episode = issueEpisodeLabel(issue);
    return InkWell(
      onTap: () => context.push(AppPaths.issueDetail(issue.id)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 48,
              child: AspectRatio(
                aspectRatio: 2 / 3,
                child: HubImage(
                  issue.posterPath,
                  borderRadius: BorderRadius.circular(8),
                  placeholderIcon: mediaTypeIcon(issue.mediaType),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(issue.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Icon(issueTypeIcon(issue.type), size: 16, color: theme.colorScheme.onSurfaceVariant),
                      Text(issueTypeLabel(issue.type), style: muted),
                      if (episode != null) Text(episode, style: muted),
                      if (issue.status == IssueStatus.resolved)
                        const StatusChip(label: 'Resolved', tone: StatusTone.ok, dense: true),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${issue.createdBy.displayName} · ${formatRelative(issue.createdAt)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
                ],
              ),
            ),
            if (issue.commentCount > 0)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.chat_bubble_outline, size: 16, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text('${issue.commentCount}', style: theme.textTheme.labelMedium),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// `/requests/issues/:id`: the thread, the compose field and resolve/reopen.
class IssueDetailScreen extends ConsumerStatefulWidget {
  const IssueDetailScreen({super.key, required this.id});

  final int id;

  @override
  ConsumerState<IssueDetailScreen> createState() => _IssueDetailScreenState();
}

class _IssueDetailScreenState extends ConsumerState<IssueDetailScreen> {
  final _compose = TextEditingController();
  bool _sending = false;
  bool _changingStatus = false;

  @override
  void dispose() {
    _compose.dispose();
    super.dispose();
  }

  IssueController get _controller => ref.read(issueProvider(widget.id).notifier);

  void _snack(String text) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _send() async {
    final text = _compose.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await _controller.comment(text);
      _compose.clear();
    } catch (e) {
      if (mounted) _snack(ApiException.from(e).message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _setStatus(bool resolve) async {
    setState(() => _changingStatus = true);
    try {
      await (resolve ? _controller.resolve() : _controller.reopen());
      if (mounted) _snack(resolve ? 'Issue resolved' : 'Issue reopened');
    } catch (e) {
      if (mounted) _snack(ApiException.from(e).message);
    } finally {
      if (mounted) setState(() => _changingStatus = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(issueProvider(widget.id));
    final issue = value.value;
    final isAdmin = ref.watch(isAdminProvider);
    final seerr = ref.watch(seerrInfoProvider);
    final canWrite = _canWrite(ref);
    final isCreator = issue != null && seerr?.seerrUserId != null && seerr!.seerrUserId == issue.createdBy.id;
    final canChangeStatus = issue != null && canWrite && (isAdmin || isCreator);
    return Scaffold(
      appBar: AppBar(
        title: Text(issue?.title ?? 'Issue'),
        actions: [
          if (canChangeStatus)
            _changingStatus
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : issue.status == IssueStatus.resolved
                ? TextButton(onPressed: () => _setStatus(false), child: const Text('Reopen'))
                : TextButton(onPressed: () => _setStatus(true), child: const Text('Resolve')),
        ],
      ),
      body: AsyncValueView(
        value: value,
        onRetry: () => ref.invalidate(issueProvider(widget.id)),
        data: (context, issue) => Column(
          children: [
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(issueProvider(widget.id));
                  try {
                    await ref.read(issueProvider(widget.id).future);
                  } catch (_) {}
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  children: [
                    _IssueHeader(issue: issue),
                    const SizedBox(height: 16),
                    if (issue.comments.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: Text('No comments yet')),
                      )
                    else
                      for (final c in issue.comments)
                        _CommentBubble(comment: c, own: c.author.id == seerr?.seerrUserId),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            SafeArea(
              top: false,
              child: canWrite
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _compose,
                              enabled: !_sending,
                              minLines: 1,
                              maxLines: 4,
                              maxLength: 2000,
                              textCapitalization: TextCapitalization.sentences,
                              decoration: const InputDecoration(
                                hintText: 'Add a comment',
                                border: OutlineInputBorder(),
                                isDense: true,
                                counterText: '',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filled(
                            tooltip: 'Send',
                            onPressed: _sending ? null : _send,
                            icon: _sending
                                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.send),
                          ),
                        ],
                      ),
                    )
                  : const _Hint(icon: Icons.link_off, text: _notLinkedHint),
            ),
          ],
        ),
      ),
    );
  }
}

class _IssueHeader extends StatelessWidget {
  const _IssueHeader({required this.issue});

  final Issue issue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final episode = issueEpisodeLabel(issue);
    final resolved = issue.status == IssueStatus.resolved;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => context.push(AppPaths.title(issue.mediaType.name, issue.tmdbId)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: AspectRatio(
              aspectRatio: 2 / 3,
              child: HubImage(
                issue.posterPath,
                borderRadius: BorderRadius.circular(8),
                placeholderIcon: mediaTypeIcon(issue.mediaType),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(issue.title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    StatusChip(
                      label: resolved ? 'Resolved' : 'Open',
                      tone: resolved ? StatusTone.ok : StatusTone.warning,
                      dense: true,
                    ),
                    StatusChip(label: issueTypeLabel(issue.type), icon: issueTypeIcon(issue.type), dense: true),
                    if (episode != null) Text(episode, style: theme.textTheme.bodySmall),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Reported by ${issue.createdBy.displayName} · ${formatRelative(issue.createdAt)}',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CommentBubble extends StatelessWidget {
  const _CommentBubble({required this.comment, required this.own});

  final IssueComment comment;
  final bool own;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SeerrAvatar(name: comment.author.displayName, path: comment.author.avatarPath, size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: own ? scheme.primaryContainer : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(comment.author.displayName, style: theme.textTheme.labelLarge)),
                      Tooltip(
                        message: formatDateTime(comment.createdAt),
                        child: Text(formatRelative(comment.createdAt), style: theme.textTheme.labelSmall),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SelectableText(comment.message, style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
