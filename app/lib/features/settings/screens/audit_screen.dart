/// `/settings/audit` (admin): the audit log (`GET /admin/audit`), newest first,
/// filtered by user, action prefix and outcome; tap a row for its params
/// (APP.md §13).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/settings_api.dart';
import '../providers/settings_providers.dart';

/// Action prefixes offered as quick filters (`<feature>.`, ARCHITECTURE §5.13).
const auditActionPrefixes = [
  'auth.',
  'admin.',
  'requests.',
  'library.',
  'activity.',
  'containers.',
  'indexers.',
  'subtitles.',
  'media.',
  'system.',
];

class AuditScreen extends ConsumerStatefulWidget {
  const AuditScreen({super.key});

  @override
  ConsumerState<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends ConsumerState<AuditScreen> {
  AuditFilter _filter = const AuditFilter();
  final _action = TextEditingController();

  @override
  void dispose() {
    _action.dispose();
    super.dispose();
  }

  void _setAction(String? prefix) {
    _action.text = prefix ?? '';
    setState(() => _filter = _filter.copyWith(actionPrefix: () => (prefix ?? '').isEmpty ? null : prefix));
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(settingsApiProvider);
    final users = ref.watch(usersProvider).value ?? const <User>[];
    final usernames = {for (final u in users) u.id: u.displayName};

    return Scaffold(
      appBar: AppBar(
        title: const Text('Audit log'),
        actions: [
          if (!_filter.isEmpty)
            TextButton(
              onPressed: () {
                _action.clear();
                setState(() => _filter = const AuditFilter());
              },
              child: const Text('Clear filters'),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    key: ValueKey('audit-user-${_filter.userId}-${users.length}'),
                    initialValue: _filter.userId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'User', isDense: true),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('All users')),
                      for (final u in users) DropdownMenuItem<String?>(value: u.id, child: Text(u.displayName)),
                    ],
                    onChanged: (id) => setState(() => _filter = _filter.copyWith(userId: () => id)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const Key('audit-action'),
                    controller: _action,
                    autocorrect: false,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      labelText: 'Action starts with',
                      hintText: 'library.',
                      isDense: true,
                    ),
                    onSubmitted: (v) => _setAction(v.trim()),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          FilterChipsBar<String>(
            options: auditActionPrefixes,
            selected: {?_filter.actionPrefix},
            allowDeselect: true,
            labelOf: (p) => p.substring(0, p.length - 1),
            onSelected: _setAction,
          ),
          FilterChipsBar<AuditOutcome>(
            options: const [AuditOutcome.ok, AuditOutcome.error],
            selected: {?_filter.outcome},
            allowDeselect: true,
            labelOf: (o) => o == AuditOutcome.ok ? 'Succeeded' : 'Failed',
            onSelected: (o) => setState(() => _filter = _filter.copyWith(outcome: () => o)),
          ),
          const Divider(height: 1),
          Expanded(
            child: InfiniteList.paged<AuditEntry>(
              resetKey: _filter,
              fetchPage: (page) => api.audit(page: page, filter: _filter),
              separatorBuilder: (_, _) => const Divider(height: 1),
              padding: const EdgeInsets.only(bottom: 24),
              empty: EmptyView(
                icon: Icons.receipt_long_outlined,
                title: _filter.isEmpty ? 'No audit entries yet' : 'No matching entries',
                message: _filter.isEmpty
                    ? 'Every change made through the hub is recorded here.'
                    : 'Try a different user, action or outcome.',
              ),
              itemBuilder: (context, e, _) => AuditTile(
                entry: e,
                username: e.username ?? usernames[e.userId],
                onTap: () => showAuditEntry(context, e),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One audit row: action, user · target, time, outcome chip.
class AuditTile extends StatelessWidget {
  const AuditTile({super.key, required this.entry, this.username, this.onTap});

  final AuditEntry entry;
  final String? username;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final who = username ?? (entry.userId == null ? 'anonymous' : entry.userId!);
    return ListTile(
      key: Key('audit-${entry.id}'),
      onTap: onTap,
      title: Text(entry.action, style: theme.textTheme.bodyLarge?.copyWith(fontFamily: 'monospace')),
      subtitle: Text(
        [who, ?entry.target].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          AuditOutcomeChip(entry: entry),
          const SizedBox(height: 4),
          Tooltip(
            message: formatDateTime(entry.at),
            child: Text(formatRelative(entry.at), style: theme.textTheme.labelSmall),
          ),
        ],
      ),
    );
  }
}

class AuditOutcomeChip extends StatelessWidget {
  const AuditOutcomeChip({super.key, required this.entry});

  final AuditEntry entry;

  @override
  Widget build(BuildContext context) => switch (entry.outcome) {
    AuditOutcome.ok => const StatusChip(label: 'OK', tone: StatusTone.ok, dense: true),
    AuditOutcome.error => StatusChip(label: entry.errorCode ?? 'Error', tone: StatusTone.error, dense: true),
    AuditOutcome.unknown => const StatusChip(label: 'Unknown', dense: true),
  };
}

/// The entry's fields and its `params` as pretty-printed JSON.
Future<void> showAuditEntry(BuildContext context, AuditEntry e) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) {
    final theme = Theme.of(context);
    final json = e.params == null ? null : const JsonEncoder.withIndent('  ').convert(e.params);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          Row(
            children: [
              Expanded(
                child: SelectableText(e.action, style: theme.textTheme.titleMedium?.copyWith(fontFamily: 'monospace')),
              ),
              AuditOutcomeChip(entry: e),
            ],
          ),
          const SizedBox(height: 12),
          KeyValueList(
            labelWidth: 110,
            entries: [
              KeyValue('Time', formatDateTime(e.at)),
              KeyValue('User', e.username ?? e.userId),
              KeyValue('Target', e.target),
              KeyValue('Error', e.errorCode),
              KeyValue('Duration', '${e.durationMs} ms'),
              KeyValue('IP', e.ip),
              KeyValue('Session', e.sessionId),
              KeyValue('Entry id', e.id),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: Text('Parameters', style: theme.textTheme.titleSmall)),
              if (json != null)
                IconButton(
                  tooltip: 'Copy',
                  icon: const Icon(Icons.copy, size: 20),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: json));
                    if (context.mounted) context.showSnack('Copied');
                  },
                ),
            ],
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              json ?? 'No parameters',
              key: const Key('audit-params'),
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  },
);
