/// Activity `/activity?tab=&import=` (APP.md §6.1): tabs Queue | Torrents |
/// History under the transfer bar; `import=<key>` opens the manual-import
/// sheet of that queue item (the target of `queue.import.<key>` alerts).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/activity_api.dart';
import '../providers/activity_providers.dart';
import '../widgets/add_torrent_form.dart';
import '../widgets/history_tab.dart';
import '../widgets/manual_import_sheet.dart';
import '../widgets/queue_tab.dart';
import '../widgets/torrents_tab.dart';
import '../widgets/transfer_bar.dart';

/// Tab names used in `?tab=`.
const activityTabs = ['queue', 'torrents', 'history'];

class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key, this.tab, this.importKey});

  final String? tab;
  final String? importKey;

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: activityTabs.length,
    vsync: this,
    initialIndex: _indexOf(widget.tab) ?? 0,
  );
  String? _handledImport;

  static int? _indexOf(String? tab) {
    final i = tab == null ? -1 : activityTabs.indexOf(tab);
    return i < 0 ? null : i;
  }

  @override
  void initState() {
    super.initState();
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging && mounted) setState(() {});
    });
    _scheduleImport();
  }

  @override
  void didUpdateWidget(covariant ActivityScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final i = _indexOf(widget.tab);
    if (widget.tab != oldWidget.tab && i != null) _tabs.animateTo(i);
    if (widget.importKey != oldWidget.importKey) _scheduleImport();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _scheduleImport() {
    final key = widget.importKey;
    if (key == null || key.isEmpty || key == _handledImport) return;
    _handledImport = key;
    WidgetsBinding.instance.addPostFrameCallback((_) => _openImport(key));
  }

  Future<void> _openImport(String key) async {
    if (!mounted) return;
    if (!ref.read(isAdminProvider)) {
      context.showSnack('Admins only');
      return;
    }
    _tabs.animateTo(0);
    QueueItem? item;
    try {
      final queue = await ref.read(queueProvider('all').future);
      item = queue.items.where((i) => i.key == key).firstOrNull;
    } catch (e) {
      if (mounted) context.showError(e);
      return;
    }
    if (!mounted) return;
    final entry = item?.importEntry;
    if (item == null || entry == null) {
      context.showSnack('Already resolved');
      return;
    }
    await showManualImportSheet(context, entry: entry, title: item.title);
  }

  Future<void> _refreshQueues() async {
    try {
      await ref.read(activityApiProvider).refreshQueue();
      if (mounted) context.showSnack('Sonarr and Radarr are checking their downloads');
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) ref.invalidate(queueProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final admin = ref.watch(isAdminProvider);
    final onTorrents = _tabs.index == 1;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity'),
        actions: [
          if (admin)
            PopupMenuButton<String>(
              key: const ValueKey('activityMenu'),
              onSelected: (v) => switch (v) {
                'transfer' => context.push(AppPaths.activityTransfer()),
                'refresh' => _refreshQueues(),
                _ => null,
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'transfer', child: Text('Speed limits & session')),
                PopupMenuItem(value: 'refresh', child: Text('Check *arr downloads now')),
              ],
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(130),
          child: Column(
            children: [
              const SizedBox(height: 82, child: Center(child: TransferBar())),
              TabBar(
                controller: _tabs,
                tabs: const [
                  Tab(text: 'Queue'),
                  Tab(text: 'Torrents'),
                  Tab(text: 'History'),
                ],
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: admin && onTorrents
          ? FloatingActionButton.extended(
              key: const ValueKey('addTorrentFab'),
              onPressed: () => showAddTorrentSheet(context),
              icon: const Icon(Icons.add),
              label: const Text('Add torrent'),
            )
          : null,
      body: TabBarView(
        controller: _tabs,
        children: [
          QueueTab(onShowTorrents: () => _tabs.animateTo(1)),
          const TorrentsTab(),
          const HistoryTab(),
        ],
      ),
    );
  }
}
