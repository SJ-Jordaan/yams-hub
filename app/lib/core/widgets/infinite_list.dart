import 'dart:async';

import 'package:flutter/material.dart';
import 'package:yams_models/yams_models.dart';

import '../api/api_exception.dart';
import 'empty_view.dart';
import 'error_view.dart';
import 'skeleton.dart';

/// One loaded page of an [InfiniteList]: its items and the key of the next
/// page (null at the end).
class InfinitePage<T> {
  const InfinitePage(this.items, this.next);

  final List<T> items;
  final Object? next;
}

/// Loads the page for [key] (null = first page).
typedef InfiniteLoader<T> = Future<InfinitePage<T>> Function(Object? key);

/// A scrolling list that loads more pages near its end, over the gateway's
/// [PagedList] (page-based) or [CursorPage] (cursor-based) envelopes.
///
/// First load shows a skeleton, a failed first load an [ErrorView], an empty
/// result [empty]. A failed "load more" shows a retry row. Pull-to-refresh
/// reloads from the first page; so does changing [resetKey] (filters). An
/// expired cursor (`400 bad_request`, `details.reason: "cursor"`) restarts
/// from the first page.
class InfiniteList<T> extends StatefulWidget {
  const InfiniteList({
    super.key,
    required this.load,
    required this.itemBuilder,
    this.empty,
    this.separatorBuilder,
    this.padding,
    this.header,
    this.loading,
    this.resetKey,
    this.controller,
  });

  /// Page-based list over `PagedList<T>` (`page` starts at 1).
  static InfiniteList<T> paged<T>({
    Key? key,
    required Future<PagedList<T>> Function(int page) fetchPage,
    required Widget Function(BuildContext context, T item, int index) itemBuilder,
    Widget? empty,
    IndexedWidgetBuilder? separatorBuilder,
    EdgeInsetsGeometry? padding,
    Widget? header,
    Widget? loading,
    Object? resetKey,
    ScrollController? controller,
  }) => InfiniteList<T>(
    key: key,
    load: (k) async {
      final page = k is int ? k : 1;
      final result = await fetchPage(page);
      return InfinitePage(result.items, result.hasMore ? page + 1 : null);
    },
    itemBuilder: itemBuilder,
    empty: empty,
    separatorBuilder: separatorBuilder,
    padding: padding,
    header: header,
    loading: loading,
    resetKey: resetKey,
    controller: controller,
  );

  /// Cursor-based list over `CursorPage<T>`.
  static InfiniteList<T> cursor<T>({
    Key? key,
    required Future<CursorPage<T>> Function(String? cursor) fetchPage,
    required Widget Function(BuildContext context, T item, int index) itemBuilder,
    Widget? empty,
    IndexedWidgetBuilder? separatorBuilder,
    EdgeInsetsGeometry? padding,
    Widget? header,
    Widget? loading,
    Object? resetKey,
    ScrollController? controller,
  }) => InfiniteList<T>(
    key: key,
    load: (k) async {
      final result = await fetchPage(k is String ? k : null);
      return InfinitePage(result.items, result.nextCursor);
    },
    itemBuilder: itemBuilder,
    empty: empty,
    separatorBuilder: separatorBuilder,
    padding: padding,
    header: header,
    loading: loading,
    resetKey: resetKey,
    controller: controller,
  );

  final InfiniteLoader<T> load;
  final Widget Function(BuildContext context, T item, int index) itemBuilder;
  final Widget? empty;
  final IndexedWidgetBuilder? separatorBuilder;
  final EdgeInsetsGeometry? padding;

  /// Scrolls with the list, above the first item.
  final Widget? header;
  final Widget? loading;
  final Object? resetKey;
  final ScrollController? controller;

  @override
  State<InfiniteList<T>> createState() => _InfiniteListState<T>();
}

class _InfiniteListState<T> extends State<InfiniteList<T>> {
  final List<T> _items = [];
  Object? _next;
  bool _done = false;
  bool _loading = false;
  bool _firstLoaded = false;
  Object? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMore());
  }

  @override
  void didUpdateWidget(covariant InfiniteList<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetKey != widget.resetKey) unawaited(_reload());
  }

  Future<void> _reload() async {
    _generation++;
    setState(() {
      _items.clear();
      _next = null;
      _done = false;
      _loading = false;
      _firstLoaded = false;
      _error = null;
    });
    await _loadMore();
  }

  static bool _isExpiredCursor(Object error) {
    final e = ApiException.tryFrom(error);
    return e != null && e.status == 400 && e.details?['reason'] == 'cursor';
  }

  Future<void> _loadMore() async {
    if (_loading || _done) return;
    final generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.load(_next);
      if (!mounted || generation != _generation) return;
      setState(() {
        _items.addAll(page.items);
        _next = page.next;
        _done = page.next == null;
        _loading = false;
        _firstLoaded = true;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      if (_next != null && _isExpiredCursor(e)) {
        _loading = false;
        await _reload();
        return;
      }
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (!_firstLoaded && _error != null) {
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (widget.header != null) widget.header!,
          ErrorView(error: _error!, onRetry: _loadMore),
        ],
      );
    } else if (!_firstLoaded) {
      body = widget.loading ?? const SkeletonList();
    } else if (_items.isEmpty) {
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (widget.header != null) widget.header!,
          widget.empty ?? const EmptyView(icon: Icons.inbox_outlined, title: 'Nothing here'),
        ],
      );
    } else {
      final hasHeader = widget.header != null;
      final offset = hasHeader ? 1 : 0;
      final count = _items.length + offset + 1; // + footer
      body = ListView.separated(
        controller: widget.controller,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: widget.padding,
        itemCount: count,
        separatorBuilder: (context, index) {
          final itemIndex = index - offset;
          if (itemIndex < 0 || itemIndex >= _items.length - 1 || widget.separatorBuilder == null) {
            return const SizedBox.shrink();
          }
          return widget.separatorBuilder!(context, itemIndex);
        },
        itemBuilder: (context, index) {
          if (hasHeader && index == 0) return widget.header!;
          final itemIndex = index - offset;
          if (itemIndex < _items.length) {
            if (itemIndex >= _items.length - 5 && !_done && !_loading && _error == null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) unawaited(_loadMore());
              });
            }
            return widget.itemBuilder(context, _items[itemIndex], itemIndex);
          }
          return _Footer(loading: _loading, error: _error, onRetry: _loadMore);
        },
      );
    }
    return RefreshIndicator(onRefresh: _reload, child: body);
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.loading, required this.error, required this.onRetry});

  final bool loading;
  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    if (error != null) {
      return ListTile(
        leading: const Icon(Icons.error_outline),
        title: Text(ApiException.from(error!).message),
        trailing: TextButton(onPressed: onRetry, child: const Text('Retry')),
      );
    }
    return const SizedBox(height: 16);
  }
}
