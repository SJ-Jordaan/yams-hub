/// `/library/history/:service/:id` (APP.md §5.5).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/library_api.dart';
import '../providers/library_providers.dart';
import '../widgets/library_widgets.dart';

class LibraryHistoryScreen extends ConsumerWidget {
  const LibraryHistoryScreen({super.key, required this.service, required this.id});

  final ArrService service;
  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(libraryApiProvider);
    final title = service == ArrService.sonarr
        ? ref.watch(seriesDetailProvider(id)).value?.series.title
        : ref.watch(movieDetailProvider(id)).value?.movie.title;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('History'),
            if (title != null) Text(title, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      body: service == ArrService.unknown
          ? const EmptyView(icon: Icons.search_off, title: 'Unknown service')
          : InfiniteList.paged<ArrHistoryItem>(
              fetchPage: (page) => api.history(service, id, page: page),
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
              empty: const EmptyView(icon: Icons.history, title: 'No history yet'),
              itemBuilder: (context, item, _) => LibraryHistoryTile(item: item),
            ),
    );
  }
}
