/// A list over a [PagedController] provider: skeleton, error, empty, stale
/// banner, pull-to-refresh and load-more near the end.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/widgets/widgets.dart';

import '../providers/requests_providers.dart';

class PagedListView<T> extends ConsumerStatefulWidget {
  const PagedListView({
    super.key,
    required this.value,
    required this.controller,
    required this.itemBuilder,
    required this.empty,
    this.header,
    this.onRetry,
  });

  final AsyncValue<PagedItems<T>> value;
  final PagedController<T> Function() controller;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final Widget empty;
  final Widget? header;
  final VoidCallback? onRetry;

  @override
  ConsumerState<PagedListView<T>> createState() => _PagedListViewState<T>();
}

class _PagedListViewState<T> extends ConsumerState<PagedListView<T>> {
  Object? _moreError;
  bool _loadingMore = false;

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    try {
      await widget.controller().loadMore();
    } catch (e) {
      if (mounted) setState(() => _moreError = e);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _refresh() async {
    setState(() => _moreError = null);
    try {
      await widget.controller().refresh();
    } catch (_) {
      // The stale banner (or the error view) reports it.
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.value;
    final data = v.value;
    final header = widget.header;
    final Widget body;
    if (data == null && v.hasError) {
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          ?header,
          ErrorView(error: v.error!, onRetry: widget.onRetry),
        ],
      );
    } else if (data == null) {
      const skeleton = SkeletonList(count: 6, leadingSize: 48);
      body = header == null
          ? skeleton
          : Column(
              children: [
                header,
                const Expanded(child: skeleton),
              ],
            );
    } else if (data.items.isEmpty) {
      body = LayoutBuilder(
        builder: (context, c) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            ?header,
            ConstrainedBox(
              constraints: BoxConstraints(minHeight: c.maxHeight * 0.7),
              child: Center(child: widget.empty),
            ),
          ],
        ),
      );
    } else {
      final extra = (header == null ? 0 : 1);
      body = NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.extentAfter < 400 && data.hasMore && _moreError == null) _loadMore();
          return false;
        },
        child: ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: data.items.length + extra + 1,
          separatorBuilder: (context, i) => i < extra ? const SizedBox.shrink() : const Divider(height: 1, indent: 76),
          itemBuilder: (context, i) {
            if (i < extra) return header!;
            final index = i - extra;
            if (index < data.items.length) return widget.itemBuilder(context, data.items[index]);
            if (!data.hasMore) return const SizedBox(height: 32);
            if (_moreError != null) {
              return Center(
                child: TextButton.icon(
                  onPressed: _loadMore,
                  icon: const Icon(Icons.refresh),
                  label: const Text("Couldn't load more · Retry"),
                ),
              );
            }
            if (!_loadingMore) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _loadMore() : null);
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          },
        ),
      );
    }
    return Column(
      children: [
        if (data != null && v.hasError) StaleBanner(onRetry: widget.onRetry),
        Expanded(
          child: RefreshIndicator(onRefresh: _refresh, child: body),
        ),
      ],
    );
  }
}
